"""Bounded, asynchronous data-plane diagnostics for the two-region DR lab."""

import asyncio
from contextlib import AsyncExitStack, asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import ipaddress
import json
import logging
import os
from pathlib import Path
import random
import socket
import time
from urllib.parse import urlparse
import uuid

import certifi
import dns.asyncresolver
import dns.resolver
from azure.core.exceptions import ResourceNotFoundError
from azure.eventhub import EventData
from azure.eventhub.aio import EventHubProducerClient
from azure.identity.aio import DefaultAzureCredential
from azure.search.documents.aio import SearchClient
from azure.storage.blob.aio import BlobServiceClient
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
import httpx
import psycopg
from psycopg.rows import dict_row
from redis.asyncio.cluster import RedisCluster
from redis.asyncio.retry import Retry
from redis.backoff import NoBackoff

if __package__:
    from .sample_upload import SampleUploader, UploadBusy, UploadError
else:
    from sample_upload import SampleUploader, UploadBusy, UploadError


LOG = logging.getLogger("dr_dashboard")
# SDK/HTTP debug logs may contain credentials, authorization headers or record bodies.
for _logger in ("azure", "httpx", "httpcore", "redis", "psycopg"):
    logging.getLogger(_logger).setLevel(logging.CRITICAL)

OP_TIMEOUT = 3.0
LIST_TIMEOUT = 10.0
CACHE_TTL = 300.0
MIB = 1024 * 1024
SERVICE_NAMES = (
    "postgres", "redis", "event_hubs", "storage_primary", "storage_secondary", "search"
)


class ConfigurationError(ValueError):
    pass


class ProbeError(RuntimeError):
    pass


def safe_error(exc: Exception) -> str:
    if isinstance(exc, TimeoutError):
        return "Operation timed out"
    if isinstance(exc, ConfigurationError):
        return str(exc)
    if isinstance(exc, ResourceNotFoundError):
        return "Resource not found"
    if isinstance(exc, ProbeError):
        return str(exc)
    return f"Operation failed ({type(exc).__name__})"


async def bounded(factory, *, timeout=None, attempts=2):
    """One retry here; SDK retry loops are disabled to avoid multiplicative retries."""
    for attempt in range(attempts):
        try:
            async with asyncio.timeout(OP_TIMEOUT if timeout is None else timeout):
                return await factory()
        except (ConfigurationError, ResourceNotFoundError, StopAsyncIteration):
            raise
        except Exception as exc:
            if attempt + 1 == attempts:
                LOG.warning("External operation failed: %s", type(exc).__name__)
                raise


@dataclass
class Settings:
    values: dict[str, str] = field(default_factory=lambda: dict(os.environ), repr=False)

    def get(self, name, default=""):
        value = self.values.get(name, default)
        return value if name in ("PG_PASSWORD", "REDIS_KEY") else value.strip()

    @property
    def region(self):
        return self.get("REGION", "krc")

    @property
    def mode(self):
        return self.get("STORAGE_READ_MODE", "primary")

    def host(self, service):
        account = self.get("STORAGE_ACCOUNT")
        return {
            "postgres": self.get("PG_HOST"),
            "redis": self.get("REDIS_HOST"),
            "event_hubs": self.get("EH_NAMESPACE"),
            "storage_primary": f"{account}.blob.core.windows.net" if account else "",
            "storage_secondary": f"{account}-secondary.blob.core.windows.net" if account else "",
            "search": urlparse(self.get("SEARCH_ENDPOINT")).hostname or "",
        }[service]

    def validate(self, service):
        required = {
            "postgres": ("PG_HOST", "PG_DB", "PG_USER", "PG_PASSWORD"),
            "redis": ("REDIS_HOST", "REDIS_KEY"),
            "event_hubs": ("EH_NAMESPACE", "EH_NAME"),
            "storage_primary": ("STORAGE_ACCOUNT",),
            "storage_secondary": ("STORAGE_ACCOUNT",),
            "search": ("SEARCH_ENDPOINT", "SEARCH_INDEX"),
        }[service]
        missing = [key for key in required if not self.get(key)]
        if len(missing) == len(required) and service in ("redis", "event_hubs", "search"):
            return False
        if missing:
            raise ConfigurationError("Missing configuration: " + ", ".join(missing))
        if service == "redis":
            try:
                port = int(self.get("REDIS_PORT", "10000"))
                if not 1 <= port <= 65535:
                    raise ValueError()
            except ValueError:
                raise ConfigurationError("REDIS_PORT must be a valid TCP port") from None
        if service == "search":
            parsed = urlparse(self.get("SEARCH_ENDPOINT"))
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                raise ConfigurationError("SEARCH_ENDPOINT must be an HTTPS endpoint without credentials")
        if service == "event_hubs" and (
            "://" in self.get("EH_NAMESPACE") or "/" in self.get("EH_NAMESPACE")
        ):
            raise ConfigurationError("EH_NAMESPACE must be a fully qualified hostname")
        return True


