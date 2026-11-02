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


def upload_key(participant_id, kind, filename):
    """uploads/<participant>/<kind>/<UTC time>_<random>_<filename>

    The random part keeps two uploads of the same filename in the same second
    apart (SensorKit files reuse index 00000 after every upload)."""
    return (f"uploads/{secure_filename(str(participant_id))}/{kind}/"
            f"{datetime.utcnow():%Y%m%dT%H%M%S}_{uuid.uuid4().hex[:8]}_{secure_filename(filename)}")
