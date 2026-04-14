import collections
import collections.abc
collections.MutableMapping = collections.abc.MutableMapping
collections.MutableSet = collections.abc.MutableSet
collections.MutableSequence = collections.abc.MutableSequence

import time
import jwt   # PyJWT
import httpx
from pathlib import Path
import time
from datetime import datetime

# # --- Configuration ---
# TEAM_ID = "55S274VKZG"
# KEY_ID = "MQ8P3Y4342"
# BUNDLE_ID = "edu.uiuc.cs.hcesc.SensingApp"
# AUTH_KEY_PATH = Path("../Keys/AuthKey_MQ8P3Y4342-JourneyKey.p8")
# DEVICE_TOKEN = "d14851092af917bd2740987d8c1b47bad855bb9bb724bd864fc8e7fb6e235abf"
# USE_SANDBOX = True  # False for production

TEAM_ID = "G77DW2U5YC"
KEY_ID = "JMZVBP4J48"
BUNDLE_ID = "edu.uiuc.cs.hcesc.SensingApp.v2"
AUTH_KEY_PATH = Path("./AuthKey_JMZVBP4J48.p8")
DEVICE_TOKEN = "d14851092af917bd2740987d8c1b47bad855bb9bb724bd864fc8e7fb6e235abf"
USE_SANDBOX = True  # False for production


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


def send_apns_notification():
    jwt_token = generate_jwt_token()
    apns_host = "https://api.sandbox.push.apple.com" if USE_SANDBOX else "https://api.push.apple.com"
    url = f"{apns_host}/3/device/{DEVICE_TOKEN}"

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
    print(f"[{datetime.now()}] Sending silent push...")
    send_apns_notification()

if __name__ == "__main__":
    #while True:
    task()
        # time.sleep(5 * 60)  # 5 minutes = 300 seconds
    # send_apns_notification()