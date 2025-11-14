from __future__ import annotations

from decimal import Decimal
import os
import statistics
import time
from typing import Any, Dict, List, Optional

import csv
import io
import json
from config import Config
import boto3
from dotenv import load_dotenv


from database.database import DB
from psycopg2.extras import DictCursor
from dataclasses import dataclass
import requests

load_dotenv()

AWS_ACCESS_KEY_ID = os.getenv("AWS_KEY")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_KEY")
AWS_REGION = os.getenv("AWS_REGION")
S3_BUCKET = os.getenv("AWS_BUCKET")

s3 = boto3.client(
    "s3",
    region_name=AWS_REGION,
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY
)



"""
***This is assuming constant data streaming / upload for 15 minutes 
so at 100 Hz -> there is 90,000 samples in 15 minutes

percent = (actual_samples / expected_samples) * 100

Does so in a linear order (fetch all uploads, download those, parse through sequentially)

will need to upscale if receiving like a bunch of calls

TODO: INSERT DATA INTO JUPITER NOTEBOOK


"""


#Checking Interval (15 Minutes preset -> move to config.py in review)
CHECKING_INTERVAL_SECONDS = 900

#% of data there needs to be in order to satisfy data requirements
DATA_COMPLETENESS_THRESHOLD = 90

#Gap > 5x normal time interval counts as "missing"
MAX_GAP_FACTOR           = 5.0      

#At most 5% of window can be gaps
MAX_GAP_FRACTION         = 0.05        


@dataclass
class UploadRecord:
    kind: str          # "accel" | "gyro" | "hr"
    external_id: str   # participant external_id
    ts: str            # timestamp as string
    object_url: str    # HTTP/S URL (or S3 key if you change downloader)


"""
    Fetch accel/gyro/hr uploads that were uploaded x seconds ago (checking_interval_seconds)
"""
def fetch_recent_uploads(db: DB) -> List[UploadRecord]:
    
    sql_query = """
        SELECT 'accel' AS kind, p.external_id, a.ts, a.object_url
        FROM accelerometer a
        JOIN participants p ON p.id = a.participant_id
        WHERE a.ts >= now() - %s * INTERVAL '1 minute'

        UNION ALL

        SELECT 'gyro' AS kind, p.external_id, g.ts, g.object_url
        FROM gyroscope g
        JOIN participants p ON p.id = g.participant_id
        WHERE g.ts >= now() - %s * INTERVAL '1 minute'

        UNION ALL

        SELECT 'hr' AS kind, p.external_id, h.ts, h.object_url
        FROM heart_rate h
        JOIN participants p ON p.id = h.participant_id
        WHERE h.ts >= now() - %s * INTERVAL '1 minute'

        ORDER BY ts;
    """

    uploads: List[UploadRecord] = []

    with db.temporary_database_connection() as conn, conn.cursor(cursor_factory=DictCursor) as cur:
        cur.execute(
            sql_query,
            (CHECKING_INTERVAL_SECONDS, CHECKING_INTERVAL_SECONDS, CHECKING_INTERVAL_SECONDS),
        )
        for row in cur.fetchall():
            uploads.append(
                UploadRecord(
                    kind=row["kind"],
                    external_id=row["external_id"],
                    ts=str(row["ts"]),
                    object_url=row["object_url"],
                )
            )

    return uploads

"""
    Download the uploads using the S3 link

"""
def download_object_content(url_or_key: str) -> bytes:

    if url_or_key.startswith("http://") or url_or_key.startswith("https://"):
        resp = requests.get(url_or_key, timeout=60)
        resp.raise_for_status()
        return resp.content

    # Case 2: S3 key (new preferred mode)
    resp = s3.get_object(Bucket=S3_BUCKET, Key=url_or_key)
    return resp["Body"].read()

"""
    Analyzer for CSV files (accereromter currently)

    Assumes CSV has header and has timestamp columns in ms in UNIX

    Returns sampling_rate_hz, expected_samples, actual_samples,
      completeness, total_gap_seconds, gap_fraction, is_usable
    """
