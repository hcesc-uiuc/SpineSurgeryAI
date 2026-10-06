# manage_enrollment_codes.py
#
# Coordinator tool for the server-side enrollment codes that gate account
# creation on POST /auth/login (see PROFILE_API.md and auth/routes.py).
#
# Usage (from backend/app, with DATABASE_URL set / in .env):
#   python manage_enrollment_codes.py generate 10          # 10 new random codes
#   python manage_enrollment_codes.py add 483920 [more codes...]
#   python manage_enrollment_codes.py deactivate 483920
#   python manage_enrollment_codes.py activate 483920
#   python manage_enrollment_codes.py list
#
# Codes are 6 digits, handed to participants out-of-band, and single-use:
# once a code enrolls an account it can't enroll anyone else. deactivate
# revokes an unused code without an app update.

import argparse
import secrets
import sys

from database.database import DB


def _valid_code(code: str) -> bool:
    return len(code) == 6 and code.isdigit()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate_parser = subparsers.add_parser("generate", help="create N new random codes")
    generate_parser.add_argument("count", type=int)

    for name, help_text in (
        ("add", "add specific new codes"),
        ("activate", "re-activate a code"),
        ("deactivate", "revoke a code"),
    ):
        subparsers.add_parser(name, help=help_text).add_argument("codes", nargs="+")

    subparsers.add_parser("list", help="show all codes")

    args = parser.parse_args()
    db = DB()
    # enrollment_codes references users(id); `list` also joins the
    # account→participant→study id tables, so make sure they all exist
    db.create_users_table()
    db.create_enrollment_codes_table()
    db.create_account_participants_table()
    db.create_study_ids_table()

    try:
        if args.command == "list":
            rows = db.list_enrollment_codes()
            if not rows:
                print("no enrollment codes")
            for row in rows:
                status = "active" if row["active"] else "INACTIVE"
                used = f"used {row['used_at']:%Y-%m-%d %H:%M}" if row["used_at"] else "unused"
                who = f"  -> {row['study_id']}" if row["study_id"] else ""
                print(f"{row['code']}  {status:8}  {used}{who}")
            return 0

        if args.command == "generate":
            created = 0
            while created < args.count:
                code = f"{secrets.randbelow(10**6):06d}"
                if db.add_enrollment_code(code):  # False on a (rare) collision; retry
                    print(code)
                    created += 1
            return 0

        failed = False
        for code in (c.strip() for c in args.codes):
            if not _valid_code(code):
                print(f"skipping {code!r}: codes are exactly 6 digits", file=sys.stderr)
                failed = True
            elif args.command == "add":
                added = db.add_enrollment_code(code)
                print(f"{code} added" if added else f"{code} already exists (left unchanged)")
                failed |= not added
            else:
                active = args.command == "activate"
                changed = db.set_enrollment_code_active(code, active)
                print(f"{code} {'activated' if active else 'deactivated'}" if changed else f"{code} not found")
                failed |= not changed
        return 1 if failed else 0
    finally:
        db.close_all_pool_connections()


if __name__ == "__main__":
    sys.exit(main())