def classify_ips(ips, settings):
    regions = set()
    for address in ips:
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            continue
        if str(ip).startswith(settings.get("KRC_VNET_PREFIX", "10.10.")):
            regions.add("KRC")
        elif str(ip).startswith(settings.get("KRS_VNET_PREFIX", "10.20.")):
            regions.add("KRS")
        else:
            regions.add("PUBLIC")
    return next(iter(regions)) if len(regions) == 1 else "MIXED" if regions else "UNKNOWN"


def tm_region(ips, settings):
    regions = set()
    for address in ips:
        if address == settings.get("KRC_PUBLIC_IP"):
            regions.add("KRC")
        elif address == settings.get("KRS_PUBLIC_IP"):
            regions.add("KRS")
        else:
            regions.add("UNKNOWN")
    return next(iter(regions)) if len(regions) == 1 else "MIXED" if regions else "UNKNOWN"


async def resolve_ips(host):
    if not host:
        raise ConfigurationError("Endpoint hostname is missing")
    try:
        return [str(ipaddress.ip_address(host))]
    except ValueError:
        pass
    resolver = dns.asyncresolver.Resolver()

    async def resolve_type(kind):
        try:
            answer = await resolver.resolve(host, kind, lifetime=OP_TIMEOUT)
            return [str(item) for item in answer]
        except dns.resolver.NoAnswer:
            return []

    answers = await asyncio.gather(resolve_type("A"), resolve_type("AAAA"))
    ips = sorted(set(answers[0] + answers[1]))
    if not ips:
        raise ProbeError("DNS returned no addresses")
    return ips


class TimedCredential:
    def __init__(self, credential):
        self.credential = credential

    async def get_token(self, *scopes, **kwargs):
        # The enclosing service operation owns the single retry.
        async with asyncio.timeout(OP_TIMEOUT):
            return await self.credential.get_token(*scopes, **kwargs)


class Runtime:
    def __init__(self, settings):
        self.settings = settings
        self.clients = {}
        self.initialization_errors = {}
        self.cache = {}
        self.locks = {"primary": asyncio.Lock(), "secondary": asyncio.Lock()}
        self.http = None
        self.credential = None
        self.sample_uploader = SampleUploader(self)

    def enabled(self, service):
        enabled = self.settings.validate(service)
        if service in self.initialization_errors:
            raise ProbeError(self.initialization_errors[service])
        return enabled

    def client(self, name):
        if name not in self.clients:
            raise ConfigurationError("Service client is unavailable; check configuration")
        return self.clients[name]

    async def start(self, stack):
        settings = self.settings
        credential = DefaultAzureCredential(
            retry_total=0, process_timeout=3,
            exclude_interactive_browser_credential=True,
        )
        await stack.enter_async_context(credential)
        self.credential = TimedCredential(credential)
        self.http = await stack.enter_async_context(httpx.AsyncClient(
            timeout=httpx.Timeout(OP_TIMEOUT), limits=httpx.Limits(max_connections=8)
        ))
        for service in SERVICE_NAMES:
            try:
                if not settings.validate(service) or service == "postgres":
                    continue
                common = dict(
                    credential=self.credential, retry_total=0,
                    connection_timeout=OP_TIMEOUT, read_timeout=OP_TIMEOUT,
                )
                if service.startswith("storage_"):
                    primary = service == "storage_primary"
                    client = BlobServiceClient(
                        f"https://{settings.host(service)}",
                        secondary_hostname=settings.host("storage_secondary") if primary else None,
                        retry_to_secondary=primary, **common,
                    )
                elif service == "event_hubs":
                    client = EventHubProducerClient(
                        settings.host(service), settings.get("EH_NAME"), self.credential,
                        retry_total=0, auth_timeout=3, socket_timeout=3,
                    )
                elif service == "redis":
                    client = RedisCluster(
                        host=settings.host(service),
                        port=int(settings.get("REDIS_PORT", "10000")),
                        password=settings.get("REDIS_KEY"), ssl=True,
                        ssl_cert_reqs="required", ssl_check_hostname=True,
                        address_remap=lambda address: (settings.host("redis"), address[1]),
                        socket_timeout=OP_TIMEOUT, socket_connect_timeout=OP_TIMEOUT,
                        max_connections=8, decode_responses=True,
                        cluster_error_retry_attempts=0, retry=Retry(NoBackoff(), 0),
                    )
                else:
                    client = SearchClient(
                        settings.get("SEARCH_ENDPOINT"), settings.get("SEARCH_INDEX"), **common,
                    )
                # RedisCluster.__aenter__ connects; defer that network operation to a bounded probe.
                if service == "redis":
                    stack.push_async_callback(client.aclose)
                else:
                    await stack.enter_async_context(client)
                self.clients[service] = client
            except Exception as exc:
                LOG.warning("Client initialization failed (%s): %s", service, type(exc).__name__)
                self.initialization_errors[service] = safe_error(exc)


