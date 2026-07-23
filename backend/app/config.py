import os

# unused class keep for now remove later

class Config:
    SQLALCHEMY_DATABASE_URI = os.getenv("DATABASE_URL", "sqlite:///data.db")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID")
    AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")
    S3_BUCKET = os.getenv("S3_BUCKET")
    DEBUG_MODE = False
    JWT_SECRET = os.getenv("JWT_SECRET", "")
    APPLE_BUNDLE_ID = os.getenv("APPLE_BUNDLE_ID", "")

    # When true, the profile endpoints (routes/profile.py) require a valid
    # Bearer token whose account owns the requested participant hash. Leave
    # FALSE while the iOS app is in demo mode (it sends no token); flip to TRUE
    # in production together with iOS demoMode=false. See PROFILE_API.md v2.
    REQUIRE_PROFILE_AUTH = os.getenv("REQUIRE_PROFILE_AUTH", "false").strip().lower() in (
        "1", "true", "yes", "on",
    )