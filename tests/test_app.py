import asyncio
from datetime import datetime, timezone
import json
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from fastapi.testclient import TestClient

from app import main


def settings(**values):
    return main.Settings({
        "REGION": "krs", "STORAGE_ACCOUNT": "sampleaccount",
        "PG_HOST": "writer.postgres.database.azure.com", "PG_DB": "dr",
        "PG_USER": "writer", "PG_PASSWORD": "never-log-this-password",
        **values,
    })


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.start = patch.object(main.Runtime, "start", new=AsyncMock())
        self.start.start()
        self.client = TestClient(main.app)
        self.client.__enter__()
        self.runtime = main.app.state.runtime
        self.runtime.settings = settings()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.start.stop()

    def test_health_is_exact_and_independent(self):
        with patch.object(main, "resolve_ips", side_effect=AssertionError("no DNS")):
            response = self.client.get("/healthz")
        self.assertEqual(response.json(), {"status": "ok", "region": "krs"})
        self.assertEqual(response.headers["cache-control"], "no-store")

    def test_info_does_not_trust_forwarded_headers(self):
        response = self.client.get("/api/info", headers={
            "host": "literal.example:8123",
            "x-forwarded-for": "1.2.3.4", "x-forwarded-host": "spoofed",
        })
        self.assertEqual(response.json()["host"], "literal.example:8123")
        self.assertEqual(response.json()["client_ip"], "testclient")
        self.assertEqual(response.json()["storage_read_mode"], "primary")

    def test_info_uses_pod_downward_api_name(self):
        self.runtime.settings = settings(POD_NAME="drtest-app-pod")
        self.assertEqual(self.client.get("/api/info").json()["pod_name"], "drtest-app-pod")

    def test_generated_disabled_optional_configuration(self):
        self.runtime.settings = settings(
            EH_NAMESPACE="", EH_NAME="", REDIS_HOST="", REDIS_KEY="",
            SEARCH_ENDPOINT="", SEARCH_INDEX="", REDIS_PORT="10000",
        )
        with patch.object(main, "resolve_ips", new=AsyncMock(return_value=["10.10.1.2"])), patch.object(
            main, "check_operation", new=AsyncMock(return_value={"connected": True})
        ):
            body = self.client.get("/api/check").json()
        for service in ("event_hubs", "redis", "search"):
            self.assertEqual(body[service]["status"], "disabled")

    def test_optional_disabled_and_partial_config_explicit(self):
        self.runtime.settings = settings(REDIS_HOST="redis.example")
        with patch.object(main, "resolve_ips", new=AsyncMock(return_value=["10.10.0.4"])), patch.object(
            main, "check_operation", new=AsyncMock(return_value={"connected": True})
        ):
            response = self.client.get("/api/check")
        data = response.json()
        self.assertEqual(data["event_hubs"]["status"], "disabled")
        self.assertIsNone(data["event_hubs"]["ok"])
        self.assertIsNone(data["event_hubs"]["error"])
        self.assertEqual(data["search"]["pe_region"], "disabled")
        self.assertEqual(data["redis"]["ok"], False)
        self.assertIn("REDIS_KEY", data["redis"]["error"])
        self.assertEqual(set(data), set(main.SERVICE_NAMES))

    def test_write_partial_read_only_and_always_primary(self):
        calls = []

        async def operation(runtime, service, record):
            calls.append((service, dict(record)))
            if service == "storage_primary":
                raise RuntimeError("secret-key-must-not-leak")
            return {"written": True}

        with patch.object(main, "write_operation", side_effect=operation), patch.object(
            main, "resolve_ips", new=AsyncMock(return_value=["10.20.0.4"])
        ):
            response = self.client.post("/api/write")
        body = response.json()
        self.assertEqual(body["status"], "partial")
        self.assertTrue(body["read_only"])
        self.assertNotIn("storage_secondary", [name for name, _ in calls])
        self.assertTrue(all(record == body["record"] for _, record in calls))
        self.assertNotIn("secret-key", response.text)

    def test_other_write_failure_does_not_make_blob_read_only(self):
        async def operation(runtime, service, record):
            if service == "postgres":
                raise RuntimeError()
            return {"written": True}
        with patch.object(main, "write_operation", side_effect=operation), patch.object(
            main, "resolve_ips", new=AsyncMock(return_value=["10.20.0.4"])
        ):
            result = self.client.post("/api/write").json()
        self.assertEqual(result["status"], "partial")
        self.assertFalse(result["read_only"])

    def test_actual_probe_failure_not_hidden_by_dns_success(self):
        with patch.object(main, "check_operation", new=AsyncMock(side_effect=RuntimeError())), patch.object(
            main, "resolve_ips", new=AsyncMock(return_value=["10.10.1.2", "10.20.1.2"])
        ):
            data = self.client.get("/api/check").json()
        self.assertFalse(data["postgres"]["ok"])
        self.assertEqual(data["postgres"]["pe_region"], "MIXED")

    def test_read_fallback_reports_actual_secondary_dns(self):
        async def latest(runtime, endpoint):
            if endpoint == "primary":
                raise TimeoutError()
            return {"record": {"id": "test"}, "endpoint_read": endpoint,
                    "endpoint_fqdn": runtime.settings.host("storage_secondary"),
                    "fallback_reason": None}

        async def ips(host):
            return ["10.20.1.1"] if "-secondary" in host else ["10.10.1.1"]

        with patch.object(main, "blob_latest", side_effect=latest), patch.object(
            main, "resolve_ips", side_effect=ips
        ), patch.object(main, "read_operation", new=AsyncMock(return_value=None)):
            body = self.client.get("/api/read").json()
            data = body["services"]["storage"]
        self.assertIn(body["status"], ("ok", "partial", "error"))
        self.assertTrue(data["ok"])
        self.assertEqual(data["data"]["endpoint_read"], "secondary")
        self.assertEqual(data["data"]["fallback_reason"], "Operation timed out")
        self.assertEqual(data["pe_region"], "KRS")
        self.assertIn("-secondary", data["fqdn"])

    def test_tm_real_contract_and_cycle_guard(self):
        self.runtime.settings = settings(TM_FQDN="tm.example")
        resolver = MagicMock()
        resolver.resolve = AsyncMock(return_value=[SimpleNamespace(target="tm.example.")])
        with patch.object(main.dns.asyncresolver, "Resolver", return_value=resolver):
            data = self.client.get("/api/tm").json()
        self.assertEqual(data["status"], "error")
        self.assertIn("cycle", data["error"])
        self.assertEqual(data["region"], "UNKNOWN")
        self.assertEqual(resolver.resolve.await_count, 2)

    def test_sample_replication_requires_both_endpoint_inventories(self):
        inventory = {
            "status": "ok", "manifest": {"endUtc": "2026-01-01T00:00:00Z"},
            "large": {"count": 1, "bytes": main.MIB}, "small": {"count": 0, "bytes": 0},
            "total_bytes": main.MIB,
        }
        cases = [
            (dict(inventory), True),
            ({**inventory, "status": "error"}, None),
            ({**inventory, "manifest": None, "status": "pending"}, None),
            ({**inventory, "total_bytes": 0}, False),
            ({**inventory, "manifest": {"endUtc": "2025-12-31T23:00:00Z"}}, False),
        ]
        for secondary, expected in cases:
            with self.subTest(secondary=secondary), patch.object(
                main, "sample_endpoint", new=AsyncMock(side_effect=[inventory, secondary])
            ), patch.object(
                main, "last_sync", new=AsyncMock(return_value="2026-01-01T00:01:00Z")
            ):
                body = self.client.get("/api/sampledata").json()
            self.assertIs(body["replication_complete"], expected)


