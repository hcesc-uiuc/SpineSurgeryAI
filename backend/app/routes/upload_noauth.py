# TEMPORARY: No-auth upload endpoints for development/testing.
# Remove this file and its blueprint registration in app.py when auth is ready on iOS.

from flask import Blueprint, request, jsonify, current_app
from werkzeug.utils import secure_filename
from dotenv import load_dotenv
from datetime import datetime
from config import Config
import boto3, os, json

load_dotenv()

s3 = boto3.client(
    "s3",
    region_name=os.getenv("AWS_REGION"),
    aws_access_key_id=os.getenv("AWS_KEY"),
    aws_secret_access_key=os.getenv("AWS_SECRET_KEY"),
)
S3_BUCKET = os.getenv("AWS_BUCKET")

upload_noauth_bp = Blueprint("upload_noauth", __name__)


def _require_participant_id(data: dict):
    pid = data.get("participantId") or data.get("participant_id")
    if not pid:
        return None, (jsonify({"error": "participantId is required"}), 400)
    return pid, None


@upload_noauth_bp.route("/noauth/uploadjson", methods=["POST"])
def upload_noauth():
    if not request.is_json:
        return jsonify({"error": "Please send JSON data"}), 400
    data = request.get_json()
    participant_id, err = _require_participant_id(data)
    if err:
        return err

    filename = data.get("filename") or request.args.get("filename") or f"upload_{datetime.utcnow():%Y%m%dT%H%M%S}.json"
    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(filename)}"

    s3.put_object(
        Bucket=S3_BUCKET, Key=key,
        Body=json.dumps(data).encode("utf-8"),
        ContentType="application/json",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_accel(participant_id, [{"ts": 0, "url": key}])
    return jsonify({"message": "Upload successful", "key": key}), 201


@upload_noauth_bp.route("/noauth/uploadfile", methods=["POST"])
def uploadfile_noauth():
    participant_id = request.form.get("participantId") or request.form.get("participant_id")
    if not participant_id:
        return jsonify({"error": "participantId is required"}), 400

    file = request.files.get("file")
    if not file:
        return jsonify({"error": "No file uploaded"}), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"
    s3.put_object(
        Bucket=S3_BUCKET, Key=key, Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_accel(participant_id, [{"ts": 0, "url": key}])
    return jsonify({"message": "Upload successful", "key": key}), 200


@upload_noauth_bp.route("/noauth/uploadfile/accel", methods=["POST"])
def uploadfile_accel_noauth():
    participant_id = request.form.get("participantId") or request.form.get("participant_id")
    if not participant_id:
        return jsonify({"error": "participantId is required"}), 400

    file = request.files.get("file")
    if not file:
        return jsonify({"error": "No file uploaded"}), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"
    s3.put_object(
        Bucket=S3_BUCKET, Key=key, Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_accel(participant_id, [{"ts": 0, "url": key}])
    return jsonify({"message": "Upload successful", "key": key}), 200


@upload_noauth_bp.route("/noauth/uploadfile/gyro", methods=["POST"])
def uploadfile_gyro_noauth():
    participant_id = request.form.get("participantId") or request.form.get("participant_id")
    if not participant_id:
        return jsonify({"error": "participantId is required"}), 400

    file = request.files.get("file")
    if not file:
        return jsonify({"error": "No file uploaded"}), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"
    s3.put_object(
        Bucket=S3_BUCKET, Key=key, Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_gyro(participant_id, [{"ts": 0, "url": key}])
    return jsonify({"message": "Upload successful", "key": key}), 200


@upload_noauth_bp.route("/noauth/uploadfile/heartrate", methods=["POST"])
def uploadfile_heartrate_noauth():
    participant_id = request.form.get("participantId") or request.form.get("participant_id")
    if not participant_id:
        return jsonify({"error": "participantId is required"}), 400

    file = request.files.get("file")
    if not file:
        return jsonify({"error": "No file uploaded"}), 400

    key = f"uploads/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(file.filename)}"
    s3.put_object(
        Bucket=S3_BUCKET, Key=key, Body=file.stream,
        ContentType=file.mimetype or "application/octet-stream",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_hr(participant_id, [{"ts": 0, "url": key}])
    return jsonify({"message": "Upload successful", "key": key}), 200


@upload_noauth_bp.route("/noauth/uploadjson/survey", methods=["POST"])
def upload_survey_noauth():
    if not request.is_json:
        return jsonify({"error": "Please send JSON data"}), 400
    data = request.get_json()

    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON structure"}), 400

    metadata = data.get("metadata")
    payload = data.get("payload")
    if not metadata:
        return jsonify({"error": "Missing 'metadata' field"}), 400
    if not payload:
        return jsonify({"error": "Missing 'payload' field"}), 400

    participant_id = metadata.get("participantId") or metadata.get("participant_id") or metadata.get("user_id")
    if not participant_id:
        return jsonify({"error": "Missing 'participantId' in metadata"}), 400

    timestamp_str = metadata.get("timestamp_utc")
    if not timestamp_str:
        return jsonify({"error": "Missing 'timestamp_utc' in metadata"}), 400

    try:
        if timestamp_str.endswith("Z"):
            timestamp_str = timestamp_str[:-1] + "+00:00"
        survey_date = datetime.fromisoformat(timestamp_str).date().isoformat()
    except ValueError as e:
        return jsonify({"error": f"Invalid timestamp format: {e}"}), 400

    key = f"surveys/{secure_filename(participant_id)}/{survey_date}_{datetime.utcnow():%H%M%S}.json"
    s3.put_object(
        Bucket=S3_BUCKET, Key=key,
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
        StorageClass="GLACIER_IR", ServerSideEncryption="AES256",
    )
    current_app.config["DB"].insert_survey(participant_id, [{
        "survey_date": survey_date,
        "url": key,
        "payload": payload,
    }])
    return jsonify({"message": "Survey uploaded successfully", "key": key, "participant_id": participant_id, "survey_date": survey_date}), 201
