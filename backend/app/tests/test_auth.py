import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import jwt
import pytest

TEST_JWT_SECRET = 'test-secret-key-for-testing-only'
APPLE_SUB       = 'apple_user_abc123'
APPLE_EMAIL     = 'user@example.com'


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
        """Valid Apple identity_token → 200 with access_token and refresh_token."""
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.create_user.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            resp = client.post('/auth/login', json={'identity_token': 'fake.apple.jwt'})

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

    def test_login_twice_same_sub_no_duplicate_user(self, client, mock_db):
        """Two logins with the same Apple sub must not create two user rows."""
        # First login: user does not exist yet
        mock_db.get_user_by_apple_id.return_value = None
        mock_db.create_user.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            client.post('/auth/login', json={'identity_token': 'fake.apple.jwt'})

        # Second login: user already exists
        mock_db.get_user_by_apple_id.return_value = {'id': 1, 'apple_id': APPLE_SUB}

        with patch('auth.routes.verify_apple_token', return_value={'sub': APPLE_SUB, 'email': APPLE_EMAIL}):
            resp = client.post('/auth/login', json={'identity_token': 'fake.apple.jwt'})

        assert resp.status_code == 200
        # create_user was called only once (for the first login)
        mock_db.create_user.assert_called_once()


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
