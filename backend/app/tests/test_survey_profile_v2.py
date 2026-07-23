import json
from datetime import datetime, timedelta, timezone

import jwt

PID = 'a' * 64  # participant ids are 64-hex sha256 digests

TEST_JWT_SECRET = 'test-secret-key-for-testing-only'  # matches conftest


def _token(user_id=1, expired=False, secret=TEST_JWT_SECRET):
    exp = datetime.now(timezone.utc) + (
        timedelta(seconds=-1) if expired else timedelta(minutes=15)
    )
    return jwt.encode({'sub': str(user_id), 'exp': exp}, secret, algorithm='HS256')


def _bearer(token):
    return {'Authorization': f'Bearer {token}'}

# A full v2 profile as the iOS app sends it (snake_case on the wire).
VALID_PROFILE_V2 = {
    'schema_version': 2,
    'participant_id': PID,
    'study_id': 'P99',                       # server-owned — the phone echoes it
    'enrollment_code': '483920',
    'enrolled_at': 1782000000.0,
    'first_open_date': 1782000000.0,         # phone-owned
    'survey_schedule': {                     # server-owned — the phone echoes it
        'cadence': 'daily',
        'weekly_day': None,
        'note': None,
        'updated_at': 1782000000.0,
    },
    'preferences': {'reminder_hour': 20, 'reminder_minute': 0},
    'survey_history': [                       # phone-owned
        {'date': '2026-07-01', 'pain_score': 4, 'completed': True},
    ],
    'sensor_status': [],
    'updated_at': 1782086400.0,
}


class TestGetStudyId:
    def test_returns_assigned_study_id(self, client, mock_db):
        mock_db.get_or_assign_study_id.return_value = 'P01'

        resp = client.get(f'/api/getstudyid/{PID}')

        assert resp.status_code == 200
        assert resp.get_json() == {'study_id': 'P01'}
        # route delegates the assign-or-return (race-safe/idempotent) to the DB
        assert mock_db.get_or_assign_study_id.call_args[0][0] == PID

    def test_returns_existing_id_on_repeat(self, client, mock_db):
        # The DB layer makes this idempotent; the route just surfaces whatever
        # it returns, so a returning participant sees the same id.
        mock_db.get_or_assign_study_id.return_value = 'P07'

        first = client.get(f'/api/getstudyid/{PID}').get_json()
        second = client.get(f'/api/getstudyid/{PID}').get_json()

        assert first == second == {'study_id': 'P07'}


class TestGetUserProfile:
    def test_missing_profile_returns_404(self, client, mock_db):
        mock_db.get_profile_json.return_value = None

        resp = client.get(f'/api/getuserprofile/{PID}')

        assert resp.status_code == 404
        assert resp.get_json()['error'] == 'not_found'

    def test_existing_profile_returned_verbatim(self, client, mock_db):
        stored = '{\n  "schema_version": 2,   "participant_id": "%s"\n}' % PID
        mock_db.get_profile_json.return_value = stored

        resp = client.get(f'/api/getuserprofile/{PID}')

        assert resp.status_code == 200
        assert resp.get_data(as_text=True) == stored
        assert resp.mimetype == 'application/json'


class TestGetSurveyStatus:
    def test_no_schedule_returns_404(self, client, mock_db):
        mock_db.get_survey_schedule.return_value = None

        resp = client.get(f'/api/getsurveystatus/{PID}')

        assert resp.status_code == 404
        assert resp.get_json()['error'] == 'not_found'

    def test_daily_schedule_shape(self, client, mock_db):
        mock_db.get_survey_schedule.return_value = {
            'cadence': 'daily', 'weekly_day': None,
            'note': None, 'updated_at': 1782000000.0,
        }

        resp = client.get(f'/api/getsurveystatus/{PID}')

        assert resp.status_code == 200
        assert resp.get_json() == {
            'cadence': 'daily', 'weekly_day': None,
            'note': None, 'updated_at': 1782000000.0,
        }

    def test_weekly_schedule_includes_day_and_note(self, client, mock_db):
        mock_db.get_survey_schedule.return_value = {
            'cadence': 'weekly', 'weekly_day': 3,
            'note': 'back on Tuesdays', 'updated_at': 1782000000.0,
        }

        resp = client.get(f'/api/getsurveystatus/{PID}')

        assert resp.status_code == 200
        body = resp.get_json()
        assert body['cadence'] == 'weekly'
        assert body['weekly_day'] == 3
        assert body['note'] == 'back on Tuesdays'


