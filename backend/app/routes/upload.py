from flask import Blueprint, request, jsonify
from services import s3_service, db_service
from flask import current_app
from datetime import datetime



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
        db.refresh_summary_cache(True)

        # Save metadata in DB
        
        return jsonify({"message": "Upload successful", "s3_link": s3_link})
    else:
        return jsonify({"error": "Please send JSON data"}), 400
    
#curl -X POST -H "Content-Type: application/json" -d '{"filename":"Jason","content":20}' http://127.0.0.1:5000/api/upload, do this in gitbash