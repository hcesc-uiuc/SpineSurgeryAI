# routes/profile.py
#
# User-profile sync endpoints for the iOS app. Full contract, JSON shapes,
# and the enrollment-code /auth/login gate are documented in PROFILE_API.md —
# read that first.
#
# Two generations live here:
#   v1 (GET/PUT /api/profile/<pid>) — the original single-document sync. The
#      app no longer calls these; kept as internal helpers.
#   v2 (July 2026) — the 4-endpoint split-authority contract the current iOS
#      app speaks (see ios/.../util/UserProfile.swift):
#        GET  /api/getstudyid/<pid>        -> {"study_id": "P01"}   (assign-or-return)
#        GET  /api/getuserprofile/<pid>    -> profile JSON | 404
#        GET  /api/getsurveystatus/<pid>   -> schedule JSON | 404   (coordinator-owned)
#        POST /api/uploaduserprofile/<pid> -> {"status": "ok"}      (upsert)
#
# Split authority: study_id and survey_schedule are SERVER-owned (assigned /
# set by coordinators); first_open_date and survey_history are PHONE-owned.
# The upload route therefore overwrites the two server-owned fields with the
# values it has stored, so a stale phone can't revert a coordinator change.
#
# Storage is the `profiles`, `study_ids`, and `survey_schedule` tables
# (database/database.py). Local always wins for the phone-owned fields — the
# app sends the complete profile on every push.
#
# NOTE: deliberately tokenless for now. The shipped iOS app runs in demo
# mode and calls these without a Bearer token (see SecureAuthManager.swift).
# TODO: once the app leaves demo mode, wrap ALL routes below (v1 and the four
# v2 routes) with auth.middleware.require_auth and verify the token's user
# maps to <participant_id> (PROFILE_API.md "Auth"). Same class of gap as the
# noauth upload endpoints (backlog #30).

import json
import time
from functools import wraps

from flask import Blueprint, Response, current_app, jsonify, request

from auth.middleware import authenticate_bearer

profile_bp = Blueprint("profile", __name__)


def require_profile_access(view):
    """Gate a profile route on the REQUIRE_PROFILE_AUTH switch.

    Demo mode (flag off, the shipped default): pass straight through, tokenless
    — matches the iOS app's demoMode, which sends no Bearer token.

    Production (flag on, set together with iOS demoMode=false): require a valid
    access token AND that the token's account owns the <participant_id> in the
    URL (via the account_participants map populated at login). Otherwise any
    caller could read/write any participant's profile just by knowing the hash.

    Returns the app's structured 401 bodies (missing_token / token_expired /
    invalid_token) or 403 {"error": "forbidden"} on an ownership mismatch.
    """
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_app.config.get("REQUIRE_PROFILE_AUTH", False):
            return view(*args, **kwargs)

        user_id, error = authenticate_bearer()
        if error is not None:
            return error

        participant_id = kwargs.get("participant_id")
        try:
            linked = current_app.config["DB"].get_participant_id_for_user(int(user_id))
        except (TypeError, ValueError):
            linked = None
        if linked is None or linked != participant_id:
            return jsonify({"error": "forbidden"}), 403

        return view(*args, **kwargs)

    return wrapped

# The document grows by one small survey_history entry per day, so a real
# profile stays in the tens of KB; anything bigger is malformed or abuse.
MAX_PROFILE_BYTES = 256 * 1024

# schema_version values this server knows how to store (PROFILE_API.md).
# 1 = original single-document profile; 2 = split-authority (adds study_id,
# survey_schedule, sensor_status).
KNOWN_SCHEMA_VERSIONS = {1, 2}


@profile_bp.route("/profile/<participant_id>", methods=["GET"])
@require_profile_access
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
@require_profile_access
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


# ---------------------------------------------------------------------------
# v2 — split-authority contract (PROFILE_API.md). The iOS app calls these.
# ---------------------------------------------------------------------------

