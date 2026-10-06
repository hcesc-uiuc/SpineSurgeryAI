import os

from dotenv import load_dotenv

# Load .env before the class body reads os.getenv — otherwise settings that
# live only in .env (JWT_SECRET, APPLE_BUNDLE_ID, ...) are silently empty.
load_dotenv()


def _env_flag(name: str) -> bool:
    return os.getenv(name, "false").strip().lower() in ("1", "true", "yes", "on")


class Config:
    SQLALCHEMY_DATABASE_URI = os.getenv("DATABASE_URL", "sqlite:///data.db")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID")
    AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")
    S3_BUCKET = os.getenv("S3_BUCKET")
    DEBUG_MODE = False

    # Required — create_app() refuses to start without them (see app.py).
    JWT_SECRET = os.getenv("JWT_SECRET", "")
    APPLE_BUNDLE_ID = os.getenv("APPLE_BUNDLE_ID", "")

    # When true, the profile endpoints (routes/profile.py) require a valid
    # Bearer token whose account owns the requested participant hash. Leave
    # FALSE while the iOS app is in demo mode (it sends no token); flip to TRUE
    # in production together with iOS demoMode=false. See PROFILE_API.md v2.
    REQUIRE_PROFILE_AUTH = _env_flag("REQUIRE_PROFILE_AUTH")

    # When true, /auth/login rejects sign-ins without a Sign in with Apple
    # nonce. A nonce that IS sent is always checked; this only decides whether
    # it's mandatory. Flip on once every device runs a build that sends one.
    REQUIRE_APPLE_NONCE = _env_flag("REQUIRE_APPLE_NONCE")
