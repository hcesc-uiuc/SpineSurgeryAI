from flask import Blueprint, render_template, current_app

dashboard_page = Blueprint("dashboard_page", __name__)

@dashboard_page.route("/dashboard")
def dashboard():
    db = current_app.config["DB"]
    participants = db.get_dashboard()
    accel = db.get_table("accelerometer")
    gyro = db.get_table("gyroscope")
    hr = db.get_table("heart_rate")
    survey = db.get_table("daily_survey")
    ingestion_rows = db.get_table("ingestion_health")
    return render_template("dashboard.html",
        participants=participants,
        accel=accel, gyro=gyro, hr=hr,
        survey=survey, ingestion_rows=ingestion_rows,
    )
