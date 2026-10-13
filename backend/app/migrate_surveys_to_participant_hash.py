"""One-time: move surveys filed under an account number to the participant hash.

Before #82, /api/uploadjson/survey filed surveys under the caller's internal
account number (participants.external_id = "1", "2", ...). #82 files them under
the participant hash, SHA-256(apple_id), like every other data type. This moves
the old rows so each participant's history lives under one participant.

Dry run by default: everything runs in one transaction that is then rolled
back, so the printed counts are exact. --apply commits instead.
Never deletes participants (daily_survey cascades on participant delete).
A day the hash participant already has is left in place and reported.

    python migrate_surveys_to_participant_hash.py [--apply]
"""
import argparse
import os
import sys

import psycopg2
from dotenv import load_dotenv

# Only participants whose external_id is a real account number are touched.
PAIRS_SQL = """
SELECT u.id, src.id, encode(sha256(convert_to(u.apple_id, 'UTF8')), 'hex')
FROM users u
JOIN participants src ON src.external_id = u.id::text
ORDER BY u.id
"""

MOVE_SQL = """
UPDATE daily_survey d SET participant_id = %(dst)s
WHERE d.participant_id = %(src)s
  AND NOT EXISTS (SELECT 1 FROM daily_survey x
                  WHERE x.participant_id = %(dst)s AND x.survey_date = d.survey_date)
"""


def _count_surveys(cur, participant_id):
    cur.execute("SELECT count(*) FROM daily_survey WHERE participant_id = %s", (participant_id,))
    return cur.fetchone()[0]


def move_surveys(conn):
    """Move rows inside the caller's transaction. Returns one dict per account
    that had surveys under its account number."""
    report = []
    with conn.cursor() as cur:
        cur.execute(PAIRS_SQL)
        for user_id, src_pid, target_ext in cur.fetchall():
            if _count_surveys(cur, src_pid) == 0:
                continue

            cur.execute("SELECT id FROM participants WHERE external_id = %s", (target_ext,))
            row = cur.fetchone()
            created = row is None
            if created:
                cur.execute("INSERT INTO participants (external_id) VALUES (%s) RETURNING id", (target_ext,))
                row = cur.fetchone()

            cur.execute(MOVE_SQL, {"src": src_pid, "dst": row[0]})
            report.append({
                "user_id": user_id,
                "target": target_ext,
                "target_created": created,
                "moved": cur.rowcount,
                "left_same_day": _count_surveys(cur, src_pid),
            })

        if any(r["moved"] for r in report):
            cur.execute("REFRESH MATERIALIZED VIEW mv_survey_daily_presence")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="commit (default: dry run)")
    args = parser.parse_args()

    load_dotenv()
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    try:
        report = move_surveys(conn)
        for r in report:
            print(f"user {r['user_id']} -> {r['target'][:8]}... "
                  f"moved={r['moved']} left_same_day={r['left_same_day']}"
                  f"{' (participant created)' if r['target_created'] else ''}")
        if not report:
            print("nothing to move")
        if args.apply:
            conn.commit()
            print("applied")
        else:
            conn.rollback()
            print("dry run: rolled back, rerun with --apply to commit")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
