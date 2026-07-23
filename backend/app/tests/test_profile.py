import json

PID = 'a' * 64  # participant ids are 64-hex sha256 digests

VALID_PROFILE = {
    'schema_version': 1,
    'participant_id': PID,
    'enrollment_code': '483920',
    'enrolled_at': 1782000000.0,
    'first_open_date': 1782000000.0,
    'preferences': {'reminder_hour': 20, 'reminder_minute': 0},
    'survey_history': [
        {'date': '2026-07-01', 'pain_score': 4, 'completed': True},
    ],
    'updated_at': 1782086400.0,
}


class TestGetProfile:
    def test_get_missing_profile_returns_404(self, client, mock_db):
        mock_db.get_profile_json.return_value = None

        resp = client.get(f'/api/profile/{PID}')

        assert resp.status_code == 404
        assert resp.get_json()['error'] == 'not_found'

    def test_get_existing_profile_returns_stored_json_verbatim(self, client, mock_db):
        # Distinctive whitespace proves the route returns the stored bytes,
        # not a re-serialization.
        stored = '{\n  "schema_version": 1,   "participant_id": "%s"\n}' % PID
        mock_db.get_profile_json.return_value = stored

        resp = client.get(f'/api/profile/{PID}')

        assert resp.status_code == 200
        assert resp.get_data(as_text=True) == stored
        assert resp.mimetype == 'application/json'


class TestPutProfile:
    def _put(self, client, body_bytes, pid=PID):
        return client.put(
            f'/api/profile/{pid}',
            data=body_bytes,
            content_type='application/json',
        )

    def test_put_valid_profile_returns_status_ok(self, client, mock_db):
        """The iOS app string-matches {"status": "ok"} before showing 'Backed up'."""
        raw = json.dumps(VALID_PROFILE)

        resp = self._put(client, raw)

        assert resp.status_code == 200
        assert resp.get_json() == {'status': 'ok'}
        mock_db.upsert_profile_json.assert_called_once_with(
            PID, raw, VALID_PROFILE['updated_at']
        )

    def test_put_replaces_whole_document(self, client, mock_db):
        """Local-wins: the raw document is stored as sent, no merging."""
        updated = dict(VALID_PROFILE, updated_at=1782172800.0)
        raw = json.dumps(updated)

        resp = self._put(client, raw)

        assert resp.status_code == 200
        stored_raw = mock_db.upsert_profile_json.call_args[0][1]
        assert stored_raw == raw

    def test_put_participant_id_mismatch_returns_400(self, client, mock_db):
        body = dict(VALID_PROFILE, participant_id='b' * 64)

        resp = self._put(client, json.dumps(body))

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'participant_id_mismatch'
        mock_db.upsert_profile_json.assert_not_called()

    def test_put_unknown_schema_version_returns_400(self, client, mock_db):
        body = dict(VALID_PROFILE, schema_version=99)

        resp = self._put(client, json.dumps(body))

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unsupported_schema_version'
        mock_db.upsert_profile_json.assert_not_called()

    def test_put_invalid_json_returns_400(self, client, mock_db):
        resp = self._put(client, b'{not json')

        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'invalid_json'
        mock_db.upsert_profile_json.assert_not_called()

    def test_put_oversized_body_returns_413(self, client, mock_db):
        body = dict(VALID_PROFILE, junk='x' * (300 * 1024))

        resp = self._put(client, json.dumps(body))

        assert resp.status_code == 413
        assert resp.get_json()['error'] == 'payload_too_large'
        mock_db.upsert_profile_json.assert_not_called()

    def test_put_missing_updated_at_uses_server_time(self, client, mock_db):
        body = {k: v for k, v in VALID_PROFILE.items() if k != 'updated_at'}

        resp = self._put(client, json.dumps(body))

        assert resp.status_code == 200
        stored_updated_at = mock_db.upsert_profile_json.call_args[0][2]
        assert isinstance(stored_updated_at, float) and stored_updated_at > 1_700_000_000
