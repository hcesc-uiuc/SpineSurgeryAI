#!/usr/bin/env python3
"""
Upload harness (Python) -- Issues #69, #72.

Replays fixture files through the same HTTP flow the iOS app uses and checks
that the backend really records them:

    accel / other  -> POST presign -> PUT to S3 -> POST complete
    loc / hk       -> multipart POST /api/noauth/uploadfile

A presign upload counts as recorded only when complete replies HTTP 200 with
"status": "completed" (the #72 rule). Fault modes make the real backend and S3
return real failures, the same modes as the iOS harness (FaultInjection.swift).

This reimplements the app's requests; it tests the backend contract, not the
Swift code. Use the iOS harness in ../s3uploadtest for that.

Standard library only (Python 3.9+).

Examples:
    python3 upload_harness.py --manifest "https://...manifest.json?X-Amz-..."
    python3 upload_harness.py --manifest "$URL" --mode all
    python3 upload_harness.py --dir ~/fixtures --mode fake-s3-success
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

DEFAULT_BACKEND = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws"
DEFAULT_SEED = "issue69-harness"
COMPLETE_MAX_ATTEMPTS = 3
TIMEOUT = 600

# Mirrors Uploader.uploadFolder on dev.
KIND_BY_PREFIX = [
    ("locations_", "loc"),
    ("accelerometer_", "accel"),
    ("healthkit_", "hk"),
    ("sqlite_", "other"),
    ("sensorkit_", "other"),
]
PRESIGN_KINDS = {"accel", "other"}

MODES = ["normal", "bad-upload-id", "fake-s3-success", "s3-rejects"]


def kind_for(filename):
    for prefix, kind in KIND_BY_PREFIX:
        if filename.startswith(prefix):
            return kind
    return "other"


def participant_hash(seed):
    # Same as ParticipantID.hash in the app: SHA-256 hex of the Apple user id.
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def log(msg=""):
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http(method, url, body=None, headers=None, timeout=TIMEOUT):
    """Returns (status, body_bytes). Non-2xx is a normal return, not an error.
    Network failures raise urllib.error.URLError."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def short(data, limit=200):
    text = data.decode("utf-8", "replace").strip().replace("\n", " ")
    return text if len(text) <= limit else text[:limit] + "..."


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def load_fixtures(args, workdir):
    """Returns a list of (filename, kind, local_path)."""
    if args.dir:
        names = sorted(n for n in os.listdir(args.dir)
                       if not n.startswith(".") and os.path.isfile(os.path.join(args.dir, n)))
        fixtures = [(n, kind_for(n), os.path.join(args.dir, n)) for n in names]
    else:
        status, data = http("GET", args.manifest, timeout=60)
        if status != 200:
            sys.exit("manifest HTTP %d: %s" % (status, short(data)))
        entries = json.loads(data)
        fixtures = []
        for e in entries:
            name = e["filename"]
            if args.only and name not in args.only:
                continue
            path = os.path.join(workdir, name)
            log("download %s" % name)
            req = urllib.request.Request(e["url"])
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as resp, open(path, "wb") as out:
                    shutil.copyfileobj(resp, out, 1024 * 1024)
            except urllib.error.HTTPError as err:
                log("  download HTTP %d (link expired?) -> skipped" % err.code)
                continue
            fixtures.append((name, e.get("kind") or kind_for(name), path))
    if args.only and args.dir:
        fixtures = [f for f in fixtures if f[0] in args.only]
    return fixtures


# ---------------------------------------------------------------------------
# Upload paths
# ---------------------------------------------------------------------------

def presign_flow(backend, pid, name, kind, path, mode):
    """presign -> PUT -> complete. Returns (recorded, detail)."""
    steps = []

    # Step 1: presign
    body = json.dumps({"participantId": pid, "filename": name,
                       "content_type": "text/csv", "kind": kind}).encode()
    try:
        status, data = http("POST", backend + "/api/noauth/uploads/presign", body,
                            {"Content-Type": "application/json"}, timeout=60)
    except urllib.error.URLError as e:
        return False, "presign network error: %s" % e.reason
    steps.append("presign %d" % status)
    if status != 201:
        return False, "; ".join(steps) + " " + short(data)
    presign = json.loads(data)

    # Step 2: PUT to S3
    if mode == "fake-s3-success":
        s3_ok = True
        steps.append("PUT skipped (fake 200)")
    else:
        url = presign["url"] + ("0" if mode == "s3-rejects" else "")
        headers = dict(presign.get("headers", {}))
        headers["Content-Length"] = str(os.path.getsize(path))
        try:
            with open(path, "rb") as f:
                status, data = http("PUT", url, f, headers)
        except urllib.error.URLError as e:
            status, data = 0, str(e.reason).encode()
        s3_ok = status == 200
        steps.append("PUT %d" % status)

    # Step 3: complete (retried on network errors and 5xx, like the app)
    upload_id = str(uuid.uuid4()) if mode == "bad-upload-id" else presign["upload_id"]
    body = json.dumps({"upload_id": upload_id, "success": s3_ok}).encode()
    completed = False
    for attempt in range(1, COMPLETE_MAX_ATTEMPTS + 1):
        try:
            status, data = http("POST", backend + "/api/noauth/uploads/complete", body,
                                {"Content-Type": "application/json"}, timeout=60)
        except urllib.error.URLError as e:
            steps.append("complete network error")
            if attempt < COMPLETE_MAX_ATTEMPTS:
                time.sleep(attempt)
                continue
            break
        if status >= 500 and attempt < COMPLETE_MAX_ATTEMPTS:
            steps.append("complete %d (retry)" % status)
            time.sleep(attempt)
            continue
        reply = {}
        try:
            reply = json.loads(data)
        except ValueError:
            pass
        reply_status = reply.get("status") if isinstance(reply, dict) else None
        completed = status == 200 and reply_status == "completed"
        detail = reply_status or (reply.get("error") if isinstance(reply, dict) else None) or short(data, 60)
        steps.append("complete %d %s" % (status, detail))
        if isinstance(reply, dict) and reply.get("error") and reply_status:
            steps[-1] += " (%s)" % reply["error"]
        break

    return s3_ok and completed, "; ".join(steps)


