from flask import Flask, render_template
from config import Config
from routes.upload import upload_bp
from flask import Blueprint, Response, jsonify
from database.database import DB
from flask import current_app
from routes.dashboard_api import dashboard_api
from routes.dashboard_page import dashboard_page
from heatmap import generate_compliance_report, generate_participant_heatmap
from auth.routes import auth_bp

import logging
import sys

def create_app():
    app = Flask(__name__)
    # app.logger.addHandler(logging.StreamHandler(sys.stdout))
    # app.logger.setLevel(logging.DEBUG)
    app.config.from_object(Config)

    # Initialize database (remove try catch later)
    try:
        app.config["DB"] = DB()
        app.config["DB"].refresh_summary_cache()

    except Exception as e:
        app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m" + str(e))

    # Register blueprints
    app.register_blueprint(upload_bp, url_prefix="/api")

    app.register_blueprint(dashboard_api)
    app.register_blueprint(dashboard_page)
    app.register_blueprint(auth_bp)
    
    
    @app.route("/")
    def home():
        return render_template(("home.html"))
    
    # add a function in database.py (temperorary solution for participant data retrieval)
    @app.route("/heatmap/<participant_id>", methods=["GET"])
    def get_heatmap(participant_id: str):
        """Generate and return heatmap HTML on demand."""
        db = current_app.config["DB"]
        html = generate_participant_heatmap(db, participant_id)
        if not html:
            return jsonify({"error": "No data for participant"}), 404

        # Get this participant's raw data
        pid = db.get_participant_id_if_exists(participant_id)
        if pid:
            tables = {
                "Accelerometer": "SELECT id, participant_id, ts, object_url, file_size_bytes FROM accelerometer WHERE participant_id = %s AND ts > '1970-01-02' ORDER BY ts DESC LIMIT 100",
                "Gyroscope": "SELECT id, participant_id, ts, object_url, file_size_bytes FROM gyroscope WHERE participant_id = %s AND ts > '1970-01-02' ORDER BY ts DESC LIMIT 100",
                "Heart Rate": "SELECT id, participant_id, ts, object_url, file_size_bytes FROM heart_rate WHERE participant_id = %s AND ts > '1970-01-02' ORDER BY ts DESC LIMIT 100",
                "Survey": "SELECT id, participant_id, survey_date AS ts, object_url FROM daily_survey WHERE participant_id = %s ORDER BY survey_date DESC LIMIT 100",
            }

            tables_html = '<div style="font-family:sans-serif;padding:20px;">'
            with db.temporary_database_connection() as conn, conn.cursor() as cur:
                for title, query in tables.items():
                    cur.execute(query, (pid,))
                    rows = cur.fetchall()
                    cols = [d[0] for d in cur.description]

                    tables_html += f"<h3>{title} ({len(rows)} rows)</h3>"
                    if not rows:
                        tables_html += "<p>No data.</p>"
                        continue

                    tables_html += '<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px;font-size:13px;"><thead><tr>'
                    for c in cols:
                        tables_html += f"<th style='background:#e9ecef;padding:8px;'>{c}</th>"
                    tables_html += "</tr></thead><tbody>"
                    for row in rows:
                        tables_html += "<tr>" + "".join(f"<td style='padding:6px;'>{v}</td>" for v in row) + "</tr>"
                    tables_html += "</tbody></table>"
            tables_html += "</div>"

            html = html.replace("</body>", f"{tables_html}</body>")

        return Response(html, mimetype="text/html")
    @app.route("/totalcompliance")
    def get_compliance():
        """Generate and return compliance HTML on demand. See photo"""
        html = generate_compliance_report(current_app.config["DB"], lookback_days=30)
        if html:
            return Response(html, mimetype="text/html")
        
        return jsonify({"error": "No data for participant"}), 404

    @app.route("/compliance")
    def compliance():
        try:
            data = current_app.config["DB"].get_compliance_for("P0001") 
            accel = current_app.config["DB"].get_table("accelerometer")
            gyro = current_app.config["DB"].get_table("gyroscope")
            ingestion_rows = current_app.config["DB"].get_table("ingestion_health")
            survey = current_app.config["DB"].get_table("daily_survey")

            hr = current_app.config["DB"].get_table("heart_rate")


            return render_template("compliance.html", data=data, accel=accel, gyro=gyro, ingestion_rows=ingestion_rows, hr=hr, survey=survey)
        except Exception as e: 
            print("error")
            app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m" + str(e))
        
    return app

if __name__ == "__main__":
    app = create_app()
    app.run(debug=False)
    # app.run(host="0.0.0.0", port=5000, debug=True)
    

 

