"""
db_runner.py — One-file Postgres manager (URL-based timeseries) for SpineSurgeryAI.

Commands:
  setup-db      -> create role & database (needs ADMIN_URL superuser, or run as postgres)
  init          -> create schema, indexes, materialized views, and views (idempotent)
  reset         -> DROP ALL objects (views/MVs/tables) then run init (DESTRUCTIVE)
  refresh       -> refresh all materialized views (tries CONCURRENTLY, falls back)
  seed          -> insert demo participants (P0001, P0002)
  insert-demo   -> insert demo URL rows across last 7 days + refresh MVs
  dashboard     -> print v_compliance_dashboard table
  exec-file     -> run an arbitrary .sql file

Connection:
  - App/admin operations use env vars:
      DATABASE_URL  (e.g., postgresql://user:pass@host:5432/dbname)
      ADMIN_URL     (e.g., postgresql://postgres@host:5432/postgres) for setup-db

Notes:
  - Timeseries tables store (participant_id, ts, object_url) for accel/gyro/hr.
  - MVs compute daily presence by counting rows per day; compliance views summarize 1/3 and 4/7 rules.
"""

from __future__ import annotations
import os
import sys
import argparse
from typing import Any, Dict, List, Optional, Sequence, Tuple
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
import psycopg2
from psycopg2 import sql
from psycopg2.extras import DictCursor, execute_values
from tabulate import tabulate

# =========================
# SQL: SCHEMA (URL model)
# =========================

SQL_01_BASE = r"""
CREATE TABLE IF NOT EXISTS participants (
  id           SERIAL PRIMARY KEY,
  external_id  TEXT UNIQUE NOT NULL,
  uploaded_at   TIMESTAMPTZ DEFAULT now()
);

-- URL-based timeseries: store pointer to object (e.g., S3) per timestamp
CREATE TABLE IF NOT EXISTS accelerometer (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  object_url     TEXT NOT NULL,
  uploaded_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gyroscope (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  object_url     TEXT NOT NULL,
  uploaded_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS heart_rate (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  ts             TIMESTAMPTZ NOT NULL,
  object_url     TEXT NOT NULL,
  uploaded_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pending_uploads (
  upload_id      UUID PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL CHECK (kind IN ('accel','gyro','hr')),
  object_key     TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','completed','failed')),
  error_message  TEXT,
  created_at     TIMESTAMPTZ DEFAULT now(),
  completed_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS pending_uploads_status_created_idx
  ON pending_uploads (status, created_at);

ALTER TABLE accelerometer ADD COLUMN IF NOT EXISTS file_size_bytes NUMERIC;
ALTER TABLE gyroscope ADD COLUMN IF NOT EXISTS file_size_bytes NUMERIC;
ALTER TABLE heart_rate ADD COLUMN IF NOT EXISTS file_size_bytes NUMERIC;
"""

SQL_02_INDEXES = r"""
-- Time-window helpers
CREATE INDEX IF NOT EXISTS ix_accel_participant_ts ON accelerometer (participant_id, ts);
CREATE INDEX IF NOT EXISTS ix_gyro_participant_ts  ON gyroscope     (participant_id, ts);
CREATE INDEX IF NOT EXISTS ix_hr_participant_ts    ON heart_rate    (participant_id, ts);
"""

# Daily presence materialized views (ANY data that day = present)
SQL_03_PRESENCE_MVS = r"""
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_accel_daily_presence AS
SELECT participant_id, ts::date AS day, COUNT(*) AS points
FROM accelerometer
GROUP BY participant_id, day
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_gyro_daily_presence AS
SELECT participant_id, ts::date AS day, COUNT(*) AS points
FROM gyroscope
GROUP BY participant_id, day
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_hr_daily_presence AS
SELECT participant_id, ts::date AS day, COUNT(*) AS points
FROM heart_rate
GROUP BY participant_id, day
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_survey_daily_presence AS
SELECT participant_id, survey_date AS day, COUNT(*) AS forms
FROM daily_survey
GROUP BY participant_id, day
WITH NO DATA;
"""

# Unique indexes on MVs to allow CONCURRENTLY refresh
SQL_03A_PRESENCE_MV_UNIQUES = r"""
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_accel_presence
  ON mv_accel_daily_presence (participant_id, day);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_gyro_presence
  ON mv_gyro_daily_presence (participant_id, day);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_hr_presence
  ON mv_hr_daily_presence (participant_id, day);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_survey_presence
  ON mv_survey_daily_presence (participant_id, day);
"""