@profile_bp.route("/getstudyid/<participant_id>", methods=["GET"])
@require_profile_access
def get_study_id(participant_id):
    """Assign-or-return this participant's friendly study id (P01, P02, …).

    The first time the server sees a participant hash it hands out the next
    id; every later call returns the same one (idempotent). The app pulls this
    on every login and only displays it — it never generates one.
    """
    study_id = current_app.config["DB"].get_or_assign_study_id(
        participant_id, time.time()
    )
    return jsonify({"study_id": study_id})


@profile_bp.route("/getuserprofile/<participant_id>", methods=["GET"])
@require_profile_access
def get_user_profile(participant_id):
    """Return the stored profile JSON verbatim, or 404 if none exists.

    Called by the app only when it has no local copy (fresh install / new
    device) — this is what restores a participant's progress. (Same behaviour
    as the v1 GET; renamed for the v2 contract.)
    """
    profile_json = current_app.config["DB"].get_profile_json(participant_id)
    if profile_json is None:
        return jsonify({"error": "not_found"}), 404
    return Response(profile_json, mimetype="application/json")


@profile_bp.route("/getsurveystatus/<participant_id>", methods=["GET"])
@require_profile_access
def get_survey_status(participant_id):
    """Return the coordinator-set check-in schedule, or 404 if none is set.

    Shape (snake_case, decoded straight into iOS SurveySchedule):
        {"cadence": "daily"|"weekly"|"paused"|"ended",
         "weekly_day": 1-7 | null,   # 1=Sunday…7=Saturday, only for weekly
         "note": str | null,
         "updated_at": unix_seconds | null}
    404 means "no schedule on file"; the app keeps its local default (daily).
    """
    schedule = current_app.config["DB"].get_survey_schedule(participant_id)
    if schedule is None:
        return jsonify({"error": "not_found"}), 404
    return jsonify(
        {
            "cadence": schedule["cadence"],
            "weekly_day": schedule["weekly_day"],
            "note": schedule["note"],
            "updated_at": schedule["updated_at"],
        }
    )


@profile_bp.route("/uploaduserprofile/<participant_id>", methods=["POST"])
@require_profile_access
def upload_user_profile(participant_id):
    """Upsert the full profile document, reconciling server-owned fields.

    Phone-owned fields (first_open_date, survey_history, preferences,
    sensor_status) are stored as sent. Server-owned fields (study_id,
    survey_schedule) are OVERWRITTEN with the values the server has stored so
    a stale phone can't revert a coordinator change; when the server has no
    stored value yet, the sent value is left untouched.

    MUST reply exactly {"status": "ok"} on success — the app string-matches
    that before showing "Backed up" in Settings.
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
    # bool is an int subclass; JSON true must not pass as a version number
    if isinstance(schema_version, bool) or schema_version not in KNOWN_SCHEMA_VERSIONS:
        return jsonify({"error": "unsupported_schema_version"}), 400

    db = current_app.config["DB"]

    # Server authority: replace the echoed study_id / survey_schedule with the
    # server's own copies. Only overwrite when the server actually has a value,
    # so a first upload (before getstudyid / a coordinator schedule) keeps what
    # the phone sent instead of nulling it.
    stored_study_id = db.get_study_id(participant_id)
    if stored_study_id is not None:
        profile_document["study_id"] = stored_study_id

    stored_schedule = db.get_survey_schedule(participant_id)
    if stored_schedule is not None:
        profile_document["survey_schedule"] = {
            "cadence": stored_schedule["cadence"],
            "weekly_day": stored_schedule["weekly_day"],
            "note": stored_schedule["note"],
            "updated_at": stored_schedule["updated_at"],
        }

    updated_at = profile_document.get("updated_at")
    if isinstance(updated_at, bool) or not isinstance(updated_at, (int, float)):
        updated_at = time.time()

    db.upsert_profile_json(
        participant_id,
        json.dumps(profile_document),
        float(updated_at),
    )
    return jsonify({"status": "ok"})