class LogicTests(unittest.IsolatedAsyncioTestCase):
    async def test_timeout_and_one_retry(self):
        calls = 0

        async def slow():
            nonlocal calls
            calls += 1
            await asyncio.sleep(10)

        started = time.monotonic()
        with self.assertRaises(TimeoutError), patch.object(main, "OP_TIMEOUT", 0.02):
            await main.bounded(slow)
        self.assertEqual(calls, 2)
        self.assertLess(time.monotonic() - started, 0.5)

    async def test_retry_success_and_sanitized_errors(self):
        call = AsyncMock(side_effect=[RuntimeError("password=x"), 42])
        self.assertEqual(await main.bounded(call), 42)
        self.assertEqual(call.await_count, 2)
        self.assertNotIn("password", main.safe_error(RuntimeError("password=x")))

    async def test_token_acquisition_is_bounded(self):
        credential = MagicMock()
        credential.get_token = AsyncMock(side_effect=TimeoutError())
        wrapper = main.TimedCredential(credential)
        with self.assertRaises(TimeoutError):
            await wrapper.get_token("scope")
        self.assertEqual(credential.get_token.await_count, 1)

    async def test_token_retries_are_not_multiplied(self):
        credential = MagicMock()
        credential.get_token = AsyncMock(side_effect=TimeoutError())
        wrapper = main.TimedCredential(credential)
        with self.assertRaises(TimeoutError):
            await main.bounded(lambda: wrapper.get_token("scope"))
        self.assertEqual(credential.get_token.await_count, 2)

    async def test_inventory_cache_ttl_and_concurrent_dedupe(self):
        runtime = main.Runtime(settings())
        count = 0

        async def inventory(runtime, endpoint):
            nonlocal count
            count += 1
            await asyncio.sleep(0.01)
            return {"status": "ok", "total_bytes": 100}

        with patch.object(main, "sample_inventory", side_effect=inventory):
            first, second = await asyncio.gather(
                main.cached_inventory(runtime, "primary"),
                main.cached_inventory(runtime, "primary"),
            )
            self.assertEqual(count, 1)
            self.assertFalse(first[1])
            self.assertTrue(second[1])
            runtime.cache["primary"] = (time.monotonic() - 301, first[0])
            refreshed = await main.cached_inventory(runtime, "primary")
            self.assertFalse(refreshed[1])
            self.assertEqual(count, 2)
            await main.cached_inventory(runtime, "secondary")
            self.assertEqual(count, 3)

    async def test_failed_inventory_is_not_cached(self):
        runtime = main.Runtime(settings())
        with patch.object(main, "sample_inventory", new=AsyncMock(side_effect=TimeoutError())):
            result = await main.sample_endpoint(runtime, "primary")
        self.assertEqual(result["status"], "error")
        self.assertIsNone(result["total_bytes"])
        self.assertNotIn("primary", runtime.cache)

    async def test_secondary_mode_never_uses_primary(self):
        runtime = main.Runtime(settings(STORAGE_READ_MODE="secondary"))
        with patch.object(main, "blob_latest", new=AsyncMock(return_value={"endpoint_read": "secondary"})) as call:
            data = await main.blob_read(runtime)
        call.assert_awaited_once_with(runtime, "secondary")
        self.assertEqual(data["endpoint_read"], "secondary")

    async def test_primary_read_retries_once_at_secondary(self):
        runtime = main.Runtime(settings())
        call = AsyncMock(side_effect=[TimeoutError(), {"endpoint_read": "secondary"}])
        with patch.object(main, "blob_latest", new=call):
            result = await main.blob_read(runtime)
        self.assertEqual(call.await_count, 2)
        self.assertEqual([args.args[1] for args in call.await_args_list], ["primary", "secondary"])
        self.assertEqual(result["fallback_reason"], "Operation timed out")

    async def test_sample_inventory_reads_requested_manifest_path(self):
        runtime = main.Runtime(settings())
        client, container, blob, downloader = MagicMock(), MagicMock(), MagicMock(), MagicMock()
        client.get_container_client.return_value = container
        container.get_blob_client.return_value = blob
        blob.download_blob = AsyncMock(return_value=downloader)
        downloader.readall = AsyncMock(return_value=json.dumps({
            "endUtc": "2026-01-01T00:00:00Z", "expected": {"large/one": main.MIB},
        }).encode())

        async def items():
            yield SimpleNamespace(name="large/one", size=main.MIB)
            yield SimpleNamespace(name="small/one", size=main.MIB)
            yield SimpleNamespace(name="_manifest.json", size=200)

        async def pages():
            yield items()

        container.list_blobs.return_value.by_page.return_value = pages()
        runtime.clients["storage_primary"] = client
        result = await main.sample_inventory(runtime, "primary")
        container.get_blob_client.assert_called_once_with("_manifest.json")
        self.assertNotIn("expected", result["manifest"])
        self.assertEqual(result["large"]["count"], 1)
        self.assertEqual(result["small"]["count"], 1)
        self.assertEqual(result["total_bytes"], 2 * main.MIB)

    async def test_blob_write_uses_expected_unique_path_and_overwrite(self):
        runtime = main.Runtime(settings())
        client = MagicMock()
        blob = MagicMock()
        blob.upload_blob = AsyncMock()
        client.get_blob_client.return_value = blob
        runtime.clients["storage_primary"] = client
        record = {"id": "unique-id", "region": "krs", "ts": "2026-01-01T00:00:00+00:00"}
        await main.write_operation(runtime, "storage_primary", record)
        client.get_blob_client.assert_called_once_with("drtest", "unique-id.json")
        self.assertTrue(blob.upload_blob.await_args.kwargs["overwrite"])
        self.assertEqual(json.loads(blob.upload_blob.await_args.args[0]), record)

    async def test_search_does_not_send_unknown_ts_field(self):
        runtime = main.Runtime(settings())
        client = MagicMock()
        client.merge_or_upload_documents = AsyncMock(
            return_value=[SimpleNamespace(succeeded=True)]
        )
        runtime.clients["search"] = client
        record = {"id": "one", "region": "krs", "ts": "2026-01-01T00:00:00Z"}
        await main.write_operation(runtime, "search", record)
        document = client.merge_or_upload_documents.await_args.args[0][0]
        self.assertEqual(set(document), {"id", "region", "title", "content"})
        self.assertEqual(json.loads(document["content"]), record)

    async def test_pg_tls_and_parameterized_idempotent_insert(self):
        runtime = main.Runtime(settings())
        cursor = MagicMock()
        cursor.execute = AsyncMock()
        cursor.__aenter__ = AsyncMock(return_value=cursor)
        connection = MagicMock()
        connection.__aenter__ = AsyncMock(return_value=connection)
        connection.cursor.return_value = cursor
        record = {"id": "one", "region": "krs", "ts": "2026-01-01T00:00:00Z"}
        with patch.object(main.psycopg.AsyncConnection, "connect", new=AsyncMock(return_value=connection)) as connect:
            await main.pg_operation(runtime, "write", record)
        self.assertEqual(connect.await_args.kwargs["sslmode"], "verify-full")
        query, parameters = cursor.execute.await_args.args
        self.assertIn("ON CONFLICT", query)
        self.assertEqual(parameters, ("one", "krs", record["ts"]))
        self.assertIn("%s", query)

    async def test_range_read_is_one_mebibyte(self):
        runtime = main.Runtime(settings())
        client, blob, downloader = MagicMock(), MagicMock(), MagicMock()
        client.get_blob_client.return_value = blob
        blob.download_blob = AsyncMock(return_value=downloader)
        downloader.readall = AsyncMock(return_value=b"x" * main.MIB)
        runtime.clients["storage_primary"] = client
        inventory = {
            "status": "ok", "large": {"count": 1, "bytes": main.MIB},
            "small": {"count": 0, "bytes": 0}, "total_bytes": main.MIB,
            "manifest": {"endUtc": "2026-01-01T00:00:00Z"}, "sampled_blob": "large/one",
        }
        with patch.object(main, "cached_inventory", new=AsyncMock(return_value=(inventory, True, 20))):
            result = await main.sample_endpoint(runtime, "primary")
        self.assertEqual(result["read_bytes"], main.MIB)
        self.assertTrue(result["cached"])
        self.assertEqual(blob.download_blob.await_args.kwargs["length"], main.MIB)
        self.assertEqual(blob.download_blob.await_args.kwargs["offset"], 0)

    async def test_redis_cluster_tls_and_lifespan_closes_clients(self):
        runtime = main.Runtime(settings(REDIS_HOST="cache.example", REDIS_KEY="private"))
        credential = MagicMock()
        credential.__aenter__ = AsyncMock(return_value=credential)
        credential.__aexit__ = AsyncMock()
        redis = MagicMock()
        redis.aclose = AsyncMock()
        with patch.object(main, "DefaultAzureCredential", return_value=credential), patch.object(
            main, "RedisCluster", return_value=redis
        ) as constructor:
            async with main.AsyncExitStack() as stack:
                await runtime.start(stack)
            kwargs = constructor.call_args.kwargs
        self.assertTrue(kwargs["ssl"])
        self.assertTrue(kwargs["ssl_check_hostname"])
        self.assertEqual(kwargs["port"], 10000)
        self.assertEqual(kwargs["cluster_error_retry_attempts"], 0)
        redis.aclose.assert_awaited_once()
        credential.__aexit__.assert_awaited_once()