# Optional daily_survey (for compliance parity)
SQL_03B_SURVEY_TABLE = r"""
CREATE TABLE IF NOT EXISTS daily_survey (
  id             BIGSERIAL PRIMARY KEY,
  participant_id INT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  survey_date    DATE NOT NULL,
  object_url     TEXT NOT NULL,
  payload        JSONB NOT NULL,
  uploaded_at     TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_survey_participant_date UNIQUE (participant_id, survey_date)
);

CREATE INDEX IF NOT EXISTS ix_survey_participant_date
ON daily_survey (participant_id, survey_date);
"""


SQL_04_COMPLIANCE_VIEWS = r"""
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

SQL_05_OVERVIEW = r"""
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
  gc.meets_4_of_7 AS gyro_4of_7,
  fn_color(gc.meets_4_of_7, gc.days_7, 4) AS gyro_color,

  hc.days_3  AS hr_days_3,
  hc.days_7  AS hr_days_7,
  hc.meets_1_of_3 AS hr_1of3,
  hc.meets_4_of_7 AS hr_4_of_7,
  fn_color(hc.meets_4_of_7, hc.days_7, 4) AS hr_color,

  sc.days_3  AS survey_days_3,
  sc.days_7  AS survey_days_7,
  sc.meets_1_of_3 AS survey_1of_3,
  sc.meets_4_of_7 AS survey_4_of_7,
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

SQL_07_AUTH_TABLES = r"""
CREATE TABLE IF NOT EXISTS users (
    id         SERIAL PRIMARY KEY,
    apple_id   VARCHAR(255) UNIQUE NOT NULL,
    email      VARCHAR(255),
    full_name  VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_refresh_tokens_hash ON refresh_tokens (token_hash);
"""

SQL_REFRESH_ALL_CONCURRENT = r"""
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_accel_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_gyro_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_hr_daily_presence;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_survey_daily_presence;
"""

SQL_REFRESH_ALL = r"""
REFRESH MATERIALIZED VIEW mv_accel_daily_presence;
REFRESH MATERIALIZED VIEW mv_gyro_daily_presence;
REFRESH MATERIALIZED VIEW mv_hr_daily_presence;
REFRESH MATERIALIZED VIEW mv_survey_daily_presence;
"""

SQL_SEED_PARTICIPANTS = r"""
INSERT INTO participants (external_id) VALUES
('P0001'), ('P0002')
ON CONFLICT (external_id) DO NOTHING;
"""

# Destructive drop of all objects (for reset)
SQL_DROP_ALL = r"""
-- Drop views and materialized views first (dependency order)
DROP VIEW IF EXISTS v_compliance_dashboard CASCADE;
DROP VIEW IF EXISTS v_last7_strips CASCADE;
DROP VIEW IF EXISTS v_hr_last7 CASCADE;
DROP VIEW IF EXISTS v_gyro_last7 CASCADE;
DROP VIEW IF EXISTS v_accel_last7 CASCADE;
DROP VIEW IF EXISTS v_survey_last7 CASCADE;
DROP VIEW IF EXISTS v_last7 CASCADE;
DROP VIEW IF EXISTS v_hr_compliance CASCADE;
DROP VIEW IF EXISTS v_gyro_compliance CASCADE;
DROP VIEW IF EXISTS v_accel_compliance CASCADE;
DROP VIEW IF EXISTS v_survey_compliance CASCADE;
DROP TABLE IF EXISTS refresh_tokens CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS ingestion_health CASCADE;

DROP FUNCTION IF EXISTS fn_compliance_from_presence(regclass) CASCADE;
DROP FUNCTION IF EXISTS fn_color(boolean,int,int) CASCADE;

DROP MATERIALIZED VIEW IF EXISTS mv_accel_daily_presence CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_gyro_daily_presence CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_hr_daily_presence CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_survey_daily_presence CASCADE;

-- Drop tables (children first because of FK constraints)
DROP TABLE IF EXISTS pending_uploads CASCADE;
DROP TABLE IF EXISTS accelerometer CASCADE;
DROP TABLE IF EXISTS gyroscope CASCADE;
DROP TABLE IF EXISTS heart_rate CASCADE;
DROP TABLE IF EXISTS daily_survey CASCADE;
DROP TABLE IF EXISTS participants CASCADE;
"""
SQL_06_INGESTION_HEALTH = r"""
CREATE TABLE IF NOT EXISTS ingestion_health (
    modality        TEXT        NOT NULL,
    participant_id  INT         NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
    window_start    TIMESTAMPTZ NOT NULL,
    window_end      TIMESTAMPTZ NOT NULL,

    -- Core counts / summary
    expected_count  INT         NOT NULL,
    actual_count    INT         NOT NULL,
    pct_expected    NUMERIC,
    status          TEXT,

    -- Detailed analysis fields from analyze_uploaded_data(...)
    format              TEXT,
    row_count           INT,
    sampling_rate_hz    NUMERIC,
    completeness        NUMERIC,
    total_gap_seconds   NUMERIC,
    gap_fraction        NUMERIC,
    is_usable           BOOLEAN,

    updated_at      TIMESTAMPTZ DEFAULT now(),

    PRIMARY KEY (modality, participant_id, window_start)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_ingestion_health
  ON ingestion_health (modality, participant_id, window_start);
"""

