# SpineSurgeryAI Upload System — Full Flow Reference

Branch: `s3-direct-ios-upload-26`
Date: 2026-04-27

This document describes every upload path that exists in the backend, who
calls each one, exactly what happens server-side, what gets written to S3
and Postgres, and what edge cases are handled. Nothing is omitted.

---

## 1. Architecture overview

```
┌────────────────┐        HTTP (plain, port 80)        ┌────────────────────┐
│                │ ─────────────────────────────────▶  │                    │
│  iOS app       │                                     │  EC2 / Flask       │
│  (SensingApp)  │ ◀─────────────────────────────────  │  18.116.67.186*    │
│                │                                     │                    │
└──┬─────────────┘                                     │  upload_bp         │
   │                                                   │  upload_noauth_bp  │
   │   HTTPS (presigned PUT only)                      │                    │
   │                                                   └──┬─────────────────┘
   │                                                      │ boto3
   ▼                                                      ▼
┌─────────────────────────────────────┐         ┌──────────────────────────┐
│  AWS S3                             │         │  AWS Postgres (RDS)      │
│  bucket = $AWS_BUCKET               │         │  participants            │
│  region = $AWS_REGION               │         │  accelerometer           │
│                                     │         │  gyroscope               │
│  uploads/accel/<utc>_<file>         │         │  heart_rate              │
│  uploads/gyro/<utc>_<file>          │         │  daily_survey            │
│  uploads/hr/<utc>_<file>            │         │  pending_uploads         │
│  uploads/<utc>_<file>     (legacy)  │         │  ingestion_health        │
│  surveys/<pid>/<date>_<HHMMSS>.json │         │  users / refresh_tokens  │
│                                     │         │  device_tokens           │
│  StorageClass = GLACIER_IR          │         └──────────────────────────┘
│  ServerSideEncryption = AES256      │
└─────────────────────────────────────┘

* The IP `18.116.67.186` is hardcoded in iOS at `Uploader.swift:13` and
  `SurveyUploader.swift:36`. It was previously flagged as possibly wrong.
```

### Blueprints registered in [backend/app/app.py](backend/app/app.py)

| Blueprint            | Module                              | URL prefix | Auth?        |
|----------------------|-------------------------------------|-----------:|--------------|
| `upload_bp`          | `routes/upload.py`                  | `/api`     | yes (JWT)    |
| `upload_noauth_bp`   | `routes/upload_noauth.py`           | `/api`     | none (TEMP)  |
| `device_token_bp`    | `routes/device_token.py`            | `/api`     | n/a          |
| `dashboard_api`      | `routes/dashboard_api.py`           | (root)     | n/a          |
| `dashboard_page`     | `routes/dashboard_page.py`          | (root)     | n/a          |
| `auth_bp`            | `auth/routes.py`                    | (root)     | n/a          |

---

## 2. Authentication model

### 2.1 `@require_auth` decorator — [backend/app/auth/middleware.py:7](backend/app/auth/middleware.py:7)

```
Authorization: Bearer <jwt>
       │
       ▼
jwt.decode(token, JWT_SECRET, algorithms=['HS256'])
       │   │
       │   ├─ ExpiredSignatureError ─▶ 401 {"error":"token_expired"}
       │   ├─ InvalidTokenError     ─▶ 401 {"error":"invalid_token"}
       │   └─ no Bearer header      ─▶ 401 {"error":"missing_token"}
       ▼
g.user_id = payload["sub"]   ← the JWT's `sub` claim becomes the
                                external participant id used for DB inserts
```

**Implication:** the iOS `Uploader.swift` does NOT set `Authorization` on
its presign / complete requests. As written, those requests would 401
against the auth-required routes today. The noauth blueprint exists
specifically to allow iOS to upload before iOS-side auth is finished.

### 2.2 Noauth blueprint — TEMPORARY

Every `/api/noauth/*` route bypasses the decorator and instead reads
`participantId` (or `participant_id`) from the request body or form.
File header at [backend/app/routes/upload_noauth.py:1](backend/app/routes/upload_noauth.py:1):

> "TEMPORARY: No-auth upload endpoints for development/testing.
>  Remove this file and its blueprint registration in app.py when auth is ready on iOS."

---

## 3. Route inventory

| Route                                       | Method | Auth | Purpose                              | Status     |
|---------------------------------------------|:------:|:----:|--------------------------------------|------------|
| `/api/uploads/presign`                      | POST   | yes  | Get S3 presigned PUT URL (sensor)    | active     |
| `/api/uploads/complete`                     | POST   | yes  | Finalize sensor upload, insert DB    | active     |
| `/api/uploadjson`                           | POST   | yes  | Stream JSON to S3 + insert_accel     | active     |
| `/api/uploadjson/survey`                    | POST   | yes  | Stream survey JSON to S3 + DB upsert | active     |
| `/api/uploadfile`                           | POST   | yes  | (legacy stream-through)              | **410**    |
| `/api/uploadfile/accel`                     | POST   | yes  | (legacy stream-through)              | **410**    |
| `/api/uploadfile/gyro`                      | POST   | yes  | (legacy stream-through)              | **410**    |
| `/api/uploadfile/heartrate`                 | POST   | yes  | (legacy stream-through)              | **410**    |
| `/api/noauth/uploads/presign`               | POST   | no   | Presign for sensor (noauth)          | active     |
| `/api/noauth/uploads/complete`              | POST   | no   | Finalize noauth presigned upload     | active     |
| `/api/noauth/uploadjson`                    | POST   | no   | Stream JSON to S3 + insert_accel     | active     |
| `/api/noauth/uploadfile`                    | POST   | no   | Multipart stream → S3 + insert_accel | active     |
| `/api/noauth/uploadfile/accel`              | POST   | no   | Multipart stream → S3 + insert_accel | active     |
| `/api/noauth/uploadfile/gyro`               | POST   | no   | Multipart stream → S3 + insert_gyro  | active     |
| `/api/noauth/uploadfile/heartrate`          | POST   | no   | Multipart stream → S3 + insert_hr    | active     |
| `/api/noauth/uploadjson/survey`             | POST   | no   | Survey JSON → S3 + upsert            | active     |

---

## 4. PATH A — Auth-required presigned (3-step) — sensor files

The "modern" path that iOS [Uploader.swift](ios/SensingApp/SensingApp/util/Uploader.swift) targets.

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║ PATH A — /api/uploads/presign  +  PUT to S3  +  /api/uploads/complete         ║
╚═══════════════════════════════════════════════════════════════════════════════╝

