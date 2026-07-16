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
