from functools import wraps

import jwt
from flask import current_app, g, jsonify, request


def authenticate_bearer():
    """Validate the request's Bearer access token.

    Returns (user_id, None) on success, or (None, (response, status)) with the
    structured 401 body the iOS app expects (missing_token / token_expired /
    invalid_token). Shared by require_auth and the profile access guard so the
    token-validation rules live in exactly one place.
    """
    header = request.headers.get('Authorization', '')
    if not header.startswith('Bearer '):
        return None, (jsonify({'error': 'missing_token'}), 401)

    token = header[len('Bearer '):]
    try:
        payload = jwt.decode(
            token,
            current_app.config['JWT_SECRET'],
            algorithms=['HS256'],
        )
    except jwt.ExpiredSignatureError:
        return None, (jsonify({'error': 'token_expired'}), 401)
    except jwt.InvalidTokenError:
        return None, (jsonify({'error': 'invalid_token'}), 401)

    return payload.get('sub'), None


def require_auth(f):
    """
    Decorator for protected routes.
    Sets g.user_id on success.
    Returns 401 with a structured error body on failure.
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        user_id, error = authenticate_bearer()
        if error is not None:
            return error
        g.user_id = user_id
        return f(*args, **kwargs)
    return decorated
