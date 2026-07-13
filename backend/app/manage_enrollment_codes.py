# manage_enrollment_codes.py
#
# Coordinator tool for the server-side enrollment codes that gate account
# creation on POST /auth/login (see PROFILE_API.md and auth/routes.py).
#
# Usage (from backend/app, with DATABASE_URL set / in .env):
#   python manage_enrollment_codes.py add 483920 [more codes...]
#   python manage_enrollment_codes.py deactivate 483920
#   python manage_enrollment_codes.py activate 483920
#   python manage_enrollment_codes.py list
#
# Codes are 6 digits, handed to participants out-of-band. Codes stay
# reusable after use (pilot policy — matches the old in-app hash list);
# deactivate revokes a code without an app update.

import argparse
import sys

from database.database import DB


def _valid_code(code: str) -> bool:
    return len(code) == 6 and code.isdigit()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    add_parser = subparsers.add_parser("add", help="add (or re-activate) codes")
    add_parser.add_argument("codes", nargs="+")

    activate_parser = subparsers.add_parser("activate", help="re-activate a code")
    activate_parser.add_argument("codes", nargs="+")

    deactivate_parser = subparsers.add_parser("deactivate", help="revoke a code")
    deactivate_parser.add_argument("codes", nargs="+")

    subparsers.add_parser("list", help="show all codes")

    args = parser.parse_args()
    db = DB()
    # enrollment_codes references users(id), so make sure both exist
    db.create_users_table()
    db.create_enrollment_codes_table()

    try:
        if args.command == "list":
            rows = db.list_enrollment_codes()
            if not rows:
                print("no enrollment codes")
                return 0
            for row in rows:
                status = "active" if row["active"] else "INACTIVE"
                used = f"last used {row['used_at']}" if row["used_at"] else "never used"
                print(f"{row['code']}  {status:8}  {used}")
            return 0

        for code in args.codes:
            code = code.strip()
            if not _valid_code(code):
                print(f"skipping {code!r}: codes are exactly 6 digits")
                continue
            if args.command in ("add", "activate"):
                db.add_enrollment_code(code)
                print(f"{code} active")
            else:
                changed = db.set_enrollment_code_active(code, False)
                print(f"{code} deactivated" if changed else f"{code} not found")
        return 0
    finally:
        db.close_all_pool_connections()


if __name__ == "__main__":
    sys.exit(main())