@asynccontextmanager
async def lifespan(application):
    async with AsyncExitStack() as stack:
        runtime = Runtime(Settings())
        await runtime.start(stack)
        application.state.runtime = runtime
        try:
            yield
        finally:
            await runtime.sample_uploader.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def no_cache(request, call_next):
    origin = request.headers.get("origin")
    expected_origin = f"{request.url.scheme}://{request.headers.get('host', '')}"
    cross_site = request.headers.get("sec-fetch-site", "").lower() == "cross-site"
    if request.method not in ("GET", "HEAD", "OPTIONS") and (
        cross_site or (origin is not None and origin != expected_origin)
    ):
        response = JSONResponse({"detail": "Cross-site changes are not allowed"}, status_code=403)
    else:
        response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


def runtime_of(request):
    return request.app.state.runtime


@app.get("/")
async def index():
    return FileResponse(Path(__file__).parent / "static" / "index.html")


@app.get("/api/healthz")
@app.get("/healthz")
async def health(request: Request):
    return {"status": "ok", "region": runtime_of(request).settings.region}


@app.get("/api/info")
async def info(request: Request):
    settings = runtime_of(request).settings
    return {
        "region": settings.region, "pod_name": settings.get("POD_NAME") or os.getenv("HOSTNAME", socket.gethostname()),
        "time": datetime.now(timezone.utc).isoformat(),
        "host": request.headers.get("host", ""),
        "client_ip": request.client.host if request.client else None,
        "storage_read_mode": settings.mode,
    }


@app.get("/api/tm")
async def traffic_manager(request: Request):
    settings = runtime_of(request).settings
    host = settings.get("TM_FQDN")
    started = time.monotonic()
    result = dict(fqdn=host, ips=[], region="UNKNOWN", cname_chain=[], error=None, status="ok")

    async def lookup():
        if not host:
            raise ConfigurationError("Missing configuration: TM_FQDN")
        resolver = dns.asyncresolver.Resolver()
        chain = []
        current = host.rstrip(".")
        visited = {current.lower()}
        for _ in range(8):
            try:
                answer = await resolver.resolve(current, "CNAME", lifetime=OP_TIMEOUT)
            except dns.resolver.NoAnswer:
                return await resolve_ips(current), chain
            target = str(answer[0].target).rstrip(".")
            chain.append(target)
            if target.lower() in visited:
                raise ProbeError("DNS CNAME cycle detected")
            visited.add(target.lower())
            current = target
        raise ProbeError("DNS CNAME chain exceeds 8 links")

    try:
        result["ips"], result["cname_chain"] = await bounded(lookup)
        result["region"] = tm_region(result["ips"], settings)
    except Exception as exc:
        result.update(status="error", error=safe_error(exc))
        LOG.warning("Traffic Manager probe failed: %s", type(exc).__name__)
    result["latency_ms"] = round((time.monotonic() - started) * 1000, 2)
    return result


