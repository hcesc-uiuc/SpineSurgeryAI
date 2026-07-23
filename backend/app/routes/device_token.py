from flask import Blueprint, request, jsonify, current_app

device_token_bp = Blueprint("device_token", __name__)


@device_token_bp.route("/uploadDeviceToken", methods=["POST"])
def upload_device_token():
    if not request.is_json:
        return jsonify({"error": "Request must be JSON"}), 400

    data = request.get_json()
    device_token = data.get("deviceToken")
    user_id = data.get("userId")

    if not device_token or not user_id:
        return jsonify({"error": "deviceToken and userId are required"}), 400

    db = current_app.config["DB"]
    db.upsert_device_token(device_token, user_id)

    return jsonify({"message": "Device token saved successfully"}), 200