iOS                            EC2 / Flask                       AWS S3        DB
 │                                  │                              │            │
 │  POST /api/uploads/presign       │                              │            │
 │  Authorization: Bearer <jwt>     │                              │            │
 │  Body (JSON):                    │                              │            │
 │   { filename:"log_2026-02-19.txt"│                              │            │
 │     content_type:"application/   │                              │            │
 │                  octet-stream",  │                              │            │
 │     size: <bytes>,               │                              │            │
 │     kind: "accel"|"gyro"|"hr" }  │                              │            │
 │ ───────────────────────────────▶ │                              │            │
 │                                  │ @require_auth                │            │
 │                                  │  ├─ no/bad token → 401       │            │
 │                                  │  └─ g.user_id = jwt.sub      │            │
 │                                  │                              │            │
 │                                  │ Validate body:               │            │
 │                                  │  ├─ filename missing → 400   │            │
 │                                  │  └─ kind ∉ {accel,gyro,hr}   │            │
 │                                  │       → 400                  │            │
 │                                  │                              │            │
 │                                  │ NOTE: `size` is read but     │            │
 │                                  │ never used (dead field).     │            │
 │                                  │                              │            │
 │                                  │ upload_id = uuid.uuid4()     │            │
 │                                  │ key = f"uploads/{kind}/      │            │
 │                                  │   {utc:%Y%m%dT%H%M%S}_       │            │
 │                                  │   {secure_filename(name)}"   │            │
 │                                  │                              │            │
 │                                  │ presigned_url =              │            │
 │                                  │   s3.generate_presigned_url( │            │
 │                                  │     "put_object",            │            │
 │                                  │     Params = {               │            │
 │                                  │       Bucket, Key,           │            │
 │                                  │       ContentType,           │            │
 │                                  │       SSE:"AES256",          │            │
 │                                  │       StorageClass:          │            │
 │                                  │         "GLACIER_IR" },      │            │
 │                                  │     ExpiresIn = 900)         │            │
 │                                  │   (signs with EC2's          │            │
 │                                  │    AWS_KEY/AWS_SECRET_KEY    │            │
 │                                  │    via SigV4 query params)   │            │
 │                                  │                              │            │
 │                                  │ db.create_pending_upload(    │            │
 │                                  │   upload_id, g.user_id,      │            │
 │                                  │   kind, key)                 │            │
 │                                  │ ──────────────────────────────────────────▶│
 │                                  │                              │  INSERT INTO│
 │                                  │                              │  participants│
 │                                  │                              │   (upsert)  │
 │                                  │                              │  INSERT INTO│
 │                                  │                              │  pending_   │
 │                                  │                              │  uploads    │
 │                                  │                              │  (status=   │
 │                                  │                              │   'pending')│
 │                                  │                              │            │
 │  201                             │                              │            │
 │  { upload_id, key,               │                              │            │
 │    url:<presigned PUT URL>,      │                              │            │
 │    headers: {                    │                              │            │
 │      Content-Type:               │                              │            │
 │        application/octet-stream, │                              │            │
 │      x-amz-server-side-          │                              │            │
 │        encryption: AES256,       │                              │            │
 │      x-amz-storage-class:        │                              │            │
 │        GLACIER_IR },             │                              │            │
 │    expires_in: 900 }             │                              │            │
 │ ◀─────────────────────────────── │                              │            │
 │                                  │                              │            │
 │  PUT  <presigned url>            │                              │            │
 │  Headers: from response verbatim │                              │            │
 │  Body: raw file bytes (streamed  │                              │            │
 │        from disk via             │                              │            │
 │        URLSession.upload(        │                              │            │
 │          for:fromFile:))         │                              │            │
 │ ──────────────────────────────────────────────────────────────▶ │            │
 │                                  │                              │ Validates  │
 │                                  │                              │ SigV4      │
 │                                  │                              │ signature; │
 │                                  │                              │ object     │
 │                                  │                              │ stored at  │
 │                                  │                              │ <key>      │
 │  200 (or 403/5xx)                │                              │            │
 │ ◀────────────────────────────────────────────────────────────── │            │
 │                                  │                              │            │
 │  uploadSuccess = (status==200)   │                              │            │
 │                                  │                              │            │
 │  POST /api/uploads/complete      │                              │            │
 │  Authorization: Bearer <jwt>     │                              │            │
 │  Body: { upload_id, success,     │                              │            │
 │           error? }               │                              │            │
 │ ───────────────────────────────▶ │                              │            │
 │                                  │ @require_auth → g.user_id    │            │
 │                                  │                              │            │
 │                                  │ if not upload_id → 400       │            │
 │                                  │                              │            │
 │                                  │ pending = db.get_pending_    │            │
 │                                  │   upload(upload_id)          │            │
 │                                  │   (now JOINs participants    │            │
 │                                  │    so external_id is         │            │
 │                                  │    available)                │            │
 │                                  │  ├─ not found     → 404      │            │
 │                                  │  └─ status≠pending           │            │
 │                                  │       → 200 cached           │            │
 │                                  │       {status, key}          │            │
 │                                  │     (idempotent replay)      │            │
 │                                  │                              │            │
 │                                  │ if success == True:          │            │
 │                                  │   try:                       │            │
 │                                  │     s3.head_object(B,K) ─────────────────▶│
 │                                  │                              │  HEAD k    │
 │                                  │                              │  ◀ 200/404 │
 │                                  │   except:                    │            │
 │                                  │     mark_upload_failed(      │            │
 │                                  │       "object not found...") │            │
 │                                  │     → 200 {status:"failed",  │            │
 │                                  │            error:...}        │            │
 │                                  │                              │            │
 │                                  │   dispatch on pending.kind:  │            │
 │                                  │     accel → db.insert_accel( │            │
 │                                  │              g.user_id,      │            │
 │                                  │              [{"url":key}])  │            │
 │                                  │     gyro  → db.insert_gyro(  │            │
 │                                  │              g.user_id,...)  │            │
 │                                  │     hr    → db.insert_hr(    │            │
 │                                  │              g.user_id,...)  │            │
 │                                  │   (ts defaults to            │            │
 │                                  │    "1970-01-01T00:00:00+00:00│            │
 │                                  │    " placeholder; fixed      │            │
 │                                  │    later by checker job)     │            │
 │                                  │ ──────────────────────────────────────────▶│
 │                                  │                              │ INSERT INTO│
 │                                  │                              │ accel/gyro/│
 │                                  │                              │ hr (pid,ts,│
 │                                  │                              │   url)     │
 │                                  │                              │            │
 │                                  │   db.mark_upload_completed(  │            │
 │                                  │     upload_id)               │            │
 │                                  │     UPDATE pending_uploads   │            │
 │                                  │     SET status='completed',  │            │
 │                                  │         completed_at=now()   │            │
 │                                  │     WHERE upload_id=…        │            │
 │                                  │       AND status='pending'   │            │
 │                                  │   → 200 {status:"completed", │            │
 │                                  │           key}               │            │
 │                                  │                              │            │
 │                                  │ else (success == False):     │            │
 │                                  │   try:                       │            │
 │                                  │     s3.delete_object(B,K) ────────────────▶│
 │                                  │                              │ DELETE k   │
 │                                  │   except: pass               │            │
 │                                  │   db.mark_upload_failed(     │            │
 │                                  │     upload_id, error_msg)    │            │
 │                                  │   → 200 {status:"failed"}    │            │
 │  200 …                           │                              │            │
 │ ◀─────────────────────────────── │                              │            │
 ▼                                  ▼                              ▼            ▼
