#!/usr/bin/env python3
"""
db_runner.py — One-file Postgres manager for your spine study.

What it does:
  • init          -> creates tables, indexes, materialized views, and views
  • refresh       -> refreshes daily presence MVs (run after new data ingests)
  • seed          -> inserts a couple of demo participants
  • insert-demo   -> inserts a few demo rows for testing
  • dashboard     -> prints v_compliance_dashboard
  • exec-file     -> runs an arbitrary .sql file (idempotent scripts recommended)

Connection:
  - Reads DATABASE_URL from environment or .env
    Example: postgresql://spine_app:spinepass@localhost:5432/spine_study
"""

import os
import sys
import argparse
import psycopg2
from psycopg2.extras import execute_batch, DictCursor
from dotenv import load_dotenv
from tabulate import tabulate

# ---------- SQL DEFINITIONS ----------

SQL_02_SCHEMA = r"""
CREATE TABLE IF NOT EXISTS participants (
  id           SERIAL PRIMARY KEY,
  external_id  TEXT UNIQUE NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS daily_survey (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  survey_date    DATE NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_survey_participant_date UNIQUE (participant_id, survey_date)
);

CREATE TABLE IF NOT EXISTS accelerometer (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  ax             REAL, ay REAL, az REAL,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gyroscope (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  gx             REAL, gy REAL, gz REAL,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS heart_rate (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  bpm            REAL,
  created_at     TIMESTAMPTZ DEFAULT now()
);
"""

SQL_03_INDEXES = r"""
CREATE INDEX IF NOT EXISTS ix_accel_participant_ts ON accelerometer (participant_id, ts);
CREATE INDEX IF NOT EXISTS ix_gyro_participant_ts  ON gyroscope     (participant_id, ts);
CREATE INDEX IF NOT EXISTS ix_hr_participant_ts    ON heart_rate    (participant_id, ts);
CREATE INDEX IF NOT EXISTS ix_survey_participant_date ON daily_survey (participant_id, survey_date);
"""

# Daily presence materialized views (ANY data = present)
SQL_04_PRESENCE_MVS = r"""
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_accel_daily_presence AS
SELECT participant_id, (ts AT TIME ZONE 'UTC')::date AS day, COUNT(*) AS points
FROM accelerometer
GROUP BY participant_id, day
WITH NO DATA;
CREATE INDEX IF NOT EXISTS ix_mv_accel_presence ON mv_accel_daily_presence (participant_id, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_gyro_daily_presence AS
SELECT participant_id, (ts AT TIME ZONE 'UTC')::date AS day, COUNT(*) AS points
FROM gyroscope
GROUP BY participant_id, day
WITH NO DATA;
CREATE INDEX IF NOT EXISTS ix_mv_gyro_presence ON mv_gyro_daily_presence (participant_id, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_hr_daily_presence AS
SELECT participant_id, (ts AT TIME ZONE 'UTC')::date AS day, COUNT(*) AS points
FROM heart_rate
GROUP BY participant_id, day
WITH NO DATA;
CREATE INDEX IF NOT EXISTS ix_mv_hr_presence ON mv_hr_daily_presence (participant_id, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_survey_daily_presence AS
SELECT participant_id, survey_date AS day, COUNT(*) AS forms
FROM daily_survey
GROUP BY participant_id, day
WITH NO DATA;
CREATE INDEX IF NOT EXISTS ix_mv_survey_presence ON mv_survey_daily_presence (participant_id, day);
"""

