import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from azure.core import MatchConditions
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError
from azure.core.pipeline.transport import AsyncHttpResponse, AsyncHttpTransport
from azure.storage.blob.aio import BlobClient
from fastapi.testclient import TestClient

from app import main, sample_upload
from app.sample_layout import MAX_BYTES, layout


def storage_error(kind, code):
    error = kind(code)
    error.error_code = code
    return error


class Blob:
    def __init__(self):
        self.data = None
        self.blocks = {}
        self.held = False

    async def download_blob(self, **kwargs):
        if self.data is None:
            raise ResourceNotFoundError("BlobNotFound")
        return SimpleNamespace(size=len(self.data), readall=AsyncMock(return_value=self.data))

    async def upload_blob(self, data, overwrite=False, lease=None):
        if self.held and lease is None:
            raise AssertionError("A leased control blob must not be overwritten without its lease")
        if not overwrite and self.data is not None:
            raise storage_error(ResourceExistsError, "BlobAlreadyExists")
        self.data = data

    async def acquire_lease(self, lease_duration):
        if self.held:
            raise storage_error(HttpResponseError, "LeaseAlreadyPresent")
        self.held = True
        return SimpleNamespace(
            renew=AsyncMock(), release=AsyncMock(side_effect=self.release),
        )

    async def release(self):
        self.held = False

    async def stage_block(self, block_id, data, length):
        assert len(data) == length
        self.blocks[block_id] = data

    async def commit_block_list(self, blocks, **kwargs):
        assert kwargs == {"match_condition": MatchConditions.IfMissing}
        if self.data is not None:
            raise storage_error(ResourceExistsError, "BlobAlreadyExists")
        self.data = b"".join(self.blocks[item] for item in blocks)


class Container:
    def __init__(self):
        self.exists = False
        self.blobs = {}

    async def create_container(self):
        if self.exists:
            raise storage_error(ResourceExistsError, "ContainerAlreadyExists")
        self.exists = True

    def get_blob_client(self, name):
        return self.blobs.setdefault(name, Blob())

    def list_blobs(self, **kwargs):
        async def values():
            for name, blob in self.blobs.items():
                if blob.data is not None:
                    yield SimpleNamespace(name=name, size=len(blob.data))

        async def pages():
            yield values()

        return SimpleNamespace(by_page=pages)


class Storage:
    def __init__(self):
        self.containers = {}

    def get_container_client(self, name):
        return self.containers.setdefault(name, Container())

    def get_blob_client(self, container, name):
        return self.get_container_client(container).get_blob_client(name)


class UploadTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.storage = Storage()
        self.runtime = SimpleNamespace(
            settings={"SAMPLE_UPLOAD_ENABLED": "true"}, cache={"old": True},
            client=lambda _: self.storage,
        )
        self.uploader = sample_upload.SampleUploader(self.runtime)
        self.expected = {"large/test.bin": 7, "small/test.bin": 3}

    async def asyncTearDown(self):
        await self.uploader.close()

    async def start_small(self):
        with patch.object(sample_upload, "configuration", return_value=("samples", self.expected)):
            result = await self.uploader.start()
        return result

    async def test_stream_commit_manifest_and_durable_status(self):
        queued = await self.start_small()
        self.assertEqual(queued["status"], "queued")
        await self.uploader.task
        state = await self.uploader.status()
        self.assertEqual((state["status"], state["completed_bytes"]), ("completed", 10))
        container = self.storage.get_container_client("samples")
        for name, size in self.expected.items():
            self.assertEqual(len(container.blobs[name].data), size)
        manifest = json.loads(container.blobs["_manifest.json"].data)
        self.assertEqual(manifest["expected"], self.expected)
        self.assertTrue(manifest["endUtc"])
        self.assertFalse(self.uploader.control().held)
        self.assertEqual(self.runtime.cache, {})
        self.assertNotIn(sample_upload.CONTROL, container.blobs)

    async def test_streaming_has_a_measured_four_mib_chunk_bound(self):
        self.uploader.deadline = sample_upload.time.monotonic() + 50
        sizes = [len(chunk) async for chunk in self.uploader.chunks(4 * 1024**2 + 17)]
        self.assertEqual(sizes, [4 * 1024**2, 17])

    async def test_sdk_exception_details_are_not_logged(self):
        marker = "fake-credential-must-not-be-logged"
        with patch.object(self.uploader, "upload", new=AsyncMock(side_effect=RuntimeError(marker))), self.assertLogs(
            sample_upload.LOG, level="ERROR"
        ) as captured:
            await self.start_small()
            await self.uploader.task
        self.assertNotIn(marker, "\n".join(captured.output))
        self.assertNotIn(marker, self.uploader.state["error"])
        self.assertEqual(self.uploader.state["status"], "failed")

    async def test_actual_sdk_serializes_atomic_missing_blob_condition(self):
        requests = []
        class Response(AsyncHttpResponse):
            def __init__(self, request):
                super().__init__(request, None)
                self.status_code = 201
                self.headers = {"etag": '"test"', "last-modified": "Wed, 28 Oct 2026 08:00:00 GMT"}
                self.content_type = "application/xml"

            def body(self):
                return b""

        class Transport(AsyncHttpTransport):
            async def open(self):
                pass

            async def close(self):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                await self.close()

            async def send(self, request, **kwargs):
                assert "etag" not in kwargs
                assert "match_condition" not in kwargs
                requests.append(request)
                return Response(request)

        async with BlobClient(
            "https://example.blob.core.windows.net", "samples", "test.bin",
            transport=Transport(),
        ) as client:
            await client.commit_block_list(["block"], match_condition=MatchConditions.IfMissing)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].headers["If-None-Match"], "*")

    async def test_second_replica_cannot_overwrite_leased_control(self):
        await self.start_small()
        other = sample_upload.SampleUploader(self.runtime)
        with patch.object(sample_upload, "configuration", return_value=("samples", self.expected)):
            with self.assertRaises(sample_upload.UploadBusy):
                await other.start()
        await self.uploader.task

    async def test_incompatible_existing_data_is_preserved_and_failed(self):
        target = self.storage.get_container_client("samples").get_blob_client("unrelated.txt")
        target.data = b"preserve"
        await self.start_small()
        await self.uploader.task
        state = await self.uploader.status()
        self.assertEqual(state["status"], "failed")
        self.assertIn("unexpected data", state["error"])
        self.assertEqual(target.data, b"preserve")

    async def test_wrong_sized_existing_data_is_not_overwritten(self):
        blob = self.storage.get_container_client("samples").get_blob_client("large/test.bin")
        blob.data = b"wrong"
        await self.start_small()
        await self.uploader.task
        self.assertEqual((await self.uploader.status())["status"], "failed")
        self.assertEqual(blob.data, b"wrong")

    async def test_correct_files_are_resumed_without_overwrite(self):
        blob = self.storage.get_container_client("samples").get_blob_client("large/test.bin")
        blob.data = b"correct"
        await self.start_small()
        await self.uploader.task
        self.assertEqual((await self.uploader.status())["status"], "completed")
        self.assertEqual(blob.data, b"correct")

    async def test_stale_running_status_becomes_explicitly_interrupted(self):
        blob = self.uploader.control()
        blob.data = json.dumps({"status": "running", "run_id": "old"}).encode()
        state = await self.uploader.status()
        self.assertEqual(state["status"], "interrupted")
        self.assertIn("Worker stopped", state["error"])
        self.assertEqual(json.loads(blob.data)["status"], "interrupted")
        self.assertFalse(blob.held)

    async def test_failed_renewal_cancels_worker_and_marks_lease_lost(self):
        async def long_upload(*args):
            await asyncio.sleep(30)

        async def failed_renewal(worker):
            self.uploader.lost = True
            worker.cancel()

        with patch.object(self.uploader, "upload", side_effect=long_upload), patch.object(
            self.uploader, "renew", side_effect=failed_renewal
        ):
            await self.start_small()
            await self.uploader.task
        self.assertEqual(self.uploader.state["status"], "lease_lost")
        self.assertTrue(self.uploader.control().held)