```

### 4.1 Why presigned

`s3.generate_presigned_url` builds a URL containing the SigV4 signature
in the query string. iOS does NOT need any AWS credentials — possession
of the URL itself, for the next 900 seconds, authorizes exactly one PUT
on exactly that bucket+key with exactly the headers that were signed.

The signed headers (per `Params`) are: `Content-Type`,
`x-amz-server-side-encryption`, `x-amz-storage-class`. iOS must send
those values verbatim or S3 returns `SignatureDoesNotMatch`.

### 4.2 Edge cases for Path A

| Scenario                                        | Outcome                                                                              |
|-------------------------------------------------|--------------------------------------------------------------------------------------|
| Missing/expired/invalid JWT                     | 401 from `@require_auth` before any work                                             |
| Missing `filename`                              | 400 `"missing filename"`                                                             |
| `kind` not in {accel,gyro,hr}                   | 400 `"kind must be accel, gyro, or hr"`                                              |
| Presign URL expires before iOS PUT              | S3 returns 403 → iOS sees status≠200 → calls `/complete` with `success=false` → row marked failed (no DB sensor insert) |
| iOS PUT succeeds; iOS crashes before /complete  | Object lives in S3, `pending_uploads` row stays `'pending'` indefinitely (no sweeper) |
| iOS lies: `success=true` but no S3 object       | `head_object` raises → row marked failed; no insert into accel/gyro/hr               |
| /complete called twice with same upload_id      | 2nd call returns cached `{status, key}` (200) — `WHERE status='pending'` guard       |
| /complete with unknown upload_id                | 404 `"upload not found"`                                                             |
| /complete with `success=false`                  | best-effort `s3.delete_object` (errors swallowed) + mark_upload_failed               |
| iOS mutates signed headers                      | S3 `SignatureDoesNotMatch` → step 2 fails → Path-A failure flow                      |
| EC2 boto3 client lacks `s3:HeadObject`          | head_object raises → `success=true` paths all become failures                        |
| Bucket has Object Lock or different SSE policy  | S3 PUT may 400; iOS sees ≠200 → calls /complete success=false                        |

---

## 5. PATH B — Noauth presigned (3-step) — sensor files

Mirror of Path A with the auth decorator removed and `participantId`
read from the request body. Implemented in
[backend/app/routes/upload_noauth.py](backend/app/routes/upload_noauth.py).

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║ PATH B — /api/noauth/uploads/presign + PUT to S3 + /api/noauth/uploads/complete║
╚═══════════════════════════════════════════════════════════════════════════════╝

iOS / curl                     EC2 / Flask                       AWS S3        DB
 │                                  │                              │            │
 │  POST /api/noauth/uploads/presign│                              │            │
 │  Body (JSON):                    │                              │            │
 │   { participantId: "P0001",      │                              │            │
 │     filename, content_type,      │                              │            │
 │     size?, kind }                │                              │            │
 │ ───────────────────────────────▶ │                              │            │
 │                                  │ NO @require_auth             │            │
 │                                  │                              │            │
 │                                  │ Validate body:               │            │
 │                                  │  ├─ participantId missing    │            │
 │                                  │       → 400                  │            │
 │                                  │  ├─ filename missing → 400   │            │
 │                                  │  └─ kind ∉ {accel,gyro,hr}   │            │
 │                                  │       → 400                  │            │
 │                                  │                              │            │
 │                                  │ upload_id = uuid.uuid4()     │            │
 │                                  │ key = f"uploads/{kind}/      │            │
 │                                  │   {utc}_{filename}"          │            │
 │                                  │                              │            │
 │                                  │ presigned_url = s3.generate_ │            │
 │                                  │   presigned_url(...)         │            │
 │                                  │   (identical Params to       │            │
 │                                  │    Path A)                   │            │
 │                                  │                              │            │
 │                                  │ db.create_pending_upload(    │            │
 │                                  │   upload_id, participantId,  │            │
 │                                  │   kind, key)                 │            │
 │                                  │   (creates participant if    │            │
 │                                  │    missing; FK to            │            │
 │                                  │    participants.id)          │            │
 │                                  │ ──────────────────────────────────────────▶│
 │                                  │                              │ pending_   │
 │                                  │                              │ uploads    │
 │                                  │                              │ row        │
 │  201 (same shape as Path A)      │                              │            │
 │ ◀─────────────────────────────── │                              │            │
 │                                  │                              │            │
 │  PUT <presigned url>             │                              │            │
 │  (identical to Path A step 2)    │                              │            │
 │ ──────────────────────────────────────────────────────────────▶ │            │
 │  200/403/5xx                     │                              │            │
 │ ◀────────────────────────────────────────────────────────────── │            │
 │                                  │                              │            │
 │  POST /api/noauth/uploads/       │                              │            │
 │       complete                   │                              │            │
 │  Body: { upload_id, success,     │                              │            │
 │           error? }               │                              │            │
 │ ───────────────────────────────▶ │                              │            │
 │                                  │ pending = db.get_pending_    │            │
 │                                  │   upload(upload_id)          │            │
 │                                  │   ← also returns external_id │            │
 │                                  │     via JOIN participants    │            │
 │                                  │  ├─ not found  → 404         │            │
 │                                  │  └─ status≠pending           │            │
 │                                  │       → 200 cached           │            │
 │                                  │                              │            │
 │                                  │ participant_id =             │            │
 │                                  │   pending["external_id"]     │            │
 │                                  │ (NOT g.user_id — there's     │            │
 │                                  │  no auth context here)       │            │
 │                                  │                              │            │
 │                                  │ success branch identical to  │            │
 │                                  │ Path A (head_object → kind   │            │
 │                                  │ dispatch → mark_completed),  │            │
 │                                  │ but uses `participant_id`    │            │
 │                                  │ from the pending row.        │            │
 │                                  │                              │            │
 │                                  │ failure branch identical:    │            │
 │                                  │ delete_object + mark_failed. │            │
 │  200                             │                              │            │
 │ ◀─────────────────────────────── │                              │            │
 ▼                                  ▼                              ▼            ▼
```

