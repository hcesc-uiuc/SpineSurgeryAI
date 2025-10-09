from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

class DataRecord(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(120), unique=True, nullable=False)
    s3_link = db.Column(db.String(200), nullable=False)