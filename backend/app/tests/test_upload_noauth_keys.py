"""noauth upload routes (used by the app today) file every S3 object under
the participant's study id (hash if none yet), and refuse uploads before login."""
import io
from unittest.mock import MagicMock, patch

import pytest

from routes.s3_keys import participant_folder, safe_participant, upload_key

PID = 'a' * 64


@pytest.fixture(autouse=True)
def no_study_id(mock_db):
    mock_db.get_study_id.return_value = None


@pytest.fixture(autouse=True)
def fake_s3():
    s3 = MagicMock()
    s3.generate_presigned_url.return_value = 'https://s3.example/put'
    with patch('routes.upload_noauth.s3', s3):
        yield s3


def _presign(client, **body):
    return client.post('/api/noauth/uploads/presign',
                       json={'filename': 'sensorkit_ppg_watch_00000.csv', 'kind': 'other', **body})


def test_presign_key_is_under_participant_and_kind(client, mock_db):
    resp = _presign(client, participantId=PID)

    assert resp.status_code == 201
    key = resp.get_json()['key']
    assert key.startswith(f'uploads/{PID}/other/')
    assert key.endswith('_sensorkit_ppg_watch_00000.csv')
    assert mock_db.create_pending_upload.call_args[0][1:] == (PID, 'other', key)


def test_presign_key_uses_study_id(client, mock_db):
    mock_db.get_study_id.return_value = 'P01'

    resp = _presign(client, participantId=PID)

    key = resp.get_json()['key']
    assert key.startswith('uploads/P01/other/')
    mock_db.get_study_id.assert_called_once_with(PID)
    assert mock_db.create_pending_upload.call_args[0][1] == PID  # owner stays the hash


def test_same_filename_same_second_gets_different_keys(client):
    a = _presign(client, participantId=PID).get_json()['key']
    b = _presign(client, participantId=PID).get_json()['key']
    assert a != b


@pytest.mark.parametrize('pid', [None, '', 'unidentified'])
def test_presign_before_login_is_refused(client, mock_db, pid):
    body = {} if pid is None else {'participantId': pid}
    resp = _presign(client, **body)

    assert resp.status_code == 400
    mock_db.create_pending_upload.assert_not_called()


def test_participant_id_cannot_escape_its_folder(client):
    key = _presign(client, participantId='../../etc').get_json()['key']
    assert key.startswith('uploads/etc/other/')
    assert '..' not in key


@pytest.mark.parametrize('route,kind,insert', [
    ('/api/noauth/uploadfile', 'other', 'insert_accel'),
    ('/api/noauth/uploadfile/accel', 'accel', 'insert_accel'),
    ('/api/noauth/uploadfile/gyro', 'gyro', 'insert_gyro'),
    ('/api/noauth/uploadfile/heartrate', 'hr', 'insert_hr'),
])
def test_direct_uploads_are_under_participant(client, mock_db, fake_s3, route, kind, insert):
    mock_db.get_study_id.return_value = 'P01'
    resp = client.post(route, content_type='multipart/form-data', data={
        'participantId': PID, 'file': (io.BytesIO(b'ts,x\n1,2\n'), 'locations_2026-11-01.csv')})

    assert resp.status_code == 200
    key = fake_s3.put_object.call_args.kwargs['Key']
    assert key.startswith(f'uploads/P01/{kind}/')
    getattr(mock_db, insert).assert_called_once_with(PID, [{'ts': 0, 'url': key}])


def test_direct_upload_before_login_is_refused(client, fake_s3):
    resp = client.post('/api/noauth/uploadfile', content_type='multipart/form-data', data={
        'participantId': 'unidentified', 'file': (io.BytesIO(b'x'), 'a.csv')})

    assert resp.status_code == 400
    fake_s3.put_object.assert_not_called()


def test_helpers(mock_db):
    mock_db.get_study_id.return_value = None
    assert participant_folder(mock_db, PID) == PID
    mock_db.get_study_id.return_value = 'P01'
    assert participant_folder(mock_db, PID) == 'P01'
    assert safe_participant(PID) == PID
    assert safe_participant('unidentified') is None
    assert safe_participant(None) is None
    assert upload_key(PID, 'hr', 'x y.csv').endswith('_x_y.csv')