### 5.1 Why `get_pending_upload` was changed

The presign route stores `participant_id` as an integer FK to
`participants.id`. The complete route needs the *external* string
("P0001") to call `db.insert_accel/gyro/hr`, which expect external IDs
and call `create_participant_if_missing` internally.

The auth path got it from `g.user_id`. The noauth path has no `g.user_id`,
so [database.py:702](backend/app/database/database.py:702) was updated to
JOIN `participants` and include `external_id` in the returned row.

```sql
SELECT pu.upload_id, pu.participant_id, p.external_id, pu.kind,
       pu.object_key, pu.status, pu.error_message,
       pu.created_at, pu.completed_at
FROM pending_uploads pu
JOIN participants p ON p.id = pu.participant_id
WHERE pu.upload_id = %s
```

### 5.2 Edge cases for Path B

Same as Path A, minus the JWT cases. Add these:

| Scenario                                                  | Outcome                                          |
|-----------------------------------------------------------|--------------------------------------------------|
| Missing `participantId` in presign body                   | 400 `"participantId is required"`                |
| `participantId` references a non-existent participant     | `create_participant_if_missing` upserts it       |
| Participant deleted between presign and complete          | JOIN returns nothing → `get_pending_upload`=None → 404 (because the FK has `ON DELETE CASCADE` on participants → pending_uploads row also gone) |

---

## 6. PATH C — Auth single-step JSON: `/api/uploadjson`

[upload.py:38](backend/app/routes/upload.py:38) — JSON body becomes the file.

```
iOS                       EC2                              S3            DB
 │ POST /api/uploadjson     │                                │             │
 │ Authorization: Bearer ...│                                │             │
 │ Body: <any JSON dict>    │                                │             │
 │ ───────────────────────▶ │                                │             │
 │                          │ @require_auth → g.user_id      │             │
 │                          │ if not request.is_json → 400   │             │
 │                          │                                │             │
 │                          │ filename =                     │             │
 │                          │  data["filename"] OR           │             │
 │                          │  query["filename"] OR          │             │
 │                          │  f"survey_{utc}.json"          │             │
 │                          │                                │             │
 │                          │ if Config.DEBUG_MODE: prints   │             │
 │                          │   the entire body to stdout    │             │
 │                          │   (sensitive!)                 │             │
 │                          │                                │             │
 │                          │ key = f"uploads/{utc}_         │             │
 │                          │   {secure_filename(filename)}" │             │
 │                          │                                │             │
 │                          │ body_bytes =                   │             │
 │                          │   json.dumps(data).encode()    │             │
 │                          │                                │             │
 │                          │ s3.put_object(                 │             │
 │                          │   Bucket=S3_BUCKET, Key=key,   │             │
 │                          │   Body=body_bytes,             │             │
 │                          │   ContentType="application/    │             │
 │                          │     json",                     │             │
 │                          │   StorageClass="GLACIER_IR",   │             │
 │                          │   SSE="AES256")                │             │
 │                          │ ──────────────────────────────▶│             │
 │                          │                                │ object      │
 │                          │                                │ stored      │
 │                          │                                │             │
 │                          │ db.insert_accel(g.user_id,     │             │
 │                          │   [{"ts": 0, "url": key}])     │             │
 │                          │ ──────────────────────────────────────────▶  │
 │                          │                                │ accelerometer│
 │                          │                                │ row inserted │
 │                          │                                │ ts ← 0       │
 │                          │                                │ (normalize_  │
 │                          │                                │  timestamp_  │
 │                          │                                │  to_iso8601  │
 │                          │                                │  treats 0    │
 │                          │                                │  as Unix epoch│
 │                          │                                │  → 1970-01-01)│
 │ 201 {message,key}        │                                │             │
 │ ◀─────────────────────── │                                │             │
```

**Note:** The route is named `uploadjson` and the handler is named
`upload`, but it always calls `db.insert_accel`, regardless of payload.
Treats arbitrary JSON as accelerometer-shaped. `ts: 0` → placeholder.

---

## 7. PATH D — Auth single-step survey: `/api/uploadjson/survey`

[upload.py:114](backend/app/routes/upload.py:114) — survey upserts into `daily_survey`.

```
iOS (SurveyUploader.swift:36)            EC2                       S3        DB
 │  POST /api/uploadjson/survey           │                          │         │
 │  Authorization: (NOT SENT — see note)  │                          │         │
 │  Body:                                 │                          │         │
 │   { metadata: {                        │                          │         │
 │       user_id, timestamp_utc,          │                          │         │
 │       timestamp_unix },                │                          │         │
 │     payload: {                         │                          │         │
 │       study_id:"spine_recovery_v1",    │                          │         │
 │       survey: {...},                   │                          │         │
 │       device_metadata: {               │                          │         │
 │         platform, device_model,        │                          │         │
 │         os_version, app_version }      │                          │         │
 │     }                                  │                          │         │
 │   }                                    │                          │         │
 │ ─────────────────────────────────────▶ │                          │         │
 │                                        │ @require_auth →          │         │
 │                                        │   g.user_id from JWT     │         │
 │                                        │   (NOTE: client-supplied │         │
 │                                        │    metadata.user_id is   │         │
 │                                        │    deliberately ignored) │         │
 │                                        │                          │         │
 │                                        │ Validate:                │         │
 │                                        │  ├─ not is_json → 400    │         │
 │                                        │  ├─ data not dict → 400  │         │
 │                                        │  ├─ no metadata → 400    │         │
 │                                        │  ├─ no payload  → 400    │         │
 │                                        │  ├─ no timestamp_utc     │         │
 │                                        │       → 400              │         │
 │                                        │  └─ unparseable iso      │         │
 │                                        │       → 400              │         │
 │                                        │                          │         │
 │                                        │ "Z" suffix is replaced   │         │
 │                                        │ with "+00:00" before     │         │
 │                                        │ datetime.fromisoformat   │         │
 │                                        │                          │         │
 │                                        │ survey_date =            │         │
 │                                        │   parsed.date()          │         │
 │                                        │   .isoformat()           │         │
 │                                        │                          │         │
 │                                        │ key = f"surveys/         │         │
 │                                        │   {secure_filename(      │         │
 │                                        │     g.user_id)}/         │         │
 │                                        │   {survey_date}_         │         │
 │                                        │   {utc:%H%M%S}.json"     │         │
 │                                        │                          │         │
 │                                        │ s3.put_object(           │         │
 │                                        │   Body=json.dumps(       │         │
 │                                        │     payload).encode()    │         │
 │                                        │   …) ────────────────────▶         │
 │                                        │   ONLY payload is stored,│         │
 │                                        │   NOT metadata.          │         │
 │                                        │                          │         │
 │                                        │ db.insert_survey(        │         │
 │                                        │   g.user_id, [{          │         │
 │                                        │     survey_date, url:key,│         │
 │                                        │     payload: payload     │         │
 │                                        │   }])                    │         │
 │                                        │ ──────────────────────────────────▶│
 │                                        │                          │ daily_  │
 │                                        │                          │ survey  │
 │                                        │                          │ UPSERT  │
 │                                        │                          │  on (pid│
 │                                        │                          │   ,date)│
 │                                        │                          │ payload │
 │                                        │                          │ stored  │
 │                                        │                          │ as JSONB│
 │ 201 {message,key,user_id,date}         │                          │         │
 │ ◀───────────────────────────────────── │                          │         │
```

