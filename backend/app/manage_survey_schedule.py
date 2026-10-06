# manage_survey_schedule.py
#
# Coordinator tool for the server-side survey schedule that the iOS app pulls
# on every login (GET /api/getsurveystatus — see PROFILE_API.md v2 and
# routes/profile.py). The schedule is SERVER-authoritative: the phone only
# reads it, so setting it here is how a coordinator changes a participant's
# check-in cadence without an app update.
#
# Usage (from backend/app, with DATABASE_URL set / in .env). <pid> is the
# participant_id hash (64-hex), the same key the profile is stored under:
#   python manage_survey_schedule.py daily  <pid> [--note "..."]
#   python manage_survey_schedule.py weekly <pid> --day <1-7> [--note "..."]
#   python manage_survey_schedule.py paused <pid> [--note "..."]
#   python manage_survey_schedule.py ended  <pid> [--note "..."]
#   python manage_survey_schedule.py show   <pid>
#   python manage_survey_schedule.py list
#
# Cadences mirror iOS SurveyCadence: daily / weekly / paused / ended.
# --day is the weekly check-in weekday, 1=Sunday…7=Saturday
# (Calendar.component(.weekday)); required for `weekly`, ignored otherwise.

import argparse
import sys
import time

from database.database import DB

CADENCES = ("daily", "weekly", "paused", "ended")
_WEEKDAY_NAMES = {
    1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
    5: "Thursday", 6: "Friday", 7: "Saturday",
}


def _format_row(row: dict) -> str:
    cadence = row["cadence"]
    detail = ""
    if cadence == "weekly":
        day = row.get("weekly_day")
        detail = f" on {_WEEKDAY_NAMES.get(day, day)}" if day else " (no day set)"
    note = f"  — {row['note']}" if row.get("note") else ""
    return f"{row['participant_id']}  {cadence}{detail}{note}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    for cadence in CADENCES:
        set_parser = subparsers.add_parser(cadence, help=f"set {cadence} cadence")
        set_parser.add_argument("participant_id")
        set_parser.add_argument("--note", default=None, help="optional coordinator message")
        if cadence == "weekly":
            set_parser.add_argument(
                "--day", type=int, required=True,
                help="weekday 1=Sunday…7=Saturday",
            )

    show_parser = subparsers.add_parser("show", help="show one participant's schedule")
    show_parser.add_argument("participant_id")

    subparsers.add_parser("list", help="show all schedules")

    args = parser.parse_args()
    db = DB()
    db.create_survey_schedule_table()

    try:
        if args.command == "list":
            rows = db.list_survey_schedules()
            if not rows:
                print("no survey schedules set")
                return 0
            for row in rows:
                print(_format_row(row))
            return 0

        if args.command == "show":
            row = db.get_survey_schedule(args.participant_id)
            if not row:
                print(f"{args.participant_id}: no schedule set (app uses daily default)")
                return 0
            print(_format_row(dict(row, participant_id=args.participant_id)))
            return 0

        # A cadence subcommand: daily / weekly / paused / ended.
        weekly_day = None
        if args.command == "weekly":
            if not 1 <= args.day <= 7:
                print("error: --day must be 1 (Sunday) … 7 (Saturday)")
                return 2
            weekly_day = args.day

        db.upsert_survey_schedule(
            args.participant_id,
            args.command,
            weekly_day,
            args.note,
            time.time(),
        )
        print(_format_row({
            "participant_id": args.participant_id,
            "cadence": args.command,
            "weekly_day": weekly_day,
            "note": args.note,
        }))
        return 0
    finally:
        db.close_all_pool_connections()


if __name__ == "__main__":
    sys.exit(main())
