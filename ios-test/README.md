# S3 Upload Test Harness (Issue #69)

A tiny iOS app that reproduces the deployed app's uploads with **known** input
data, so upload bugs can be isolated from on-device recording.

It downloads a fixed set of fixture files from an S3 prefix (listed by a
`manifest.json`) and replays each one through the **exact same upload code the
app uses** — the files `S3Uploader.swift`, `Uploader.swift`, and
`ParticipantID.swift` are vendored verbatim from `ios/SensingApp/SensingApp/util/`
into `s3uploadtest/s3uploadtest/`. Whatever fails in the field fails here too,
but now against controlled inputs with each step's HTTP status on screen.

## How it maps to the app

The kind routing mirrors `Uploader.uploadFolder`:

| Fixture prefix   | kind    | Upload path taken                                  |
|------------------|---------|----------------------------------------------------|
| `accelerometer_` | `accel` | presign → PUT → complete (`S3TestUploader`)        |
| `sqlite_`        | `other` | presign → PUT → complete (`S3TestUploader`)        |
| `sensorkit_`     | `other` | presign → PUT → complete (`S3TestUploader`)        |
| `locations_`     | `loc`   | multipart `POST /api/noauth/uploadfile` (`Uploader`)|
| `healthkit_`     | `hk`    | multipart `POST /api/noauth/uploadfile` (`Uploader`)|

The backend target is whatever the vendored code hardcodes (currently the
Lambda URL in `S3Uploader.swift` / `Uploader.swift`) — i.e. the same endpoint
the shipping app hits. To test a different backend, change the URL in the
vendored files.

## One-time setup (needs AWS access to the bucket)

1. Create a fixtures prefix, e.g. `s3://YOUR-BUCKET/test-fixtures/`.
2. Ask Rabbi to drop one representative real file per kind there
   (`accelerometer_*.csv`, `locations_*.csv`, `healthkit_*.csv`,
   `sqlite_*.db`, `sensorkit_*.csv`).
3. Generate and upload the manifest:

   ```bash
   cd ios-test/fixtures
   BUCKET=YOUR-BUCKET PREFIX=test-fixtures/ REGION=us-east-2 \
     ./generate_manifest.sh > manifest.json
   aws s3 cp manifest.json s3://YOUR-BUCKET/test-fixtures/manifest.json
   ```

   `generate_manifest.sh` emits **presigned** GET URLs (7-day lifetime), so the
   bucket can stay private. `manifest.example.json` shows the shape.

## Running

1. Open `ios-test/s3uploadtest/s3uploadtest.xcodeproj` in Xcode and run on a
   simulator or device.
2. Paste the manifest URL (public-read, or a presigned URL for the manifest
   itself) into the **Manifest URL** field.
3. Tap **Run All**. Each fixture shows pass/fail plus a per-step log
   (presign / PUT / complete, or the multipart status).

All harness uploads are stamped with a fixed test participant
(`ParticipantID.store(forAppleUserID: "issue69-harness")`) so the rows they
create in the backend are easy to identify and purge.

## Fault modes (Issue #72)

A presign upload only counts once the backend's complete step replies
`"status": "completed"` (see `UPLOAD_FLOW.md`). The **Fault mode** picker makes
the real backend and S3 return real failure replies, so you can check the app
treats them as failures. It works by intercepting the harness's own requests
(`FaultInjection.swift`); the vendored upload code is not modified.

| Mode            | What it does                                   | Real reply                          | Presign files should be |
|-----------------|------------------------------------------------|-------------------------------------|-------------------------|
| Normal          | nothing                                        | 200 `completed`                     | recorded                |
| Bad upload ID   | sends an unknown `upload_id` to complete       | 404 `upload not found`              | not recorded            |
| Fake S3 success | skips the PUT, returns a fake 200              | 200 `failed` (object not found)     | not recorded            |
| S3 rejects      | corrupts the PUT signature                     | S3 403, then complete `failed`      | not recorded            |

Multipart files (`loc`, `hk`) are not affected and should be recorded in every
mode. A row passes when the file did what its mode expects.

Fault runs leave `pending_uploads` rows marked `failed` (or `pending` for Bad
upload ID) under the test participant; purge them with the rest of the test data.

## Notes / known app quirks this surfaces

- The presign path hardcodes `content_type: text/csv` even for `.db` files.
- The multipart path loads the whole file into memory and sends a placeholder
  `Content-Type`.
- The server's `/api/noauth/uploadfile` records every file as an `accel` DB row
  regardless of kind — so `loc`/`hk` fixtures land under accel server-side.