**iOS-side oddity:** [SurveyUploader.swift:36](ios/SensingApp/SensingApp/Survey/SurveyUploader.swift:36)
hits the auth-required route but never sets `Authorization`. As written
this would 401. Either iOS is supposed to migrate to
`/api/noauth/uploadjson/survey`, or the production middleware is
permissive in this environment.

**Re-uploads of the same `(participant_id, survey_date)` overwrite** the
prior `object_url` and `payload` on the DB row (`ON CONFLICT … DO UPDATE`).
Note however that each upload writes a **new** S3 key (timestamp
includes seconds), so old payload objects in S3 are orphaned — no
cleanup occurs.

---

## 8. PATH E — Deprecated auth file uploads (410 Gone)

```
/api/uploadfile           ─┐
/api/uploadfile/accel      ├─ all four return:
/api/uploadfile/gyro       │  HTTP 410
/api/uploadfile/heartrate ─┘  { "error": "Endpoint deprecated. Use
                                  /api/uploads/presign +
                                  /api/uploads/complete" }
```

These are the legacy "stream-through-EC2" routes; they no longer process
bodies. Auth decorator still runs, so a missing token returns 401
*before* the 410. (Order: middleware first, handler second.)

---

## 9. PATH F — Noauth single-step JSON: `/api/noauth/uploadjson`

[upload_noauth.py:31](backend/app/routes/upload_noauth.py:31)

```
client                EC2                                S3          DB
 │ POST /api/noauth/uploadjson│                            │           │
 │ Body: <JSON dict>          │                            │           │
 │      MUST contain          │                            │           │
 │      participantId         │                            │           │
 │ ─────────────────────────▶ │                            │           │
 │                            │ NO auth                    │           │
 │                            │ if not is_json → 400       │           │
 │                            │                            │           │
 │                            │ pid =                      │           │
 │                            │  data.participantId OR     │           │
 │                            │  data.participant_id       │           │
 │                            │ if !pid → 400              │           │
 │                            │                            │           │
 │                            │ filename =                 │           │
 │                            │  data.filename OR          │           │
 │                            │  query.filename OR         │           │
 │                            │  f"upload_{utc}.json"      │           │
 │                            │                            │           │
 │                            │ key = f"uploads/{utc}_     │           │
 │                            │   {secure_filename(name)}" │           │
 │                            │                            │           │
 │                            │ s3.put_object(             │           │
 │                            │   Body=json.dumps(data)    │           │
 │                            │     .encode()              │           │
 │                            │   ...) ────────────────────▶           │
 │                            │                            │ object    │
 │                            │                            │ stored    │
 │                            │                            │           │
 │                            │ db.insert_accel(pid,       │           │
 │                            │   [{"ts":0,"url":key}]) ──────────────▶│
 │                            │                            │ accel row │
 │                            │                            │ inserted  │
 │ 201 {message,key}          │                            │           │
 │ ◀───────────────────────── │                            │           │
```

Subtle detail: the entire request body (including `participantId`) is
serialized into the S3 object. The route does not strip metadata before
upload.

---

## 10. PATH G — Noauth multipart streamed: `/api/noauth/uploadfile[/{accel,gyro,heartrate}]`

Four routes, identical structure, differ only by which DB insert is called.

```
client                                      EC2                          S3        DB
 │ POST /api/noauth/uploadfile[/{kind}]      │                              │         │
 │ Content-Type: multipart/form-data         │                              │         │
 │  ├─ "participantId":  "P0001"             │                              │         │
 │  └─ "file":           <binary>            │                              │         │
 │ ────────────────────────────────────────▶ │                              │         │
 │                                           │ NO auth                      │         │
 │                                           │ pid =                        │         │
 │                                           │  form.participantId OR       │         │
 │                                           │  form.participant_id         │         │
 │                                           │ if !pid → 400                │         │
 │                                           │ file = request.files["file"] │         │
 │                                           │ if !file → 400               │         │
 │                                           │                              │         │
 │                                           │ key = f"uploads/{utc}_       │         │
 │                                           │   {secure_filename(          │         │
 │                                           │     file.filename)}"         │         │
 │                                           │   (NOTE: no "/{kind}/"       │         │
 │                                           │    subprefix here, unlike    │         │
 │                                           │    the presigned routes)     │         │
 │                                           │                              │         │
 │                                           │ s3.put_object(               │         │
 │                                           │   Body = file.stream,        │         │
 │                                           │     ── streamed; werkzeug    │         │
 │                                           │     buffers >500KB to disk,  │         │
 │                                           │     smaller stays in memory  │         │
 │                                           │   ContentType =              │         │
 │                                           │     file.mimetype OR         │         │
 │                                           │     "application/octet-      │         │
 │                                           │      stream",                │         │
 │                                           │   StorageClass="GLACIER_IR", │         │
 │                                           │   SSE="AES256")              │         │
 │                                           │ ────────────────────────────▶│         │
 │                                           │                              │ stored  │
 │                                           │                              │         │
 │                                           │ Per-route DB call:           │         │
 │                                           │  /uploadfile           →     │         │
 │                                           │   db.insert_accel(pid,       │         │
 │                                           │     [{"ts":0,"url":key}])    │         │
 │                                           │  /uploadfile/accel     →     │         │
 │                                           │   db.insert_accel(...)       │         │
 │                                           │  /uploadfile/gyro      →     │         │
 │                                           │   db.insert_gyro(...)        │         │
 │                                           │  /uploadfile/heartrate →     │         │
 │                                           │   db.insert_hr(...)          │         │
 │                                           │ ──────────────────────────────────────▶│
 │                                           │                              │ row     │
 │ 200 {message,key}                         │                              │ inserted│
 │ ◀──────────────────────────────────────── │                              │         │
```

