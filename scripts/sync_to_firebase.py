#!/usr/bin/env python3
"""Upload field CSV files to Firebase / Google Cloud Storage.

Requires the ``GOOGLE_APPLICATION_CREDENTIALS`` environment variable to point
to a GCP service-account JSON key file.

Two upload back-ends are tried in order:
    1. ``google-cloud-storage`` Python package (pip install google-cloud-storage)
       — preferred, fully supported.
    2. GCS JSON API via ``urllib.request`` + service-account JWT signing
       — stdlib-only fallback when the package is not installed.

A local manifest file (``.upload_manifest.json`` inside --data-dir) tracks
MD5 hash → remote blob path for every successfully uploaded file.  Files whose
MD5 has not changed since the last run are skipped.

Usage
-----
    python scripts/sync_to_firebase.py --bucket my-bucket-name
    python scripts/sync_to_firebase.py --bucket my-bucket --prefix field-data/
    python scripts/sync_to_firebase.py --data-dir ./data/field --bucket my-bucket
    python scripts/sync_to_firebase.py --bucket my-bucket --dry-run

Environment variables
---------------------
    GOOGLE_APPLICATION_CREDENTIALS   Path to GCP service-account JSON key.
    GCS_BUCKET                       Bucket name (alternative to --bucket).

Exit codes
----------
    0  All files synced or already up-to-date.
    1  One or more uploads failed.
    2  Configuration error (missing bucket, missing credentials, etc.).
"""

import argparse
import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_DATA_DIR = os.path.join(REPO_DIR, "data", "field")
MANIFEST_FILENAME = ".upload_manifest.json"

# ---------------------------------------------------------------------------
# MD5 helper
# ---------------------------------------------------------------------------

def _file_md5(path: str) -> str:
    """Return hex MD5 digest of file contents."""
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------

