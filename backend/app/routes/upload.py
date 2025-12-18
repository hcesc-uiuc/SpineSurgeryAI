from flask import Blueprint, request, jsonify
# from services import s3_service, db_service
from flask import current_app
from datetime import datetime

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


