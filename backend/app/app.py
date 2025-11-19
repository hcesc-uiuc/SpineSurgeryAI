from flask import Flask, render_template
from config import Config
from routes.upload import upload_bp
from database.database import DB
from flask import current_app
from routes.dashboard_api import dashboard_api
from routes.dashboard_page import dashboard_page

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    # Initialize database (remove try catch later)
    try:
        app.config["DB"] = DB()
    except:
        app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m")

    # Register blueprints
    app.register_blueprint(upload_bp, url_prefix="/api")

    app.register_blueprint(dashboard_api)
    app.register_blueprint(dashboard_page)
    
    @app.route("/")
    def home():
        return render_template(("home.html"))
    
    @app.route("/compliance")
    def compliance():
        try:
            data = current_app.config["DB"].get_compliance_for("P0001") 
            table = current_app.config["DB"].get_table("accel")
            return render_template("compliance.html", data=data, table=table)
        except Exception as e: 
            app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m" + str(e))

    return app

if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5000, debug=False)
    

 