def analyze_uploaded_data(kind: str, content_bytes: bytes) -> Dict[str, Any]:
    
    text = content_bytes.decode("utf-8", errors="replace").strip()

    if not text:
        return {
            "format": "empty",
            "row_count": 0,
            "sampling_rate_hz": 0.0,
            "expected_samples": 0,
            "actual_samples": 0,
            "completeness": 0.0,
            "total_gap_seconds": 0.0,
            "gap_fraction": 1.0,
            "is_usable": False,
        }

    parse_format = "unknown"
    timestamps_ms = []

    # Try CSV first
    try:
        print("[checker] analyze_uploaded_data: trying CSV parse", flush=True)

        f = io.StringIO(text)
        reader = csv.DictReader(f)
        if reader.fieldnames and "timestamp" in reader.fieldnames:
            parse_format = "csv"
            for row in reader:
                ts_str = row.get("timestamp")
                if ts_str is None or ts_str == "":
                    continue
                try:
                    ts = int(ts_str)
                except ValueError:
                    try:
                        # handle scientific notation like 1.76109E+12
                        ts = int(Decimal(ts_str))   # Perfect precision
                    except ValueError:
                        # truly bad row, skip
                        continue
                timestamps_ms.append(ts)

            print(f"[checker] CSV parse done, timestamps={len(timestamps_ms)}", flush=True)

    except Exception as e:
        print(f"[checker] CSV parse error: {e!r}", flush=True)

        pass

    # if no timestamps try json
    if not timestamps_ms:
        try:
            data = json.loads(text)
            if isinstance(data, list):
                # Assume each item is a dict with 'timestamp' in ms
                parse_format = "json-list"
                for item in data:
                    if isinstance(item, dict) and "timestamp" in item:
                        try:
                            ts = int(item["timestamp"])
                            timestamps_ms.append(ts)
                        except (TypeError, ValueError):
                            continue
        except Exception:
            pass

    actual_samples = len(timestamps_ms)
    print(f"[checker] total timestamps collected: {actual_samples}", flush=True)

    # If we still have nothing usable:
    if actual_samples < 2:
        return {
            "format": parse_format,
            "row_count": actual_samples,
            "sampling_rate_hz": 0.0,
            "expected_samples": 0,
            "actual_samples": actual_samples,
            "completeness": 0.0,
            "total_gap_seconds": 0.0,
            "gap_fraction": 1.0,
            "is_usable": False,
        }

    # Calculate sampling rate
    timestamps_ms.sort()
    print("[checker] timestamps sorted", flush=True)

    dts_seconds = [
        (timestamps_ms[i] - timestamps_ms[i - 1]) / 1000.0
        for i in range(1, actual_samples)
    ]
    print(f"[checker] dt list built, len={len(dts_seconds)}", flush=True)


    # median dt = typical sampling interval
    median_dt = statistics.median(dts_seconds)
    sampling_rate_hz = 1.0 / median_dt if median_dt > 0 else 0.0
    print(f"[checker] median_dt={median_dt}, sampling_rate_hz={sampling_rate_hz}", flush=True)


    # expected samples for a 15-min window at that rate
    expected_samples = int(round(sampling_rate_hz * CHECKING_INTERVAL_SECONDS))

    completeness = (
        float(actual_samples) / expected_samples
        if expected_samples > 0
        else 0.0
    )

    # big gaps = anything > MAX_GAP_FACTOR * median_dt
    gap_threshold = median_dt * MAX_GAP_FACTOR
    total_gap_seconds = sum(dt for dt in dts_seconds if dt > gap_threshold)

    gap_fraction = (
        total_gap_seconds / CHECKING_INTERVAL_SECONDS
        if CHECKING_INTERVAL_SECONDS > 0
        else 1.0
    )

    is_usable = (
        completeness >= DATA_COMPLETENESS_THRESHOLD
        and gap_fraction <= MAX_GAP_FRACTION
    )

    return {
        "format": parse_format,
        "row_count": actual_samples,
        "sampling_rate_hz": float(sampling_rate_hz),
        "expected_samples": int(expected_samples),
        "actual_samples": int(actual_samples),
        "completeness": float(completeness),
        "total_gap_seconds": float(total_gap_seconds),
        "gap_fraction": float(gap_fraction),
        "is_usable": bool(is_usable),
    }


"""
Runs function once for main loop (helper function)
"""
def run_once(db: DB):
    print(
        f"[checker] Looking for accel/gyro/hr uploads in last {CHECKING_INTERVAL_SECONDS / 60} minutes...",
        flush=True,
    )

    uploads = fetch_recent_uploads(db)
    if not uploads:
        print("[checker] No recent uploads found.", flush=True)
        return

    print(f"[checker] Found {len(uploads)} recent upload(s).", flush=True)

    for upload in uploads:
        if (Config.DEBUG_MODE):
            print(
                f"[checker] Processing {upload.kind} data for participant={upload.external_id!r} "
                f"ts={upload.ts} url={upload.object_url}",
                flush=True,
            )
        else:
            print(
                f"[checker] Processing {upload.kind} data for participant={upload.external_id!r} "
                f"ts={upload.ts}",
                flush=True,
            )
        try:
            print("[checker] Downloading object...", flush=True)
            content = download_object_content(upload.object_url)
            print(f"[checker] Downloaded {len(content)} bytes", flush=True)

            print("[checker] Analyzing data...", flush=True)
            analysis = analyze_uploaded_data(upload.kind, content)

            print(f"[checker] Results: {analysis}", flush=True)

            print(f"[checker]: Results: " + str(analysis))

            # INSERT DATA INTO JUPITER NOTEBOOK HERE!!! (currently only prints data)
            

        except Exception as e:
            print(
                f"[checker] ERROR for participant={upload.external_id!r}, "
                f"kind={upload.kind!r}: {e!r}",
                flush=True,
            )


"""
Main loop runs every 15 minutes
"""
def main_loop():
    db = DB() 
    
    print(
        f"[checker] Starting loop: interval={CHECKING_INTERVAL_SECONDS}s, "
        f"window={CHECKING_INTERVAL_SECONDS}min, "
        f"threshold={DATA_COMPLETENESS_THRESHOLD}",
        flush=True,
    )

    try:
        while True:
            try:
                run_once(db)
            except Exception as e:
                # Don't crash on a single failure
                print(f"[checker] ERROR in run_once: {e!r}", flush=True)
            try:
                db.refresh_summary_cache()
            except Exception as e:
                # Don't crash on a single failure
                print(f"[checker] ERROR in refreshing summary cache!: {e!r}", flush=True)
            
            time.sleep(CHECKING_INTERVAL_SECONDS)
    except KeyboardInterrupt:
        print("[checker] Shutting down (KeyboardInterrupt).", flush=True)
    finally:
        try:
            db.close_all_pool_connections()
        except Exception:
            pass

def debug():
    db = DB() 
    run_once(db)
    # content = download_object_content("uploads/20251114T000314_accelerometer_2025-10-22_06-20-03.csv")
    # analysis = analyze_uploaded_data("e", content)

    # print(f"[checker]: Results: " + str(analysis))


if __name__ == "__main__":
    main_loop()