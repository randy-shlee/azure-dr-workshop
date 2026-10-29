"""In-process, lease-coordinated sample upload. Never creates Kubernetes resources."""

import asyncio
import base64
from contextlib import suppress
from datetime import datetime, timezone
import json
import logging
import os
import re
import time
import uuid

from azure.core import MatchConditions
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError

if __package__:
    from .sample_layout import CONTROL_BLOB as CONTROL, CONTROL_CONTAINER, LEASE_SECONDS, MAX_BYTES, RENEW_SECONDS, layout
else:
    from sample_layout import CONTROL_BLOB as CONTROL, CONTROL_CONTAINER, LEASE_SECONDS, MAX_BYTES, RENEW_SECONDS, layout


CHUNK_BYTES = 4 * 1024 * 1024
ACTIVE = {"queued", "running"}
LOG = logging.getLogger(__name__)


class UploadError(ValueError):
    pass


class UploadBusy(UploadError):
    pass


class LeaseLost(UploadError):
    pass


def utc():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def configuration(settings):
    container = settings.get("SAMPLE_DATA_CONTAINER", "sampledata")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])", container) or "--" in container:
        raise UploadError("SAMPLE_DATA_CONTAINER must be a valid blob container name")
    if container == "drtest":
        raise UploadError("Sample data must not use the drtest control container")
    try:
        expected = layout(
            settings.get("SAMPLE_DATA_SIZE_GB", "10"),
            settings.get("SAMPLE_DATA_LARGE_FILE_SIZE_GB", "1"),
            settings.get("SAMPLE_DATA_SMALL_FILE_COUNT", "2000"),
            settings.get("SAMPLE_DATA_SMALL_FILE_SIZE_MB", "1"),
        )
    except ValueError as exc:
        raise UploadError(str(exc)) from None
    return container, expected


async def call(factory):
    async with asyncio.timeout(10):
        return await factory()


async def ensure_container(container):
    try:
        await call(container.create_container)
    except ResourceExistsError as exc:
        # Do not mistake unrelated conflicts (e.g. a deleting container) for success.
        if exc.error_code != "ContainerAlreadyExists":
            raise


async def read_json(blob):
    try:
        stream = await call(lambda: blob.download_blob(max_concurrency=1))
        # Control and manifest reads are bounded too, including corrupt legacy blobs.
        if stream.size > 2 * 1024 * 1024:
            raise UploadError("Existing manifest/control blob exceeds the safe read limit")
        return json.loads(await call(stream.readall))
    except ResourceNotFoundError:
        return None


