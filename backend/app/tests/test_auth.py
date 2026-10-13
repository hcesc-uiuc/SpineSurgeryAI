import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import jwt
import pytest

TEST_JWT_SECRET = 'test-secret-key-for-testing-only'
APPLE_SUB       = 'apple_user_abc123'
APPLE_EMAIL     = 'user@example.com'
VALID_CODE      = '483920'


def _make_token(user_id=1, secret=TEST_JWT_SECRET, expired=False):
    """Helper: build a signed access token for tests."""
    if expired:
        exp = datetime.now(timezone.utc) - timedelta(seconds=1)
    else:
        exp = datetime.now(timezone.utc) + timedelta(minutes=15)
    return jwt.encode({'sub': str(user_id), 'exp': exp}, secret, algorithm='HS256')


def _auth_header(token):
    return {'Authorization': f'Bearer {token}'}


# ---------------------------------------------------------------------------
# Login tests
# ---------------------------------------------------------------------------

class TestLogin:
    def test_login_valid_token_returns_tokens(self, client, mock_db):
        """Valid Apple identity_token + enrollment code → 200 with both tokens."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.enroll_user_with_code.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            resp = client.post('/auth/login', json={
                'identity_token': 'fake.apple.jwt',
                'enrollment_code': VALID_CODE,
            })

        assert resp.status_code == 200
        data = resp.get_json()
        assert 'access_token' in data
        assert 'refresh_token' in data

    def test_login_invalid_token_returns_401(self, client, mock_db):
        """Invalid Apple identity_token → 401 invalid_identity_token."""
        with patch('auth.routes.verify_apple_token', side_effect=Exception('bad token')):
            resp = client.post('/auth/login', json={'identity_token': 'bad.token'})

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_identity_token'

    def test_login_missing_token_returns_400(self, client):
        """Missing identity_token field → 400 missing_identity_token."""
        resp = client.post('/auth/login', json={})
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'missing_identity_token'

    def test_login_links_participant_hash(self, client, mock_db):
        """Login records the account↔participant map (SHA-256 of the Apple sub,
        exactly what iOS ParticipantID.hash computes) so profile endpoints can
        authorize by participant hash when REQUIRE_PROFILE_AUTH is on."""
        mock_db.get_user_by_apple_id.return_value = {'id': 5, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB}):
            resp = client.post('/auth/login', json={'identity_token': 'fake.apple.jwt'})

        assert resp.status_code == 200
        expected_pid = hashlib.sha256(APPLE_SUB.encode()).hexdigest()
        args = mock_db.link_account_participant.call_args[0]
        assert args[0] == 5
        assert args[1] == expected_pid

    def test_login_twice_same_sub_no_duplicate_user(self, client, mock_db):
        """Two logins with the same Apple sub must not create two user rows."""
        # First login: user does not exist yet (needs an enrollment code)
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.enroll_user_with_code.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            client.post('/auth/login', json={
                'identity_token': 'fake.apple.jwt',
                'enrollment_code': VALID_CODE,
            })

        # Second login: user already exists (no code needed)
        mock_db.get_user_by_apple_id.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            resp = client.post('/auth/login', json={'identity_token': 'fake.apple.jwt'})

        assert resp.status_code == 200
        # The account was created only once (for the first login)
        mock_db.enroll_user_with_code.assert_called_once()


# ---------------------------------------------------------------------------
# Enrollment gate tests (PROFILE_API.md — account creation requires a code)
# ---------------------------------------------------------------------------

class TestEnrollmentGate:
    def _login(self, client, body_extra=None):
        body = {'identity_token': 'fake.apple.jwt'}
        body.update(body_extra or {})
        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            return client.post('/auth/login', json=body)

    def test_new_user_without_code_returns_403(self, client, mock_db):
        """New Apple user with no enrollment_code → 403, no account created,
        and it isn't counted as a guess."""
        mock_db.get_user_by_apple_id.return_value = None

        resp = self._login(client)

        assert resp.status_code == 403
        assert resp.get_json()['error'] == 'invalid_enrollment_code'
        mock_db.enroll_user_with_code.assert_not_called()
        mock_db.record_enrollment_attempt.assert_not_called()

    def test_blank_code_not_counted(self, client, mock_db):
        mock_db.get_user_by_apple_id.return_value = None
        assert self._login(client, {'enrollment_code': '   '}).status_code == 403
        mock_db.record_enrollment_attempt.assert_not_called()

    def test_global_cap_pauses_enrollment(self, client, mock_db):
        """Too many code tries across all new accounts → 429 for everyone,
        before the code is looked at."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.count_enrollment_attempts.return_value = 31

        resp = self._login(client, {'enrollment_code': VALID_CODE})

        assert resp.status_code == 429
        assert resp.get_json()['error'] == 'too_many_attempts'
        mock_db.enroll_user_with_code.assert_not_called()

    def test_concurrent_first_login_continues_as_existing_user(self, client, mock_db):
        """enroll returns None because a parallel first login created the
        account; the request re-reads it instead of answering 403/500."""
        mock_db.get_user_by_apple_id.side_effect = [None, {'id': 7, 'apple_id': APPLE_SUB}]
        mock_db.enroll_user_with_code.return_value = None

        resp = self._login(client, {'enrollment_code': VALID_CODE})

        assert resp.status_code == 200
        assert mock_db.get_user_by_apple_id.call_count == 2

    def test_unusable_code_returns_403(self, client, mock_db):
        """Unknown, revoked, or already-used code (DB claim fails) → 403."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.enroll_user_with_code.return_value = None

        resp = self._login(client, {'enrollment_code': VALID_CODE})

        assert resp.status_code == 403
        assert resp.get_json()['error'] == 'invalid_enrollment_code'

    def test_valid_code_enrolls_with_stripped_code(self, client, mock_db):
        """Usable code → account created via the atomic claim, tokens issued."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.enroll_user_with_code.return_value = {'id': 7, 'apple_id': APPLE_SUB}

        resp = self._login(client, {'enrollment_code': f'  {VALID_CODE}  ', 'full_name': 'Ada'})

        assert resp.status_code == 200
        # Only the Apple sub and code are passed — no email/name is ever stored
        mock_db.enroll_user_with_code.assert_called_once_with(
            APPLE_SUB, VALID_CODE, hashlib.sha256(APPLE_SUB.encode()).hexdigest()
        )

    def test_too_many_attempts_returns_429_without_checking_code(self, client, mock_db):
        """Sixth try in the window → 429, and the code isn't even looked at."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.record_enrollment_attempt.return_value = 6

        resp = self._login(client, {'enrollment_code': VALID_CODE})

        assert resp.status_code == 429
        assert resp.get_json()['error'] == 'too_many_attempts'
        mock_db.enroll_user_with_code.assert_not_called()
        pid = hashlib.sha256(APPLE_SUB.encode()).hexdigest()
        mock_db.record_enrollment_attempt.assert_called_once_with(pid, 3600)

    def test_fifth_attempt_still_allowed(self, client, mock_db):
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.record_enrollment_attempt.return_value = 5
        mock_db.enroll_user_with_code.return_value = {'id': 7, 'apple_id': APPLE_SUB}

        assert self._login(client, {'enrollment_code': VALID_CODE}).status_code == 200

    def test_existing_user_skips_code_check(self, client, mock_db):
        """Returning user logs in with no code and isn't attempt-limited."""
        mock_db.get_user_by_apple_id.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        resp = self._login(client)

        assert resp.status_code == 200
        mock_db.enroll_user_with_code.assert_not_called()
        mock_db.record_enrollment_attempt.assert_not_called()


