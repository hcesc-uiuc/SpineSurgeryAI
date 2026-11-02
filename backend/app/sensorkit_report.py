"""
sensorkit_report.py -- Issue #74.

Answers "is each SensorKit sensor actually producing data?" from what phones
have uploaded. For every sensorkit_* object under uploads/<study id>/other/
(and the older uploads/other/) it reads the
first 4 KB, counts rows after the CSV header, and joins the object to its
participant through pending_uploads.

Per participant and sensor it prints: uploads, uploads with data rows,
header-only uploads, repeated uploads (same size as the previous upload, the
processed/ collision bug), total size and the last upload that had data.
Then it lists gaps: expected sensors a participant never uploaded, and sensors
with no data upload in the last --stale-hours (default 48). Exits 1 if there
are gaps, so it can run from cron.

Run where the backend runs (needs AWS_BUCKET, AWS credentials or the instance
role, and DATABASE_URL):

    python sensorkit_report.py                   # all participants
    python sensorkit_report.py --since 2026-09-14
    python sensorkit_report.py --participant 0c2435962352   # hash prefix
    python sensorkit_report.py --exclude-participant a956a786be18   # e.g. the test harness
    python sensorkit_report.py --stale-hours 24
"""

import argparse
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta

import boto3
import psycopg2
from dotenv import load_dotenv

# uploads/other/<time>_<name> (before #85) or uploads/<study id>/other/<time>_<random>_<name>
# Every SensorKit file the app writes (file prefix minus "sensorkit_")
EXPECTED_SENSORS = [
    "sensorkit_accel_phone", "sensorkit_accel_watch", "sensorkit_gyro_phone", "sensorkit_wristdetection_watch",
    "sensorkit_pressure_phone", "sensorkit_phoneusage_phone", "sensorkit_messages_phone",
    "sensorkit_keyboard_phone", "sensorkit_sleep_watch", "sensorkit_ppg_watch",
    "sensorkit_ambientlight_phone", "sensorkit_deviceusage_phone", "sensorkit_wristtemp_watch",
    "sensorkit_heartrate_watch",
]

KEY_RE = re.compile(r"^uploads/(?:[^/]+/)?other/(\d{8}T\d{6})_(?:[0-9a-f]{8}_)?(sensorkit_[a-z]+_[a-z]+)_\d{5}\.csv$")


def data_rows(s3, bucket, key):
    """Rows after the header in the first 4 KB (a lower bound for big files)."""
    body = s3.get_object(Bucket=bucket, Key=key, Range="bytes=0-4095")["Body"].read()
    lines = [l for l in body.decode("utf-8", "replace").split("\n") if l.strip()]
    return max(0, len(lines) - 1)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    p.add_argument("--since", help="only uploads on/after this date (YYYY-MM-DD)")
    p.add_argument("--participant", help="participant hash prefix to include")
    p.add_argument("--exclude-participant", action="append", default=[], help="hash prefix to exclude")
    p.add_argument("--stale-hours", type=float, default=48, help="flag sensors with no data upload for this long")
    args = p.parse_args()

    load_dotenv()
    bucket = os.environ["AWS_BUCKET"]
    s3 = boto3.client("s3", region_name=os.getenv("AWS_REGION"),
                      aws_access_key_id=os.getenv("AWS_KEY"),
                      aws_secret_access_key=os.getenv("AWS_SECRET_KEY"))

    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    cur = conn.cursor()
    cur.execute("select pu.object_key, p.external_id from pending_uploads pu "
                "join participants p on p.id = pu.participant_id "
                "where pu.object_key like 'uploads/%other/%sensorkit_%'")
    owner = dict(cur.fetchall())
    cur.execute("select participant_id, study_id from study_ids")
    study = dict(cur.fetchall())

    since = args.since.replace("-", "") if args.since else None
    objects = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="uploads/"):
        for o in page.get("Contents", []):
            m = KEY_RE.match(o["Key"])
            if not m or (since and m.group(1)[:8] < since):
                continue
            pid = owner.get(o["Key"], "unknown")
            if args.participant and not pid.startswith(args.participant):
                continue
            if any(pid.startswith(x) for x in args.exclude_participant):
                continue
            objects.append((pid, m.group(2), m.group(1), o["Key"], o["Size"]))

    stats = defaultdict(lambda: {"uploads": 0, "with_data": 0, "header_only": 0,
                                 "repeats": 0, "bytes": 0, "last_data": "-", "last_stamp": None,
                                 "prev_size": None})
    for pid, sensor, stamp, key, size in sorted(objects, key=lambda x: (x[0], x[1], x[2])):
        s = stats[(pid, sensor)]
        s["uploads"] += 1
        s["bytes"] += size
        if s["prev_size"] == size and size > 0:
            s["repeats"] += 1
        s["prev_size"] = size
        if data_rows(s3, bucket, key) > 0:
            s["with_data"] += 1
            s["last_data"] = "%s-%s-%s %s:%s" % (stamp[:4], stamp[4:6], stamp[6:8], stamp[9:11], stamp[11:13])
            s["last_stamp"] = stamp
        else:
            s["header_only"] += 1

    print("%-14s %-30s %7s %9s %11s %7s %11s  %s" % (
        "participant", "sensor", "uploads", "with_data", "header_only", "repeats", "total_MB", "last_data_upload"))
    def label(pid):
        return study.get(pid) or pid[:12]

    for (pid, sensor), s in sorted(stats.items()):
        print("%-14s %-30s %7d %9d %11d %7d %11.2f  %s" % (
            label(pid), sensor, s["uploads"], s["with_data"], s["header_only"], s["repeats"],
            s["bytes"] / 1e6, s["last_data"]))

    print()
    by_sensor = defaultdict(lambda: [0, 0])
    for (pid, sensor), s in stats.items():
        by_sensor[sensor][0] += s["uploads"]
        by_sensor[sensor][1] += s["with_data"]
    print("%-30s %7s %9s  %s" % ("sensor", "uploads", "with_data", "verdict"))
    for sensor, (n, d) in sorted(by_sensor.items()):
        print("%-30s %7d %9d  %s" % (sensor, n, d, "DATA SEEN" if d else "NO DATA YET"))

    # Gaps: key times are UTC, so compare against UTC now
    cutoff = (datetime.utcnow() - timedelta(hours=args.stale_hours)).strftime("%Y%m%dT%H%M%S")
    gaps = []
    for pid in sorted({pid for pid, _ in stats}):
        for sensor in EXPECTED_SENSORS:
            s = stats.get((pid, sensor))
            if s is None:
                gaps.append((label(pid), sensor, "never uploaded"))
            elif s["last_stamp"] is None:
                gaps.append((label(pid), sensor, "header-only uploads, no data"))
            elif s["last_stamp"] < cutoff:
                gaps.append((label(pid), sensor, "no data since %s UTC" % s["last_data"]))
    print()
    print("Gaps (no data upload in %g h, or never):" % args.stale_hours)
    for who, sensor, why in gaps:
        print("  %-14s %-30s %s" % (who, sensor, why))
    if not gaps:
        print("  none")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
