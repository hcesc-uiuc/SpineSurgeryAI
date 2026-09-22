"""
sensorkit_report.py -- Issue #74.

Answers "is each SensorKit sensor actually producing data?" from what phones
have uploaded. For every sensorkit_* object under uploads/other/ it reads the
first 4 KB, counts rows after the CSV header, and joins the object to its
participant through pending_uploads.

Per participant and sensor it prints: uploads, uploads with data rows,
header-only uploads, repeated uploads (same size as the previous upload, the
processed/ collision bug), total size and the last upload that had data.

Run where the backend runs (needs AWS_BUCKET, AWS credentials or the instance
role, and DATABASE_URL):

    python sensorkit_report.py                   # all participants
    python sensorkit_report.py --since 2026-09-14
    python sensorkit_report.py --participant 0c2435962352   # hash prefix
    python sensorkit_report.py --exclude-participant a956a786be18   # e.g. the test harness
"""

import argparse
import os
import re
from collections import defaultdict

import boto3
import psycopg2
from dotenv import load_dotenv

KEY_RE = re.compile(r"^uploads/other/(\d{8}T\d{6})_(sensorkit_[a-z]+_[a-z]+)_\d{5}\.csv$")


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
                "where pu.object_key like 'uploads/other/%sensorkit_%'")
    owner = dict(cur.fetchall())

    since = args.since.replace("-", "") if args.since else None
    objects = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="uploads/other/"):
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
                                 "repeats": 0, "bytes": 0, "last_data": "-", "prev_size": None})
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
        else:
            s["header_only"] += 1

    print("%-14s %-30s %7s %9s %11s %7s %11s  %s" % (
        "participant", "sensor", "uploads", "with_data", "header_only", "repeats", "total_MB", "last_data_upload"))
    for (pid, sensor), s in sorted(stats.items()):
        print("%-14s %-30s %7d %9d %11d %7d %11.2f  %s" % (
            pid[:12], sensor, s["uploads"], s["with_data"], s["header_only"], s["repeats"],
            s["bytes"] / 1e6, s["last_data"]))

    print()
    by_sensor = defaultdict(lambda: [0, 0])
    for (pid, sensor), s in stats.items():
        by_sensor[sensor][0] += s["uploads"]
        by_sensor[sensor][1] += s["with_data"]
    print("%-30s %7s %9s  %s" % ("sensor", "uploads", "with_data", "verdict"))
    for sensor, (n, d) in sorted(by_sensor.items()):
        print("%-30s %7d %9d  %s" % (sensor, n, d, "DATA SEEN" if d else "NO DATA YET"))


if __name__ == "__main__":
    main()