async def service_result(runtime, service, operation, *, owns_retry=False):
    started = time.monotonic()
    result = dict(
        status="ok", ok=True, latency_ms=0, error=None,
        fqdn=runtime.settings.host(service), ips=[], pe_region="UNKNOWN", data=None,
    )
    try:
        if not runtime.enabled(service):
            result.update(status="disabled", ok=None, pe_region="disabled")
            return result
    except Exception as exc:
        result.update(status="error", ok=False, error=safe_error(exc))
        return result

    async def metadata():
        try:
            result["ips"] = await bounded(lambda: resolve_ips(result["fqdn"]))
            result["pe_region"] = classify_ips(result["ips"], runtime.settings)
        except Exception as exc:
            result["dns_error"] = safe_error(exc)

    async def probe():
        try:
            result["data"] = await operation() if owns_retry else await bounded(operation)
        except Exception as exc:
            result.update(status="error", ok=False, error=safe_error(exc))
            LOG.warning("Service operation failed (%s): %s", service, type(exc).__name__)

    await asyncio.gather(metadata(), probe())
    result["latency_ms"] = round((time.monotonic() - started) * 1000, 2)
    return result


async def pg_operation(runtime, action, record=None):
    settings = runtime.settings
    connection = await psycopg.AsyncConnection.connect(
        host=settings.get("PG_HOST"), dbname=settings.get("PG_DB"),
        user=settings.get("PG_USER"), password=settings.get("PG_PASSWORD"),
        sslmode="verify-full", sslrootcert=certifi.where(), connect_timeout=3,
        options="-c statement_timeout=3000 -c lock_timeout=3000", row_factory=dict_row,
    )
    async with connection:
        async with connection.cursor() as cursor:
            if action == "check":
                await cursor.execute("SELECT 1 AS value")
            elif action == "write":
                await cursor.execute(
                    "CREATE TABLE IF NOT EXISTS dr_test "
                    "(id uuid PRIMARY KEY, region text NOT NULL, ts timestamptz NOT NULL)"
                )
                await cursor.execute(
                    "INSERT INTO dr_test (id, region, ts) VALUES (%s, %s, %s) "
                    "ON CONFLICT (id) DO UPDATE SET region=EXCLUDED.region, ts=EXCLUDED.ts",
                    (record["id"], record["region"], record["ts"]),
                )
                return record
            else:
                await cursor.execute(
                    "SELECT id::text, region, ts FROM dr_test ORDER BY ts DESC, id DESC LIMIT 1"
                )
            row = await cursor.fetchone()
            if row and isinstance(row.get("ts"), datetime):
                row["ts"] = row["ts"].isoformat()
            return row


async def check_operation(runtime, service):
    if service == "postgres":
        return await pg_operation(runtime, "check")
    client = runtime.client(service)
    if service == "redis":
        if not await client.ping():
            raise ProbeError("Redis PING was not acknowledged")
        return {"ping": True}
    if service == "event_hubs":
        return await client.get_eventhub_properties()
    if service.startswith("storage_"):
        await client.get_container_client("drtest").get_container_properties()
        return {"container": "drtest"}
    return {"count": await client.get_document_count()}


@app.get("/api/check")
async def check(request: Request):
    runtime = runtime_of(request)
    results = await asyncio.gather(*(
        service_result(runtime, name, lambda name=name: check_operation(runtime, name))
        for name in SERVICE_NAMES
    ))
    return dict(zip(SERVICE_NAMES, results))


async def write_operation(runtime, service, record):
    encoded = json.dumps(record, separators=(",", ":"))
    if service == "postgres":
        return await pg_operation(runtime, "write", record)
    client = runtime.client(service)
    if service == "redis":
        if not await client.set("dr:last", encoded):
            raise ProbeError("Redis SET was not acknowledged")
    elif service == "event_hubs":
        batch = await client.create_batch()
        batch.add(EventData(encoded))
        await client.send_batch(batch, timeout=OP_TIMEOUT)
    elif service == "storage_primary":
        await client.get_blob_client("drtest", f'{record["id"]}.json').upload_blob(
            encoded, overwrite=True, metadata={"ts": record["ts"]},
        )
    elif service == "search":
        results = await client.merge_or_upload_documents([{
            "id": record["id"], "region": record["region"],
            "title": f'DR sample {record["id"]}', "content": encoded,
        }])
        if not results or not all(item.succeeded for item in results):
            raise ProbeError("Search rejected the document")
    return {"id": record["id"], "written": True}


