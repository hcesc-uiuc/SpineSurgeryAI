from flask import Blueprint, request, jsonify
# from services import s3_service, db_service
from flask import current_app
from datetime import datetime
from auth.middleware import require_auth

#S3 imports
from flask import Blueprint, request, jsonify
from dotenv import load_dotenv

from werkzeug.utils import secure_filename
from datetime import datetime
import boto3, os
from config import Config
import json

upload_bp = Blueprint("upload", __name__)

# AWS credentials (set these in your environment)
load_dotenv()

AWS_ACCESS_KEY_ID = os.getenv("AWS_KEY")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_KEY")
AWS_REGION = os.getenv("AWS_REGION")
S3_BUCKET = os.getenv("AWS_BUCKET")

s3 = boto3.client(
    "s3",
    region_name=AWS_REGION,
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY
)


upload_bp = Blueprint("upload", __name__)

@upload_bp.route("/uploadjson", methods=["POST"])
@require_auth
def upload():
    db = current_app.config["DB"]

    if not request.is_json:
        return jsonify({"error": "Please send JSON data"}), 400

    # The JSON body (can be any structure, no 'filename' required)
    data = request.get_json()

    # Try to get filename from JSON, then from query param, else default
    filename = None
    if isinstance(data, dict):
        filename = data.get("filename")

    if not filename:
        filename = request.args.get("filename")

    if not filename:
        filename = f"survey_{datetime.utcnow():%Y%m%dT%H%M%S}.json"

    if Config.DEBUG_MODE:
        print("---- REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", request.get_data(as_text=True))
        print("---- REQUEST END ----")

    # Build S3 key
    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(filename)}"

    # Store the entire JSON body as the file contents
    body_bytes = json.dumps(data).encode("utf-8")

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=body_bytes,
        ContentType="application/json",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256",
    )

    db.insert_accel("P0001", [{
        "ts": 0,
        "url": key,
    }])

    return jsonify({"message": "Upload successful", "key": key}), 201

@upload_bp.route("/uploadfile", methods=["POST"])
@require_auth
def uploadfile():
    db = current_app.config["DB"]

    if (Config.DEBUG_MODE):
        # Be careful printing body — can be huge or binary

        print("---- REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", request.get_data(as_text=True))
        print("---- REQUEST END ----")    
    file = request.files.get("file")
    if not file:
        return jsonify(error="No file uploaded"), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256"
    )

    db.insert_accel("P0001", [{"ts": 0, "url": key}])

    return jsonify(message="Upload successful", key=key)


@upload_bp.route("/uploadfile/accel", methods=["POST"])
@require_auth
def uploadfileaccel():
    db = current_app.config["DB"]

    if (Config.DEBUG_MODE):
        # Be careful printing body — can be huge or binary
        print("---- REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", request.get_data(as_text=True))
        print("---- REQUEST END ----")    

    file = request.files.get("file")
    if not file:
        return jsonify(error="No file uploaded"), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256"
    )

    db.insert_accel("P0001", [{"ts": 0, "url": key}])

    return jsonify(message="Upload successful", key=key)


@upload_bp.route("/uploadfile/gyro", methods=["POST"])
@require_auth
def uploadfilegyro():
    db = current_app.config["DB"]

    if (Config.DEBUG_MODE):
        # Be careful printing body — can be huge or binary
        print("---- REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", request.get_data(as_text=True))
        print("---- REQUEST END ----")    

    file = request.files.get("file")
    if not file:
        return jsonify(error="No file uploaded"), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256"
    )

    db.insert_gyro("P0001", [{"ts": 0, "url": key}])

    return jsonify(message="Upload successful", key=key)


@upload_bp.route("/uploadfile/heartrate", methods=["POST"])
@require_auth
def uploadfileheartrate():
    db = current_app.config["DB"]

    if (Config.DEBUG_MODE):
        # Be careful printing body — can be huge or binary
        print("---- REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", request.get_data(as_text=True))
        print("---- REQUEST END ----")    

    file = request.files.get("file")
    if not file:
        return jsonify(error="No file uploaded"), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256"
    )

    db.insert_hr("P0001", [{"ts": 0, "url": key}])

    return jsonify(message="Upload successful", key=key)


@upload_bp.route("/uploadjson/survey", methods=["POST"])
@require_auth
def upload_survey():
    """
    Upload a survey response in the format
    {
      "metadata": {
        "user_id": "P0001",
        "timestamp_utc": "2026-01-12T22:41:00Z"
      },
      "payload": {
        "study_id": "spine_recovery_v1",
        "survey": { ... },
        "device_metadata": { ... }
      }
    }
    
    """
    db = current_app.config["DB"]

    if not request.is_json:
        return jsonify(error="Please send JSON data"), 400

    data = request.get_json()

    if Config.DEBUG_MODE:
        print("---- SURVEY REQUEST START ----")
        print("Method:", request.method)
        print("URL:", request.url)
        print("Headers:\n", request.headers)
        print("Body:\n", json.dumps(data, indent=2))
        print("---- SURVEY REQUEST END ----")

    if not isinstance(data, dict):
        return jsonify(error="Invalid JSON structure"), 400

    metadata = data.get("metadata")
    payload = data.get("payload")

    if not metadata:
        return jsonify(error="Missing 'metadata' field"), 400
    if not payload:
        return jsonify(error="Missing 'payload' field"), 400

    user_id = metadata.get("user_id")
    if not user_id:
        return jsonify(error="Missing 'user_id' in metadata"), 400

    timestamp_str = metadata.get("timestamp_utc")
    if not timestamp_str:
        return jsonify(error="Missing 'timestamp_utc' in metadata"), 400

    try:
        if timestamp_str.endswith("Z"):
            timestamp_str = timestamp_str[:-1] + "+00:00"
        survey_datetime = datetime.fromisoformat(timestamp_str)
        survey_date = survey_datetime.date().isoformat()  # "2026-01-12"
    except ValueError as e:
        return jsonify(error=f"Invalid timestamp format: {e}"), 400

    # Build S3 key for payload only
    safe_user_id = secure_filename(user_id)
    key = f"surveys/{safe_user_id}/{survey_date}_{datetime.utcnow():%H%M%S}.json"

    # Upload only the payload to S3
    payload_bytes = json.dumps(payload).encode("utf-8")

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=payload_bytes,
        ContentType="application/json",
        StorageClass="GLACIER_IR",
        ServerSideEncryption="AES256",
    )

    db.insert_survey(user_id, [{
        "survey_date": survey_date,
        "url": key,
        "payload": payload,
    }])

    return jsonify(
        message="Survey uploaded successfully",
        key=key,
        user_id=user_id,
        survey_date=survey_date,
    ), 201












