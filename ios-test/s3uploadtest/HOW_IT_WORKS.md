# What this harness does

`s3uploadtest` is a small iOS app that **reproduces the deployed SensingApp's
uploads with known input data**. It exists to answer one question: *when an
upload fails, is it the recording or the upload code?* By feeding fixed files
into the exact same upload code the app uses, it removes the on-device
recording as a variable so upload bugs can be reproduced and re-run at will.

## The core idea

The real app records sensor files on the device, then uploads them. If some
uploads fail, it's hard to tell whether the file was bad or the upload path is
broken. This harness swaps the **source** of the file — a known fixture pulled
from S3 instead of an on-device recording — while keeping **everything
downstream identical**.

To guarantee "identical," the app's upload code is **vendored verbatim** into
this project:

- `S3Uploader.swift`, `Uploader.swift`, `ParticipantID.swift` are byte-for-byte
  copies of `ios/SensingApp/SensingApp/util/…` (see the banner at the top of
  each). They are **not** edited here — if the app's version changes, re-copy it.
- `HarnessRunner.swift` and `ContentView.swift` are the only harness-specific
  code: they fetch fixtures and drive the vendored uploaders.

So the only thing different from the shipping app is where the file comes from.
If a pathway breaks in the field, it breaks here too.

## The flow (per file)

```
manifest.json  ──►  download fixture  ──►  route by kind  ──►  upload  ──►  record ✅/❌
 (list of URLs)     (presigned GET)        (same as app)      (real code)   + per-step log
```

1. **Fetch the manifest.** The app GETs a `manifest.json` (a small list of
   `{filename, kind, url}` entries) from an S3 prefix. This is just a stand-in
   for "list the bucket," since iOS can't list S3 without AWS credentials.
2. **Download each fixture** from its (usually presigned) `url` to a temp file,
   kept under its real filename so the uploaded object name matches.
3. **Route by `kind`** to the same pathway the app's `Uploader.uploadFolder`
   would use for that file.
4. **Upload** through the vendored code and **record** pass/fail plus the
   per-step HTTP statuses.

## The two upload pathways

| `kind` | Filename prefix | Pathway (vendored) | What runs |
|--------|-----------------|--------------------|-----------|
| `accel` | `accelerometer_` | `S3TestUploader.runFullFlow` | presign → PUT to S3 → complete |
| `other` | `sqlite_`, `sensorkit_` | `S3TestUploader.runFullFlow` | presign → PUT to S3 → complete |
| `loc` | `locations_` | `Uploader.shared.uploadFile` | multipart `POST /api/noauth/uploadfile` |
| `hk` | `healthkit_` | `Uploader.shared.uploadFile` | multipart `POST /api/noauth/uploadfile` |

The routing is one branch in `HarnessRunner`:

```swift
if presignKinds.contains(entry.kind) {            // ["accel", "other"]
    ok = await S3TestUploader().runFullFlow(filenameURL: localURL, kind: entry.kind)
} else {                                          // loc, hk
    ok = await Uploader.shared.uploadFile(fileURL: localURL)
}
```

The **backend it uploads to** is whatever the vendored code hardcodes — the
same Lambda URL the shipping app hits. To target a different backend, change
the URL in the vendored files.

## Reading the results

- Each row shows a fixture with ✅ pass / ❌ fail, its kind, and which pathway
  it took.
- The **log** panel shows the vendored code's own step-by-step output (captured
  from stdout): the presign HTTP status, the S3 PUT status, and the complete
  status — or, for the multipart path, the `/uploadfile` status.
- **Download and upload are independent stages.** A file can download fine
  (✅ GET) yet fail on upload (❌ presign/PUT/complete); the log tells you which
  stage broke.

## Test participant

Every harness upload is stamped with a fixed participant hash:

```swift
ParticipantID.store(forAppleUserID: "issue69-harness")
```

This uses the app's real hashing, so the rows the harness creates in the
backend are easy to identify and purge after a test run.

## What it does NOT do

- It does not test on-device **recording** (SensorKit/HealthKit/SQLite capture)
  — that's exactly the variable it removes.
- It does not mock the backend. Uploads go to the **real** endpoint, so a run
  writes real (test-participant) rows and S3 objects.
- The fixtures' at-rest encryption is irrelevant to the harness (it just GETs
  them); use the bucket default (SSE-S3), not SSE-C.

## Known app quirks this can surface

- The presign path hardcodes `content_type: text/csv` even for `.db` files.
- The multipart path loads the whole file into memory and sends a placeholder
  `Content-Type`.
- The server's `/api/noauth/uploadfile` records every file as an `accel` DB row
  regardless of kind, so `loc`/`hk` fixtures land under accel server-side.

See `ios-test/README.md` for the step-by-step setup (fixtures, manifest, run).
