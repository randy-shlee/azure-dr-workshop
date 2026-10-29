#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
need_python
if command -v cygpath >/dev/null; then export ESTIMATE_STATE_DIR="$(cygpath -w "$STATE_DIR")"
else export ESTIMATE_STATE_DIR="$STATE_DIR"; fi
"$PYTHON_BIN" - "$@" <<'PY'
import argparse
import datetime
import json
import os
import pathlib
import sys
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description="Live Azure Retail API auditable, non-binding monthly estimate. Missing/ambiguous meters are UNKNOWN, never zero.")
parser.add_argument("--hours", type=float, default=730)
parser.add_argument("--currency", default="USD")
parser.add_argument("--aks-vm-size", default="Standard_D4s_v5")
parser.add_argument("--aks-node-count", type=int, default=2, help="Nodes PER region (default: two)")
parser.add_argument("--pg-sku", default="Standard_D2ds_v5")
parser.add_argument("--pg-storage-gb", type=int, default=32)
parser.add_argument("--storage-gb", type=float, default=10)
parser.add_argument("--storage-write-ops", type=int, default=100000)
parser.add_argument("--storage-read-ops", type=int, default=100000)
parser.add_argument("--dns-queries", type=int, default=1000000)
parser.add_argument("--log-gb", type=float, default=1, help="Log ingestion GB per workspace")
parser.add_argument("--no-event-hubs", action="store_true")
parser.add_argument("--no-event-hubs-georecovery", action="store_true",
                    help="Disable metadata pairing; both Standard namespaces and all four private endpoints are still billed")
parser.add_argument("--event-hubs-ingress-events", type=int, default=1000000,
                    help="Billable 64KiB ingress-event units PER namespace over the estimated period, not replicated data")
parser.add_argument("--dns-resolver", action="store_true",
                    help="Include two regional DNS Private Resolver inbound endpoints; no outbound endpoints/rules")
parser.add_argument("--no-redis", action="store_true")
parser.add_argument("--no-search", action="store_true")
acr_geo = parser.add_mutually_exclusive_group()
acr_geo.add_argument("--acr-geo", action="store_true", help="Enable ACR geo-replica charges (default: disabled, matching infrastructure)")
acr_geo.add_argument("--no-acr-geo", action="store_false", dest="acr_geo", help="Explicitly disable ACR geo-replica charges")
parser.set_defaults(acr_geo=False)
parser.add_argument("--use-ephemeral-os-disk", action="store_true")
parser.add_argument("--app-gateway", action="store_true")
parser.add_argument("--budget", type=float, default=float(os.environ.get("MONTHLY_BUDGET", "1000")))
parser.add_argument("--catalog", help="Offline Retail API Items array for tests/audit (no network)")
parser.add_argument("--output", help="JSON report path (default .state/cost-estimate.json)")
parser.add_argument("--strict", action="store_true", help="Exit 2 if any estimate item is UNKNOWN")
args = parser.parse_args()
if args.hours <= 0 or args.aks_node_count < 2:
    parser.error("hours must be positive; AKS system pools require at least two nodes per region")
if min(args.pg_storage_gb, args.storage_gb, args.storage_write_ops, args.storage_read_ops, args.dns_queries, args.log_gb, args.event_hubs_ingress_events) < 0:
    parser.error("Quantities cannot be negative")
currency = args.currency.upper()
offline = json.loads(pathlib.Path(args.catalog).read_text()) if args.catalog else None
cache = {}
audit = []

def pages(url):
    seen = set()
    while url:
        if url in seen:
            raise RuntimeError("Retail API NextPageLink loop")
        # Follow the API-provided absolute link unchanged; do not rebuild/append $skip.
        if urllib.parse.urlparse(url).hostname != "prices.azure.com":
            raise RuntimeError("Unexpected Retail API pagination hostname")
        seen.add(url)
        for attempt in range(5):
            try:
                with urllib.request.urlopen(url, timeout=90) as response:
                    doc = json.load(response)
                break
            except Exception:
                if attempt == 4:
                    raise
                time.sleep(2**attempt)
        yield from doc["Items"]
        url = doc.get("NextPageLink") or ""

