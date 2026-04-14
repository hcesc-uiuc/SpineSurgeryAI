from flask import Flask,request, jsonify
import configparser
import psycopg2
from psycopg2 import sql
from datetime import datetime
from typing import Optional


app = Flask(__name__)


def _load_config():
    """Load database configuration from INI file."""
    config = configparser.ConfigParser()
    config.read("config.ini")
    
    db_config = {
        'host': config.get('postgresql', 'host'),
        'port': config.getint('postgresql', 'port'),
        'database': config.get('postgresql', 'database'),
        'user': config.get('postgresql', 'user'),
        'password': config.get('postgresql', 'password')
    }
    return db_config

def _connect():
    """Establish connection to the PostgreSQL database."""
    try:
        db_config = _load_config()
        connection = psycopg2.connect(**db_config)
        print(f"Connected to PostgreSQL database: {db_config['database']}")
        return connection
    except psycopg2.Error as e:
        print(f"Error connecting to PostgreSQL: {e}")
        return None

def create_table():
    """
    Create the device_tokens table if it doesn't exist.
    
    Table structure:
        - id: Auto-incrementing primary key
        - device_token: Device token string (unique)
        - timestamp_unix: Unix timestamp (integer)
        - timestamp_readable: Human-readable timestamp
        - created_at: Automatic timestamp of record creation
    """
    create_table_query = """
    CREATE TABLE IF NOT EXISTS device_tokens (
        id SERIAL PRIMARY KEY,
        device_token VARCHAR(255) NOT NULL UNIQUE,
        timestamp_unix BIGINT NOT NULL,
        timestamp_readable TIMESTAMP NOT NULL,
        subject_id TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    
    CREATE INDEX IF NOT EXISTS idx_device_token ON device_tokens(device_token);
    CREATE INDEX IF NOT EXISTS idx_timestamp_unix ON device_tokens(timestamp_unix);
    """
    
    try:
        connection = _connect()
        cursor = connection.cursor()
        cursor.execute(create_table_query)
        connection.commit()
        cursor.close()
        print("Table 'device_tokens' created successfully (if it didn't exist)")

    except psycopg2.Error as e:
        connection.rollback()
        print(f"Error creating table: {e}")
        raise


def insert_token(device_token: str, subject_id: str, timestamp_unix: Optional[int] = None):
    """
    Insert a device token into the database.
    
    Args:
        device_token (str): The device token to insert
        timestamp_unix (int, optional): Unix timestamp. If None, uses current time
    
    Returns:
        int: The ID of the inserted record, or None if insertion failed
    """
    if timestamp_unix is None:
        timestamp_unix = int(datetime.now().timestamp())
    
    # Convert unix timestamp to readable datetime
    timestamp_readable = datetime.fromtimestamp(timestamp_unix)
    
    insert_query = """
    INSERT INTO device_tokens (device_token, timestamp_unix, timestamp_readable, subject_id)
    VALUES (%s, %s, %s, %s)
    ON CONFLICT (device_token) 
    DO UPDATE SET 
        timestamp_unix = EXCLUDED.timestamp_unix,
        timestamp_readable = EXCLUDED.timestamp_readable,
        created_at = CURRENT_TIMESTAMP
    RETURNING id;
    """
    
    try:
        connection = _connect()
        cursor = connection.cursor()
        cursor.execute(insert_query, (device_token, timestamp_unix, timestamp_readable, subject_id))
        record_id = cursor.fetchone()[0]
        connection.commit()
        cursor.close()
        print(f"Token inserted/updated successfully. ID: {record_id}")
        return record_id
    except psycopg2.Error as e:
        connection.rollback()
        print(f"Error inserting token: {e}")
        return None



# This file won't be accessible by script
# This is because the file will be in a docker image
def write_line(deviceToken):
    with open("./tokens.txt", "a") as myfile:
        myfile.write(deviceToken)


@app.route('/uploadDeviceToken', methods=['POST'])
def post_json():
    # Ensure request is JSON
    if not request.is_json:
        return jsonify({"error": "Request must be JSON"}), 400
    
    # Get JSON data
    data = request.get_json()
    
    # You can access fields like:
    # title = data.get("title")
    # body = data.get("body")
    # user_id = data.get("userId")

    # Print or process the data
    print(f"Received: {data}")
    
    create_table()
    insert_token(data["deviceToken"],data["userId"])

    # Send a JSON response
    return jsonify({
        "message": "JSON received successfully",
        "received_data": data
    }), 200


@app.route('/')
def hello():
    return "Hello from Flask in Docker!"


if __name__ == '__main__':
    # app.run(debug=True, port=8080)
    app.run(host="0.0.0.0", port=5001)

    