class UploadRouteTests(unittest.TestCase):
    def setUp(self):
        self.start = patch.object(main.Runtime, "start", new=AsyncMock())
        self.start.start()
        self.client = TestClient(main.app)
        self.client.__enter__()
        self.uploader = main.app.state.runtime.sample_uploader
        main.app.state.runtime.settings = main.Settings({"SAMPLE_UPLOAD_ENABLED": "true"})
        self.headers = {"Origin": "http://testserver", "X-Confirm-Sample-Upload": "10GB"}

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.start.stop()

    def test_same_origin_and_confirmation_are_required(self):
        for headers in ({}, {"Origin": "http://wrong.example"}, {"Origin": "http://testserver"}):
            self.assertEqual(self.client.post("/api/sampledata/upload", headers=headers).status_code, 403)

    def test_arbitrary_browser_configuration_is_rejected(self):
        for path, data in (("/api/sampledata/upload?size=100", None), ("/api/sampledata/upload", b"100GB")):
            response = self.client.post(path, headers=self.headers, content=data)
            self.assertEqual(response.status_code, 400)

    def test_start_is_accepted_without_waiting_for_payload(self):
        with patch.object(self.uploader, "start", new=AsyncMock(return_value={"status": "queued"})):
            response = self.client.post("/api/sampledata/upload", headers=self.headers)
        self.assertEqual((response.status_code, response.json()["status"]), (202, "queued"))

    def test_busy_and_backend_failure_are_not_success_responses(self):
        for error, status in ((sample_upload.UploadBusy("busy"), 409), (RuntimeError("backend"), 503)):
            with patch.object(self.uploader, "start", new=AsyncMock(side_effect=error)):
                self.assertEqual(
                    self.client.post("/api/sampledata/upload", headers=self.headers).status_code, status,
                )

    def test_disabled_remains_disabled(self):
        main.app.state.runtime.settings = main.Settings({"SAMPLE_UPLOAD_ENABLED": "false"})
        self.assertEqual(self.client.post("/api/sampledata/upload", headers=self.headers).status_code, 403)
        self.assertEqual(self.client.get("/api/sampledata/upload").json()["status"], "disabled")

    def test_exact_decimal_cap_cannot_be_raised(self):
        for requested in (10, 100):
            expected = layout(requested, 1, 2000, 1)
            self.assertEqual((sum(expected.values()), len(expected)), (MAX_BYTES, 2008))
            self.assertEqual(expected["large/large-000007.bin"], 386655232)
        with self.assertRaises(sample_upload.UploadError):
            sample_upload.configuration({"SAMPLE_DATA_CONTAINER": "drtest"})
