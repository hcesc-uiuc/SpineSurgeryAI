from flask import Blueprint, render_template
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

dashboard_api = Blueprint("dashboard_api", __name__)


@dashboard_api.route("/presence/accel/<external_id>")
@require_auth
def presence_accel(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_accel_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/gyro/<external_id>")
@require_auth
def presence_gyro(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_gyro_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/hr/<external_id>")
@require_auth
def presence_hr(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_hr_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/survey/<external_id>")
@require_auth
def presence_survey(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_survey_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/health/<external_id>")
@require_auth
def ingestion_health(external_id):
    db = current_app.config["DB"]
    query = """
    SELECT modality, window_start, window_end,
           expected_count, actual_count, pct_expected, status
    FROM ingestion_health ih
    JOIN participants p ON p.id = ih.participant_id
    WHERE p.external_id = %s
    ORDER BY window_start DESC
    LIMIT 50;
    """
    with db.temporary_database_connection() as conn, conn.cursor() as cur:
        cur.execute(query, (external_id,))
        rows = [
            {
                "modality": r[0],
                "window_start": r[1].isoformat(),
                "window_end": r[2].isoformat(),
                "expected_count": r[3],
                "actual_count": r[4],
                "pct_expected": float(r[5]) if r[5] is not None else None,
                "status": r[6],
            }
            for r in cur.fetchall()
        ]
    return jsonify(rows)
