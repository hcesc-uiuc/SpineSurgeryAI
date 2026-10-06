import os
import sys

# Allow imports from backend/app/
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import pytest
from unittest.mock import MagicMock, patch

from app import create_app

TEST_JWT_SECRET = 'test-secret-key-for-testing-only'
TEST_BUNDLE_ID  = 'com.test.app'


@pytest.fixture
def mock_db():
    db = MagicMock()
    db.record_enrollment_attempt.return_value = 1  # first try in the window
    db.claim_apple_nonce.return_value = True       # nonce not seen before
    return db


@pytest.fixture
def app(mock_db):
    with patch('app.DB', return_value=mock_db):
        flask_app = create_app({
            'TESTING': True,
            'JWT_SECRET': TEST_JWT_SECRET,
            'APPLE_BUNDLE_ID': TEST_BUNDLE_ID,
            'REQUIRE_APPLE_NONCE': False,
        })
    flask_app.config['DB'] = mock_db

    # Minimal protected route for middleware tests (avoids S3 dependency)
    from auth.middleware import require_auth
    from flask import g, jsonify

    @flask_app.get('/api/test-protected')
    @require_auth
    def _test_protected():
        return jsonify({'user_id': g.user_id})

    return flask_app


@pytest.fixture
def client(app):
    return app.test_client()
