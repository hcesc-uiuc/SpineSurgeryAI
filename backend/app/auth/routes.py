import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from flask import Blueprint, current_app, jsonify, request

from .apple import verify_apple_token

auth_bp = Blueprint('auth', __name__, url_prefix='/auth')

ACCESS_TOKEN_TTL  = timedelta(hours=24)
REFRESH_TOKEN_TTL = timedelta(days=365)


def _make_access_token(user_id: int) -> str:
    return jwt.encode(
        {'sub': str(user_id), 'exp': datetime.now(timezone.utc) + ACCESS_TOKEN_TTL},
        current_app.config['JWT_SECRET'],
        algorithm='HS256',
    )


def _make_refresh_token() -> tuple[str, str]:
    """Returns (raw_token_for_client, sha256_hash_for_db)."""
    raw = secrets.token_urlsafe(64)
    hashed = hashlib.sha256(raw.encode()).hexdigest()
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

    apple_user_id = apple_payload['sub']

    db = current_app.config['DB']

    user = db.get_user_by_apple_id(apple_user_id)
    if not user:
        # Account creation is gated on a coordinator-issued enrollment code
        # (PROFILE_API.md). Returning users never reach this branch, so they
        # are never re-prompted; the iOS app maps this 403 to its
        # "code not recognized" sheet.
        code = body.get('enrollment_code')
        code_record = (
            db.get_enrollment_code(code.strip()) if isinstance(code, str) else None
        )
        if not code_record or not code_record['active']:
            return jsonify({'error': 'invalid_enrollment_code'}), 403

        # Anonymization: email/full_name are deliberately NOT stored — the
        # study links data by a one-way participant hash only (PROFILE_API.md
        # "Identity"; the shipped app never sends full_name).
        user = db.create_user(apple_user_id, None, None)
        db.mark_enrollment_code_used(code_record['code'], user['id'])

    # Record the account↔participant link so profile endpoints can authorize by
    # participant hash when REQUIRE_PROFILE_AUTH is on. The participant_id is
    # SHA-256(apple_sub) — exactly what iOS ParticipantID.hash() computes — so
    # the server derives it here rather than trusting the client. Idempotent:
    # re-linked (harmlessly) on every login.
    participant_id = hashlib.sha256(apple_user_id.encode()).hexdigest()
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

    hashed = hashlib.sha256(raw.encode()).hexdigest()
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
        hashed = hashlib.sha256(raw.encode()).hexdigest()
        current_app.config['DB'].revoke_refresh_token(hashed)

    return jsonify({'ok': True})
