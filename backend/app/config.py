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