@app.post("/api/write")
async def write(request: Request):
    runtime = runtime_of(request)
    record = {
        "id": str(uuid.uuid4()), "region": runtime.settings.region,
        "ts": datetime.now(timezone.utc).isoformat(),
    }
    names = [name for name in SERVICE_NAMES if name != "storage_secondary"]
    results = await asyncio.gather(*(
        service_result(runtime, name, lambda name=name: write_operation(runtime, name, record))
        for name in names
    ))
    services = dict(zip(names, results))
    failures = sum(item["ok"] is False for item in results)
    successes = sum(item["ok"] is True for item in results)
    return {
        "record": record, "services": services,
        "read_only": services["storage_primary"]["ok"] is False,
        "status": "partial" if failures and successes else "error" if failures else "ok",
    }


async def blob_latest(runtime, endpoint):
    container = runtime.client(f"storage_{endpoint}").get_container_client("drtest")
    latest = None
    async for blob in container.list_blobs():
        if not blob.name.endswith(".json"):
            continue
        if latest is None or (blob.last_modified, blob.name) > (latest.last_modified, latest.name):
            latest = blob
    record = None
    if latest is not None:
        downloader = await container.get_blob_client(latest.name).download_blob(
            offset=0, length=MIB, max_concurrency=1,
        )
        record = json.loads(await downloader.readall())
    return {
        "record": record, "endpoint_read": endpoint,
        "endpoint_fqdn": runtime.settings.host(f"storage_{endpoint}"),
        "fallback_reason": None,
    }


async def blob_read(runtime):
    mode = runtime.settings.mode
    if mode not in ("primary", "secondary"):
        raise ConfigurationError("STORAGE_READ_MODE must be primary or secondary")
    if mode == "secondary":
        return await bounded(lambda: blob_latest(runtime, "secondary"))
    # Internal SDK retries are zero, so the endpoint reported here is the one actually read.
    # The primary client still has secondary_hostname/retry_to_secondary configured.
    try:
        return await bounded(lambda: blob_latest(runtime, "primary"), attempts=1)
    except Exception as exc:
        LOG.warning("Primary read failed; using explicit secondary: %s", type(exc).__name__)
        data = await bounded(lambda: blob_latest(runtime, "secondary"), attempts=1)
        data["fallback_reason"] = safe_error(exc)
        return data


async def read_operation(runtime, service):
    if service == "postgres":
        return await pg_operation(runtime, "read")
    client = runtime.client(service)
    if service == "redis":
        value = await client.get("dr:last")
        return {"record": json.loads(value) if value else None}
    if service == "event_hubs":
        properties = await client.get_eventhub_properties()
        partitions = {}
        # Sequential reads avoid unbounded partition fan-out on a small pod.
        for partition in properties["partition_ids"]:
            value = await client.get_partition_properties(partition)
            partitions[partition] = value["last_enqueued_sequence_number"]
        return {"last_enqueued_sequence_numbers": partitions}
    return {"count": await client.get_document_count()}


@app.get("/api/read")
async def read(request: Request):
    runtime = runtime_of(request)
    names = ["postgres", "redis", "event_hubs", "search"]

    async def read_blob_result():
        endpoint = runtime.settings.mode if runtime.settings.mode in ("primary", "secondary") else "primary"
        blob = await service_result(
            runtime, f"storage_{endpoint}", lambda: blob_read(runtime), owns_retry=True,
        )
        if blob["ok"] and blob["data"]:
            actual = blob["data"]["endpoint_read"]
            actual_host = runtime.settings.host(f"storage_{actual}")
            if actual_host != blob["fqdn"]:
                blob["fqdn"] = actual_host
                try:
                    blob["ips"] = await bounded(lambda: resolve_ips(blob["fqdn"]))
                    blob["pe_region"] = classify_ips(blob["ips"], runtime.settings)
                    blob.pop("dns_error", None)
                except Exception as exc:
                    blob["ips"], blob["pe_region"], blob["dns_error"] = [], "UNKNOWN", safe_error(exc)
        return blob

    results = await asyncio.gather(*(
        service_result(runtime, name, lambda name=name: read_operation(runtime, name))
        for name in names
    ), read_blob_result())
    services = dict(zip([*names, "storage"], results))
    failures = sum(item["ok"] is False for item in services.values())
    successes = sum(item["ok"] is True for item in services.values())
    return {
        "services": services,
        "status": "partial" if failures and successes else "error" if failures else "ok",
    }