# =========================
# Helpers: connections
# =========================

def get_env(name: str) -> Optional[str]:
    v = os.getenv(name)
    return v if v and v.strip() else None

def strip_driver_prefix(url: str) -> str:
    # Allow SQLAlchemy-style URLs but psycopg2 needs 'postgresql://'
    return url.replace("postgresql+psycopg2://", "postgresql://")

@contextmanager
def connect_url(url_env: str, fallback: Optional[str] = None):
    load_dotenv()
    url = get_env(url_env) or fallback
    if not url:
        print(f"ERROR: set {url_env} or provide fallback.")
        sys.exit(1)
    dsn = strip_driver_prefix(url)
    conn = psycopg2.connect(dsn)
    try:
        conn.autocommit = True
        yield conn
    finally:
        conn.close()

def exec_sql(conn, sql_text: str, label: str):
    print(f"-> Executing: {label}")
    with conn.cursor() as cur:
        cur.execute(sql_text)

def exec_file_path(conn, path: str):
    with open(path, "r", encoding="utf-8") as f:
        txt = f.read()
    exec_sql(conn, txt, f"file {path}")

# =========================
# Admin: setup-db
# =========================

def setup_db(db_name: str, db_user: str, db_pass: str):
    """Create role and database (idempotent). Requires ADMIN_URL (superuser)."""
    with connect_url("ADMIN_URL") as conn:
        with conn.cursor() as cur:
            # create role
            cur.execute("""
                DO $$
                BEGIN
                  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s) THEN
                    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', %s, %s);
                  END IF;
                END$$;
            """, (db_user, db_user, db_pass))
            # create db owned by role
            cur.execute("""
                DO $$
                BEGIN
                  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = %s) THEN
                    EXECUTE format('CREATE DATABASE %I OWNER %I', %s, %s);
                  END IF;
                END$$;
            """, (db_name, db_name, db_user))

        print(f"✅ setup-db complete: db={db_name}, user={db_user}")

# =========================
# App-level operations
# =========================

def init_all():
    with connect_url("DATABASE_URL") as conn:
        exec_sql(conn, SQL_01_BASE, "01_base_schema")
        exec_sql(conn, SQL_02_INDEXES, "02_indexes")
        exec_sql(conn, SQL_03B_SURVEY_TABLE, "03b_daily_survey")
        exec_sql(conn, SQL_03_PRESENCE_MVS, "03_presence_mvs")
        exec_sql(conn, SQL_03A_PRESENCE_MV_UNIQUES, "03a_presence_mv_unique_indexes")
        exec_sql(conn, SQL_04_COMPLIANCE_VIEWS, "04_compliance_views")
        exec_sql(conn, SQL_05_OVERVIEW, "05_overview_views")
        exec_sql(conn, SQL_06_INGESTION_HEALTH, "06_ingestion_health")
        exec_sql(conn, SQL_07_AUTH_TABLES, "07_auth_tables")
        print("✅ init complete.")

def reset_all():
    """DESTRUCTIVE: drop everything, then run init."""
    with connect_url("DATABASE_URL") as conn:
        exec_sql(conn, SQL_DROP_ALL, "00_drop_all_objects")
    init_all()

def refresh_all():
    with connect_url("DATABASE_URL") as conn:
        try:
            exec_sql(conn, SQL_REFRESH_ALL_CONCURRENT, "refresh MV (concurrent)")
        except Exception as e:
            print(f"Concurrent refresh failed: {e}\nFalling back to non-concurrent...")
            exec_sql(conn, SQL_REFRESH_ALL, "refresh MV (non-concurrent)")
        print("✅ refresh complete.")

def seed_participants():
    with connect_url("DATABASE_URL") as conn:
        exec_sql(conn, SQL_SEED_PARTICIPANTS, "seed participants")
        print("✅ seed complete.")