class SampleUploader:
    def __init__(self, runtime):
        self.runtime = runtime
        self.task = None
        self.lease = None
        self.deadline = 0
        self.lost = False
        self.state = {}

    def enabled(self):
        return self.runtime.settings.get("SAMPLE_UPLOAD_ENABLED", "false").lower() == "true"

    def control(self):
        return self.runtime.client("storage_primary").get_blob_client(CONTROL_CONTAINER, CONTROL)

    async def acquire(self, blob):
        try:
            return await call(lambda: blob.acquire_lease(lease_duration=LEASE_SECONDS))
        except HttpResponseError as exc:
            if exc.error_code in ("LeaseAlreadyPresent", "LeaseIsBreakingAndCannotBeAcquired"):
                raise UploadBusy("A sample upload is already running; poll status") from None
            raise

    async def start(self):
        if self.task and not self.task.done():
            raise UploadBusy("A sample upload is already running; poll status")
        container, expected = configuration(self.runtime.settings)
        client = self.runtime.client("storage_primary")
        await ensure_container(client.get_container_client("drtest"))
        blob = self.control()
        if await read_json(blob) is None:
            try:
                await call(lambda: blob.upload_blob(b"{}", overwrite=False))
            except ResourceExistsError as exc:
                if exc.error_code != "BlobAlreadyExists":
                    raise
        lease = await self.acquire(blob)
        try:
            previous = await read_json(blob) or {}
            self.state = {
                "status": "queued", "run_id": str(uuid.uuid4()), "container": container,
                "startUtc": utc(), "endUtc": None, "updatedUtc": utc(),
                "count": len(expected), "bytes": sum(expected.values()), "cap_bytes": MAX_BYTES,
                "completed_count": 0, "completed_bytes": 0, "error": None,
                "previous_status": "interrupted" if previous.get("status") in ACTIVE else previous.get("status"),
            }
            self.lease, self.deadline, self.lost = lease, time.monotonic() + 50, False
            await self.save()
        except BaseException:
            try:
                await call(lease.release)
            except Exception as exc:
                LOG.error("Sample lease release failed after start error: %s", type(exc).__name__)
            raise
        self.task = asyncio.create_task(self.run(container, expected))
        return dict(self.state)

    def check_lease(self):
        if self.lost or time.monotonic() >= self.deadline:
            raise LeaseLost("Upload lease lost; resume only after checking status")

    async def save(self):
        self.check_lease()
        self.state["updatedUtc"] = utc()
        await call(lambda: self.control().upload_blob(
            json.dumps(self.state).encode(), overwrite=True, lease=self.lease,
        ))

    async def renew(self, worker):
        while True:
            await asyncio.sleep(RENEW_SECONDS)
            try:
                await call(self.lease.renew)
                self.deadline = time.monotonic() + 50
            except Exception as exc:
                LOG.error("Sample lease renewal failed: %s", type(exc).__name__)
                self.lost = True
                worker.cancel()
                return

    async def chunks(self, size):
        remaining = size
        while remaining:
            self.check_lease()
            chunk = os.urandom(min(CHUNK_BYTES, remaining))
            remaining -= len(chunk)
            yield chunk
            await asyncio.sleep(0)

    async def upload(self, container, expected):
        await ensure_container(container)
        manifest_blob = container.get_blob_client("_manifest.json")
        previous = await read_json(manifest_blob)
        if previous is not None and (
            not isinstance(previous, dict) or previous.get("expected") != expected
        ):
            raise UploadError("Existing manifest uses an incompatible layout; use a different container. No data deleted")
        actual = {}
        pages = container.list_blobs(results_per_page=500).by_page()
        while True:
            try:
                page = await call(lambda: anext(pages))
            except StopAsyncIteration:
                break
            async with asyncio.timeout(10):
                async for blob in page:
                    self.check_lease()
                    if blob.name == "_manifest.json":
                        continue
                    if blob.name not in expected:
                        raise UploadError("Existing container has unexpected data; use a different container. No data deleted")
                    if blob.size != expected[blob.name]:
                        raise UploadError("Existing blob has the wrong size; repair explicitly before resuming. No data deleted")
                    actual[blob.name] = blob.size
        self.state.update(status="running", completed_count=len(actual), completed_bytes=sum(actual.values()))
        await self.save()
        # Record the layout before the first data write so an interrupted run is identifiable.
        manifest = {
            "expected": expected, "startUtc": (previous or {}).get("startUtc") or self.state["startUtc"],
            "endUtc": None, "count": len(expected), "bytes": sum(expected.values()),
        }
        self.check_lease()
        if previous is None:
            await call(lambda: manifest_blob.upload_blob(json.dumps(manifest).encode(), overwrite=False))
        for name, size in expected.items():
            if name in actual:
                continue
            self.check_lease()
            blob = container.get_blob_client(name)
            # Explicit blocks prevent the SDK's single-PUT buffering of small streams.
            # One request/block and at most four MiB per allocation; no local payload files.
            block_ids = []
            async for chunk in self.chunks(size):
                block_id = f"{self.state['run_id']}:{len(block_ids):08d}".encode()
                block_id = base64.b64encode(block_id).decode()
                await call(lambda: blob.stage_block(block_id, chunk, length=len(chunk)))
                block_ids.append(block_id)
            self.check_lease()
            try:
                await call(lambda: blob.commit_block_list(
                    block_ids, match_condition=MatchConditions.IfMissing,
                ))
            except ResourceExistsError:
                raise UploadError("A blob changed during upload; inspect the container before resuming") from None
            self.state["completed_count"] += 1
            self.state["completed_bytes"] += size
            await self.save()
        self.check_lease()
        manifest["endUtc"] = utc()
        await call(lambda: manifest_blob.upload_blob(json.dumps(manifest).encode(), overwrite=True))
        self.state.update(status="completed", endUtc=manifest["endUtc"])
        self.runtime.cache.clear()

    async def run(self, container_name, expected):
        worker = asyncio.current_task()
        renewer = asyncio.create_task(self.renew(worker))
        try:
            container = self.runtime.client("storage_primary").get_container_client(container_name)
            await self.upload(container, expected)
        except asyncio.CancelledError:
            self.state.update(status="lease_lost" if self.lost else "cancelled",
                              error="Lease renewal failed" if self.lost else "Application stopped; resume to continue",
                              endUtc=utc())
        except Exception as exc:
            LOG.error("Sample upload failed: %s", type(exc).__name__)
            self.state.update(status="lease_lost" if isinstance(exc, LeaseLost) else "failed",
                              error=str(exc) if isinstance(exc, UploadError) else f"Upload failed ({type(exc).__name__})",
                              endUtc=utc())
        finally:
            renewer.cancel()
            with suppress(asyncio.CancelledError):
                await renewer
            if not self.lost:
                try:
                    await self.save()
                except Exception as exc:
                    LOG.error("Sample upload status persistence failed: %s", type(exc).__name__)
                    # Durable running state is reconciled once its lease expires.
                    self.lost = True
            if self.lost:
                # Do not release a possibly valid lease while an SDK write is winding down.
                self.state.update(status="lease_lost", error="Upload lease lost; durable status will reconcile after expiry")
            else:
                try:
                    await call(self.lease.release)
                except Exception as exc:
                    LOG.error("Sample lease release failed: %s", type(exc).__name__)

    async def status(self):
        base = {"enabled": self.enabled(), "cap_bytes": MAX_BYTES}
        if not base["enabled"]:
            return {**base, "status": "disabled"}
        blob = self.control()
        value = await read_json(blob)
        if not value:
            return {**base, "status": "idle"}
        if value.get("status") in ACTIVE:
            try:
                lease = await self.acquire(blob)
            except UploadBusy:
                return {**value, **base}
            try:
                # Read again under the lease; never overwrite a newly completed run.
                value = await read_json(blob)
                if value.get("status") in ACTIVE:
                    value.update(status="interrupted", endUtc=utc(), updatedUtc=utc(),
                                 error="Worker stopped or lease lost. Start again to resume correctly sized files")
                    await call(lambda: blob.upload_blob(json.dumps(value).encode(), overwrite=True, lease=lease))
            finally:
                await call(lease.release)
        return {**value, **base}

    async def close(self):
        if self.task and not self.task.done():
            self.task.cancel()
            await self.task
