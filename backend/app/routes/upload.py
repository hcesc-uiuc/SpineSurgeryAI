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

@upload_bp.route("/upload", methods=["POST"])
def upload():
    if request.is_json:
        data = request.get_json()
        filename = data["filename"]
        content = data["content"]

        
        db = current_app.config["DB"]

        # Upload to S3  

        # s3_link = s3_service.upload_to_s3(content, filename)
        s3_link = str(filename) + str(content)
        db.insert_hr("P0001", [{"ts": str(datetime.now()), "url": s3_link}])
        db.insert_accel("P0001", [{"ts": str(datetime.now()), "url": s3_link}])
        db.insert_gyro("P0001", [{"ts": str(datetime.now()), "url": s3_link}])
        db.refresh_summary_cache(True)

        # Save metadata in DB
        
        return jsonify({"message": "Upload successful", "s3_link": s3_link})
    else:
        return jsonify({"error": "Please send JSON data"}), 400

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

    db.insert_accel("P0001", [{"ts": str(datetime.now()), "url": key}])

    return jsonify(message="Upload successful", key=key)


