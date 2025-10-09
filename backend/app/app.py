# from flask import Flask

# app = Flask(__name__)

# @app.route("/")
# def home():
#     return "Hello Akarsh — Flask is running inside your venv!"

# if __name__ == "__main__":
#     app.run(debug=True)

from flask import Flask
from config import Config
from models.data_record import db
from routes.upload import upload_bp

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    # Initialize database
    db.init_app(app)

    # Register blueprints
    app.register_blueprint(upload_bp, url_prefix="/api")

    @app.route("/")
    def index():
        return "Welcome — try POSTing to /api/upload"

    return app

if __name__ == "__main__":
    app = create_app()
    with app.app_context():
        db.create_all()  # Creates tables if not exist
    app.run(debug=True)
