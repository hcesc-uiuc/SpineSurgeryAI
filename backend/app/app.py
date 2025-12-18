from flask import Flask, render_template
from config import Config
from routes.upload import upload_bp
from flask import Blueprint, Response, jsonify
from database.database import DB
from flask import current_app
from routes.dashboard_api import dashboard_api
from routes.dashboard_page import dashboard_page
from heatmap import generate_participant_heatmap

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
    
    
    @app.route("/")
    def home():
        return render_template(("home.html"))
    
    @app.route("/heatmap/<participant_id>", methods=["GET"])
    def get_heatmap(participant_id: str):
        """Generate and return heatmap HTML on demand."""
        html = generate_participant_heatmap(current_app.config["DB"], participant_id)
        if html:
            return Response(html, mimetype="text/html")
        return jsonify({"error": "No data for participant"}), 404
    
    @app.route("/compliance")
    def compliance():
        try:
            data = current_app.config["DB"].get_compliance_for("P0001") 
            table = current_app.config["DB"].get_table("accelerometer")
            ingestion_rows = current_app.config["DB"].get_table("ingestion_health")
            return render_template("compliance.html", data=data, table=table, ingestion_rows=ingestion_rows)
        except Exception as e: 
            print("error")
            app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m" + str(e))
        
    return app

if __name__ == "__main__":
    app = create_app()
    app.run(debug=False)
    # app.run(host="0.0.0.0", port=5000, debug=True)
    

 

