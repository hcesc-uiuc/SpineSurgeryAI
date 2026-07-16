from functools import wraps

import jwt
from flask import current_app, g, jsonify, request


def require_auth(f):
    """
    Decorator for protected routes.
    Sets g.user_id on success.
    Returns 401 with a structured error body on failure.
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        header = request.headers.get('Authorization', '')
        if not header.startswith('Bearer '):
            return jsonify({'error': 'missing_token'}), 401

        token = header[len('Bearer '):]
        try:
            payload = jwt.decode(
                token,
                current_app.config['JWT_SECRET'],
                algorithms=['HS256'],
            )
            g.user_id = payload['sub']
        except jwt.ExpiredSignatureError:
            return jsonify({'error': 'token_expired'}), 401
        except jwt.InvalidTokenError:
            return jsonify({'error': 'invalid_token'}), 401

        return f(*args, **kwargs)
    return decorated