def parse_time(value):
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ProbeError("Replication timestamps must include a timezone")
    return parsed.astimezone(timezone.utc)


def replication_complete(last_sync_time, manifest_end_time):
    sync, end = parse_time(last_sync_time), parse_time(manifest_end_time)
    return sync >= end if sync is not None and end is not None else None


async def sample_inventory(runtime, endpoint):
    container = runtime.client(f"storage_{endpoint}").get_container_client(
        runtime.settings.get("SAMPLE_DATA_CONTAINER", "sampledata")
    )
    manifest = None
    try:
        async def get_manifest():
            downloader = await container.get_blob_client("_manifest.json").download_blob(
                max_concurrency=1,
            )
            value = json.loads(await downloader.readall())
            # expected has ~20,000 names; keep the API response/cache compact.
            return {key: item for key, item in value.items() if key != "expected"}
        manifest = await bounded(get_manifest)
    except ResourceNotFoundError:
        LOG.info("Sample manifest not yet present (%s)", endpoint)

    async def inventory():
        counts = {"large": {"count": 0, "bytes": 0}, "small": {"count": 0, "bytes": 0}}
        selected, seen = None, 0
        pages = container.list_blobs(results_per_page=500).by_page()
        while True:
            try:
                # Retrying a failed iterator in place can look like normal exhaustion.
                # Restart the entire scan instead, so incomplete counts are never cached.
                page = await bounded(lambda: anext(pages), attempts=1)
            except StopAsyncIteration:
                break
            async for blob in page:
                category = blob.name.split("/", 1)[0]
                if category not in counts:
                    continue
                counts[category]["count"] += 1
                counts[category]["bytes"] += blob.size
                if blob.size >= MIB:
                    seen += 1
                    if random.randrange(seen) == 0:
                        selected = blob.name
        return {
            **counts, "total_bytes": sum(item["bytes"] for item in counts.values()),
            "manifest": manifest, "sampled_blob": selected,
            "status": "ok" if manifest else "pending",
        }

    # Restart the entire scan on retry; never cache incomplete counts.
    return await bounded(inventory, timeout=LIST_TIMEOUT)


async def cached_inventory(runtime, endpoint):
    async with runtime.locks[endpoint]:
        existing = runtime.cache.get(endpoint)
        now = time.monotonic()
        if existing and now - existing[0] < CACHE_TTL:
            return dict(existing[1]), True, now - existing[0]
        value = await sample_inventory(runtime, endpoint)
        runtime.cache[endpoint] = (time.monotonic(), value)
        return dict(value), False, 0.0


async def sample_endpoint(runtime, endpoint):
    started = time.monotonic()
    result = {
        "status": "error", "manifest": None, "large": None, "small": None,
        "total_bytes": None, "read_1mb_ms": None, "read_bytes": 0,
        "sampled_blob": None, "cached": False, "cache_age_seconds": 0,
        "error": None, "endpoint_read": endpoint,
        "fqdn": runtime.settings.host(f"storage_{endpoint}"),
    }
    try:
        runtime.enabled(f"storage_{endpoint}")
        data, cached, age = await cached_inventory(runtime, endpoint)
        result.update(data, cached=cached, cache_age_seconds=round(age, 2))
        if result["sampled_blob"]:
            async def range_read():
                client = runtime.client(f"storage_{endpoint}").get_blob_client(
                    runtime.settings.get("SAMPLE_DATA_CONTAINER", "sampledata"), result["sampled_blob"],
                )
                downloader = await client.download_blob(
                    offset=0, length=MIB, max_concurrency=1,
                )
                return len(await downloader.readall())
            read_started = time.monotonic()
            size = await bounded(range_read)
            result.update(read_1mb_ms=round((time.monotonic() - read_started) * 1000, 2), read_bytes=size)
            if size != MIB:
                raise ProbeError("Sample range read did not return 1 MiB")
    except Exception as exc:
        result.update(status="error", error=safe_error(exc))
        LOG.warning("Sample inventory/read failed (%s): %s", endpoint, type(exc).__name__)
    result["latency_ms"] = round((time.monotonic() - started) * 1000, 2)
    return result


