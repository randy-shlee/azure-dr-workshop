#!/usr/bin/env bash
set -Eeuo pipefail
# Runs inside the WI-enabled private AKS Job. No account keys, SAS or package installs.
export AZCOPY_AUTO_LOGIN_TYPE=WORKLOAD
export AZCOPY_CONCURRENCY_VALUE="${AZCOPY_CONCURRENCY_VALUE:-2}"
export AZCOPY_BUFFER_GB="${AZCOPY_BUFFER_GB:-0.0625}"
export AZCOPY_LOG_LOCATION=/work/logs AZCOPY_JOB_PLAN_LOCATION=/work/plans
mkdir -p /work/logs /work/plans /work/data
python3 - <<'PY'
import datetime
import json
import os
import pathlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

def layout(size_gb, large_gb, small_count, small_mb):
    size, large, small = int(size_gb) * 1024**3, int(large_gb) * 1024**3, int(small_mb) * 1024**2
    if min(size, large, small) <= 0 or int(small_count) < 0:
        raise ValueError("Sizes must be positive and small count nonnegative")
    remaining = size - int(small_count) * small
    if remaining < large:
        raise ValueError("Requested budget must fit small files and at least one large file")
    count = remaining // large
    return {**{f"large/large-{i:06d}.bin": large for i in range(count)},
            **{f"small/small-{i:06d}.bin": small for i in range(int(small_count))}}

def token(scope):
    body = urllib.parse.urlencode({
        "client_id": os.environ["AZURE_CLIENT_ID"],
        "grant_type": "client_credentials",
        "scope": scope,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": pathlib.Path(os.environ["AZURE_FEDERATED_TOKEN_FILE"]).read_text()
    }).encode()
    request = urllib.request.Request(
        f"https://login.microsoftonline.com/{os.environ['AZURE_TENANT_ID']}/oauth2/v2.0/token",
        data=body)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["access_token"]

