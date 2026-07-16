# routes/profile.py
#
# User-profile sync endpoints for the iOS app. Full contract, JSON shapes,
# and the enrollment-code /auth/login gate are documented in PROFILE_API.md —
# read that first.
#
# Storage is the `profiles` table (database/database.py): one raw JSON
# document per participant, stored verbatim. Local always wins — the app
# sends the complete profile on every push, so PUT replaces the whole row.
#
# NOTE: deliberately tokenless for now. The shipped iOS app runs in demo
# mode and calls these without a Bearer token (see SecureAuthManager.swift).
# Once the app leaves demo mode, protect both routes with
# auth.middleware.require_auth and verify the token's user maps to
# <participant_id> (PROFILE_API.md "Auth").

import json
import time

from flask import Blueprint, Response, current_app, jsonify, request

profile_bp = Blueprint("profile", __name__)

# The document grows by one small survey_history entry per day, so a real
# profile stays in the tens of KB; anything bigger is malformed or abuse.
MAX_PROFILE_BYTES = 256 * 1024

# schema_version values this server knows how to store (PROFILE_API.md).
KNOWN_SCHEMA_VERSIONS = {1}


@profile_bp.route("/profile/<participant_id>", methods=["GET"])
def get_profile(participant_id):
    """Return the stored profile JSON verbatim, or 404 if none exists.

    Called by the app only when it has no local copy (fresh install /
    new device) — this is what restores a participant's progress.
    """
    profile_json = current_app.config["DB"].get_profile_json(participant_id)
    if profile_json is None:
        return jsonify({"error": "not_found"}), 404
    return Response(profile_json, mimetype="application/json")


@profile_bp.route("/profile/<participant_id>", methods=["PUT"])
def put_profile(participant_id):
    """Upsert the full profile document (local-wins: no server-side merge).

    MUST reply exactly {"status": "ok"} on success — the app checks that
    string before showing "Backed up" in Settings.
    """
    if request.content_length is not None and request.content_length > MAX_PROFILE_BYTES:
        return jsonify({"error": "payload_too_large"}), 413

    raw_profile_bytes = request.get_data()
    if len(raw_profile_bytes) > MAX_PROFILE_BYTES:
        return jsonify({"error": "payload_too_large"}), 413

    try:
        profile_document = json.loads(raw_profile_bytes)
    except (ValueError, UnicodeDecodeError):
        return jsonify({"error": "invalid_json"}), 400
    if not isinstance(profile_document, dict):
        return jsonify({"error": "invalid_json"}), 400

    if profile_document.get("participant_id") != participant_id:
        return jsonify({"error": "participant_id_mismatch"}), 400

    schema_version = profile_document.get("schema_version")
    # bool is an int subclass; JSON true must not pass as version 1
    if isinstance(schema_version, bool) or schema_version not in KNOWN_SCHEMA_VERSIONS:
        return jsonify({"error": "unsupported_schema_version"}), 400

    updated_at = profile_document.get("updated_at")
    if isinstance(updated_at, bool) or not isinstance(updated_at, (int, float)):
        updated_at = time.time()

    current_app.config["DB"].upsert_profile_json(
        participant_id,
        raw_profile_bytes.decode("utf-8"),
        float(updated_at),
    )
    return jsonify({"status": "ok"})