# FIXED: dynamic SQL via plpgsql so we can pass a table name
SQL_05_COMPLIANCE_VIEWS = r"""
CREATE OR REPLACE FUNCTION fn_compliance_from_presence(presence_table regclass)
RETURNS TABLE (
  participant_id INT,
  days_3 INT,
  days_7 INT,
  meets_1_of_3 BOOLEAN,
  meets_4_of_7 BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  RETURN QUERY EXECUTE format($f$
    WITH win AS (
      SELECT
        participant_id,
        (COUNT(*) FILTER (WHERE day >= current_date - INTERVAL '2 day'))::int AS days_3,
        (COUNT(*) FILTER (WHERE day >= current_date - INTERVAL '6 day'))::int AS days_7
      FROM %s
      WHERE day >= current_date - INTERVAL '6 day'
      GROUP BY participant_id
    )
    SELECT
      participant_id,
      COALESCE(days_3, 0)::int AS days_3,
      COALESCE(days_7, 0)::int AS days_7,
      (COALESCE(days_3, 0) >= 1) AS meets_1_of_3,
      (COALESCE(days_7, 0) >= 4) AS meets_4_of_7
    FROM win
  $f$, presence_table::text);
END;
$$;

CREATE OR REPLACE VIEW v_accel_compliance AS
SELECT * FROM fn_compliance_from_presence('mv_accel_daily_presence');

CREATE OR REPLACE VIEW v_gyro_compliance AS
SELECT * FROM fn_compliance_from_presence('mv_gyro_daily_presence');

CREATE OR REPLACE VIEW v_hr_compliance AS
SELECT * FROM fn_compliance_from_presence('mv_hr_daily_presence');

CREATE OR REPLACE VIEW v_survey_compliance AS
SELECT * FROM fn_compliance_from_presence('mv_survey_daily_presence');
"""


SQL_06_OVERVIEW = r"""
CREATE OR REPLACE FUNCTION fn_color(flag boolean, close int, target int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN flag IS TRUE THEN 'green'
           WHEN close >= target - 1 THEN 'yellow'
           ELSE 'red'
         END;
$$;

CREATE OR REPLACE VIEW v_last7 AS
SELECT generate_series(current_date - INTERVAL '6 day', current_date, '1 day')::date AS day;

CREATE OR REPLACE VIEW v_accel_last7 AS
SELECT p.id AS participant_id, s.day,
       CASE WHEN a.points IS NOT NULL THEN 1 ELSE 0 END AS present
FROM participants p
CROSS JOIN v_last7 s
LEFT JOIN mv_accel_daily_presence a
       ON a.participant_id = p.id AND a.day = s.day;

CREATE OR REPLACE VIEW v_gyro_last7 AS
SELECT p.id AS participant_id, s.day,
       CASE WHEN g.points IS NOT NULL THEN 1 ELSE 0 END AS present
FROM participants p
CROSS JOIN v_last7 s
LEFT JOIN mv_gyro_daily_presence g
       ON g.participant_id = p.id AND g.day = s.day;

CREATE OR REPLACE VIEW v_hr_last7 AS
SELECT p.id AS participant_id, s.day,
       CASE WHEN h.points IS NOT NULL THEN 1 ELSE 0 END AS present
FROM participants p
CROSS JOIN v_last7 s
LEFT JOIN mv_hr_daily_presence h
       ON h.participant_id = p.id AND h.day = s.day;

CREATE OR REPLACE VIEW v_survey_last7 AS
SELECT p.id AS participant_id, s.day,
       CASE WHEN v.forms IS NOT NULL THEN 1 ELSE 0 END AS present
FROM participants p
CROSS JOIN v_last7 s
LEFT JOIN mv_survey_daily_presence v
       ON v.participant_id = p.id AND v.day = s.day;

CREATE OR REPLACE VIEW v_last7_strips AS
SELECT
  p.id AS participant_id,
  ARRAY_AGG(al.present ORDER BY al.day) AS accel_strip,
  ARRAY_AGG(gl.present ORDER BY gl.day) AS gyro_strip,
  ARRAY_AGG(hrl.present ORDER BY hrl.day) AS hr_strip,
  ARRAY_AGG(sl.present  ORDER BY sl.day) AS survey_strip
FROM participants p
JOIN v_accel_last7  al ON al.participant_id = p.id
JOIN v_gyro_last7   gl ON gl.participant_id = p.id AND gl.day = al.day
JOIN v_hr_last7     hrl ON hrl.participant_id = p.id AND hrl.day = al.day
JOIN v_survey_last7 sl  ON sl.participant_id = p.id AND sl.day = al.day
GROUP BY p.id;

CREATE OR REPLACE VIEW v_compliance_dashboard AS
SELECT
  p.id AS participant_id,
  p.external_id,

  ac.days_3  AS accel_days_3,
  ac.days_7  AS accel_days_7,
  ac.meets_1_of_3 AS accel_1of3,
  ac.meets_4_of_7 AS accel_4of7,
  fn_color(ac.meets_4_of_7, ac.days_7, 4) AS accel_color,

  gc.days_3  AS gyro_days_3,
  gc.days_7  AS gyro_days_7,
  gc.meets_1_of_3 AS gyro_1of3,
  gc.meets_4_of_7 AS gyro_4of7,
  fn_color(gc.meets_4_of_7, gc.days_7, 4) AS gyro_color,

  hc.days_3  AS hr_days_3,
  hc.days_7  AS hr_days_7,
  hc.meets_1_of_3 AS hr_1of3,
  hc.meets_4_of_7 AS hr_4of_7,
  fn_color(hc.meets_4_of_7, hc.days_7, 4) AS hr_color,

  sc.days_3  AS survey_days_3,
  sc.days_7  AS survey_days_7,
  sc.meets_1_of_3 AS survey_1of3,
  sc.meets_4_of_7 AS survey_4of_7,
  fn_color(sc.meets_4_of_7, sc.days_7, 4) AS survey_color,

  strips.accel_strip,
  strips.gyro_strip,
  strips.hr_strip,
  strips.survey_strip

FROM participants p
LEFT JOIN v_accel_compliance ac  ON ac.participant_id = p.id
LEFT JOIN v_gyro_compliance  gc  ON gc.participant_id = p.id
LEFT JOIN v_hr_compliance    hc  ON hc.participant_id = p.id
LEFT JOIN v_survey_compliance sc ON sc.participant_id = p.id
LEFT JOIN v_last7_strips strips  ON strips.participant_id = p.id
ORDER BY p.id;
"""

