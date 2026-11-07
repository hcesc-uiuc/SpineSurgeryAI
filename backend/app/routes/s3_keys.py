"""S3 object keys. Every upload is filed under the participant it belongs to."""
from datetime import datetime
import uuid

from werkzeug.utils import secure_filename

# What iOS sends before login (ParticipantID.current)
UNIDENTIFIED = "unidentified"


def safe_participant(participant_id):
    """The participant id as a safe key segment, or None if it is missing or
    the pre-login placeholder."""
    safe = secure_filename(str(participant_id or ""))
    if not safe or safe == UNIDENTIFIED:
        return None
    return safe


def participant_folder(db, participant_id):
    """The S3 folder for a participant: their study id (P01, P02, ...), or the
    hash if they have none yet. Read-only, so unknown ids never use up a
    study number."""
    return db.get_study_id(participant_id) or participant_id


def upload_key(folder, kind, filename):
    """uploads/<study id>/<kind>/<UTC time>_<random>_<filename>

    The random part keeps two uploads of the same filename in the same second
    apart (SensorKit files reuse index 00000 after every upload)."""
    return (f"uploads/{secure_filename(str(folder))}/{kind}/"
            f"{datetime.utcnow():%Y%m%dT%H%M%S}_{uuid.uuid4().hex[:8]}_{secure_filename(filename)}")


def check_uploaded(s3, bucket, key, expected_size):
    """None if the object is in S3 (and, when the phone sent its file size,
    has exactly that size); otherwise why not. The phone deletes its copy as
    soon as an upload is confirmed, so "confirmed" has to mean complete."""
    try:
        head = s3.head_object(Bucket=bucket, Key=key)
    except Exception:
        return "object not found in S3"
    if expected_size is None:
        return None
    try:
        expected = int(expected_size)
    except (TypeError, ValueError):
        return "invalid size"
    if head.get("ContentLength") != expected:
        return f"size mismatch: S3 has {head.get('ContentLength')} bytes, phone sent {expected}"
    return None
