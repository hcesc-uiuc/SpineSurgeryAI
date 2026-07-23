# User Profile & Enrollment API — contract for the Flask backend

Written June 2026 alongside the iOS implementation (branch `akarsh-issue-55`).
The iOS app already speaks this contract; implement it here and everything
starts syncing with **zero app changes**. A stub blueprint with TODOs is at
`routes/profile.py` (not yet registered in `app.py`).

## Why

1. **Any-device restore**: a participant who loses their phone signs in with
   the same Apple ID on a new device and gets their progress back (recovery
   day count, daily check-in calendar history, preferences) — like signing
   into Instagram on a new machine. The app keeps a local copy and only
   downloads when there is no local copy (**local always wins**); every local
   change is pushed up in full.
2. **Gated account creation**: only people holding a coordinator-issued
   6-digit study code can create an account. The app currently validates
   codes client-side against SHA-256 hashes baked into the binary
   (`ios/.../login/EnrollmentCode.swift`) — an accepted interim. The real
   gate belongs here (see `/auth/login` below).

## Identity

Profiles are keyed by `participant_id` — the app's anonymous SHA-256 hash of
the Apple per-user identifier (see `ios/.../util/ParticipantID.swift`). It is
deterministic across devices/reinstalls for the same Apple ID and contains no
PII. **Do not add name/PII fields to this schema** — the June 2026
anonymization work depends on it. Keep the auth-account ↔ participant_id
mapping siloed away from the research dataset.

## Endpoints

### GET /api/profile/<participant_id>

Returns the stored profile JSON verbatim, or **404** if none exists.
The app calls this once, only when it has no local copy.

### PUT /api/profile/<participant_id>

Body = the full profile JSON below. Upsert (replace whole document — the
app always sends the complete profile; local-wins means no server-side
merging). On success reply exactly:

```json
{ "status": "ok" }
```

The app checks for `"status": "ok"` before showing "Backed up" in Settings —
any other reply (including a 200 HTML error page) is treated as not-synced
and retried later, so partial deployments are safe.

### Profile JSON (snake_case on the wire)

```json
{
  "schema_version": 1,
  "participant_id": "9f2c…64-hex…",
  "enrollment_code": "483920",
  "enrolled_at": 1782000000.0,
  "first_open_date": 1782000000.0,
  "preferences": { "reminder_hour": 20, "reminder_minute": 0 },
  "survey_history": [
    { "date": "2026-07-01", "pain_score": 4, "completed": true },
    { "date": "2026-07-02", "pain_score": null, "completed": true }
  ],
  "updated_at": 1782086400.0
}
```

Notes:
- Timestamps are Unix seconds (floats). `date` is a local "yyyy-MM-dd" day.
- Nullable: `enrollment_code`, `enrolled_at`, `first_open_date`, `pain_score`.
- `schema_version` bumps on shape changes — store the raw document so old
  clients keep working.
- Suggested storage: one row per participant with a JSON column
  (participant_id PK, profile_json, updated_at) — no need to normalize.

### Auth on these endpoints