def prices(region, service, constraints):
    key = (region, service, tuple(sorted(constraints.items())))
    if key not in cache:
        filters = {"armRegionName": region, "serviceName": service, **constraints}
        expression = " and ".join(f"{k} eq '{str(v).replace(chr(39), chr(39)*2)}'" for k, v in filters.items())
        expression += " and priceType eq 'Consumption'"
        url = "https://prices.azure.com/api/retail/prices?" + urllib.parse.urlencode(
            {"api-version": "2023-01-01-preview", "currencyCode": "'" + currency + "'", "$filter": expression})
        try:
            raw = offline if offline is not None else list(pages(url))
            found = [i for i in raw if all(i.get(k) == v for k, v in filters.items())
                     and i.get("type") == "Consumption" and i.get("currencyCode") == currency]
            # Deduplicate the same meter's historical records only; different meter IDs remain ambiguous.
            latest = {}
            for item in found:
                identity = (item["meterId"], item["skuId"], item["unitOfMeasure"], item["tierMinimumUnits"])
                if identity not in latest or item.get("effectiveStartDate", "") > latest[identity].get("effectiveStartDate", ""):
                    latest[identity] = item
            cache[key] = (list(latest.values()), url, None)
        except Exception as error:
            cache[key] = ([], url, str(error))
    return cache[key]

def add(label, region, service, quantity, unit, ignore_free_allowance=False, **constraints):
    candidates, url, error = prices(region, service, constraints)
    candidates = [i for i in candidates if i.get("unitOfMeasure") == unit]
    row = {"item": label, "region": region, "quantity": quantity, "unit": unit,
           "match": constraints, "query": url}
    grouped = {}
    for item in candidates:
        grouped.setdefault((item["meterId"], item["skuId"]), []).append(item)
    if len(grouped) != 1:
        row.update(status="UNKNOWN", reason=error or f"Exact meter matches: {len(grouped)}",
                   candidateMeterIds=sorted({i["meterId"] for i in candidates}))
    else:
        tiers = sorted(next(iter(grouped.values())), key=lambda i: i["tierMinimumUnits"])
        if ignore_free_allowance:
            tiers = [i for i in tiers if i["retailPrice"] > 0]
        if not tiers or (tiers[0]["tierMinimumUnits"] != 0 and not ignore_free_allowance):
            row.update(status="UNKNOWN", reason="No applicable initial pricing tier")
            audit.append(row)
            return
        item = tiers[0]
        consumed = []
        amount = 0
        for index, tier in enumerate(tiers):
            lower = 0 if index == 0 and ignore_free_allowance else tier["tierMinimumUnits"]
            upper = tiers[index + 1]["tierMinimumUnits"] if index+1 < len(tiers) else quantity
            units = max(0, min(quantity, upper) - lower)
            if units:
                amount += units * tier["retailPrice"]
                consumed.append({"tierMinimumUnits": tier["tierMinimumUnits"], "quantity": units, "unitPrice": tier["retailPrice"]})
        row.update(status="MATCHED", unitPrice=item["retailPrice"], amount=amount, appliedTiers=consumed,
                   meterId=item["meterId"], skuId=item["skuId"], skuName=item["skuName"],
                   productName=item["productName"], meterName=item["meterName"], currency=item["currencyCode"],
                   effectiveStartDate=item["effectiveStartDate"], isPrimaryMeterRegion=item.get("isPrimaryMeterRegion"),
                   ignoredSharedFreeAllowance=ignore_free_allowance)
    audit.append(row)