def _load_manifest(data_dir: str) -> dict:
    """Load the upload manifest from data_dir/.upload_manifest.json."""
    path = os.path.join(data_dir, MANIFEST_FILENAME)
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_manifest(data_dir: str, manifest: dict) -> None:
    """Persist the upload manifest."""
    path = os.path.join(data_dir, MANIFEST_FILENAME)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2)
    except OSError as exc:
        print(f"  Warning: could not save manifest: {exc}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Back-end 1: google-cloud-storage package
# ---------------------------------------------------------------------------

def _upload_gcs_package(
    bucket_name: str, blob_name: str, local_path: str
) -> bool:
    """Upload using the google-cloud-storage package.  Returns True on success."""
    try:
        from google.cloud import storage  # type: ignore
    except ImportError:
        return False  # signal caller to try fallback

    try:
        client = storage.Client()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        blob.upload_from_filename(local_path, content_type="text/csv")
        return True
    except Exception as exc:
        print(f"  [gcs-package] Upload error: {exc}", file=sys.stderr)
        raise  # propagate so caller can count failure


# ---------------------------------------------------------------------------
# Back-end 2: stdlib urllib + service-account JWT signing
# ---------------------------------------------------------------------------

def _b64url(data: bytes) -> str:
    """Base64url encode without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _make_jwt(sa_info: dict, scope: str) -> str:
    """
    Create a signed JWT for Google OAuth2 using the service-account key.

    Requires the ``cryptography`` package for RSA signing.  If unavailable
    this function raises ImportError.
    """
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
    except ImportError as exc:
        raise ImportError(
            "cryptography package required for stdlib GCS upload. "
            "Install with: pip install cryptography"
        ) from exc

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {
        "iss": sa_info["client_email"],
        "scope": scope,
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }
    header_b64 = _b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()

    private_key = serialization.load_pem_private_key(
        sa_info["private_key"].encode(), password=None
    )
    signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return f"{header_b64}.{payload_b64}.{_b64url(signature)}"


def _get_access_token(sa_info: dict) -> str:
    """Exchange a service-account JWT for a GCS access token."""
    scope = "https://www.googleapis.com/auth/devstorage.read_write"
    jwt = _make_jwt(sa_info, scope)

    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": jwt,
        }
    ).encode()

    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())["access_token"]


def _upload_gcs_urllib(
    bucket_name: str, blob_name: str, local_path: str, sa_info: dict
) -> bool:
    """Upload using urllib.request + service-account signing.  Returns True on success."""
    import urllib.parse

    token = _get_access_token(sa_info)
    with open(local_path, "rb") as fh:
        data = fh.read()

    encoded_blob = urllib.parse.quote(blob_name, safe="")
    upload_url = (
        f"https://storage.googleapis.com/upload/storage/v1/b/"
        f"{urllib.parse.quote(bucket_name, safe='')}/o"
        f"?uploadType=media&name={encoded_blob}"
    )
    req = urllib.request.Request(
        upload_url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "text/csv",
            "Content-Length": str(len(data)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as exc:
        print(f"  [urllib] HTTP {exc.code}: {exc.read().decode(errors='replace')}",
              file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Unified upload dispatcher
# ---------------------------------------------------------------------------

def _upload_file(
    bucket_name: str,
    blob_name: str,
    local_path: str,
    sa_info: dict,
    dry_run: bool,
) -> bool:
    """
    Upload local_path to gs://bucket_name/blob_name.

    Tries google-cloud-storage package first; falls back to urllib.
    In dry_run mode, prints what would happen and returns True.
    """
    if dry_run:
        print(f"  [dry-run] would upload {os.path.basename(local_path)} "
              f"-> gs://{bucket_name}/{blob_name}")
        return True

    # Try package backend
    try:
        # Returns False only if package is missing; raises on upload error
        result = _upload_gcs_package(bucket_name, blob_name, local_path)
        if result is not False:
            return result
    except Exception:
        return False  # already printed error above

    # Package not installed — fall back to urllib
    try:
        return _upload_gcs_urllib(bucket_name, blob_name, local_path, sa_info)
    except Exception as exc:
        print(f"  [urllib] error: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Main sync logic
# ---------------------------------------------------------------------------

def sync(
    data_dir: str,
    bucket: str,
    prefix: str,
    dry_run: bool,
) -> int:
    """Sync all CSVs in data_dir to GCS.  Returns exit code."""
    if not os.path.isdir(data_dir):
        print(f"Data directory not found: {data_dir}", file=sys.stderr)
        return 1

    # Load service-account info for urllib fallback (even if package is used,
    # we parse it now to surface credential errors early)
    cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
    if not cred_path:
        print(
            "Error: GOOGLE_APPLICATION_CREDENTIALS environment variable not set.",
            file=sys.stderr,
        )
        return 2
    if not os.path.isfile(cred_path):
        print(f"Error: credentials file not found: {cred_path}", file=sys.stderr)
        return 2

    sa_info: dict = {}
    if not dry_run:
        try:
            with open(cred_path, "r", encoding="utf-8") as fh:
                sa_info = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"Error: cannot parse credentials file: {exc}", file=sys.stderr)
            return 2

    csv_files = sorted(
        f for f in os.listdir(data_dir)
        if f.lower().endswith(".csv")
    )

    if not csv_files:
        print(f"No CSV files found in {data_dir}.")
        return 0

    manifest = _load_manifest(data_dir)
    n_synced = n_skipped = n_failed = 0

    for fname in csv_files:
        fpath = os.path.join(data_dir, fname)
        md5 = _file_md5(fpath)
        blob_name = prefix.rstrip("/") + "/" + fname if prefix else fname

        # Check manifest
        existing = manifest.get(fname, {})
        if isinstance(existing, dict) and existing.get("md5") == md5:
            n_skipped += 1
            print(f"  skip  {fname}  (unchanged)")
            continue

        print(f"  upload {fname} -> gs://{bucket}/{blob_name}")
        ok = _upload_file(bucket, blob_name, fpath, sa_info, dry_run)
        if ok:
            manifest[fname] = {
                "md5": md5,
                "blob": blob_name,
                "uploaded_at": datetime.now(timezone.utc).isoformat(),
            }
            n_synced += 1
        else:
            n_failed += 1

    if not dry_run:
        _save_manifest(data_dir, manifest)

    print(
        f"\n{n_synced} files synced, {n_skipped} skipped (unchanged), "
        f"{n_failed} failed"
    )
    return 0 if n_failed == 0 else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Upload field CSV files to Firebase / Google Cloud Storage."
    )
    p.add_argument(
        "--data-dir",
        default=DEFAULT_DATA_DIR,
        metavar="DIR",
        help="Directory containing CSV files to upload (default: ./data/field).",
    )
    p.add_argument(
        "--bucket",
        default=os.environ.get("GCS_BUCKET", ""),
        metavar="BUCKET_NAME",
        help="GCS / Firebase Storage bucket name.  "
             "Can also be set via GCS_BUCKET env var.",
    )
    p.add_argument(
        "--prefix",
        default="field-data/",
        metavar="PREFIX",
        help="Remote path prefix for uploaded files (default: field-data/).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be uploaded without actually uploading.",
    )
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    if not args.bucket and not args.dry_run:
        print(
            "Error: --bucket is required (or set GCS_BUCKET environment variable).",
            file=sys.stderr,
        )
        return 2

    bucket = args.bucket or "dry-run-bucket"
    return sync(args.data_dir, bucket, args.prefix, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
