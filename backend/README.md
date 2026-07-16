# SpineSurgeryAI

Research study system for tracking recovery after spine surgery. Participants
wear an Apple Watch and use our iOS app, which collects motion sensor data and
a short daily survey. A Flask backend ingests everything into S3 + Postgres and
gives study coordinators dashboards to monitor compliance.

Two halves in this repo:

```
ios/SensingApp/     SwiftUI app (SensorKit/HealthKit collection, surveys,
                    Apple Sign In, profile sync)
backend/app/        Flask server (this README mostly covers this part)
```

The production server runs on EC2. The app's base URL is set in
`SecureAuthManager.swift`.

## How data moves through the system

1. The app records accelerometer, gyroscope, and heart-rate data and exports
   it as files, plus one survey JSON per day.
2. Files go to S3 **directly from the phone** via presigned URLs:
   - `POST /api/uploads/presign` — server validates, creates a row in
     `pending_uploads`, returns a presigned PUT URL (15 min expiry; objects
     land in `uploads/<kind>/...` with AES256 + Glacier IR)
   - the app PUTs the file straight to S3
   - `POST /api/uploads/complete` — server does an S3 `head_object` to verify
     the file really exists, then inserts a row in the matching data table.
     Completion is idempotent, so the app can safely retry.
3. Data rows are inserted with a placeholder timestamp (1970-01-01) because
   the real recording time is inside the file. `checker.py` is a separate
   worker loop that downloads recent objects, parses out the actual recording
   window, fixes `ts`, and writes quality stats (sampling rate, completeness,
   gaps) to `ingestion_health`.
4. Materialized views compute "did participant X upload anything on day Y",
   and compliance views roll that up into the 1-of-3 / 4-of-7 day rules the
   study uses. The dashboards read those views.

## Identity and anonymity

This is the most important design constraint in the codebase. The patient's
name/identity must never reach the research dataset.

- At sign-in the app computes `participant_id` = SHA-256 of Apple's per-user
  identifier (`ParticipantID.swift`). That hash is what tags all uploaded
  data (`participants.external_id` in Postgres). It's deterministic across
  devices/reinstalls, and one-way.
- The auth tables (`users`, `refresh_tokens`) are separate from the research
  tables — no foreign keys between them.
- As of July 2026, `login()` does **not** store email or full name (Apple
  sends email in the identity token; we drop it deliberately). The columns
  still exist in `users` but stay NULL.
- Do not add name/PII fields to any of this without talking to the team
  first. See `backend/app/PROFILE_API.md` ("Identity").

## Auth

Apple Sign In, verified server-side (`backend/app/auth/`):

- `POST /auth/login` — body `{identity_token, enrollment_code?}`. The
  identity token (a JWT from Apple) is verified against Apple's public keys
  with audience = our bundle ID (`auth/apple.py`). Returns
  `{access_token, refresh_token}`.
- Access token: HS256 JWT signed with `JWT_SECRET`, currently 24 h TTL,
  `sub` = internal user id. Refresh token: random 512-bit value, 365 d,
  stored as a SHA-256 hash in `refresh_tokens`.
- `POST /auth/refresh` returns a new access token only (the refresh token is
  not rotated). `POST /auth/logout` revokes the refresh token.
- Protected routes use the `@require_auth` decorator (`auth/middleware.py`),
  which sets `g.user_id` and returns 401 bodies
  (`token_expired` / `invalid_token`) that the iOS app knows how to handle.

**Enrollment gate**: creating a *new* account requires a 6-digit code that a
study coordinator handed out. Unknown/missing/deactivated code → 403
`{"error": "invalid_enrollment_code"}`. Returning users are never asked
again — if the Apple ID already has an account, the code is ignored. Codes
live in the `enrollment_codes` table and are managed with:

```
python manage_enrollment_codes.py add 483920
python manage_enrollment_codes.py deactivate 483920
python manage_enrollment_codes.py list
```

Codes are reusable (many participants can enroll with one code); deactivating
a code stops new enrollments without needing an app update. This replaces the
interim SHA-256 hash list baked into the app (`EnrollmentCode.swift`), which
should be deleted from the iOS side once this is deployed.

Note: the shipped app currently runs in demo mode and doesn't send Bearer
tokens yet. That's why `routes/upload_noauth.py` exists (mirror endpoints
that take `participant_id` explicitly) and why the profile endpoints below
are tokenless. Both are marked TEMPORARY in the code and get locked down
when the app's demo mode is removed.

