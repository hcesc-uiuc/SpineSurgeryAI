# TEMPORARY: No-auth upload endpoints for development/testing.
# Remove this file and its blueprint registration in app.py when auth is ready on iOS.

from flask import Blueprint, request, jsonify, current_app
from werkzeug.utils import secure_filename
from dotenv import load_dotenv
from datetime import datetime
from config import Config
import boto3, os, json, uuid

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


@upload_noauth_bp.route("/noauth/uploads/presign", methods=["POST"])
def uploads_presign_noauth():
    db = current_app.config["DB"]
    body = request.get_json(silent=True) or {}

    participant_id = body.get("participantId") or body.get("participant_id")
    if not participant_id:
        return jsonify(error="participantId is required"), 400

    filename = body.get("filename")
    content_type = body.get("content_type", "application/octet-stream")
    kind = body.get("kind")

    if not filename:
        return jsonify(error="missing filename"), 400
    if kind not in ("accel", "gyro", "hr"):
        return jsonify(error="kind must be accel, gyro, or hr"), 400

    upload_id = str(uuid.uuid4())
    key = f"uploads/{kind}/{datetime.utcnow():%Y%m%dT%H%M%S}_{secure_filename(filename)}"

    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": S3_BUCKET,
            "Key": key,
            "ContentType": content_type,
            "ServerSideEncryption": "AES256",
            "StorageClass": "GLACIER_IR",
        },
        ExpiresIn=900,
    )

    db.create_pending_upload(upload_id, participant_id, kind, key)

    return jsonify(
        upload_id=upload_id,
        key=key,
        url=presigned_url,
        headers={
            "Content-Type": content_type,
            "x-amz-server-side-encryption": "AES256",
            "x-amz-storage-class": "GLACIER_IR",
        },
        expires_in=900,
    ), 201


@upload_noauth_bp.route("/noauth/uploads/complete", methods=["POST"])
def uploads_complete_noauth():
    db = current_app.config["DB"]
    body = request.get_json(silent=True) or {}

    upload_id = body.get("upload_id")
    success = body.get("success")
    error_msg = body.get("error", "")

    if not upload_id:
        return jsonify(error="missing upload_id"), 400

    pending = db.get_pending_upload(upload_id)
    if not pending:
        return jsonify(error="upload not found"), 404

    if pending["status"] != "pending":
        return jsonify(status=pending["status"], key=pending["object_key"]), 200

    participant_id = pending["external_id"]

    if success:
        try:
            s3.head_object(Bucket=S3_BUCKET, Key=pending["object_key"])
        except Exception:
            db.mark_upload_failed(upload_id, "object not found in S3 after reported success")
            return jsonify(status="failed", error="object not found in S3"), 200

        kind = pending["kind"]
        key = pending["object_key"]

        if kind == "accel":
            db.insert_accel(participant_id, [{"url": key}])
        elif kind == "gyro":
            db.insert_gyro(participant_id, [{"url": key}])
        elif kind == "hr":
            db.insert_hr(participant_id, [{"url": key}])

        db.mark_upload_completed(upload_id)
        return jsonify(status="completed", key=key), 200
    else:
        try:
            s3.delete_object(Bucket=S3_BUCKET, Key=pending["object_key"])
        except Exception:
            pass
        db.mark_upload_failed(upload_id, error_msg)
        return jsonify(status="failed"), 200


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