hours, nodes = args.hours, args.aks_node_count
for region in ("koreacentral", "koreasouth"):
    vm_meter = args.aks_vm_size.removeprefix("Standard_").replace("_", " ")
    # A Linux product filter is essential: armSkuName alone also returns Windows/Spot/Low Priority.
    add(f"AKS Linux VM x{nodes}", region, "Virtual Machines", nodes*hours, "1 Hour",
        armSkuName=args.aks_vm_size, skuName=args.aks_vm_size, meterName=vm_meter,
        productName="Virtual Machines Dsv5 Series")
    if not args.use_ephemeral_os_disk:
        add(f"AKS managed OS disk P6 Premium_LRS 64GiB x{nodes}", region, "Storage", nodes*hours/730, "1/Month",
            productName="Premium SSD Managed Disks", skuName="P6 LRS", meterName="P6 LRS Disk")
    add("PostgreSQL D2 flexible server (one server)", region, "Azure Database for PostgreSQL", hours, "1 Hour",
        armSkuName=args.pg_sku, productName="Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute",
        skuName="2 vCore", meterName="vCore")
    add("PostgreSQL provisioned storage", region, "Azure Database for PostgreSQL", args.pg_storage_gb*hours/730, "1 GB/Month",
        productName="Azure Database for PostgreSQL Flex Server Storage", skuName="Storage", meterName="Storage Data Stored")
    if not args.no_event_hubs:
        add("Event Hubs Standard one TU", region, "Event Hubs", hours, "1 Hour",
            productName="Event Hubs", skuName="Standard", meterName="Standard Throughput Unit")
        add("Event Hubs Standard ingress events (64KiB units)", region, "Event Hubs",
            args.event_hubs_ingress_events/1000000, "1M",
            productName="Event Hubs", skuName="Standard", meterName="Standard Ingress Events")
    if not args.no_redis:
        add("Managed Redis Balanced B3", region, "Redis Cache", hours, "1 Hour",
            productName="Azure Managed Redis - Balanced", skuName="B3", meterName="B3 Cache Instance")
    if not args.no_search:
        add("AI Search Basic one search unit", region, "Azure Cognitive Search", hours, "1 Hour",
            productName="Azure AI Search", skuName="Basic", meterName="Basic Unit")
    add("Static public IPv4", region, "Virtual Network", hours, "1 Hour",
        skuName="Standard", meterName="Standard IPv4 Static Public IP")
    # KRC: blob, ACR, PG, Monitor; KRS additionally has blob_secondary.
    private_endpoints = 4 + (region == "koreasouth") + 2*(not args.no_event_hubs) + (not args.no_redis) + (not args.no_search)
    add(f"{region} private endpoints (includes Monitor PE)", "Global", "Virtual Network",
        private_endpoints*hours, "1 Hour",
        productName="Virtual Network Private Link", skuName="Standard", meterName="Standard Private Endpoint")
    add("Log Analytics ingestion", region, "Log Analytics", args.log_gb, "1 GB",
        ignore_free_allowance=True, productName="Log Analytics", skuName="Analytics Logs", meterName="Analytics Logs Data Ingestion")
    if args.dns_resolver:
        # The Retail API publishes a globally applicable blank-region meter,
        # not separate koreacentral/koreasouth resolver endpoint meters.
        add(f"{region} DNS Private Resolver inbound endpoint", "", "Azure DNS", hours/730, "1",
            productName="Azure DNS", skuName="Private Resolver", meterName="Private Resolver Inbound Endpoint")
    if args.app_gateway:
        add("Application Gateway Standard v2 fixed", region, "Application Gateway", hours, "1/Hour",
            productName="Application Gateway Standard v2", skuName="Standard", meterName="Standard Fixed Cost")
        add("Application Gateway ten capacity units assumed", region, "Application Gateway", 10*hours, "1/Hour",
            productName="Application Gateway Standard v2", skuName="Standard", meterName="Standard Capacity Units")
add("Standard Load Balancer x2 (first five rules each)", "Global", "Load Balancer", 2*hours, "1 Hour",
    productName="Load Balancer", skuName="Standard", meterName="Standard Included LB Rules and Outbound Rules")
add("ACR Premium registry", "koreacentral", "Container Registry", hours/24, "1/Day",
    productName="Container Registry", skuName="Premium", meterName="Premium Registry Unit")
if args.acr_geo:
    add("ACR Premium geo replica", "koreasouth", "Container Registry", hours/24, "1/Day",
        productName="Container Registry", skuName="Premium", meterName="Premium Registry Replication Unit")
add("RA-GRS Hot sample storage (10 GB maximum; exact bytes in manifest)", "koreacentral", "Storage",
    args.storage_gb*hours/730, "1 GB/Month", productName="General Block Blob v2", skuName="Hot RA-GRS",
    meterName="Hot RA-GRS Data Stored")
for operation, count in (("Write", args.storage_write_ops), ("Read", args.storage_read_ops)):
    add(f"Blob {operation.lower()} operations (10K units)", "koreacentral", "Storage", count/10000, "10K",
        productName="General Block Blob v2", skuName="Hot RA-GRS",
        meterName=("Hot GRS Write Operations" if operation == "Write" else "Hot Read Operations"))
add("Traffic Manager Azure endpoints x2 probes", "Global", "Traffic Manager", 2*hours/730, "1",
    productName="Traffic Manager", skuName="Azure Endpoint", meterName="Azure Endpoint Health Checks")