## Profile sync

`GET/PUT /api/profile/<participant_id>` (`routes/profile.py`) backs up the
app's local user profile — recovery day count, check-in calendar history,
preferences — so a participant who signs in on a new phone gets their
progress back. The server stores the JSON document verbatim in the
`profiles` table and never merges (the app always sends the full profile;
local wins). PUT must reply exactly `{"status": "ok"}` — the app
string-matches that before showing "Backed up". Full contract, including
error cases and the schema, is in `backend/app/PROFILE_API.md`.

## Database

Postgres, accessed through a connection-pooled wrapper class
(`database/database.py`). No ORM — plain SQL via psycopg2.

Core research schema is created by `database/database_runner.py`
(`python database_runner.py init`, idempotent; also has `reset`, `refresh`,
`seed`, `insert-demo`, `dashboard` commands). Auxiliary tables are created
automatically at app startup by `create_*_table()` calls in `app.py`, so a
fresh deploy self-heals.

Research data:

| table | contents |
|---|---|
| `participants` | internal serial `id` + `external_id` (the participant hash) |
| `accelerometer`, `gyroscope`, `heart_rate` | one row per uploaded file: `ts`, `object_url` (S3 key), `file_size_bytes` |
| `daily_survey` | one row per participant per day, JSONB payload |
| `ingestion_health` | per-file quality stats written by `checker.py` |
| `mv_*_daily_presence` | materialized views: rows per participant per day |
| `v_*_compliance`, `v_compliance_dashboard`, `v_last7_strips` | compliance rollups the dashboards read |

Operational tables (created at startup):

| table | contents |
|---|---|
| `pending_uploads` | in-flight presigned uploads (pending/completed/failed) |
| `users`, `refresh_tokens` | Apple Sign In accounts + sessions (no PII stored) |
| `enrollment_codes` | coordinator-issued study codes (active flag, last use) |
| `device_tokens` | APNs tokens for push notifications |
| `profiles` | raw profile JSON documents, one per participant |

## Endpoints at a glance

```
Auth            POST /auth/login  /auth/refresh  /auth/logout
Uploads         POST /api/uploads/presign  /api/uploads/complete   (Bearer)
                POST /api/uploadjson  /api/uploadjson/survey       (Bearer)
                POST /api/noauth/...                               (TEMPORARY, no token)
Profile sync    GET/PUT /api/profile/<participant_id>              (tokenless for now)
Device tokens   POST /api/uploadDeviceToken
Dashboards      GET /  /dashboard  /compliance  /compliance/<id>
                GET /heatmap/<id>  /totalcompliance
                GET /presence/<modality>/<id>  /health/<id>        (JSON for charts)
```

Old `/api/uploadfile*` endpoints return 410 — replaced by the presign flow.

## Running locally

```
cd backend/app
python -m venv venv
venv\Scripts\activate            # or source venv/bin/activate
pip install -r requirements.txt
```

`.env` in `backend/app/` (loaded via python-dotenv):

```
DATABASE_URL=postgresql://user:pass@localhost:5432/spine_study
AWS_KEY=...              # S3 credentials (note: not AWS_ACCESS_KEY_ID)
AWS_SECRET_KEY=...
AWS_REGION=us-east-2
AWS_BUCKET=...
JWT_SECRET=...           # REQUIRED — config defaults to "" which is unsafe
APPLE_BUNDLE_ID=edu.uiuc.cs.hcesc.SensingApp.v3
```

Then:

```
python database_runner.py init    # once, creates the research schema (run from database/)
python app.py                     # dev server on :5000
python -m pytest tests/          # 29 tests, mocked DB — no Postgres/network needed
```

`checker.py` (the timestamp/quality worker) runs as its own process:
`python checker.py`.

Production runs via `wsgi.py` / the Dockerfile (Flask + Jupyter image).

## Deployment checklist

1. `JWT_SECRET` and `APPLE_BUNDLE_ID` set in the environment.
2. Enrollment codes loaded (`manage_enrollment_codes.py add ...`).
3. `database_runner.py init` has been run against the target DB (startup
   auto-creates the auxiliary tables, but not the research schema/views).
4. Once live and the app leaves demo mode: remove the `noauth` blueprint,
   add `require_auth` to the profile routes, and delete the hash list in
   `EnrollmentCode.swift` on the iOS side.