def multipart_flow(backend, pid, name, path):
    """Single multipart POST, like Uploader.uploadFile. Returns (recorded, detail)."""
    boundary = "Boundary-%s" % uuid.uuid4()
    with open(path, "rb") as f:
        content = f.read()
    parts = [
        ("--%s\r\nContent-Disposition: form-data; name=\"participantId\"\r\n\r\n%s\r\n"
         % (boundary, pid)).encode(),
        ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
         "Content-Type: application/octet-stream\r\n\r\n" % (boundary, name)).encode(),
        content,
        ("\r\n--%s--\r\n" % boundary).encode(),
    ]
    body = b"".join(parts)
    try:
        status, data = http("POST", backend + "/api/noauth/uploadfile", body,
                            {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    except urllib.error.URLError as e:
        return False, "uploadfile network error: %s" % e.reason
    return status == 200, "uploadfile %d %s" % (status, short(data, 80))


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_mode(mode, fixtures, backend, pid):
    log("")
    log("=== mode: %s ===" % mode)
    rows = []
    for i, (name, kind, path) in enumerate(fixtures, 1):
        presign_path = kind in PRESIGN_KINDS
        route = "presign" if presign_path else "multipart"
        size_mb = os.path.getsize(path) / 1e6
        log("[%d/%d] %s (%s, %s, %.1f MB)" % (i, len(fixtures), name, kind, route, size_mb))
        if presign_path:
            recorded, detail = presign_flow(backend, pid, name, kind, path, mode)
            expected = mode == "normal"
        else:
            # Fault modes only touch the presign path.
            recorded, detail = multipart_flow(backend, pid, name, path)
            expected = True
        ok = recorded == expected
        log("  %s" % detail)
        log("  => %s, expected %s: %s" % ("RECORDED" if recorded else "NOT RECORDED",
                                          "RECORDED" if expected else "NOT RECORDED",
                                          "PASS" if ok else "FAIL"))
        rows.append((name, route, recorded, expected, ok))
    passed = sum(1 for r in rows if r[4])
    log("mode %s: %d/%d as expected" % (mode, passed, len(rows)))
    return rows


def main():
    p = argparse.ArgumentParser(description="Replay fixtures through the app's upload flow (#69, #72).")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--manifest", help="manifest.json URL (list of {filename, kind, url})")
    src.add_argument("--dir", help="local folder of fixture files; kind comes from the filename prefix")
    p.add_argument("--mode", default="normal", choices=MODES + ["all"],
                   help="fault mode (default normal; 'all' runs every mode)")
    p.add_argument("--backend", default=DEFAULT_BACKEND, help="backend base URL (default: the app's Lambda URL)")
    p.add_argument("--seed", default=DEFAULT_SEED,
                   help="test participant seed; uploads are tagged sha256(seed) (default %s)" % DEFAULT_SEED)
    p.add_argument("--only", nargs="+", metavar="FILENAME", help="only run these fixture filenames")
    args = p.parse_args()

    pid = participant_hash(args.seed)
    log("Backend:     %s" % args.backend)
    log("Participant: %s  (sha256 of %r)" % (pid, args.seed))

    workdir = tempfile.mkdtemp(prefix="upload-harness-")
    try:
        fixtures = load_fixtures(args, workdir)
        if not fixtures:
            sys.exit("no fixtures to run")
        modes = MODES if args.mode == "all" else [args.mode]
        summary = [(m, run_mode(m, fixtures, args.backend, pid)) for m in modes]
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    log("")
    log("=== summary ===")
    all_ok = True
    for mode, rows in summary:
        passed = sum(1 for r in rows if r[4])
        all_ok = all_ok and passed == len(rows)
        log("%-16s %d/%d as expected" % (mode, passed, len(rows)))
        for name, route, recorded, expected, ok in rows:
            if not ok:
                log("   FAIL %s (%s): recorded=%s expected=%s" % (name, route, recorded, expected))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
