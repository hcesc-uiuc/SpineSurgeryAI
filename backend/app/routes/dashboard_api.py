from flask import Blueprint, render_template
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

dashboard_api = Blueprint("dashboard_api", __name__)


@dashboard_api.route("/presence/accel/<external_id>")
def presence_accel(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_accel_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/gyro/<external_id>")
def presence_gyro(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_gyro_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/hr/<external_id>")
def presence_hr(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_hr_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/survey/<external_id>")
def presence_survey(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_survey_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])