For now the iOS app is in demo mode and calls without a Bearer token. Once
`/auth/*` exists (see below), require `Authorization: Bearer <access_token>`
and verify the token's account maps to the requested `participant_id` —
otherwise any client can read/write any profile (same class of problem as
the existing `noauth` upload endpoints, backlog #30).

## Enrollment code — server side (replaces the in-app hash list)

Extend `POST /auth/login` (endpoint the iOS app already calls in non-demo
mode with `{ "identity_token": ..., "enrollment_code": <optional> }`):

1. Verify the Apple identity token; derive the stable Apple user id.
2. If an account for that Apple id **exists** → issue tokens (code ignored).
   This is what makes returning users skip the code prompt on new devices.
3. If **no account exists**:
   - `enrollment_code` missing or not in the server's code table → **403**
     with `{ "error": "invalid_enrollment_code" }`. The app maps 403 to a
     "code not recognized" message in the code sheet.
   - Valid code → create the account, optionally mark the code used
     (server-side codes can be single-use / revocable, which the in-app
     hash list cannot), issue tokens.
4. Keep a `enrollment_codes` table (code, active, used_by, used_at) managed
   by coordinators.

Once this is live, delete the hash list in `EnrollmentCode.swift` and let the
server be the only validator (the app already sends the code on first login).

## Token endpoints the app also expects (pre-existing, still unimplemented)

See `ios/.../login/SecureAuthManager.swift` header for the full flow:
`POST /auth/login` → `{access_token (15 min), refresh_token (365 d)}`,
`POST /auth/refresh`, `POST /auth/logout`, 401 body
`{ "error": "token_expired" | "invalid_grant" | "invalid_token" }`.

---

## Implementation notes (July 2026, branch akarsh-issue-55-backend-fixes)

Everything above is now implemented on this branch, on top of the existing
auth stack from branch 17/18 (`auth/` package). What changed and why:

### Profile sync — new
- `routes/profile.py` — GET/PUT `/api/profile/<participant_id>` exactly per
  this doc. PUT stores the raw request bytes so GET returns the document
  verbatim; replies exactly `{"status": "ok"}` (the app string-matches it).
  Validates participant_id-vs-URL, `schema_version` (known: 1), 256 KB cap.
- `profiles` table (participant_id TEXT PK, profile_json TEXT, updated_at
  DOUBLE PRECISION — not REAL: float4 can't hold unix seconds exactly).
  Auto-created at startup like the other tables.
- **Tokenless on purpose**: the shipped app is in demo mode and sends no
  Bearer token. When demo mode is removed, wrap both routes with
  `auth.middleware.require_auth` + a user→participant check.

### Enrollment gate — added inside the existing `auth/routes.py login()`
- New accounts only: missing/unknown/inactive code → **403**
  `{"error": "invalid_enrollment_code"}`. Existing accounts skip the check
  entirely (that's what stops re-prompting on new devices).
- `enrollment_codes` table (code PK, active, used_by → users.id, used_at).
  Codes are **reusable** (pilot policy, matches the old in-app hash list);
  `used_by`/`used_at` record the most recent use only. Coordinators manage
  codes with `manage_enrollment_codes.py` (add / deactivate / activate /
  list) — deactivation revokes a code without an app update.
- **PII removal**: `login()` no longer stores `email` (from the Apple token)
  or `full_name` (the app never sends it). The columns remain in `users`
  (no migration needed) but are always NULL for new accounts. Decided
  2026-07-10 per the anonymization requirements in "Identity" above.

### Tests
`tests/test_auth.py` extended (gate cases; the two new-user tests now send a
code) and `tests/test_profile.py` added — 29 tests total, all mocked-DB, no
network or Postgres needed: `python -m pytest tests/`.

### Deployment checklist
1. `JWT_SECRET` env var — config defaults to `""`; MUST be set in production.
2. `APPLE_BUNDLE_ID` env var — `edu.uiuc.cs.hcesc.SensingApp.v3`.
3. Load real codes: `python manage_enrollment_codes.py add <code> ...`.
4. After this is live: delete the hash list in `EnrollmentCode.swift`
   (iOS-side, separate change).

---

## v2 (July 2026) — 4-endpoint split-authority contract

The current iOS app (`ios/.../util/UserProfile.swift`, `schema_version: 2`)
splits the profile into two owners of truth and syncs them over four
endpoints instead of the single v1 GET/PUT. Implemented on `routes/profile.py`;
the v1 `/api/profile` routes stay as internal helpers (the app no longer calls
them). All four are **tokenless** for now, same as v1 — TODO: wrap them (and
v1) in `require_auth` + a user↔participant check when demo mode is removed.

**Split authority.** Two owners, reconciled on every login:
- **Server-owned**: `study_id` (P01…) and `survey_schedule`
  (daily/weekly/paused/ended). Coordinators set these; the phone pulls them on
  every login and overwrites its local copy — it never edits them.
- **Phone-owned**: `first_open_date` (the Day-N anchor) and `survey_history`
  (the calendar of *completed* check-ins — completion state only, never the
  survey answers). The phone owns these and pushes them up on every mutation.

### Endpoints

- **`GET /api/getstudyid/<participant_id>` → `{"study_id": "P01"}`.**
  Assign-or-return: the first time the server sees a hash it hands out the next
  id; later calls return the same one (idempotent). Numbers come from a Postgres
  `SEQUENCE` (race-safe); a SELECT-first fast path means repeat calls never burn
  a value. Assigns to *any* hash on request (matches the iOS bootstrap, which
  calls this on every login) — locking that down is part of the auth TODO.
- **`GET /api/getuserprofile/<participant_id>` → profile JSON | 404.**
  The v1 GET, renamed. Returns the stored document verbatim; the app calls it
  only when it has no local copy (fresh install / new device).
- **`GET /api/getsurveystatus/<participant_id>` → schedule JSON | 404.**
  `{cadence, weekly_day, note, updated_at}` (snake_case, decoded straight into
  iOS `SurveySchedule`). `weekly_day` is 1=Sunday…7=Saturday, non-null only for
  `weekly`. **404** = no schedule on file; the app keeps its daily default.
- **`POST /api/uploaduserprofile/<participant_id>` → `{"status": "ok"}`.**
  Upsert of the full document (same validation as v1 PUT: pid-match,
  `schema_version` ∈ {1, 2}, 256 KB cap). Stores phone-owned fields as sent, but
  **overwrites `study_id` and `survey_schedule` with the server's stored values**
  so a stale phone can't revert a coordinator change (when the server has no
  stored value yet, the sent value is kept). Because it rewrites those fields,
  the stored bytes are a re-serialization, not verbatim (unlike the v1 PUT).

### Storage — two new tables (auto-created in `app.py`, alongside `profiles`)
- `study_ids` (participant_id PK, study_id UNIQUE, assigned_at DOUBLE PRECISION)
  + a `study_id_seq` SEQUENCE. The participant→study_id map is the
  account↔participant kind of link the "Identity" section says to keep **siloed**
  from the research dataset — its own table, never joined into sensor/survey data.
- `survey_schedule` (participant_id PK, cadence, weekly_day INT, note,
  updated_at DOUBLE PRECISION) — one row per participant, coordinator-managed.

### Coordinators — `manage_survey_schedule.py` (mirrors `manage_enrollment_codes.py`)
```
python manage_survey_schedule.py daily  <participant_id> [--note "..."]
python manage_survey_schedule.py weekly <participant_id> --day <1-7> [--note "..."]
python manage_survey_schedule.py paused <participant_id> [--note "..."]
python manage_survey_schedule.py ended  <participant_id> [--note "..."]
python manage_survey_schedule.py show   <participant_id>
python manage_survey_schedule.py list
```

### Auth — off in demo, ready for production (the `REQUIRE_PROFILE_AUTH` switch)
All six profile routes carry the `require_profile_access` guard, gated by the
`REQUIRE_PROFILE_AUTH` config flag (env var, default **false**):

- **false (shipped default)** — tokenless passthrough, matching the iOS app's
  `demoMode = true` (it sends no Bearer token). Deploying this code changes
  nothing until the flag is set, so the live demo is never broken.
- **true (production)** — each route requires a valid access token AND that the
  token's account **owns** the `<participant_id>` in the URL; otherwise the
  app's structured 401 (`missing_token`/`token_expired`/`invalid_token`) or
  **403** `{"error":"forbidden"}`. Without this, anyone knowing a participant
  hash could read/write that participant's profile.

The ownership check uses a new **`account_participants`** map (user_id PK →
participant_id), populated at `/auth/login`: the server hashes the verified
Apple `sub` with SHA-256 — byte-for-byte what iOS `ParticipantID.hash` produces
— so it never trusts a client-sent id. Kept siloed from the research dataset
per "Identity". Token validation is shared with `require_auth` via
`auth.middleware.authenticate_bearer`.

**Going to production is a coordinated flip:**
1. iOS: set `demoMode = false` (deletes the three demo blocks in
   `SecureAuthManager.swift`) so the app sends Bearer tokens.
2. Server: `REQUIRE_PROFILE_AUTH=true`, and load real enrollment codes
   (`manage_enrollment_codes.py add …`) — in demo mode codes are checked
   client-side, but real `/auth/login` requires them in the DB or every new
   user gets 403.
3. Put the API behind **HTTPS** — the iOS `baseURL` is currently plaintext
   `http://`; tokens and hashes must not travel in the clear.

### Tests
`tests/test_survey_profile_v2.py` — all four endpoints (assign/idempotency,
404s, the server-authority overwrite, phone-owned passthrough, schema_version 2,
the v1 validation cases) plus the `REQUIRE_PROFILE_AUTH` enforcement path
(missing/expired token, ownership match/mismatch). `tests/test_auth.py` covers
the login→participant link. Mocked-DB like `test_profile.py`.
Full suite: `python -m pytest tests/` (55 tests).
