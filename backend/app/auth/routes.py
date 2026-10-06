import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from flask import Blueprint, current_app, jsonify, request

from .apple import verify_apple_token

auth_bp = Blueprint('auth', __name__, url_prefix='/auth')

ACCESS_TOKEN_TTL  = timedelta(hours=24)
REFRESH_TOKEN_TTL = timedelta(days=365)

# A new account gets this many enrollment-code tries per rolling window.
ENROLLMENT_MAX_ATTEMPTS   = 5
ENROLLMENT_WINDOW_SECONDS = 3600


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _nonce_ok(raw_nonce, apple_payload: dict) -> bool:
    """Sign in with Apple nonce check: the app sent the raw nonce, Apple
    signed SHA-256(raw nonce) into the token, and each nonce is single-use."""
    expected = apple_payload.get('nonce')
    if not isinstance(raw_nonce, str) or not isinstance(expected, str):
        return False
    if not hmac.compare_digest(_sha256(raw_nonce), expected):
        return False
    return current_app.config['DB'].claim_apple_nonce(expected, apple_payload['exp'])


def _make_access_token(user_id: int) -> str:
    return jwt.encode(
        {'sub': str(user_id), 'exp': datetime.now(timezone.utc) + ACCESS_TOKEN_TTL},
        current_app.config['JWT_SECRET'],
        algorithm='HS256',
    )


def _make_refresh_token() -> tuple[str, str]:
    """Returns (raw_token_for_client, sha256_hash_for_db)."""
    raw = secrets.token_urlsafe(64)
    hashed = _sha256(raw)
    return raw, hashed


@auth_bp.post('/login')
def login():
    body = request.get_json(silent=True) or {}
    identity_token = body.get('identity_token')

    if not identity_token:
        return jsonify({'error': 'missing_identity_token'}), 400

    try:
        apple_payload = verify_apple_token(identity_token)
    except Exception:
        return jsonify({'error': 'invalid_identity_token'}), 401

    # Nonce: always checked when sent; required once REQUIRE_APPLE_NONCE is on
    # (old builds that don't send one keep working until then).
    raw_nonce = body.get('nonce')
    if raw_nonce is not None or current_app.config.get('REQUIRE_APPLE_NONCE'):
        if not _nonce_ok(raw_nonce, apple_payload):
            return jsonify({'error': 'invalid_nonce'}), 401

    apple_user_id = apple_payload['sub']
    # SHA-256(apple_sub) — exactly what iOS ParticipantID.hash() computes — so
    # the server derives it rather than trusting the client.
    participant_id = _sha256(apple_user_id)

    db = current_app.config['DB']

    user = db.get_user_by_apple_id(apple_user_id)
    if not user:
        # Account creation is gated on a single-use, coordinator-issued
        # enrollment code (PROFILE_API.md). Returning users never reach this
        # branch, so they are never re-prompted; the iOS app maps 403 to its
        # "code not recognized" sheet.
        attempts = db.record_enrollment_attempt(participant_id, ENROLLMENT_WINDOW_SECONDS)
        if attempts > ENROLLMENT_MAX_ATTEMPTS:
            return jsonify({'error': 'too_many_attempts'}), 429

        # Anonymization: email/full_name are deliberately NOT stored — the
        # study links data by a one-way participant hash only (PROFILE_API.md
        # "Identity").
        code = body.get('enrollment_code')
        user = (
            db.enroll_user_with_code(apple_user_id, code.strip(), participant_id)
            if isinstance(code, str) else None
        )
        if not user:
            return jsonify({'error': 'invalid_enrollment_code'}), 403

    # Record the account↔participant link so profile endpoints can authorize by
    # participant hash when REQUIRE_PROFILE_AUTH is on. Idempotent: re-linked
    # (harmlessly) on every login.
    db.link_account_participant(
        user['id'], participant_id, datetime.now(timezone.utc).timestamp()
    )

    raw_refresh, hashed_refresh = _make_refresh_token()
    expires_at = datetime.now(timezone.utc) + REFRESH_TOKEN_TTL
    db.create_refresh_token(user['id'], hashed_refresh, expires_at)

    return jsonify({
        'access_token':  _make_access_token(user['id']),
        'refresh_token': raw_refresh,
    })


@auth_bp.post('/refresh')
def refresh():
    body = request.get_json(silent=True) or {}
    raw = body.get('refresh_token')

    if not raw:
        return jsonify({'error': 'missing_refresh_token'}), 400

    hashed = _sha256(raw)
    db = current_app.config['DB']
    record = db.get_refresh_token_by_hash(hashed)

    if not record or record['revoked'] or record['expires_at'] < datetime.now(timezone.utc):
        return jsonify({'error': 'invalid_grant'}), 401

    return jsonify({'access_token': _make_access_token(record['user_id'])})


@auth_bp.post('/logout')
def logout():
    body = request.get_json(silent=True) or {}
    raw = body.get('refresh_token')

    if raw:
        hashed = _sha256(raw)
        current_app.config['DB'].revoke_refresh_token(hashed)

    return jsonify({'ok': True})
