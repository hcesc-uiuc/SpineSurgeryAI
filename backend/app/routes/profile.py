# routes/profile.py
#
# STUB — user-profile sync endpoints for the iOS app. NOT yet registered in
# app.py (register with url_prefix="/api" once implemented). Full contract,
# JSON shapes, and the enrollment-code /auth/login extension are documented
# in PROFILE_API.md — read that first.
#
# The iOS side (branch akarsh-issue-55) already calls these endpoints and
# degrades gracefully while they 404, so this can be deployed incrementally.

from flask import Blueprint, request, jsonify

profile_bp = Blueprint("profile", __name__)


# TODO(backend): add storage. Suggested: table `profiles`
#   participant_id TEXT PRIMARY KEY,
#   profile_json   TEXT NOT NULL,   -- store the raw document verbatim
#   updated_at     REAL NOT NULL
# via the existing DB wrapper (database/database.py).


@profile_bp.route("/profile/<participant_id>", methods=["GET"])
def get_profile(participant_id):
    """Return the stored profile JSON verbatim, or 404 if none exists.

    Called by the app only when it has no local copy (fresh install /
    new device) — this is what restores a participant's progress.

    TODO(backend):
      - look up participant_id in the profiles table
      - 404 when absent: return jsonify({"error": "not_found"}), 404
      - once /auth is live: require a Bearer token and verify the token's
        account maps to participant_id (see PROFILE_API.md "Auth").
    """
    return jsonify({"error": "not_implemented"}), 404


@profile_bp.route("/profile/<participant_id>", methods=["PUT"])
def put_profile(participant_id):
    """Upsert the full profile document (local-wins: no server-side merge).

    MUST reply exactly {"status": "ok"} on success — the app checks that
    string before showing "Backed up" in Settings.

    TODO(backend):
      - body = request.get_json(); sanity-check body["participant_id"]
        matches the URL and body["schema_version"] is known
      - basic size cap / validation (see backlog #30 concerns)
      - upsert into profiles table
      - same Bearer-token check as GET once /auth is live
    """
    return jsonify({"error": "not_implemented"}), 501