class PureTests(unittest.TestCase):
    def test_dns_classification(self):
        config = settings()
        self.assertEqual(main.classify_ips(["10.10.1.1"], config), "KRC")
        self.assertEqual(main.classify_ips(["10.20.1.1"], config), "KRS")
        self.assertEqual(main.classify_ips(["192.168.1.1"], config), "PUBLIC")
        self.assertEqual(main.classify_ips(["10.10.1.1", "2001:db8::1"], config), "MIXED")
        self.assertEqual(main.classify_ips([], config), "UNKNOWN")
        config = settings(KRC_PUBLIC_IP="1.2.3.4", KRS_PUBLIC_IP="5.6.7.8")
        self.assertEqual(main.tm_region(["1.2.3.4", "5.6.7.8"], config), "MIXED")

    def test_replication_compares_actual_aware_clock_not_now(self):
        self.assertTrue(main.replication_complete("2026-01-01T02:00:00+02:00", "2026-01-01T00:00:00Z"))
        self.assertFalse(main.replication_complete("2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z"))
        self.assertIsNone(main.replication_complete(None, "2026-01-01T00:00:00Z"))
        self.assertIsNone(main.replication_complete("2026-01-01T00:00:00Z", None))
        with self.assertRaises(main.ProbeError):
            main.replication_complete("2026-01-01T00:00:00", "2026-01-01T00:00:00Z")

    def test_invalid_configuration_is_not_disabled(self):
        with self.assertRaises(main.ConfigurationError):
            settings(EH_NAMESPACE="namespace.example").validate("event_hubs")
        with self.assertRaises(main.ConfigurationError):
            settings(SEARCH_ENDPOINT="http://example", SEARCH_INDEX="x").validate("search")
        with self.assertRaises(main.ConfigurationError):
            settings(REDIS_HOST="cache", REDIS_KEY="x", REDIS_PORT="bad").validate("redis")

    def test_secret_values_preserve_whitespace_and_are_not_in_repr(self):
        config = settings(PG_PASSWORD=" password with spaces ", REDIS_KEY=" key ")
        self.assertEqual(config.get("PG_PASSWORD"), " password with spaces ")
        self.assertEqual(config.get("REDIS_KEY"), " key ")
        self.assertNotIn("password with spaces", repr(config))


if __name__ == "__main__":
    unittest.main()
