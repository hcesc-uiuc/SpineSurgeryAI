# study_roster.py
#
# Coordinator report: who enrolled, with which code, and what data each
# participant has sent. Match study ids / codes against your own offline
# roster — the server deliberately stores no names.
#
# Usage (from backend/app, with DATABASE_URL set / in .env):
#   python study_roster.py              # enrolled participants and their data
#   python study_roster.py unenrolled   # data from hashes that never enrolled
#
# Each data cell is "<uploads> <last upload date>". "unenrolled" lists data
# sent under participant hashes with no enrolled account (strangers, test
# phones, demo-mode installs) — exclude it from analysis.

import argparse
import sys

from database.database import DB

KINDS = ("accel", "gyro", "hr", "survey", "other")


def _date(ts) -> str:
    return f"{ts:%Y-%m-%d}" if ts else "-"


def _group(rows):
    """Fold (participant, kind) rows into one dict per participant, in order."""
    people = {}
    for row in rows:
        person = people.setdefault(row["participant_id"], {**row, "data": {}})
        if row["kind"]:
            person["data"][row["kind"]] = f"{row['uploads']} {_date(row['last_upload'])}"
    return list(people.values())


def _print_table(headers, people, columns):
    print("  ".join(f"{h:<16}" if h in KINDS else f"{h:<12}" for h in headers))
    for person in people:
        cells = [f"{c(person) or '-':<12}" for c in columns]
        cells += [f"{person['data'].get(k, '-'):<16}" for k in KINDS]
        print("  ".join(cells))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("view", nargs="?", default="roster", choices=("roster", "unenrolled"))
    args = parser.parse_args()

    db = DB()
    try:
        if args.view == "roster":
            people = _group(db.get_study_roster())
            if not people:
                print("no enrolled participants")
                return 0
            _print_table(
                ("STUDY ID", "CODE", "ENROLLED", "PARTICIPANT", *KINDS),
                people,
                (lambda p: p["study_id"], lambda p: p["code"],
                 lambda p: p["enrolled_at"] and _date(p["enrolled_at"]),
                 lambda p: p["participant_id"][:12]),
            )
        else:
            people = _group(db.get_unenrolled_uploads())
            if not people:
                print("no data from un-enrolled participants")
                return 0
            _print_table(("PARTICIPANT", *KINDS), people, (lambda p: p["participant_id"][:12],))
        return 0
    finally:
        db.close_all_pool_connections()


if __name__ == "__main__":
    sys.exit(main())