# ---------------------------------------------------------------------------
# Sign in with Apple nonce
# ---------------------------------------------------------------------------

RAW_NONCE = 'k7Qx-raw-nonce'
NONCE_HASH = hashlib.sha256(RAW_NONCE.encode()).hexdigest()


class TestNonce:
    def _login(self, client, nonce_claim=None, body_nonce=None):
        payload = {'sub': APPLE_SUB, 'exp': 2_000_000_000}
        if nonce_claim is not None:
            payload['nonce'] = nonce_claim
        body = {'identity_token': 'fake.apple.jwt'}
        if body_nonce is not None:
            body['nonce'] = body_nonce
        with patch('auth.routes.verify_apple_token', return_value=payload):
            return client.post('/auth/login', json=body)

    @pytest.fixture(autouse=True)
    def _returning_user(self, mock_db):
        mock_db.get_user_by_apple_id.return_value = {'id': 1, 'apple_id': APPLE_SUB}

    def test_matching_nonce_accepted_and_claimed(self, client, mock_db):
        resp = self._login(client, nonce_claim=NONCE_HASH, body_nonce=RAW_NONCE)
        assert resp.status_code == 200
        mock_db.claim_apple_nonce.assert_called_once_with(NONCE_HASH, 2_000_000_000)

    def test_mismatched_nonce_rejected(self, client, mock_db):
        resp = self._login(client, nonce_claim=NONCE_HASH, body_nonce='something-else')
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_nonce'
        mock_db.claim_apple_nonce.assert_not_called()

    def test_replayed_nonce_rejected(self, client, mock_db):
        mock_db.claim_apple_nonce.return_value = False
        resp = self._login(client, nonce_claim=NONCE_HASH, body_nonce=RAW_NONCE)
        assert resp.status_code == 401

    def test_sent_nonce_but_token_has_none_rejected(self, client):
        assert self._login(client, body_nonce=RAW_NONCE).status_code == 401

    def test_no_nonce_allowed_while_flag_off(self, client, mock_db):
        assert self._login(client).status_code == 200
        mock_db.claim_apple_nonce.assert_not_called()

    def test_no_nonce_rejected_when_flag_on(self, app, client):
        app.config['REQUIRE_APPLE_NONCE'] = True
        resp = self._login(client, nonce_claim=NONCE_HASH)
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_nonce'

    def test_nonce_checked_before_enrollment(self, client, mock_db):
        """A bad nonce never reaches account creation or the attempt counter."""
        mock_db.get_user_by_apple_id.return_value = None
        self._login(client, nonce_claim=NONCE_HASH, body_nonce='wrong')
        mock_db.record_enrollment_attempt.assert_not_called()
        mock_db.enroll_user_with_code.assert_not_called()

    def _enroll(self, client, code):
        payload = {'sub': APPLE_SUB, 'exp': 2_000_000_000, 'nonce': NONCE_HASH}
        body = {'identity_token': 'fake.apple.jwt', 'nonce': RAW_NONCE, 'enrollment_code': code}
        with patch('auth.routes.verify_apple_token', return_value=payload):
            return client.post('/auth/login', json=body)

    def test_wrong_code_uses_up_the_nonce(self, client, mock_db):
        """Each nonce authorizes one attempt, even a refused one: replaying a
        captured first sign-in with another code must fail. The app signs in
        with Apple again (fresh nonce) to send the code."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.enroll_user_with_code.return_value = None
        assert self._enroll(client, '000000').status_code == 403
        mock_db.claim_apple_nonce.assert_called_once_with(NONCE_HASH, 2_000_000_000)

        mock_db.claim_apple_nonce.return_value = False        # now used
        mock_db.enroll_user_with_code.return_value = {'id': 7, 'apple_id': APPLE_SUB}
        resp = self._enroll(client, VALID_CODE)
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_nonce'
        mock_db.enroll_user_with_code.assert_called_once()     # only the first try

    def test_nonce_claimed_before_rate_limit(self, client, mock_db):
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.record_enrollment_attempt.return_value = 6
        assert self._enroll(client, VALID_CODE).status_code == 429
        mock_db.claim_apple_nonce.assert_called_once()

    def test_replay_writes_nothing(self, client, mock_db):
        """A replayed nonce is refused before the account link or tokens."""
        mock_db.claim_apple_nonce.return_value = False
        resp = self._login(client, nonce_claim=NONCE_HASH, body_nonce=RAW_NONCE)
        assert resp.get_json()['error'] == 'invalid_nonce'
        mock_db.link_account_participant.assert_not_called()
        mock_db.create_refresh_token.assert_not_called()

    def test_token_with_nonce_claim_needs_the_nonce_even_with_flag_off(self, client, mock_db):
        """A token minted for a nonce-sending build can't be used by leaving the
        nonce out, before REQUIRE_APPLE_NONCE is turned on."""
        resp = self._login(client, nonce_claim=NONCE_HASH)
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_nonce'
        mock_db.create_refresh_token.assert_not_called()


# ---------------------------------------------------------------------------
# Startup: refuse to run without auth settings
# ---------------------------------------------------------------------------

class TestStartupCheck:
    @pytest.mark.parametrize('overrides, message', [
        ({'JWT_SECRET': ''}, 'JWT_SECRET'),
        ({'JWT_SECRET': 'too-short'}, 'JWT_SECRET'),
        ({'APPLE_BUNDLE_ID': ''}, 'APPLE_BUNDLE_ID'),
    ])
    def test_refuses_to_start(self, mock_db, overrides, message):
        from app import create_app
        settings = {'JWT_SECRET': TEST_JWT_SECRET, 'APPLE_BUNDLE_ID': 'com.test.app', **overrides}
        with patch('app.DB', return_value=mock_db), pytest.raises(RuntimeError, match=message):
            create_app(settings)

    def test_health_route_for_docker_healthcheck(self, client):
        resp = client.get('/health')
        assert resp.status_code == 200
        assert resp.get_json() == {'status': 'ok'}

    def test_backfills_participant_links_after_creating_every_table(self, app, mock_db):
        """Accounts that only refresh never hit /auth/login, so startup links them."""
        names = [c[0] for c in mock_db.method_calls]
        last_create = max(i for i, n in enumerate(names) if n.startswith('create_'))
        assert names.index('backfill_account_participants') > last_create

    def test_failed_backfill_does_not_skip_table_creation(self, mock_db):
        from app import create_app
        mock_db.backfill_account_participants.side_effect = RuntimeError('boom')
        with patch('app.DB', return_value=mock_db):
            create_app({'JWT_SECRET': TEST_JWT_SECRET, 'APPLE_BUNDLE_ID': 'com.test.app'})
        mock_db.create_enrollment_attempts_table.assert_called_once()
        mock_db.create_apple_nonces_table.assert_called_once()


# ---------------------------------------------------------------------------
# Refresh tests
# ---------------------------------------------------------------------------

class TestRefresh:
    def _valid_token_record(self, user_id=1):
        raw = secrets.token_urlsafe(32)
        hashed = hashlib.sha256(raw.encode()).hexdigest()
        record = {
            'id': 1,
            'user_id': user_id,
            'token_hash': hashed,
            'expires_at': datetime.now(timezone.utc) + timedelta(days=365),
            'revoked': False,
        }
        return raw, hashed, record

    def test_refresh_valid_token_returns_access_token(self, client, mock_db):
        """Valid refresh token → 200 with new access_token."""
        raw, _, record = self._valid_token_record()
        mock_db.get_refresh_token_by_hash.return_value = record

        resp = client.post('/auth/refresh', json={'refresh_token': raw})

        assert resp.status_code == 200
        assert 'access_token' in resp.get_json()

    def test_refresh_revoked_token_returns_401(self, client, mock_db):
        """Revoked refresh token → 401 invalid_grant."""
        raw, _, record = self._valid_token_record()
        record['revoked'] = True
        mock_db.get_refresh_token_by_hash.return_value = record

        resp = client.post('/auth/refresh', json={'refresh_token': raw})

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_grant'

    def test_refresh_expired_token_returns_401(self, client, mock_db):
        """Expired refresh token → 401 invalid_grant."""
        raw, _, record = self._valid_token_record()
        record['expires_at'] = datetime.now(timezone.utc) - timedelta(seconds=1)
        mock_db.get_refresh_token_by_hash.return_value = record

        resp = client.post('/auth/refresh', json={'refresh_token': raw})

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_grant'

    def test_refresh_missing_token_returns_400(self, client):
        """Missing refresh_token field → 400 missing_refresh_token."""
        resp = client.post('/auth/refresh', json={})
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'missing_refresh_token'

    def test_refresh_unknown_token_returns_401(self, client, mock_db):
        """Unknown refresh token (not in DB) → 401 invalid_grant."""
        mock_db.get_refresh_token_by_hash.return_value = None

        resp = client.post('/auth/refresh', json={'refresh_token': 'unknown-token'})

        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_grant'


# ---------------------------------------------------------------------------
# Logout tests
# ---------------------------------------------------------------------------

class TestLogout:
    def test_logout_revokes_token_and_subsequent_refresh_fails(self, client, mock_db):
        """Logout marks token revoked; subsequent refresh returns 401."""
        raw = secrets.token_urlsafe(32)

        # Logout
        resp = client.post('/auth/logout', json={'refresh_token': raw})
        assert resp.status_code == 200
        assert resp.get_json()['ok'] is True

        # Verify revoke was called with the correct hash
        expected_hash = hashlib.sha256(raw.encode()).hexdigest()
        mock_db.revoke_refresh_token.assert_called_once_with(expected_hash)

        # Now simulate refresh with revoked token
        mock_db.get_refresh_token_by_hash.return_value = {
            'id': 1, 'user_id': 1,
            'expires_at': datetime.now(timezone.utc) + timedelta(days=1),
            'revoked': True,
        }
        resp2 = client.post('/auth/refresh', json={'refresh_token': raw})
        assert resp2.status_code == 401
        assert resp2.get_json()['error'] == 'invalid_grant'


# ---------------------------------------------------------------------------
# Middleware / protected route tests
# ---------------------------------------------------------------------------

class TestRequireAuth:
    def test_protected_route_no_token_returns_401(self, client):
        """Request without Authorization header → 401 missing_token."""
        resp = client.get('/api/test-protected')
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'missing_token'

    def test_protected_route_valid_token_returns_200(self, client):
        """Valid Bearer token → 200 with user_id."""
        token = _make_token(user_id=42)
        resp = client.get('/api/test-protected', headers=_auth_header(token))
        assert resp.status_code == 200
        assert resp.get_json()['user_id'] == '42'

    def test_protected_route_expired_token_returns_401(self, client):
        """Expired Bearer token → 401 token_expired."""
        token = _make_token(expired=True)
        resp = client.get('/api/test-protected', headers=_auth_header(token))
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'token_expired'

    def test_protected_route_malformed_token_returns_401(self, client):
        """Garbage Bearer token → 401 invalid_token."""
        resp = client.get('/api/test-protected', headers=_auth_header('not.a.jwt'))
        assert resp.status_code == 401
        assert resp.get_json()['error'] == 'invalid_token'
