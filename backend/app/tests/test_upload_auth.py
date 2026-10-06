"""Authenticated upload routes file data under the caller's participant hash
(linked at login) — never the internal account number in the token."""
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import jwt
import pytest

TEST_JWT_SECRET = 'test-secret-key-for-testing-only'  # matches conftest
PID = 'b' * 64


def _bearer(user_id=7):
    exp = datetime.now(timezone.utc) + timedelta(minutes=15)
    return {'Authorization': 'Bearer ' + jwt.encode({'sub': str(user_id), 'exp': exp}, TEST_JWT_SECRET, algorithm='HS256')}


@pytest.fixture(autouse=True)
def fake_s3():
    s3 = MagicMock()
    s3.generate_presigned_url.return_value = 'https://s3.example/put'
    with patch('routes.upload.s3', s3):
        yield s3


def test_presign_stores_participant_hash(client, mock_db):
    mock_db.get_participant_id_for_user.return_value = PID

    resp = client.post('/api/uploads/presign', headers=_bearer(7),
                       json={'filename': 'a.csv', 'kind': 'accel'})

    assert resp.status_code == 201
    mock_db.get_participant_id_for_user.assert_called_once_with(7)
    assert mock_db.create_pending_upload.call_args[0][1] == PID


def test_complete_files_data_under_participant_hash(client, mock_db):
    mock_db.get_participant_id_for_user.return_value = PID
    mock_db.get_pending_upload.return_value = {
        'external_id': PID, 'status': 'pending', 'kind': 'gyro', 'object_key': 'k'}

    resp = client.post('/api/uploads/complete', headers=_bearer(7),
                       json={'upload_id': 'u1', 'success': True})

    assert resp.get_json()['status'] == 'completed'
    mock_db.insert_gyro.assert_called_once_with(PID, [{'url': 'k'}])


def test_complete_someone_elses_upload_is_not_found(client, mock_db):
    mock_db.get_participant_id_for_user.return_value = PID
    mock_db.get_pending_upload.return_value = {
        'external_id': 'c' * 64, 'status': 'pending', 'kind': 'gyro', 'object_key': 'k'}

    resp = client.post('/api/uploads/complete', headers=_bearer(7),
                       json={'upload_id': 'u1', 'success': True})

    assert resp.status_code == 404
    mock_db.insert_gyro.assert_not_called()
    mock_db.mark_upload_completed.assert_not_called()


def test_account_without_participant_link_is_refused(client, mock_db):
    mock_db.get_participant_id_for_user.return_value = None

    resp = client.post('/api/uploads/presign', headers=_bearer(7),
                       json={'filename': 'a.csv', 'kind': 'accel'})

    assert resp.status_code == 403
    assert resp.get_json()['error'] == 'not_enrolled'
    mock_db.create_pending_upload.assert_not_called()