This is the bandwidth-wasteful path the presigned flow replaces; bytes
move iOS → EC2 → S3 instead of iOS → S3 directly. Useful for quick curl
testing.

Note that **all four return 200** (not 201), unlike `/uploadjson` which
returns 201.

---

## 11. PATH H — Noauth survey: `/api/noauth/uploadjson/survey`

[upload_noauth.py:133](backend/app/routes/upload_noauth.py:133)

Same structure as Path D but participantId comes from
`metadata.participantId` / `metadata.participant_id` / `metadata.user_id`
(in that fallback order), not from `g.user_id`. S3 key:
`surveys/<sanitized-pid>/<survey_date>_<HHMMSS>.json`. DB:
`db.insert_survey` (UPSERT on `(participant_id, survey_date)`).

Validation cascade:

```
1. is_json?              → 400 if not
2. data is dict?         → 400 if not
3. metadata present?     → 400 if not
4. payload  present?     → 400 if not
5. metadata has        ┐
   participantId / pid /│ → 400 if all missing
   user_id?            ┘
6. metadata.timestamp_utc?  → 400 if missing
7. timestamp parses?     → 400 if not
                                 │
                                 ▼
                  s3.put_object(payload only) → DB upsert → 201
```

---

## 12. Database schema (relevant tables)

From [backend/app/database/database_runner.py](backend/app/database/database_runner.py).

```
participants
 ┌────────────┬──────────────────────────┐
 │ id         │ SERIAL PK                │
 │ external_id│ TEXT UNIQUE NOT NULL     │  ← "P0001", "P0002"
 │ uploaded_at│ TIMESTAMPTZ DEFAULT now()│
 └────────────┴──────────────────────────┘

accelerometer / gyroscope / heart_rate  (identical schema)
 ┌────────────────┬──────────────────────────────────┐
 │ id             │ BIGSERIAL PK                     │
 │ participant_id │ INT FK participants(id) CASCADE  │
 │ ts             │ TIMESTAMPTZ NOT NULL             │  ← 1970-01-01 placeholder
 │ object_url     │ TEXT NOT NULL                    │  ← S3 key (not full URL)
 │ uploaded_at    │ TIMESTAMPTZ DEFAULT now()        │
 │ file_size_bytes│ NUMERIC (added later)            │
 └────────────────┴──────────────────────────────────┘
 INDEX ix_<table>_participant_ts ON (participant_id, ts)

pending_uploads
 ┌────────────────┬──────────────────────────────────┐
 │ upload_id      │ UUID PK                          │
 │ participant_id │ INT FK participants(id) CASCADE  │
 │ kind           │ TEXT CHECK ∈ {accel,gyro,hr}     │
 │ object_key     │ TEXT NOT NULL                    │
 │ status         │ TEXT DEFAULT 'pending'           │
 │                │   CHECK ∈ {pending,completed,    │
 │                │            failed}               │
 │ error_message  │ TEXT NULL                        │
 │ created_at     │ TIMESTAMPTZ DEFAULT now()        │
 │ completed_at   │ TIMESTAMPTZ NULL                 │
 └────────────────┴──────────────────────────────────┘
 INDEX pending_uploads_status_created_idx
   ON (status, created_at)         ← ready for a sweeper job

daily_survey
 ┌────────────────┬──────────────────────────────────┐
 │ id             │ BIGSERIAL PK                     │
 │ participant_id │ INT FK participants(id) CASCADE  │
 │ survey_date    │ DATE NOT NULL                    │
 │ object_url     │ TEXT NOT NULL                    │
 │ payload        │ JSONB NOT NULL                   │
 │ uploaded_at    │ TIMESTAMPTZ DEFAULT now()        │
 │ UNIQUE (participant_id, survey_date)              │
 └────────────────┴──────────────────────────────────┘

ingestion_health  (written by checker job, not upload routes)
users / refresh_tokens / device_tokens  (auth, not upload)
```

### 12.1 Daily-presence materialized views

Driven from the `ts` column of accel/gyro/hr rows, a daily presence
materialized view is maintained:

```
mv_accel_daily_presence  (participant_id, day, points)
mv_gyro_daily_presence   (participant_id, day, points)
mv_hr_daily_presence     (participant_id, day, points)
mv_survey_daily_presence (participant_id, day, forms)
```

`day = ts::date`. **Because `/complete` inserts `ts = 1970-01-01`**, every
sensor upload looks like it happened in 1970 in the MV until a separate
"checker" process calls
[`db.update_recording_timestamp(kind, row_id, recording_iso)`](backend/app/database/database.py:464)
to backfill the real timestamp from the file's contents. After that the
MVs need a refresh (`db.refresh_summary_cache()`).

---

## 13. DB helpers used by the upload routes

| Method                                                             | Used by                                                |
|--------------------------------------------------------------------|--------------------------------------------------------|
| `create_participant_if_missing(external_id)`                       | indirectly via every insert_*                          |
| `insert_accel(external_id, rows)`                                  | Path A success, Path B success, Path C, Path F, Path G (uploadfile, uploadfile/accel) |
| `insert_gyro(external_id, rows)`                                   | Path A success, Path B success, Path G (uploadfile/gyro)|
| `insert_hr(external_id, rows)`                                     | Path A success, Path B success, Path G (uploadfile/heartrate)|
| `insert_survey(external_id, rows)`                                 | Path D, Path H                                         |
| `create_pending_upload(upload_id, external_id, kind, key)`         | Path A presign, Path B presign                         |
| `get_pending_upload(upload_id)` (now JOINs participants)           | Path A complete, Path B complete                       |
| `mark_upload_completed(upload_id)`                                 | Path A success, Path B success                         |
| `mark_upload_failed(upload_id, error)`                             | Path A failure, Path B failure                         |
| `update_recording_timestamp(kind, row_id, ts_iso)`                 | (checker, not upload routes)                           |

`insert_accel/gyro/hr` accept rows in two shapes:

```python
# dict — preferred
{"url": "<s3-key>"}                              # ts → placeholder 1970-01-01
{"url": "<s3-key>", "ts": "<iso8601 or epoch>"}

# tuple
("<s3-key>",)                                    # ts → placeholder 1970-01-01
("<ts>", "<s3-key>")
```

If `url` is missing, the helper raises `ValueError`.

---

## 14. iOS callers

### 14.1 `Uploader` ([ios/SensingApp/SensingApp/util/Uploader.swift](ios/SensingApp/SensingApp/util/Uploader.swift))

