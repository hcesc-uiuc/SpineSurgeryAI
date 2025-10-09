from flask import Blueprint, request, jsonify
from services import s3_service, db_service

upload_bp = Blueprint("upload", __name__)

@upload_bp.route("/upload", methods=["POST"])
def upload():
    data = request.get_json()
    filename = data["filename"]
    content = data["content"]

    # Upload to S3
    s3_link = s3_service.upload_to_s3(content, filename)

    # Save metadata in DB
    db_service.save_record(filename, s3_link)

    return jsonify({"message": "Upload successful", "s3_link": s3_link})