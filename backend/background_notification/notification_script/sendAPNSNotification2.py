import collections
import collections.abc
collections.MutableMapping = collections.abc.MutableMapping
collections.MutableSet = collections.abc.MutableSet
collections.MutableSequence = collections.abc.MutableSequence

import os
import time
import jwt   # PyJWT
import httpx
import psycopg2
from pathlib import Path
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

TEAM_ID = "G77DW2U5YC"
KEY_ID = "JMZVBP4J48"
BUNDLE_ID = "edu.uiuc.cs.hcesc.SensingApp.v2"
AUTH_KEY_PATH = Path("./AuthKey_JMZVBP4J48.p8")
USE_SANDBOX = False  # True for Xcode dev builds, False for TestFlight/App Store


def get_device_tokens() -> list[str]:
    """Fetch all device tokens from the database."""
    conn = psycopg2.connect(dsn=os.getenv("DATABASE_URL"))
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT device_token FROM device_tokens;")
            return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def generate_jwt_token():
    """Generate APNs JWT using your .p8 key."""
    with open(AUTH_KEY_PATH, "r") as f:
        secret = f.read()

    token = jwt.encode(
        {
            "iss": TEAM_ID,
            "iat": int(time.time())
        },
        secret,
        algorithm="ES256",
        headers={
            "alg": "ES256",
            "kid": KEY_ID
        }
    )
    return token


def send_apns_notification(device_token: str):
    jwt_token = generate_jwt_token()
    apns_host = "https://api.sandbox.push.apple.com" if USE_SANDBOX else "https://api.push.apple.com"
    url = f"{apns_host}/3/device/{device_token}"

    # headers = {
    #     "apns-topic": BUNDLE_ID,
    #     "authorization": f"bearer {jwt_token}",
    #     "apns-push-type": "alert",
    #     "content-type": "application/json",
    # }
    # custom_data = {"action": "refresh", "timestamp": int(time.time())}
    # payload = {
    #     "aps": {
    #         "alert": {
    #             "title": "Hello from Python!",
    #             "body": "This is a direct APNs call without apns2 🚀"
    #         },
    #         "sound": "default",
    #         "badge": 1,
    #     },
    #     "data": custom_data
    # }

    headers = {
        "apns-topic": BUNDLE_ID,
        "authorization": f"bearer {jwt_token}",
        "apns-push-type": "background",  # silent notification
        "content-type": "application/json",
        "apns-priority": "5",
    }

    custom_data = {"action": "refresh", "timestamp": int(time.time())}
    payload = {
        "aps": {
            "content-available": 1  # No alert, badge, or sound
        },
        "data": custom_data,  # Optional custom payload for your app
    }

    # Send over HTTP/2
    with httpx.Client(http2=True) as client:
        response = client.post(url, headers=headers, json=payload)

    print("     Status:", response.status_code)
    if response.status_code == 200:
        print("     ✅ Notification sent successfully!")
    else:
        print("     ❌ Failed:", response.text)


def task():
    tokens = get_device_tokens()
    print(f"[{datetime.now()}] Sending silent push to {len(tokens)} device(s)...")
    for token in tokens:
        send_apns_notification(token)

if __name__ == "__main__":
    task()