class TestUploadUserProfile:
    def _post(self, client, body_bytes, pid=PID):
        return client.post(
            f'/api/uploaduserprofile/{pid}',
            data=body_bytes,
            content_type='application/json',
        )

    def _no_server_overrides(self, mock_db):
        # Default: server has nothing stored, so the sent values are kept.
        mock_db.get_study_id.return_value = None
        mock_db.get_survey_schedule.return_value = None

    def _stored(self, mock_db):
        """Parse the document the route handed to upsert_profile_json."""
        return json.loads(mock_db.upsert_profile_json.call_args[0][1])

    def test_valid_profile_returns_status_ok(self, client, mock_db):
        """The iOS app string-matches {"status": "ok"} before showing 'Backed up'."""
        self._no_server_overrides(mock_db)

        resp = self._post(client, json.dumps(VALID_PROFILE_V2))

        assert resp.status_code == 200
        assert resp.get_json() == {'status': 'ok'}
        # stored under the participant hash with the sent updated_at
        assert mock_db.upsert_profile_json.call_args[0][0] == PID
        assert mock_db.upsert_profile_json.call_args[0][2] == VALID_PROFILE_V2['updated_at']

    def test_phone_owned_fields_stored_as_sent(self, client, mock_db):
        self._no_server_overrides(mock_db)

        self._post(client, json.dumps(VALID_PROFILE_V2))

        stored = self._stored(mock_db)
        assert stored['first_open_date'] == 1782000000.0
        assert stored['survey_history'] == VALID_PROFILE_V2['survey_history']

    def test_server_owned_study_id_is_overwritten(self, client, mock_db):
        # Phone echoes P99; server's stored id is P05 and must win.
        mock_db.get_study_id.return_value = 'P05'
        mock_db.get_survey_schedule.return_value = None

        self._post(client, json.dumps(VALID_PROFILE_V2))

        assert self._stored(mock_db)['study_id'] == 'P05'

    def test_server_owned_schedule_is_overwritten(self, client, mock_db):
        # Phone (stale) sends daily; a coordinator has set weekly — weekly wins,
        # so the stale phone can't revert the coordinator change.
        mock_db.get_study_id.return_value = None
        mock_db.get_survey_schedule.return_value = {
            'cadence': 'weekly', 'weekly_day': 2,
            'note': 'paused review', 'updated_at': 1782500000.0,
        }

        self._post(client, json.dumps(VALID_PROFILE_V2))

        schedule = self._stored(mock_db)['survey_schedule']
        assert schedule['cadence'] == 'weekly'
        assert schedule['weekly_day'] == 2
        assert schedule['updated_at'] == 1782500000.0

    def test_sent_server_fields_kept_when_server_has_none(self, client, mock_db):
        # First upload, before getstudyid / any coordinator schedule: keep sent.
        self._no_server_overrides(mock_db)

        self._post(client, json.dumps(VALID_PROFILE_V2))

        stored = self._stored(mock_db)
        assert stored['study_id'] == 'P99'
        assert stored['survey_schedule']['cadence'] == 'daily'

    def test_schema_version_2_accepted(self, client, mock_db):
        self._no_server_overrides(mock_db)

        resp = self._post(client, json.dumps(VALID_PROFILE_V2))

        assert resp.status_code == 200

    def test_participant_id_mismatch_returns_400(self, client, mock_db):
        self._no_server_overrides(mock_db)
        body = dict(VALID_PROFILE_V2, participant_id='b' * 64)

        resp = self._post(client, json.dumps(body))

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'participant_id_mismatch'
        mock_db.upsert_profile_json.assert_not_called()

    def test_unknown_schema_version_returns_400(self, client, mock_db):
        self._no_server_overrides(mock_db)
        body = dict(VALID_PROFILE_V2, schema_version=99)

        resp = self._post(client, json.dumps(body))

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unsupported_schema_version'
        mock_db.upsert_profile_json.assert_not_called()

    def test_invalid_json_returns_400(self, client, mock_db):
        self._no_server_overrides(mock_db)

        resp = self._post(client, b'{not json')

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'invalid_json'
        mock_db.upsert_profile_json.assert_not_called()

    def test_oversized_body_returns_413(self, client, mock_db):
        self._no_server_overrides(mock_db)
        body = dict(VALID_PROFILE_V2, junk='x' * (300 * 1024))

        resp = self._post(client, json.dumps(body))

        assert resp.status_code == 413
        assert resp.get_json()['error'] == 'payload_too_large'
        mock_db.upsert_profile_json.assert_not_called()

    def test_missing_updated_at_uses_server_time(self, client, mock_db):
        self._no_server_overrides(mock_db)
        body = {k: v for k, v in VALID_PROFILE_V2.items() if k != 'updated_at'}

        resp = self._post(client, json.dumps(body))

        assert resp.status_code == 200
        stored_updated_at = mock_db.upsert_profile_json.call_args[0][2]
        assert isinstance(stored_updated_at, float) and stored_updated_at > 1_700_000_000