SQL_REFRESH_ALL = r"""
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_accel_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_gyro_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_hr_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_survey_daily_presence;
"""

SQL_SEED_PARTICIPANTS = r"""
INSERT INTO participants (external_id) VALUES
('P0001'), ('P0002')
ON CONFLICT (external_id) DO NOTHING;
"""

# ---------- HELPER CODE ----------

def get_conn():
    load_dotenv()
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        print("ERROR: Set DATABASE_URL env var (e.g., postgresql://user:pass@localhost:5432/spine_study)")
        sys.exit(1)
    try:
        conn = psycopg2.connect(dsn)
        conn.autocommit = True
        return conn
    except Exception as e:
        print("Connection error:", e)
        sys.exit(1)

def exec_sql(conn, sql: str, label: str):
    print(f"-> Executing: {label}")
    with conn.cursor() as cur:
        cur.execute(sql)

def exec_file(conn, path: str):
    with open(path, "r", encoding="utf-8") as f:
        sql = f.read()
    exec_sql(conn, sql, f"file {path}")

def init_all(conn):
    exec_sql(conn, SQL_02_SCHEMA, "02_schema")
    exec_sql(conn, SQL_03_INDEXES, "03_indexes")
    exec_sql(conn, SQL_04_PRESENCE_MVS, "04_presence_materialized_views")
    exec_sql(conn, SQL_05_COMPLIANCE_VIEWS, "05_compliance_views")
    exec_sql(conn, SQL_06_OVERVIEW, "06_overview_views")
    print("✅ init complete.")

def refresh_all(conn):
    # Use non-concurrent if first-time populate or when concurrent fails
    try:
        exec_sql(conn, SQL_REFRESH_ALL, "refresh MVs (concurrently)")
    except Exception:
        print("Concurrent refresh failed. Falling back to non-concurrent...")
        with conn.cursor() as cur:
            for mv in ("mv_accel_daily_presence","mv_gyro_daily_presence","mv_hr_daily_presence","mv_survey_daily_presence"):
                print(f"-> REFRESH MATERIALIZED VIEW {mv}")
                cur.execute(f"REFRESH MATERIALIZED VIEW {mv};")
    print("✅ refresh complete.")

def seed(conn):
    exec_sql(conn, SQL_SEED_PARTICIPANTS, "seed participants")
    print("✅ seed complete.")

