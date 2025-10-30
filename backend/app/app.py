from flask import Flask, render_template
from routes.upload import upload_bp
from database.database import DB
from flask import current_app


def create_app():
    app = Flask(__name__)

    # Initialize database (remove try catch later)
    try:
        app.config["DB"] = DB()
    except:
        app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m")

    # Register blueprints
    app.register_blueprint(upload_bp, url_prefix="/api")

    @app.route("/")
    def home():
        return render_template("home.html")
    
    @app.route("/compliance")
    def compliance():
        try:
            data = current_app.config["DB"].get_compliance_for("P0001") 
            table = current_app.config["DB"].get_table("heart_rate")
            return render_template("compliance.html", data=data, table=table)
        except: 
            app.logger.error("\033[91m" + "Cannot connect to database" + "\033[0m")

    return app

if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5000, debug=False)  # MAKES THIS PUBLIC

    #app.run(debug=True)