class TestProfileAuthEnforcement:
    """REQUIRE_PROFILE_AUTH=on (production, iOS demoMode=false): the profile
    routes require a valid token whose account owns the participant hash.
    With the flag off (the shipped demo default) the routes stay tokenless —
    every other test in this file exercises that path."""

    def _enforce(self, client, mock_db, linked_pid=PID):
        client.application.config['REQUIRE_PROFILE_AUTH'] = True
        client.application.config['JWT_SECRET'] = TEST_JWT_SECRET
        mock_db.get_participant_id_for_user.return_value = linked_pid

    def test_flag_off_is_tokenless(self, client, mock_db):
        # Default demo behaviour: no token required.
        client.application.config['REQUIRE_PROFILE_AUTH'] = False
        mock_db.get_or_assign_study_id.return_value = 'P01'

        resp = client.get(f'/api/getstudyid/{PID}')

        assert resp.status_code == 200

    def test_missing_token_returns_401(self, client, mock_db):
        self._enforce(client, mock_db)

        resp = client.get(f'/api/getstudyid/{PID}')

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'missing_token'

    def test_expired_token_returns_401(self, client, mock_db):
        self._enforce(client, mock_db)

        resp = client.get(f'/api/getstudyid/{PID}', headers=_bearer(_token(expired=True)))

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'token_expired'

    def test_valid_token_owning_participant_allowed(self, client, mock_db):
        self._enforce(client, mock_db, linked_pid=PID)
        mock_db.get_or_assign_study_id.return_value = 'P01'

        resp = client.get(f'/api/getstudyid/{PID}', headers=_bearer(_token()))

        assert resp.status_code == 200
        assert resp.get_json() == {'study_id': 'P01'}

    def test_valid_token_wrong_participant_forbidden(self, client, mock_db):
        # Token's account is linked to a different participant hash.
        self._enforce(client, mock_db, linked_pid='c' * 64)

        resp = client.get(f'/api/getstudyid/{PID}', headers=_bearer(_token()))

        assert resp.status_code == 403
        assert resp.get_json()['error'] == 'forbidden'
        mock_db.get_or_assign_study_id.assert_not_called()

    def test_unlinked_account_forbidden(self, client, mock_db):
        # Valid token, but no account_participants row (should never happen
        # post-login, but must not fall open).
        self._enforce(client, mock_db, linked_pid=None)

        resp = client.get(f'/api/getstudyid/{PID}', headers=_bearer(_token()))

        assert resp.status_code == 403

    def test_upload_requires_ownership(self, client, mock_db):
        self._enforce(client, mock_db, linked_pid=PID)
        mock_db.get_study_id.return_value = None
        mock_db.get_survey_schedule.return_value = None

        resp = client.post(
            f'/api/uploaduserprofile/{PID}',
            data=json.dumps(VALID_PROFILE_V2),
            content_type='application/json',
            headers=_bearer(_token()),
        )

        assert resp.status_code == 200
        assert resp.get_json() == {'status': 'ok'}