def normalize_ts(ts: Any) -> str:
    if isinstance(ts, str):
        return ts
    if isinstance(ts, (int, float)):
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
    if isinstance(ts, datetime):
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return ts.isoformat()
    raise TypeError("Unsupported timestamp type for demo insert")

def insert_demo_rows():
    """Insert fake URL rows for last 7 days for P0001/P0002; then refresh."""
    with connect_url("DATABASE_URL") as conn:
        with conn.cursor(cursor_factory=DictCursor) as cur:
            # Ensure participants
            cur.execute("INSERT INTO participants (external_id) VALUES ('P0001'),('P0002') ON CONFLICT DO NOTHING;")
            cur.execute("SELECT id, external_id FROM participants WHERE external_id IN ('P0001','P0002') ORDER BY id;")
            parts = cur.fetchall()

            now = datetime.now(timezone.utc)
            accel_rows: List[Tuple[int, str, str]] = []
            gyro_rows:  List[Tuple[int, str, str]] = []
            hr_rows:    List[Tuple[int, str, str]] = []

            for p in parts:
                pid = p["id"]
                for d in range(7):
                    day = (now - timedelta(days=(6 - d))).replace(hour=12, minute=0, second=0, microsecond=0)
                    # 60% chance present that day
                    import random
                    if random.random() < 0.6:
                        t = normalize_ts(day)
                        accel_rows.append((pid, t, f"https://example.com/accel/{pid}/{int(day.timestamp())}.json"))
                        gyro_rows.append((pid, t, f"https://example.com/gyro/{pid}/{int(day.timestamp())}.json"))
                        hr_rows.append((pid, t, f"https://example.com/hr/{pid}/{int(day.timestamp())}.json"))

            if accel_rows:
                execute_values(cur,
                    "INSERT INTO accelerometer (participant_id, ts, object_url) VALUES %s",
                    accel_rows, page_size=1000)
            if gyro_rows:
                execute_values(cur,
                    "INSERT INTO gyroscope (participant_id, ts, object_url) VALUES %s",
                    gyro_rows, page_size=1000)
            if hr_rows:
                execute_values(cur,
                    "INSERT INTO heart_rate (participant_id, ts, object_url) VALUES %s",
                    hr_rows, page_size=1000)

            print(f"✅ inserted demo: accel={len(accel_rows)}, gyro={len(gyro_rows)}, hr={len(hr_rows)}")

    refresh_all()

def print_dashboard():
    with connect_url("DATABASE_URL") as conn:
        with conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute("SELECT * FROM v_compliance_dashboard ORDER BY participant_id;")
            rows = cur.fetchall()
            if not rows:
                print("No rows. Try: init -> (seed/insert-demo) -> refresh.")
                return
            print(tabulate([dict(r) for r in rows], headers="keys", tablefmt="github", disable_numparse=True))

def exec_file(path: str):
    with connect_url("DATABASE_URL") as conn:
        exec_file_path(conn, path)
        print(f"✅ executed file: {path}")

# =========================
# CLI
# =========================

def main():
    parser = argparse.ArgumentParser(description="Postgres manager (URL-based timeseries)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_setup = sub.add_parser("setup-db", help="create role & database (needs ADMIN_URL)")
    p_setup.add_argument("--db-name", required=True)
    p_setup.add_argument("--db-user", required=True)
    p_setup.add_argument("--db-pass", required=True)

    sub.add_parser("init", help="create schema, MVs, views")
    sub.add_parser("reset", help="DROP all objects and recreate schema (destructive)")
    sub.add_parser("refresh", help="refresh materialized views")
    sub.add_parser("seed", help="insert demo participants")
    sub.add_parser("insert-demo", help="insert demo URL rows + refresh")
    sub.add_parser("dashboard", help="print v_compliance_dashboard")

    p_exec = sub.add_parser("exec-file", help="execute a .sql file")
    p_exec.add_argument("path", help="path to .sql file")

    args = parser.parse_args()

    if args.cmd == "setup-db":
        setup_db(args.db_name, args.db_user, args.db_pass)
    elif args.cmd == "init":
        init_all()
    elif args.cmd == "reset":
        reset_all()
    elif args.cmd == "refresh":
        refresh_all()
    elif args.cmd == "seed":
        seed_participants()
    elif args.cmd == "insert-demo":
        insert_demo_rows()
    elif args.cmd == "dashboard":
        print_dashboard()
    elif args.cmd == "exec-file":
        exec_file(args.path)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
