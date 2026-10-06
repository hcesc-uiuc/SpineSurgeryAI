import jwt
import requests
from flask import current_app

APPLE_PUBLIC_KEYS_URL = 'https://appleid.apple.com/auth/keys'
APPLE_ISSUER = 'https://appleid.apple.com'


def verify_apple_token(identity_token: str) -> dict:
    """
    Verify an Apple identity_token and return the decoded payload.
    Raises jwt.PyJWTError on failure — caller must handle.
    """
    audience = current_app.config['APPLE_BUNDLE_ID']

    # Fetch Apple's current public key set
    response = requests.get(APPLE_PUBLIC_KEYS_URL, timeout=5)
    response.raise_for_status()
    jwks = response.json()

    # Match the key used to sign this token
    header = jwt.get_unverified_header(identity_token)
    matching_key = next(
        (k for k in jwks['keys'] if k['kid'] == header['kid']),
        None
    )
    if matching_key is None:
        raise jwt.InvalidTokenError('No matching Apple public key found')

    public_key = jwt.algorithms.RSAAlgorithm.from_jwk(matching_key)

    payload = jwt.decode(
        identity_token,
        public_key,
        algorithms=['RS256'],
        audience=audience,
        issuer=APPLE_ISSUER,
    )
    return payload
    # payload contains:
    #   sub   — stable Apple user ID (use this as apple_id in DB)
    #   email — present on first login only; may be a relay address
    #   exp   — expiry (jwt.decode enforces this automatically)