class Storage:
    def __init__(self, endpoint):
        self.endpoint = endpoint.rstrip("/")
        self.access_token = ""
        self.expires = 0

    def request(self, path, method="GET", body=None, headers=None, allow404=False):
        if time.time() >= self.expires:
            self.access_token = token("https://storage.azure.com/.default")
            self.expires = time.time() + 1800
        h = {"Authorization": f"Bearer {self.access_token}", "x-ms-version": "2023-11-03",
             "x-ms-date": datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")}
        h.update(headers or {})
        for attempt in range(7):
            try:
                req = urllib.request.Request(self.endpoint + "/" + path, data=body, headers=h, method=method)
                with urllib.request.urlopen(req, timeout=120) as response:
                    return response.read(), dict(response.headers)
            except urllib.error.HTTPError as error:
                if error.code == 404 and allow404:
                    return None, {}
                if error.code not in (403, 408, 429, 500, 502, 503, 504) or attempt == 6:
                    raise
                time.sleep(min(60, 2**attempt))
        raise RuntimeError("Storage retry exhausted")

    def inventory(self):
        found, marker = {}, ""
        while True:
            query = urllib.parse.urlencode({"restype": "container", "comp": "list", "maxresults": "5000", "marker": marker})
            data, _ = self.request("sampledata?" + query)
            root = ET.fromstring(data)
            for blob in root.findall("./Blobs/Blob"):
                name = blob.findtext("Name")
                found[name] = int(blob.findtext("./Properties/Content-Length"))
            marker = root.findtext("NextMarker")
            if not marker:
                return found

def azcopy(arguments, input_size=None):
    command = ["/tools/azcopy", "copy", *arguments, "--output-type=text", "--log-level=ERROR",
               "--block-size-mb=4", "--cap-mbps=" + os.environ.get("UPLOAD_CAP_MBPS", "0")]
    if input_size is None:
        subprocess.run(command, check=True)
        return
    # PipeBlob avoids a 10 GiB local file on a minimal AKS node. Random blocks do not
    # compress to misleadingly tiny benchmark payloads. Names, not payloads, are deterministic.
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    try:
        remaining = input_size
        while remaining:
            chunk = os.urandom(min(4 * 1024**2, remaining))
            process.stdin.write(chunk)
            remaining -= len(chunk)
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError("AzCopy stream upload failed")
    except BaseException:
        process.stdin.close()
        process.wait()
        raise

def main():
    expected = layout(os.environ.get("SIZE_GB", "100"), os.environ.get("LARGE_FILE_SIZE_GB", "10"),
                      os.environ.get("SMALL_FILE_COUNT", "20000"), os.environ.get("SMALL_FILE_SIZE_MB", "1"))
    mode = os.environ.get("UPLOAD_MODE", "upload")
    endpoint = os.environ["STORAGE_ENDPOINT"]
    store = Storage(endpoint)
    if mode == "verify":
        data, _ = store.request("sampledata/_manifest.json")
        manifest = json.loads(data)
        if manifest["expected"] != expected:
            raise RuntimeError("Secondary manifest layout does not match configured sample layout")
        actual = store.inventory()
        for name, size in expected.items():
            if actual.get(name) != size:
                raise RuntimeError(f"Secondary missing/wrong-sized blob: {name}")
        # A real data-plane GET through the KRS secondary private endpoint, not just ARM metadata.
        for name in (next(n for n in expected if n.startswith("large/")),
                     next((n for n in expected if n.startswith("small/")), None)):
            if name:
                data, _ = store.request("sampledata/" + name, headers={"Range": "bytes=0-1023"})
                if len(data) != 1024:
                    raise RuntimeError(f"Secondary ranged read failed: {name}")
        print("SECONDARY_READ_VERIFIED " + json.dumps({"endUtc": utc(), "objects": len(expected),
                                                       "bytes": sum(expected.values())}), flush=True)
        return
    start = utc()
    old, _ = store.request("sampledata/_manifest.json", allow404=True)
    if old:
        previous = json.loads(old)
        if previous.get("expected") != expected:
            raise RuntimeError("Existing manifest uses a different layout; use a different account/container")
        start = previous["startUtc"]
    actual = store.inventory()
    for name in set(actual) & set(expected):
        if actual[name] != expected[name]:
            raise RuntimeError(f"Existing wrong-sized blob {name}; repair explicitly before resuming")
    base = endpoint.rstrip("/") + "/sampledata/"
    for name, size in expected.items():
        if name.startswith("large/") and name not in actual:
            azcopy([base + name, "--from-to=PipeBlob", "--overwrite=false"], size)
    # Bounded batches keep ephemeral space <256 MiB even with 20,000 small files.
    directory = pathlib.Path("/work/data")
    batch = []
    batch_bytes = 0
    def flush():
        nonlocal batch, batch_bytes
        if not batch:
            return
        azcopy([str(directory) + "/*", base + "small/", "--recursive=true", "--overwrite=false"])
        for path in batch:
            path.unlink()
        batch, batch_bytes = [], 0
    for name, size in expected.items():
        if not name.startswith("small/") or name in actual:
            continue
        if size > 128 * 1024**2:
            raise ValueError("SMALL_FILE_SIZE_MB must be <=128 to bound local disk usage")
        if batch_bytes + size > 128 * 1024**2:
            flush()
        path = directory / pathlib.PurePosixPath(name).name
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = os.urandom(min(1024**2, remaining))
                stream.write(chunk)
                remaining -= len(chunk)
        batch.append(path)
        batch_bytes += size
    flush()
    actual = store.inventory()
    for name, size in expected.items():
        if actual.get(name) != size:
            raise RuntimeError(f"Uploaded inventory mismatch: {name}")
    extra = set(actual) - set(expected) - {"_manifest.json"}
    if extra:
        raise RuntimeError("Unexpected blobs in dedicated sampledata container: " + repr(sorted(extra)[:10]))
    manifest = {"schema": 1, "startUtc": start, "endUtc": utc(), "largeFileCount": sum(n.startswith("large/") for n in expected),
                "smallFileCount": sum(n.startswith("small/") for n in expected), "actualFileCount": len(expected),
                "actualBytes": sum(expected.values()), "actualGiB": sum(expected.values()) / 1024**3,
                "expected": expected}
    encoded = json.dumps(manifest, separators=(",", ":")).encode()
    store.request("sampledata/_manifest.json", method="PUT", body=encoded,
                  headers={"x-ms-blob-type": "BlockBlob", "Content-Type": "application/json"})
    # Compact marker is intentionally machine-readable in AKS command-invoke logs.
    summary = {k: v for k, v in manifest.items() if k != "expected"}
    summary["replicationFenceUtc"] = utc()
    print("UPLOAD_MANIFEST " + json.dumps(summary), flush=True)

if __name__ == "__main__":
    main()
PY