@app.get("/api/sampledata/upload")
async def sample_upload_status(request: Request):
    uploader = runtime_of(request).sample_uploader
    try:
        async with asyncio.timeout(12):
            return await uploader.status()
    except Exception as exc:
        raise HTTPException(503, safe_error(exc)) from None


@app.post("/api/sampledata/upload", status_code=202)
async def sample_upload_start(request: Request):
    uploader = runtime_of(request).sample_uploader
    if not uploader.enabled():
        raise HTTPException(403, "Sample upload is disabled")
    # Never trust X-Forwarded-* here; uvicorn runs with --no-proxy-headers.
    origin = request.headers.get("origin", "")
    if origin != f"{request.url.scheme}://{request.headers.get('host', '')}":
        raise HTTPException(403, "A same-origin Origin header is required")
    if request.headers.get("x-confirm-sample-upload") != "10GB":
        raise HTTPException(403, "Explicit X-Confirm-Sample-Upload: 10GB confirmation is required")
    if request.headers.get("content-length", "0") != "0" or request.headers.get("transfer-encoding"):
        raise HTTPException(400, "Upload configuration/body is not accepted")
    if request.query_params:
        raise HTTPException(400, "Upload parameters are not accepted")
    try:
        async with asyncio.timeout(12):
            return await uploader.start()
    except UploadBusy as exc:
        raise HTTPException(409, str(exc)) from None
    except UploadError as exc:
        raise HTTPException(400, str(exc)) from None
    except Exception as exc:
        raise HTTPException(503, safe_error(exc)) from None


async def last_sync(runtime):
    resource_id = runtime.settings.get("STORAGE_RESOURCE_ID")
    subscription = runtime.settings.get("AZURE_SUBSCRIPTION_ID")
    if not resource_id or not subscription:
        raise ConfigurationError("Missing configuration: AZURE_SUBSCRIPTION_ID / STORAGE_RESOURCE_ID")
    expected_prefix = f"/subscriptions/{subscription}/resourceGroups/".lower()
    if not resource_id.lower().startswith(expected_prefix) or "?" in resource_id or "#" in resource_id:
        raise ConfigurationError("STORAGE_RESOURCE_ID must belong to AZURE_SUBSCRIPTION_ID")
    async def request():
        token = await runtime.credential.get_token("https://management.azure.com/.default")
        response = await runtime.http.get(
            "https://management.azure.com" + resource_id,
            params={"api-version": "2026-09-01", "$expand": "geoReplicationStats"},
            headers={"Authorization": f"Bearer {token.token}"},
        )
        response.raise_for_status()
        stats = response.json().get("properties", {}).get("geoReplicationStats", {})
        return stats.get("lastSyncTime")
    return await bounded(request)


@app.get("/api/sampledata")
async def sampledata(request: Request):
    runtime = runtime_of(request)
    async def sync_result():
        try:
            return await last_sync(runtime), None
        except Exception as exc:
            LOG.warning("ARM replication status failed: %s", type(exc).__name__)
            return None, safe_error(exc)
    primary, secondary, sync = await asyncio.gather(
        sample_endpoint(runtime, "primary"), sample_endpoint(runtime, "secondary"), sync_result(),
    )
    end = (primary.get("manifest") or {}).get("endUtc")
    error = sync[1]
    complete = None
    try:
        complete = replication_complete(sync[0], end)
    except Exception as exc:
        error = safe_error(exc)
    if primary["status"] != "ok" or secondary["status"] != "ok":
        complete = None
    elif complete is True:
        secondary_manifest = secondary.get("manifest") or {}
        complete = (
            end == secondary_manifest.get("endUtc")
            and primary.get("large") == secondary.get("large")
            and primary.get("small") == secondary.get("small")
            and primary.get("total_bytes") == secondary.get("total_bytes")
        )
    return {
        "primary": primary, "secondary": secondary, "last_sync_time": sync[0],
        "manifest_end_time": end, "replication_complete": complete, "error": error,
    }