```
Uploader.shared.uploadFile(fileURL:, kind: "accel")
   └─ executes Path A end-to-end
       Step 1:  POST  http://18.116.67.186/api/uploads/presign
       Step 2:  PUT   <returned-presigned-url>
                       URLSession.upload(for:fromFile:)  ← streams from disk
       Step 3:  POST  http://18.116.67.186/api/uploads/complete

Uploader.shared.uploadFolder()
   └─ scans Documents/ for files prefixed "log_"
   └─ for each file:
        await uploadFile(fileURL: file, kind: "accel")
        break          ← bug-or-test-shortcut: only first file uploads
```

Triggered from UI in
[MainAppView.swift:99](ios/SensingApp/SensingApp/MainAppView.swift:99)
(button "Upload File", hardcoded `log_2026-02-19.txt`) and
[MainAppView.swift:105](ios/SensingApp/SensingApp/MainAppView.swift:105)
(button "Upload All Files").

iOS does NOT delete the local file at any point. (The earlier plan said
"only delete after /complete returns success" — that step isn't
implemented.)

### 14.2 `SurveyUploader` ([ios/SensingApp/SensingApp/Survey/SurveyUploader.swift](ios/SensingApp/SensingApp/Survey/SurveyUploader.swift))

```
SurveyUploader.shared.uploadSurvey(surveyData)
   └─ POST  http://18.116.67.186/api/uploadjson/survey   (Path D)
        Wraps surveyData in:
          {
            metadata: { user_id, timestamp_utc, timestamp_unix },
            payload:  { study_id, survey: <surveyData>, device_metadata }
          }
        No Authorization header is set.
```

Called from
[SurgerySurveyView.swift:844](ios/SensingApp/SensingApp/Survey/SurgerySurveyView.swift:844).

---

## 15. AWS S3 specifics

### 15.1 Bucket layout (after all upload paths)

```
s3://$AWS_BUCKET/
├── uploads/
│   ├── accel/<utc>_<filename>      ← Path A, Path B
│   ├── gyro/<utc>_<filename>       ← Path A, Path B
│   ├── hr/<utc>_<filename>         ← Path A, Path B
│   └── <utc>_<filename>            ← Path C (uploadjson),
│                                     Path F (noauth/uploadjson),
│                                     Path G (noauth/uploadfile/*)
└── surveys/<participant>/<YYYY-MM-DD>_<HHMMSS>.json   ← Path D, Path H
```

Note: the kind is encoded in the **path** for presigned uploads but NOT
for the legacy noauth multipart routes. This means a noauth gyro upload
and a noauth heartrate upload land in the same `uploads/` prefix —
indistinguishable by S3 key alone; only the DB insert tells them apart.

### 15.2 Object metadata (every path applies these)

| Param                      | Value                                       |
|----------------------------|---------------------------------------------|
| `StorageClass`             | `GLACIER_IR` (Glacier Instant Retrieval)    |
| `ServerSideEncryption`     | `AES256` (S3-managed keys)                  |
| `ContentType`              | path-dependent (see flowcharts above)       |

### 15.3 Configuration

Loaded via `python-dotenv` in
[upload.py:21-26](backend/app/routes/upload.py:21) and
[upload_noauth.py:11-19](backend/app/routes/upload_noauth.py:11):

```
AWS_KEY         → boto3 aws_access_key_id
AWS_SECRET_KEY  → boto3 aws_secret_access_key
AWS_REGION      → boto3 region_name
AWS_BUCKET      → S3_BUCKET (target bucket)
DATABASE_URL    → Postgres DSN
JWT_SECRET      → token signing key (auth path only)
```

Each blueprint module instantiates its own boto3 S3 client at import
time (module-level singleton). They share the same credentials.

### 15.4 IAM permissions required on EC2 role

Confirmed required by the active routes, against
`arn:aws:s3:::<bucket>/uploads/*` and `…/surveys/*`:

| Action            | Used by                               |
|-------------------|---------------------------------------|
| `s3:PutObject`    | Path C, D, F, G, H                    |
| `s3:HeadObject`   | Path A, Path B (success branch)       |
| `s3:DeleteObject` | Path A, Path B (failure branch)       |
| `s3:Generate…`    | (not an IAM action — local signing)   |

`generate_presigned_url` itself doesn't make an AWS call; it signs
locally with the credentials boto3 has loaded.

---

## 16. Cross-path invariants

### 16.1 Timestamp handling

All sensor-data inserts use `ts = 1970-01-01T00:00:00+00:00` placeholder.
This is intentional — the uploader has no reliable view of when the
sensor data was actually recorded; only the data file itself does. A
separate "checker" job is responsible for parsing each uploaded object
and calling `update_recording_timestamp` to set the correct ts. Until
then, daily-presence materialized views show all uploads as 1970-01-01.

`normalize_timestamp_to_iso8601` (defined at
[database.py:91](backend/app/database/database.py:91)) accepts:
- `str` → returned as-is
- `int`/`float` → treated as Unix seconds → ISO 8601 with `+00:00`
- `datetime` → ISO 8601 (naive datetimes assumed UTC)

Path C and Paths F/G pass `ts: 0` explicitly (Unix epoch); the helper
converts that to `1970-01-01T00:00:00+00:00`.

### 16.2 Filename sanitization

Every path runs `werkzeug.utils.secure_filename` on the user-controlled
filename component before composing the S3 key. This strips path
traversal, NULL bytes, and reserved-character sequences. Empty strings
after sanitization will produce keys like `uploads/<utc>_` (still
upload-safe; just ugly).

### 16.3 Idempotency

Only the presigned path (`/uploads/complete`) is idempotent. The
single-step routes (`/uploadjson`, `/uploadjson/survey`,
`/noauth/upload*`) will produce a new S3 object (and a new accelerometer
or daily_survey row) on every call. For surveys, the `daily_survey`
UPSERT means duplicate `(pid, date)` calls *replace* the DB row, but
each call still writes a new S3 object (orphaning the previous one).

### 16.4 Streaming vs in-memory

| Path                                         | Streaming?                               |
|----------------------------------------------|------------------------------------------|
| Path A/B step 2 (iOS PUT to S3)              | Yes — `URLSession.upload(for:fromFile:)` |
| Path G `request.files["file"].stream`        | Yes — werkzeug spools to disk if >500KB  |
| Path C body `request.get_json()`             | No — full body buffered before parse     |
| Path D body `request.get_json()`             | No                                       |
| Path F body `request.get_json()`             | No                                       |
| Path H body `request.get_json()`             | No                                       |