add("Traffic Manager DNS queries", "Global", "Traffic Manager", args.dns_queries/1000000, "1M",
    productName="Traffic Manager", skuName="Azure Region", meterName="DNS Queries")
add("Private DNS zones (baseline 7, globally billed)", "", "Azure DNS", 7*hours/730, "1",
    productName="Azure DNS", skuName="Private", meterName="Private Zone")

subtotal = sum(i.get("amount", 0) for i in audit if i["status"] == "MATCHED")
unknown = sum(i["status"] == "UNKNOWN" for i in audit)
report = {
    "generatedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "currency": currency, "hours": hours,
    "aksNodesPerRegion": nodes, "aksVmCount": 2*nodes, "nonBinding": True, "budget": args.budget,
    "enableAcrGeoReplication": args.acr_geo,
    "features": {"deployEventHubs": not args.no_event_hubs,
                 "enableEventHubsGeoRecovery": not args.no_event_hubs and not args.no_event_hubs_georecovery,
                 "deployRedis": not args.no_redis, "deployAiSearch": not args.no_search,
                 "deployDnsResolver": args.dns_resolver, "deployAppGateway": args.app_gateway},
    "eventHubsStandardTuCount": 0 if args.no_event_hubs else 2,
    "eventHubsIngressUnitsPerNamespace": 0 if args.no_event_hubs else args.event_hubs_ingress_events,
    "dnsResolverInboundEndpointCount": 2 if args.dns_resolver else 0,
    "managedOsDiskCount": 0 if args.use_ephemeral_os_disk else 2*nodes,
    "privateEndpointCount": 9 + 4*(not args.no_event_hubs) + 2*((not args.no_redis) + (not args.no_search)),
    "knownSubtotal": round(subtotal, 2), "unknownItems": unknown, "items": audit,
    "excludedVariableCosts": ["Inter-region egress and Redis/ACR/storage geo replication traffic",
        "Private endpoint and load balancer data processing", "Disk operations, PostgreSQL IOPS/backup excess",
        "Search semantic/agentic usage", "Log retention/query extras and diagnostic export storage",
        "Azure Monitor custom metric ingestion/alerts", "DNS queries beyond assumptions, fast probes during drills",
        "ACR images beyond included storage, AKS image storage, data egress, taxes and negotiated discounts"],
    "warnings": ["Subtotal is a lower bound, NOT a total when UNKNOWN/excluded items exist.",
        "Budget alerts are notifications, not a spending cap or automatic shutdown.",
        "730 hours assumed; pause does not stop PaaS or storage charges.",
        "Cross-region availability and subscription quota are not proven by a retail price.",
        "RA-GRS includes secondary data storage; do not double count a second sample-data account.",
        "Standard Event Hubs bills two namespaces (one TU each), even without metadata pairing. Kafka and Capture are disabled.",
        "Geo-DR copies metadata, not events. Ingress assumes billable 64KiB event units in EACH namespace across the drill; standby events are not replicated.",
        "Free AKS control-plane tier has no SLA; 64GiB managed OS disks on premium-capable D4s_v5 are estimated as P6 Premium_LRS, not an AKS osDiskSKU override.",
        "Log Analytics shared free ingestion grants are ignored; paid marginal ingestion is estimated conservatively.",
        "Optional DNS resolvers include inbound endpoints only, priced with the exact blank-region global meter; no outbound endpoints or rulesets.",
        "Retail tiers are integrated once per meter/SKU; isPrimaryMeterRegion=false does not mean a region has no rate."]
}
path = pathlib.Path(args.output or (pathlib.Path(os.environ["ESTIMATE_STATE_DIR"]) / "cost-estimate.json"))
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, indent=2))
for item in audit:
    amount = f"{item['amount']:.2f} {currency}" if item["status"] == "MATCHED" else "UNKNOWN: " + item["reason"]
    print(f"{item['region']:13} {item['item']}: {amount}")
print(f"\nKnown subtotal: {subtotal:.2f} {currency}; UNKNOWN items: {unknown}; JSON audit: {path}")
print(f"Budget reference: {args.budget:.2f} {currency} (nonbinding). Excluded variable charges are listed in JSON.")
if subtotal > args.budget:
    print("WARNING: Known subtotal alone exceeds the configured budget.")
if args.strict and unknown:
    sys.exit(2)
PY