def insert_demo(conn):
    """Insert a few demo rows across the last 7 days for P0001, P0002."""
    from datetime import datetime, timedelta, timezone
    import random

    with conn.cursor(cursor_factory=DictCursor) as cur:
        cur.execute("SELECT id, external_id FROM participants ORDER BY id;")
        parts = cur.fetchall()
        if not parts:
            print("No participants — seeding first.")
            seed(conn)
            cur.execute("SELECT id, external_id FROM participants ORDER BY id;")
            parts = cur.fetchall()

        now = datetime.now(timezone.utc)
        accel_points, gyro_points, hr_points = [], [], []

        for p in parts:
            pid = p["id"]
            for d in range(7):
                day = now - timedelta(days=(6 - d))
                if random.random() < 0.6:
                    for _ in range(random.randint(2, 6)):
                        ts = day.replace(hour=random.randint(8, 21),
                                         minute=random.randint(0,59),
                                         second=random.randint(0,59))
                        accel_points.append((pid, ts.isoformat(), random.uniform(-1,1), random.uniform(-1,1), random.uniform(-1,1)))
                        gyro_points.append((pid, ts.isoformat(), random.uniform(-180,180), random.uniform(-180,180), random.uniform(-180,180)))
                        hr_points.append((pid, ts.isoformat(), random.uniform(55, 110)))

        cur.execute("SET timezone TO 'UTC';")
        if accel_points:
            execute_batch(cur,
                "INSERT INTO accelerometer (participant_id, ts, ax, ay, az) VALUES (%s, %s, %s, %s, %s)",
                accel_points, page_size=1000
            )
        if gyro_points:
            execute_batch(cur,
                "INSERT INTO gyroscope (participant_id, ts, gx, gy, gz) VALUES (%s, %s, %s, %s, %s)",
                gyro_points, page_size=1000
            )
        if hr_points:
            execute_batch(cur,
                "INSERT INTO heart_rate (participant_id, ts, bpm) VALUES (%s, %s, %s)",
                hr_points, page_size=1000
            )

    print(f"✅ inserted demo rows: accel={len(accel_points)}, gyro={len(gyro_points)}, hr={len(hr_points)}")
    refresh_all(conn)
    
def print_dashboard(conn):
    with conn.cursor(cursor_factory=DictCursor) as cur:
        cur.execute("SELECT * FROM v_compliance_dashboard ORDER BY participant_id;")
        rows = cur.fetchall()
        if not rows:
            print("No rows in v_compliance_dashboard. Did you run 'init' and 'refresh' and add data?")
            return

        # Convert DictRow -> dict for tabulate
        records = [dict(r) for r in rows]

        # Optional: if you want a narrower view, uncomment and adjust:
        # wanted = [
        #   "participant_id","external_id",
        #   "accel_days_3","accel_days_7","accel_1of3","accel_4of7","accel_color",
        #   "gyro_days_7","gyro_4of7","gyro_color",
        #   "hr_days_7","hr_4of7","hr_color",
        #   "survey_days_7","survey_4of7","survey_color",
        # ]
        # records = [{k: rec.get(k) for k in wanted} for rec in records]

        # Print full table
        from tabulate import tabulate
        print(tabulate(records, headers="keys", tablefmt="github", disable_numparse=True))


# ---------- CLI ----------

def main():
    parser = argparse.ArgumentParser(description="Postgres manager for spine study DB")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="create schema, indexes, MVs, views")
    sub.add_parser("refresh", help="refresh presence MVs")
    sub.add_parser("seed", help="insert demo participants")
    sub.add_parser("insert-demo", help="insert demo timeseries data + refresh MVs")
    sub.add_parser("dashboard", help="print v_compliance_dashboard")
    p_exec = sub.add_parser("exec-file", help="execute a .sql file")
    p_exec.add_argument("path", help="path to .sql file")

    args = parser.parse_args()
    conn = get_conn()

    try:
        if args.cmd == "init":
            init_all(conn)
        elif args.cmd == "refresh":
            refresh_all(conn)
        elif args.cmd == "seed":
            seed(conn)
        elif args.cmd == "insert-demo":
            insert_demo(conn)
        elif args.cmd == "dashboard":
            print_dashboard(conn)
        elif args.cmd == "exec-file":
            exec_file(conn, args.path)
        else:
            parser.print_help()
    finally:
        conn.close()

if __name__ == "__main__":
    main()