So the JSON paths still load the full body into Python before re-encoding
and pushing to S3. For large JSON survey blobs this is fine; for very
large arbitrary `/uploadjson` payloads it is not.

---

## 17. Edge case quick reference (consolidated)

| Failure mode                               | Path A | Path B | Path C | Path D | Path F | Path G | Path H |
|--------------------------------------------|:------:|:------:|:------:|:------:|:------:|:------:|:------:|
| Missing/expired/invalid JWT                |  401   |   —    |  401   |  401   |   —    |   —    |   —    |
| Missing `participantId` in body            |   —    |  400   |   —    |   —    |  400   |  400   |  400   |
| Body not JSON                              |   —    |   —    |  400   |  400   |  400   |   —    |  400   |
| Missing `filename`                         |  400   |  400   |   —    |   —    |   —    |   —    |   —    |
| Invalid `kind`                             |  400   |  400   |   —    |   —    |   —    |   —    |   —    |
| Missing `metadata` / `payload`             |   —    |   —    |   —    |  400   |   —    |   —    |  400   |
| Missing `timestamp_utc`                    |   —    |   —    |   —    |  400   |   —    |   —    |  400   |
| Bad ISO timestamp                          |   —    |   —    |   —    |  400   |   —    |   —    |  400   |
| Missing multipart `file`                   |   —    |   —    |   —    |   —    |   —    |  400   |   —    |
| S3 PUT fails (signature/network)           |  client│ client │  500*  |  500*  |  500*  |  500*  |  500*  |
| S3 head_object 404 after `success=true`    |  200 (status:"failed") | same | n/a | n/a | n/a | n/a | n/a |
| Replay /complete                           |  cached│ cached │  n/a   |  n/a   |  n/a   |  n/a   |  n/a   |
| Unknown upload_id                          |  404   |  404   |  n/a   |  n/a   |  n/a   |  n/a   |  n/a   |

*Single-step routes do not currently catch boto3/DB exceptions, so a
failure inside `s3.put_object` or `db.insert_*` propagates as a Flask
500 with a stack trace.

---

## 18. Security observations

1. **Plain HTTP** — Both iOS callers hit `http://18.116.67.186` (no TLS).
   The presigned URL itself, the JWT (when sent), and survey contents
   travel over an unencrypted hop to EC2. The PUT to S3 is HTTPS, so
   only the EC2 leg leaks.

2. **Hardcoded EC2 IP** — [Uploader.swift:13](ios/SensingApp/SensingApp/util/Uploader.swift:13) and
   [SurveyUploader.swift:36](ios/SensingApp/SensingApp/Survey/SurveyUploader.swift:36).
   Previously flagged as possibly wrong. There is no DNS, no environment
   switching, no cert pinning.

3. **Noauth blueprint is registered by default** — `app.py:36`
   registers `upload_noauth_bp` with no environment guard. A production
   deploy will accept any request claiming any `participantId` and write
   to S3 + the DB. The header comment says "TEMPORARY: remove when iOS
   auth is ready" — until then this is open.

4. **`Config.DEBUG_MODE` prints request bodies to stdout** in
   [upload.py:60](backend/app/routes/upload.py:60) and
   [upload.py:139](backend/app/routes/upload.py:139). With logging that
   ships to a third-party aggregator, that is PHI/PII leakage.

5. **`metadata.user_id` ignored in /uploadjson/survey** — Path D
   deliberately overwrites with `g.user_id`. Good. Path H (noauth)
   trusts whatever `metadata.participantId|participant_id|user_id`
   says — that is the only way the route works without auth.

6. **Presigned URL is a bearer token** — anyone with the URL can do
   that one PUT for the next 900 seconds. URL is logged on iOS
   (`print` at [Uploader.swift:114](ios/SensingApp/SensingApp/util/Uploader.swift:114)
   prints the key, not the URL — fine).

7. **`pending_uploads` orphans accumulate** — no sweeper. A row whose
   client died after presign but before /complete stays `pending`
   forever, holding an `ON DELETE CASCADE` reference back to the
   participant.

8. **No rate limiting / no per-participant quotas** — any path can be
   called as fast as the server can handle it. S3 will scale; the DB
   inserts won't hold up indefinitely under abuse.

9. **`/uploadjson` is misleadingly named** — it always inserts into
   `accelerometer`, regardless of what the JSON contains. Treat it as
   "upload arbitrary JSON, recorded as if it were accel data."

---

## 19. Files involved

| File                                                                  | Role                                          |
|-----------------------------------------------------------------------|-----------------------------------------------|
| [backend/app/app.py](backend/app/app.py)                              | App factory, blueprint registration           |
| [backend/app/routes/upload.py](backend/app/routes/upload.py)          | Auth-required upload routes                   |
| [backend/app/routes/upload_noauth.py](backend/app/routes/upload_noauth.py) | Noauth upload routes (TEMPORARY)         |
| [backend/app/auth/middleware.py](backend/app/auth/middleware.py)      | `@require_auth` JWT decorator                 |
| [backend/app/database/database.py](backend/app/database/database.py)  | DB class + insert/pending helpers             |
| [backend/app/database/database_runner.py](backend/app/database/database_runner.py) | Schema DDL + CLI                |
| [ios/SensingApp/SensingApp/util/Uploader.swift](ios/SensingApp/SensingApp/util/Uploader.swift) | Sensor file uploader     |
| [ios/SensingApp/SensingApp/Survey/SurveyUploader.swift](ios/SensingApp/SensingApp/Survey/SurveyUploader.swift) | Survey uploader |
| [ios/SensingApp/SensingApp/MainAppView.swift](ios/SensingApp/SensingApp/MainAppView.swift) | UI buttons that trigger uploads      |
| [ios/SensingApp/SensingApp/Survey/SurgerySurveyView.swift](ios/SensingApp/SensingApp/Survey/SurgerySurveyView.swift) | Survey UI → uploadSurvey |

---

## 20. End-to-end happy path summary

```
SENSOR FILE (auth):
  iOS → presign(jwt, kind) → presigned URL
  iOS → S3 PUT (raw bytes) → 200
  iOS → complete(jwt, success) → HeadObject → insert_accel/gyro/hr → mark_completed

SENSOR FILE (noauth):
  iOS → presign(participantId, kind) → presigned URL
  iOS → S3 PUT (raw bytes) → 200
  iOS → complete(participantId implicit via pending row) → HeadObject → insert → mark_completed

SURVEY (auth):
  iOS → POST wrapped JSON → server uses g.user_id → S3 put_object(payload only) → upsert daily_survey

SURVEY (noauth):
  client → POST wrapped JSON with participantId in metadata → S3 → upsert daily_survey
```
