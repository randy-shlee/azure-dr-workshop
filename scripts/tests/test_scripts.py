import ast
import contextlib
import copy
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
import urllib.request
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app"))
BASH = shutil.which("bash")
if os.name == "nt":
    git_bash = pathlib.Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe"
    if git_bash.is_file():
        BASH = str(git_bash)
WORK = ROOT / "scripts" / "tests" / ".run"


def embedded(name):
    text = (ROOT / "scripts" / name).read_text()
    return text.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]


def functions_only(name):
    tree = ast.parse(embedded(name))
    nodes = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))]
    namespace = {"__name__": "tests"}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), name, "exec"), namespace)
    return namespace


def shell(command, environment=None):
    env = dict(os.environ, PYTHON_BIN=shutil.which("python") or "", STATE_DIR="scripts/tests/.run/state")
    env.pop("MSYS_NO_PATHCONV", None)
    env.update(environment or {})
    if "MOCK_CALLS" in env:
        # Git Bash prepends its own binaries to the inherited Windows PATH.
        command = ('export PATH="$PWD/scripts/tests/.run/bin:$PATH"\n'
                   'curl() { "$PWD/scripts/tests/.run/bin/curl" "$@"; }\n'
                   'export -f curl\n' + command)
    return subprocess.run([BASH, "-c", command], cwd=ROOT, env=env, stdin=subprocess.DEVNULL, text=True, capture_output=True)


class ShellTests(unittest.TestCase):
    def test_storage_sync_metric_does_not_hide_future_timestamp(self):
        program = embedded("publish-storage-sync-metric.sh")
        with mock.patch.object(sys, "argv", ["publisher", "2999-01-01T00:00:00Z"]):
            with self.assertRaisesRegex(ValueError, "future"):
                exec(compile(program, "publisher", "exec"), {})
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["publisher", "2020-01-01T00:00:00Z"]), contextlib.redirect_stdout(output):
            exec(compile(program, "publisher", "exec"), {})
        metric = json.loads(output.getvalue())["data"]["baseData"]
        self.assertEqual(metric["namespace"], "drtest")
        self.assertEqual(metric["metric"], "LastSyncAgeSeconds")
        self.assertGreater(metric["series"][0]["min"], 0)
        self.assertEqual(metric["series"][0]["count"], 1)

    def test_deployment_name_tracks_prefix(self):
        proc = shell('unset DEPLOYMENT_NAME; export PREFIX=another; source scripts/common.sh; echo "$DEPLOYMENT_NAME"')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "another-drtest")

    def test_drill_service_flags_and_health_path_match_infra(self):
        for name in ("00-precheck.sh", "10-failover.sh", "20-failback.sh"):
            text = (ROOT / "scripts" / "drill" / name).read_text()
            self.assertIn("HEALTH_PATH:-/healthz", text)
            self.assertIn("enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoRecovery'", text)
            self.assertNotIn("HEALTH_PATH:-/health}", text)
        deploy = (ROOT / "scripts" / "deploy.sh").read_text()
        self.assertEqual(deploy.count('--template-file "$ROOT_DIR/infra/main.bicep"'), 2)

    def test_tm_rejects_degraded_and_disabled_endpoints(self):
        for status, monitor, success in (("Enabled", "Online", True), ("Enabled", "Degraded", False),
                                         ("Disabled", "Online", False), ("Enabled", "CheckingEndpoint", False)):
            doc = {"endpoints": [{"name": region, "endpointStatus": status,
                                  "endpointMonitorStatus": monitor} for region in ("krc", "krs")]}
            proc = shell('source scripts/common.sh; cfg() { echo /tm/test; }; '
                         'az() { printf "%s\\n" "$TM_DOC"; }; tm_assert_online',
                         {"TM_DOC": json.dumps(doc)})
            self.assertEqual(proc.returncode == 0, success, proc.stderr)

    def test_budget_deletion_has_a_separate_confirmation(self):
        proc = shell('source scripts/common.sh; confirm "DELETE subscription groups"; '
                     'confirm "DELETE BUDGET test-drtest-budget" CONFIRM_BUDGET',
                     {"CONFIRM": "DELETE subscription groups", "CONFIRM_BUDGET": "DELETE BUDGET test-drtest-budget"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        proc = shell('source scripts/common.sh; confirm "DELETE BUDGET test-drtest-budget" CONFIRM_BUDGET',
                     {"CONFIRM": "DELETE BUDGET test-drtest-budget", "CONFIRM_BUDGET": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Set CONFIRM_BUDGET=", proc.stderr)

    def test_destroy_accepts_only_exact_infrastructure_group_names(self):
        config = {
            "prefix": "workshop", "primaryResourceGroup": "rg-workshop-krc",
            "secondaryResourceGroup": "rg-workshop-krs", "globalResourceGroup": "rg-workshop-global",
            "trafficManager": {"id": "/tm/workshop", "fqdn": "workshop.trafficmanager.net"},
            "budgetName": "workshop-drtest-budget",
        }
        source = (ROOT / "scripts" / "destroy.sh").read_text().split('load_config', 1)[1]
        path, calls = WORK / "destroy-config.json", WORK / "destroy-calls.txt"
        prefix = """
source scripts/common.sh
cfg() { jq -er "$1 // empty" "$CONFIG_FILE"; }
az() { printf '%s\\n' "$*" >>"$DESTROY_CALLS"; }
"""
        environment = {
            "CONFIG_FILE": str(path), "DESTROY_CALLS": calls.as_posix(),
            "PREFIX": "workshop", "SUBSCRIPTION_ID": "test-subscription", "REQUIRE_OWNER_TAG": "false",
            "CONFIRM": "DELETE test-subscription rg-workshop-krc rg-workshop-krs rg-workshop-global",
            "CONFIRM_BUDGET": "DELETE BUDGET workshop-drtest-budget",
        }
        path.write_text(json.dumps(config))
        calls.unlink(missing_ok=True)
        proc = shell(prefix + source, environment)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        commands = calls.read_text()
        self.assertEqual(commands.count("group delete"), 3)
        self.assertIn("group wait -n rg-workshop-global", commands)
        self.assertIn("rest --method delete", commands)
        for invalid in ("workshop-krc", "rg-workshop-krc-other", "rg-another-krc"):
            config["primaryResourceGroup"] = invalid
            path.write_text(json.dumps(config))
            calls.unlink(missing_ok=True)
            proc = shell(prefix + source, environment)
            self.assertNotEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Unexpected workshop resource group", proc.stderr)
            self.assertFalse(calls.exists(), "No delete may occur before validating all target names.")

    def test_destroy_skips_budget_for_portal_profile(self):
        config = {
            "prefix": "workshop", "primaryResourceGroup": "rg-workshop-krc",
            "secondaryResourceGroup": "rg-workshop-krs", "globalResourceGroup": "rg-workshop-global",
            "trafficManager": {"id": "/tm/workshop", "fqdn": "workshop.trafficmanager.net"},
            "budget": 0, "budgetName": "",
        }
        source = (ROOT / "scripts" / "destroy.sh").read_text().split("load_config", 1)[1]
        path, calls = WORK / "portal-destroy-config.json", WORK / "portal-destroy-calls.txt"
        path.write_text(json.dumps(config))
        calls.unlink(missing_ok=True)
        prefix = """
source scripts/common.sh
az() { printf '%s\\n' "$*" >>"$DESTROY_CALLS"; }
"""
        proc = shell(prefix + source, {
            "CONFIG_FILE": str(path), "DESTROY_CALLS": calls.as_posix(),
            "PREFIX": "workshop", "SUBSCRIPTION_ID": "test-subscription", "REQUIRE_OWNER_TAG": "false",
            "CONFIRM": "DELETE test-subscription rg-workshop-krc rg-workshop-krs rg-workshop-global",
            "CONFIRM_BUDGET": "",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        commands = calls.read_text()
        self.assertEqual(commands.count("group delete"), 3)
        self.assertNotIn("Microsoft.Consumption/budgets", commands)
        self.assertNotIn("DELETE BUDGET", proc.stderr)

    def test_remote_exit_and_error_validation(self):
        cases = [
            ('{"exitCode":0,"logs":"ok"}', True),
            ('{"exitCode":42,"logs":"failed"}', False),
            ('{"logs":"no exit status"}', False),
            ('{"exitCode":0,"logs":"Error from server (Forbidden): denied"}', False),
            ('{"exitCode":0,"logs":"error: resource missing"}', False),
        ]
        for result, success in cases:
            with self.subTest(result=result):
                proc = shell("source scripts/common.sh; remote_result \"$RESULT\"", {"RESULT": result})
                self.assertEqual(proc.returncode == 0, success, proc.stderr)

    def test_dns_exact_match_and_timeout(self):
        prefix = """
source scripts/common.sh
cfg() { case "$1" in .trafficManager.fqdn) echo test.trafficmanager.net;; *) echo 10.0.0.1;; esac; }
enabled() { return 1; }
sleep() { :; }
"""
        proc = shell(prefix + '\nnslookup() { printf "Address: 10.0.0.1\\n"; }; tm_dns_wait secondary',
                     {"DNS_TIMEOUT_SECONDS": "1"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        proc = shell(prefix + '\nnslookup() { printf "Address: 10.0.0.10\\n"; }; tm_dns_wait secondary',
                     {"DNS_TIMEOUT_SECONDS": "1"})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("within timeout", proc.stderr)

    def test_drill_trap_records_failure(self):
        proc = shell('source scripts/common.sh; drill_init; step mock-failure bash -c "exit 7"')
        self.assertEqual(proc.returncode, 7, proc.stderr)
        logs = list((WORK / "state").glob("drill-log-*.csv"))
        self.assertTrue(logs)
        data = logs[0].read_text()
        self.assertIn('"START","mock-failure"', data)
        self.assertIn('"ERROR","mock-failure"', data)
        self.assertNotIn('"END","mock-failure"', data)

    def test_pg_never_detaches_replica(self):
        proc = shell("""
source scripts/common.sh
region_rg() { echo rg; }; cfg() { echo "$1"; }
az() {
  if [[ "$*" == *"replica promote"* ]]; then echo "$*" >&2
  elif [[ "$*" == *"--query replicationRole"* ]]; then echo Replica
  elif [[ "$*" == *".primary.pg.name"* ]]; then
    echo '{"state":"Ready","replicationRole":"Primary"}'
  else
    echo '{"state":"Ready","replicationRole":"Replica","sourceServerResourceId":".primary.pg.id"}'
  fi
}
pg_switchover secondary
""")
        self.assertIn("--promote-mode switchover --promote-option planned", proc.stderr)
        self.assertNotIn("--promote-mode standalone", proc.stderr)
        self.assertNotEqual(proc.returncode, 0, "Mock remains Replica, so postcondition must fail")

    def test_storage_planned_failover_is_reversible_and_never_uses_unplanned(self):
        primary = {
            "sku": {"name": "Standard_RAGRS"}, "provisioningState": "Succeeded",
            "primaryLocation": "koreacentral", "secondaryLocation": "koreasouth",
            "geoReplicationStats": {"status": "Live", "canPlannedFailover": True},
        }
        secondary = primary | {"primaryLocation": "koreasouth", "secondaryLocation": "koreacentral"}
        command = """
source scripts/common.sh
cfg() {
  case "$1" in
    .primary.location) echo koreacentral;;
    .secondary.location) echo koreasouth;;
    .primary.storage.id) echo /storage/test;;
  esac
}
active=primary
az() {
  if [[ "$*" == "storage account show"* ]]; then
    if [[ "$active" == primary ]]; then echo "$PRIMARY_DOC"; else echo "$SECONDARY_DOC"; fi
  else
    echo "$*" >&2
    if [[ "$active" == primary ]]; then active=secondary; else active=primary; fi
  fi
}
storage_planned_failover secondary
storage_planned_failover secondary
storage_planned_failover primary
"""
        proc = shell(command, {"PRIMARY_DOC": json.dumps(primary), "SECONDARY_DOC": json.dumps(secondary)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr.count("--failover-type Planned --yes"), 2)
        self.assertNotIn("--failover-type Unplanned", proc.stderr)
        self.assertIn("already active", proc.stderr)

    def test_storage_failover_rejects_lrs_unhealthy_pair_and_incomplete_result(self):
        valid = {
            "sku": {"name": "Standard_RAGRS"}, "provisioningState": "Succeeded",
            "primaryLocation": "koreacentral", "secondaryLocation": "koreasouth",
            "geoReplicationStats": {"status": "Live", "canPlannedFailover": True},
        }
        command = """
source scripts/common.sh
cfg() { case "$1" in .primary.location) echo koreacentral;; .secondary.location) echo koreasouth;; *) echo /storage/test;; esac; }
az() { if [[ "$*" == "storage account show"* ]]; then echo "$STORAGE_DOC"; else echo "FAILOVER_REQUEST $*" >&2; fi; }
storage_planned_failover secondary
"""
        cases = [
            (valid | {"sku": {"name": "Standard_LRS"}}, False),
            (valid | {"secondaryLocation": "japaneast"}, False),
            (valid | {"failoverInProgress": True}, False),
            (valid | {"geoReplicationStats": {"status": "Bootstrap", "canPlannedFailover": False}}, False),
            (valid, True),
        ]
        for doc, requested in cases:
            with self.subTest(doc=doc):
                proc = shell(command, {"STORAGE_DOC": json.dumps(doc)})
                self.assertNotEqual(proc.returncode, 0, "Unchanged post-operation state must not pass")
                self.assertEqual("FAILOVER_REQUEST" in proc.stderr, requested)

    def test_pg_pair_rejects_standalone_wrong_source_and_unready_replica(self):
        command = """
source scripts/common.sh
region_rg() { echo rg; }; cfg() { echo "$1"; }
az() {
  if [[ "$*" == *".primary.pg.name"* ]]; then echo '{"state":"Ready","replicationRole":"Primary"}'
  else echo "$REPLICA_DOC"; fi
}
pg_assert_pair primary
"""
        for doc in (
            {"state": "Ready", "replicationRole": "None"},
            {"state": "Ready", "replicationRole": "Replica", "sourceServerResourceId": "/another/server"},
            {"state": "Updating", "replicationRole": "Replica", "sourceServerResourceId": ".primary.pg.id"},
        ):
            proc = shell(command, {"REPLICA_DOC": json.dumps(doc)})
            self.assertNotEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("not a Ready replica", proc.stderr)

    def test_pg_pair_preserves_arm_ids_when_passing_them_to_native_jq(self):
        proc = shell("""
source scripts/common.sh
region_rg() { echo "$1"; }
cfg() {
  if [[ "$1" == ".primary.pg.id" ]]; then echo /subscriptions/test/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg
  else echo "$1"; fi
}
az() {
  if [[ "$*" == *".primary.pg.name"* ]]; then echo '{"state":"Ready","replicationRole":"Primary"}'
  else echo '{"state":"Ready","replicationRole":"GeoAsyncReplica","sourceServerResourceId":"/subscriptions/test/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg"}'; fi
}
pg_assert_pair primary
""")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_drill_moves_storage_before_traffic_and_verifies_data_afterwards(self):
        for script, key, endpoint in (("10-failover.sh", "secondary", "enable-krs"),
                                      ("20-failback.sh", "primary", "enable-krc")):
            text = (ROOT / "scripts" / "drill" / script).read_text()
            self.assertLess(text.index("storage_planned_failover " + key), text.index(endpoint))
            self.assertLess(text.index("pg_switchover " + key), text.index(endpoint))
            self.assertGreater(text.index("dr_verify_data " + key), text.index(endpoint))

    def test_pg_switchover_reverses_the_replication_pair_and_is_idempotent(self):
        proc = shell("""
source scripts/common.sh
region_rg() { echo "$1"; }; cfg() { echo "$1"; }
active=primary
az() {
  local key=primary other=secondary
  if [[ "$*" == *".secondary.pg.name"* ]]; then key=secondary; other=primary; fi
  if [[ "$*" == *"replica promote"* ]]; then active="$key"; echo "$*" >&2
  elif [[ "$*" == *"--query replicationRole"* ]]; then
    if [[ "$key" == "$active" ]]; then echo Primary; else echo GeoAsyncReplica; fi
  elif [[ "$key" == "$active" ]]; then echo '{"state":"Ready","replicationRole":"Primary"}'
  else printf '{"state":"Ready","replicationRole":"GeoAsyncReplica","sourceServerResourceId":".%s.pg.id"}\\n' "$other"; fi
}
pg_switchover secondary
pg_switchover secondary
pg_switchover primary
""")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr.count("--promote-mode switchover --promote-option planned"), 2)
        self.assertIn("already primary", proc.stderr)
        self.assertNotIn("standalone", proc.stderr)

    def test_dr_data_check_requires_write_and_matching_primary_readback(self):
        command = """
source scripts/common.sh
cfg() { if [[ "$1" == ".secondary.region" ]]; then echo krs; else echo example.test; fi; }
enabled() { return 1; }
curl() {
  case "$*" in
    *"/api/info") echo '{"region":"krs","storage_read_mode":"primary"}';;
    *"/api/write") echo "$WRITE_DOC";;
    *"/api/read") echo "$READ_DOC";;
  esac
}
dr_verify_data secondary
"""
        write = {"record": {"id": "test-id"}, "services": {"postgres": {"ok": True}, "storage_primary": {"ok": True}}}
        read = {"services": {
            "postgres": {"ok": True, "data": {"id": "test-id"}},
            "storage": {"ok": True, "data": {"record": {"id": "test-id"}, "endpoint_read": "primary"}},
        }}
        bad_read = copy.deepcopy(read)
        bad_read["services"]["storage"]["data"]["endpoint_read"] = "secondary"
        mismatch = copy.deepcopy(read)
        mismatch["services"]["postgres"]["data"]["id"] = "old-id"
        bad_write = copy.deepcopy(write)
        bad_write["services"]["storage_primary"]["ok"] = False
        for written, readback, success in ((write, read, True), (write, bad_read, False),
                                            (write, mismatch, False), (bad_write, read, False)):
            proc = shell(command, {"WRITE_DOC": json.dumps(written), "READ_DOC": json.dumps(readback)})
            self.assertEqual(proc.returncode == 0, success, proc.stderr)

    def test_job_failure_is_not_treated_as_success(self):
        proc = shell("""
source scripts/common.sh
aks_run() {
  if [[ "$*" == *"get job"* ]]; then
    echo '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}'
  else echo remote-pod-logs; fi
}
wait_job primary failed-job 5
""")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Job failed-job failed", proc.stderr)

    def test_pg_pause_resume_order_tracks_current_roles(self):
        prefix = """
source scripts/common.sh
region_rg() { echo rg; }; cfg() { echo "$1"; }
az() { if [[ "$*" == *"primary.pg.name"* ]]; then echo GeoAsyncReplica; else echo Primary; fi; }
"""
        proc = shell(prefix + "\npg_order stop; echo '--'; pg_order start")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [line for line in proc.stdout.splitlines() if line]
        self.assertEqual(lines, ["secondary", "primary", "--", "primary", "secondary"])


class GeneratedManifestTests(unittest.TestCase):
    def setUp(self):
        binary = WORK / "bin"
        binary.mkdir(parents=True, exist_ok=True)
        az = binary / "az"
        az.write_text("""#!/usr/bin/env bash
set -eu
case "$*" in
  *"account show"*) echo test-subscription;;
  *"account set"*) :;;
  *"acr agentpool show"*)
    echo '{"provisioningState":"Succeeded","count":1,"virtualNetworkSubnetResourceId":"/subscriptions/test/subnets/build"}';;
  *"acr build"*) printf '%s\\n' "$*" >>"$MOCK_CALLS";;
  *"network traffic-manager profile show"*)
    echo '{"endpoints":[{"endpointStatus":"Enabled","endpointMonitorStatus":"Online"},{"endpointStatus":"Enabled","endpointMonitorStatus":"Online"}]}';;
  *"aks command invoke"*)
    arguments=("$@")
    for ((i=0; i<${#arguments[@]}; i++)); do
      if [[ "${arguments[i]}" == --file && -n "${arguments[i+2]:-}" && "${arguments[i+2]}" != -* ]]; then
        echo 'Use a separate --file option for each attachment.' >&2
        exit 2
      fi
    done
    if [[ "$*" == *"get deployment drtest-app"* ]]; then
      jq -nc '{exitCode:0,logs:({metadata:{generation:1},status:{observedGeneration:1,updatedReplicas:1,availableReplicas:1,replicas:1}}|tojson)}'
    elif [[ "$*" == *"get service drtest-app"* ]]; then
      ip=203.0.113.10; [[ "$*" != *"krs-aks"* ]] || ip=203.0.113.20
      jq -nc --arg ip "$ip" '{exitCode:0,logs:({status:{loadBalancer:{ingress:[{ip:$ip}]}}}|tojson)}'
    elif [[ "$*" == *"kubectl apply -f app-secrets.json"* ]]; then
            if [[ "${MOCK_VALIDATE_SECRETS:-false}" == true ]]; then
                secret=''
                for ((argument_index=0; argument_index<${#arguments[@]}; argument_index++)); do
                    if [[ "${arguments[argument_index]}" == --file && "${arguments[argument_index+1]}" == *app-secrets.json ]]; then
                        secret="${arguments[argument_index+1]}"
                    fi
                done
                expected_redis=workshop-krc; [[ "$*" != *krs-aks* ]] || expected_redis=workshop-krs
                jq -e --arg redis "$expected_redis" '.kind=="Secret" and .metadata.namespace=="drtest" and
                    .stringData.PG_PASSWORD=="workshop-pg" and .stringData.REDIS_KEY==$redis' "$secret" >/dev/null
            fi
      printf '%s\\n' "$*" >>"$MOCK_CALLS"
      echo '{"exitCode":0,"logs":"applied"}'
    elif [[ "$*" == *"exec deployment/drtest-app"* ]]; then
      jq -nc '{exitCode:0,logs:({services:{postgres:{status:"ok",pe_region:"KRC",ips:["10.10.16.4"],latency_ms:2}}}|tojson)}'
    elif [[ "$*" == *"get job"* ]]; then
      printf '%s\\n' '{"exitCode":0,"logs":"{\\"status\\":{\\"conditions\\":[{\\"type\\":\\"Complete\\",\\"status\\":\\"True\\"}]}}"}'
    elif [[ "$*" == *"logs job/"* ]]; then
      printf '%s\\n' '{"exitCode":0,"logs":"SEARCH_INDEX_VERIFIED"}'
    else printf '%s\\n' '{"exitCode":0,"logs":"applied"}'; fi;;
  *) echo "Unexpected mock az call: $*" >&2; exit 99;;
esac
""")
        az.chmod(0o755)
        curl = binary / "curl"
        curl.write_text("""#!/usr/bin/env bash
set -eu
if [[ -n "${MOCK_HTTP_CALLS:-}" ]]; then printf '%s\\n' "$*" >>"$MOCK_HTTP_CALLS"; fi
case "$*" in
  *"/api/info"*) echo '{"region":"krc"}';;
  *"/api/tm"*) echo '{"region":"KRC","status":"ok"}';;
  *"/api/sampledata"*) echo '{"primary":{"status":"ok"},"secondary":{"status":"ok"},"replication_complete":true}';;
  *)
    if [[ "${MOCK_API_ERROR:-}" == true ]]; then echo '{"status":"partial","services":{"postgres":{"status":"error","error":"fixture failure"}}}'
    else echo '{"status":"ok","services":{"postgres":{"status":"ok"}}}'; fi;;
esac
""")
        curl.chmod(0o755)
        nslookup = binary / "nslookup"
        nslookup.write_text("""#!/usr/bin/env bash
printf '%s\\n' 'Name: test.trafficmanager.net' 'Address: 203.0.113.10'
""")
        nslookup.chmod(0o755)
        shutil.copytree(ROOT / "k8s" / "base", WORK / "base", dirs_exist_ok=True)
        self.config = {
            "prefix": "test", "primaryResourceGroup": "test-krc", "secondaryResourceGroup": "test-krs",
            "globalResourceGroup": "test-global", "allowedClientCidrs": ["203.0.113.10/32"],
            "features": {"deployAppGateway": False, "deployAiSearch": True, "deployEventHubs": True, "deployRedis": True,
                         "enableEventHubsGeoRecovery": True},
            "eventHubs": {"aliasName": "eh-test-dr", "host": "eh-test-dr.servicebus.windows.net"},
            "postgres": {"writerEndpoint": "writer.example", "readerEndpoint": "reader.example"},
            "trafficManager": {"id": "/tm/test", "fqdn": "test.trafficmanager.net"},
        }
        for key, region in (("primary", "krc"), ("secondary", "krs")):
            self.config[key] = {
                "region": region, "location": "koreacentral" if key == "primary" else "koreasouth",
                "aks": {"name": region + "-aks"}, "identity": {"clientId": "client-" + region},
                "publicIp": {"name": "pip-" + region, "address": "203.0.113.10" if key == "primary" else "203.0.113.20"},
                "eventHubs": {"host": "eh-test-dr.servicebus.windows.net", "id": "/eh/" + region},
                "redis": {"host": "redis.example"}, "search": {"endpoint": "https://search.example"},
                "acr": {"name": "testacr", "loginServer": "acr.example"},
                "storage": {"id": "/storage/test", "name": "teststorage", "primaryEndpoint": "https://blob.example", "secondaryEndpoint": "https://secondary.example"},
                "appGateway": {"backendAddress": "10.10.0.100", "backendSourceCidr": "10.10.17.0/24"},
            }
        self.environment = {
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "CONFIG_FILE": "scripts/tests/.run/config.json",
            "APP_CONFIG_OUTPUT_DIR": "scripts/tests/.run/overlays",
            "STATE_DIR": "scripts/tests/.run/state",
            "MOCK_CALLS": (WORK / "app-calls.txt").as_posix(),
        }

    def run_script(self, name, extra_env=None):
        (WORK / "config.json").write_text(json.dumps(self.config))
        return shell("bash scripts/" + name, self.environment | (extra_env or {}))

    def test_public_service_limits_clients_and_allows_tm_probes(self):
        self.config["allowedClientCidrs"] = ["203.0.113.10/32", "203.0.113.0/28"]
        proc = self.run_script("gen-app-config.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for region in ("krc", "krs"):
            with self.subTest(region=region):
                service = json.loads((WORK / f"overlays/{region}/service.yaml").read_text())
                annotations = service["metadata"]["annotations"]
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-allowed-service-tags"], "AzureTrafficManager")
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"],
                                 "203.0.113.10/32,203.0.113.0/28")
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-pip-name"], "pip-" + region)
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-load-balancer-resource-group"], "test-" + region)
                self.assertNotIn("loadBalancerSourceRanges", service["spec"], "Source ranges and service-tag annotations are incompatible")
                self.assertNotIn("service.beta.kubernetes.io/azure-load-balancer-internal", annotations)
                self.assertEqual(service["metadata"]["namespace"], "drtest")
                self.assertEqual(service["spec"]["ports"][0]["targetPort"], 8000)

    def test_dashboard_config_and_shared_base_are_renderable(self):
        proc = self.run_script("gen-app-config.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        kubectl = shutil.which("kubectl")
        self.assertIsNotNone(kubectl, "kubectl is required to validate Kustomize output.")
        for region in ("krc", "krs"):
            directory = WORK / "overlays" / region
            config = json.loads((directory / "configmap.yaml").read_text())["data"]
            self.assertEqual(config["STORAGE_ACCOUNT"], "teststorage")
            self.assertEqual(config["STORAGE_READ_MODE"], "primary")
            self.assertEqual(config["STORAGE_READ_ENDPOINT"], "https://blob.example")
            self.assertEqual(config["STORAGE_READ_ONLY"], "false")
            self.assertEqual(config["PG_HOST"], "writer.example")
            self.assertEqual(config["PG_DB"], "postgres")
            self.assertEqual(config["EH_NAMESPACE"], "eh-test-dr.servicebus.windows.net")
            self.assertEqual(config["EH_NAME"], "drtest-events")
            self.assertEqual(config["TM_FQDN"], "test.trafficmanager.net")
            self.assertEqual(config["KRS_PUBLIC_IP"], "203.0.113.20")
            self.assertNotIn("PG_PASSWORD", config)
            self.assertNotIn("REDIS_KEY", config)
            rendered = subprocess.run([kubectl, "kustomize", str(directory)], text=True, capture_output=True)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertIn("containerPort: 8000", rendered.stdout)
            self.assertIn("cpu: 100m", rendered.stdout)
            self.assertIn("memory: 256Mi", rendered.stdout)
            self.assertIn("kind: Deployment", rendered.stdout)

    def test_disabled_services_generate_empty_backend_variables(self):
        self.config["features"].update(deployEventHubs=False, deployRedis=False, deployAiSearch=False)
        proc = self.run_script("gen-app-config.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        config = json.loads((WORK / "overlays/krs/configmap.yaml").read_text())["data"]
        for name in ("EH_NAMESPACE", "EH_NAME", "REDIS_HOST", "SEARCH_ENDPOINT", "SEARCH_INDEX"):
            self.assertEqual(config[name], "")

    def test_sample_upload_configuration_preserves_disabled_flag_and_container(self):
        self.config["sampleData"] = {
            "uploadEnabled": False, "containerName": "sampledata-10gb",
            "sizeGB": 10, "largeFileSizeGB": 1, "smallFileCount": 2000, "smallFileSizeMB": 1,
        }
        proc = self.run_script("gen-app-config.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for region in ("krc", "krs"):
            config = json.loads((WORK / f"overlays/{region}/configmap.yaml").read_text())["data"]
            self.assertEqual(config["SAMPLE_UPLOAD_ENABLED"], "false")
            self.assertEqual(config["SAMPLE_DATA_CONTAINER"], "sampledata-10gb")
            self.assertEqual(config["SAMPLE_DATA_SIZE_GB"], "10")

    def test_application_deploy_requires_private_build_pool(self):
        proc = self.run_script("app-deploy.sh", {"ACR_AGENT_POOL": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("VNet-connected ACR Tasks pool", proc.stderr)

    def test_packaged_app_apply_transfers_and_removes_secrets(self):
        image = "acr.example/drtest-app:workshop-test"
        calls = WORK / "app-calls.txt"
        calls.unlink(missing_ok=True)
        proc = self.run_script("app-apply.sh", {
            "APP_IMAGE": image, "PG_USER": "testadmin", "PG_PASSWORD": "workshop-pg",
            "REDIS_KEY_KRC": "workshop-krc", "REDIS_KEY_KRS": "workshop-krs",
            "MOCK_VALIDATE_SECRETS": "true", "CONFIRM": "DEPLOY APP test-subscription test",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        history = calls.read_text()
        self.assertEqual(history.count("kubectl apply -f app-secrets.json"), 2)
        self.assertIn("krc-aks", history)
        self.assertIn("krs-aks", history)
        for secret in ("workshop-pg", "workshop-krc", "workshop-krs"):
            self.assertNotIn(secret, history + proc.stdout + proc.stderr)
        self.assertFalse(list((WORK / "state").glob("app-deploy.*")), "Temporary Secrets must be removed.")

    def test_aks_attachments_require_repeated_file_options(self):
        (WORK / "config.json").write_text(json.dumps(self.config))
        prefix = 'source scripts/common.sh; load_config; aks_run primary "kubectl apply -f app-secrets.json" '
        for attachments, success in (
            ('--file "$CONFIG_FILE" "$CONFIG_FILE"', False),
            ('--file "$CONFIG_FILE" --file "$CONFIG_FILE"', True),
        ):
            proc = shell(prefix + attachments, self.environment)
            self.assertEqual(proc.returncode == 0, success, proc.stderr)
            if not success:
                self.assertIn("separate --file", proc.stderr)

    def test_application_deploy_builds_only_app_and_waits_for_both_regions(self):
        calls = WORK / "app-calls.txt"
        calls.unlink(missing_ok=True)
        proc = self.run_script("app-deploy.sh", {
            "ACR_AGENT_POOL": "privatepool", "PG_USER": "testadmin", "PG_PASSWORD": "fake-unit-password",
            "REDIS_KEY_KRC": "fake-krc", "REDIS_KEY_KRS": "fake-krs",
            "APP_TAG": "unit-test", "CONFIRM": "DEPLOY APP test-subscription test"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        history = calls.read_text()
        self.assertIn("acr build", history)
        self.assertIn("--agent-pool privatepool", history)
        self.assertIn("--platform linux/amd64 .", history)
        self.assertIn("krc-aks", history)
        self.assertIn("krs-aks", history)
        self.assertNotIn("fake-unit-password", proc.stdout + proc.stderr + history)
        self.assertNotIn("fake-krc", proc.stdout + proc.stderr + history)
        self.assertFalse(list((WORK / "state").glob("app-deploy.*")), "Temporary secret stage must be removed.")
        rendered = subprocess.run([shutil.which("kubectl"), "kustomize", str(WORK / "overlays/krc")],
                                  text=True, capture_output=True)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("image: acr.example/drtest-app:unit-test", rendered.stdout)

    def test_application_smoke_prints_pod_pe_table(self):
        proc = self.run_script("test-app.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("SERVICE\tSTATUS\tPE_REGION\tIPS\tMS", proc.stdout)
        self.assertIn("postgres\tok\tKRC\t10.10.16.4", proc.stdout)
        self.assertIn("DNS advisory", proc.stderr)

    def test_application_smoke_rejects_partial_dependency_failure(self):
        proc = self.run_script("test-app.sh", {"MOCK_API_ERROR": "true"})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("dependency failures", proc.stderr)

    def test_application_smoke_skips_only_explicitly_excluded_samples(self):
        calls = WORK / "smoke-http-calls.txt"
        for skip in ("false", "true"):
            calls.unlink(missing_ok=True)
            proc = self.run_script("test-app.sh", {
                "SKIP_SAMPLE_CHECK": skip, "MOCK_HTTP_CALLS": calls.as_posix()})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            requests = calls.read_text()
            self.assertIn("/api/write", requests)
            self.assertIn("/api/read", requests)
            self.assertEqual("/api/sampledata" in requests, skip == "false")
            self.assertEqual("sample API verification was explicitly skipped" in proc.stderr, skip == "true")

    def test_appgw_internal_service_uses_gateway_source_not_operator(self):
        self.config["features"]["deployAppGateway"] = True
        self.config["secondary"]["appGateway"] = {"backendAddress": "10.20.0.100", "backendSourceCidr": "10.20.17.0/24"}
        proc = self.run_script("gen-app-config.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for region, octet in (("krc", 10), ("krs", 20)):
            with self.subTest(region=region):
                service = json.loads((WORK / f"overlays/{region}/service.yaml").read_text())
                annotations = service["metadata"]["annotations"]
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-load-balancer-internal"], "true")
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"], "snet-aks")
                self.assertEqual(annotations["service.beta.kubernetes.io/azure-load-balancer-ipv4"], f"10.{octet}.0.100")
                self.assertEqual(service["spec"]["loadBalancerSourceRanges"], [f"10.{octet}.17.0/24"])
                self.assertNotIn("service.beta.kubernetes.io/azure-allowed-ip-ranges", annotations)
                self.assertNotIn("service.beta.kubernetes.io/azure-allowed-service-tags", annotations)
                rendered = subprocess.run([shutil.which("kubectl"), "kustomize", str(WORK / "overlays" / region)],
                                          text=True, capture_output=True)
                self.assertEqual(rendered.returncode, 0, rendered.stderr)
                self.assertNotIn("azure-allowed-service-tags", rendered.stdout)
                self.assertNotIn("REPLACED_BY_REGIONAL_OVERLAY", rendered.stdout)

    def test_search_job_is_wi_enabled_and_command_is_valid_bash(self):
        proc = self.run_script("search-index.sh")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        job = json.loads((WORK / "state/search-index-job.json").read_text())
        template = job["spec"]["template"]
        self.assertEqual(template["metadata"]["labels"]["azure.workload.identity/use"], "true")
        self.assertEqual(template["spec"]["serviceAccountName"], "drtest-app")
        command = template["spec"]["containers"][0]["command"][-1]
        result = subprocess.run([BASH, "-n", "-c", command], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("api-version=2025-09-01", command)
        self.assertIn('all(i.get("status") is True', command.replace('\\"', '"'))

    def test_georecovery_rejects_direct_regional_namespace_app_config(self):
        self.config["secondary"]["eventHubs"]["host"] = "eh-test-krs.servicebus.windows.net"
        proc = self.run_script("gen-app-config.sh")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("must use the Standard Geo-DR alias", proc.stderr)


class GeoRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.ids = {
            key: f"/subscriptions/test/resourceGroups/rg-test-{region}/providers/Microsoft.EventHub/namespaces/eh-test-{region}"
            for key, region in (("primary", "krc"), ("secondary", "krs"))
        }
        config = {
            "features": {"deployEventHubs": True, "enableEventHubsGeoRecovery": True},
            "eventHubs": {"aliasName": "eh-test-dr"},
            **{key: {"eventHubs": {"id": value}} for key, value in self.ids.items()},
        }
        path = WORK / "eh-config.json"
        path.write_text(json.dumps(config))
        self.primary = {"value": [{"name": "eh-test-dr", "properties": {
            "role": "Primary", "provisioningState": "Succeeded",
            "partnerNamespace": self.ids["secondary"], "pendingReplicationOperationsCount": 0,
        }}]}
        self.secondary = {"value": [{"name": "eh-test-dr", "properties": {
            "role": "Secondary", "provisioningState": "Succeeded",
            "partnerNamespace": self.ids["primary"], "pendingReplicationOperationsCount": 0,
        }}]}
        self.environment = {"CONFIG_FILE": str(path), "PREFIX": "test", "EH_TIMEOUT_SECONDS": "1",
                            "EH_POLL_SECONDS": "0", "CONFIRM_EH": "FAILOVER EH GEO test"}

    def run_recovery(self, args, extra=None):
        source = (ROOT / "scripts" / "eh-georecovery.sh").read_text().split("load_config\n", 1)[1]
        prefix = """
source scripts/common.sh
active="${ALREADY_ACTIVE:-false}"
az() {
  case "$*" in
    *"--method post"*) echo "MUTATION $*" >&2; active=true;;
    *"--method get"*)
      local doc
      if [[ "${BLOCK_PRIMARY:-false}" == true && "$*" != *"namespaces/eh-test-krs/"* ]]; then
        echo 'Original region unavailable' >&2
        return 23
      fi
      if [[ "$*" == *"namespaces/eh-test-krs/"* ]]; then
        if [[ "$active" == true ]]; then
          doc='{"value":[{"name":"eh-test-dr","properties":{"role":"PrimaryNotReplicating","provisioningState":"Succeeded"}}]}'
        else doc="$SECONDARY_DOC"; fi
      elif [[ "$active" == true ]]; then doc='{"value":[]}'
      else doc="$PRIMARY_DOC"; fi
      if [[ "$*" == *"/disasterRecoveryConfigs/eh-test-dr?"* ]]; then jq '.value[0]' <<<"$doc"
      else jq 'del(.value[]?.properties.pendingReplicationOperationsCount)' <<<"$doc"; fi;;
    *) echo "Unexpected API call: $*" >&2; return 99;;
  esac
}
"""
        environment = self.environment | {"PRIMARY_DOC": json.dumps(self.primary),
                                          "SECONDARY_DOC": json.dumps(self.secondary)} | (extra or {})
        return shell(prefix + "\nset -- " + args + "\n" + source, environment)

    def test_wait_requires_synchronized_metadata_pair(self):
        proc = self.run_recovery("wait krc")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("event data is NOT replicated", proc.stderr)
        self.assertNotIn("MUTATION", proc.stderr)

    def test_failover_targets_secondary_alias_and_is_idempotent(self):
        proc = self.run_recovery("failover krs")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(self.ids["secondary"] + "/disasterRecoveryConfigs/eh-test-dr/failover", proc.stderr)
        self.assertEqual(proc.stderr.count("MUTATION"), 1)
        self.assertIn("NEW empty namespace", proc.stderr)
        for forbidden in ("--method delete", "--method patch", "geoDataReplication", "force"):
            self.assertNotIn(forbidden, proc.stderr)
        proc = self.run_recovery("failover krs", {"ALREADY_ACTIVE": "true"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("already active in KRS", proc.stderr)
        self.assertNotIn("MUTATION", proc.stderr)

    def test_reverse_failover_is_rejected_without_mutating_namespaces(self):
        proc = self.run_recovery("failover krc")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("old KRC namespace is unsupported", proc.stderr)
        self.assertNotIn("MUTATION", proc.stderr)
        failback = (ROOT / "scripts" / "drill" / "20-failback.sh").read_text()
        self.assertIn("wait active", failback)
        self.assertNotIn("eh-georecovery.sh\" failover", failback)

    def test_pending_entities_wrong_partner_and_failed_config_block_failover(self):
        for change in ({"pendingReplicationOperationsCount": 1},
                       {"partnerNamespace": "/another/namespace"},
                       {"provisioningState": "Failed"}):
            with self.subTest(change=change):
                primary = copy.deepcopy(self.primary)
                primary["value"][0]["properties"].update(change)
                proc = self.run_recovery("failover krs", {"PRIMARY_DOC": json.dumps(primary)})
                self.assertNotEqual(proc.returncode, 0)
                self.assertNotIn("MUTATION", proc.stderr)

    def test_confirmation_is_required_for_one_way_failover(self):
        proc = self.run_recovery("failover krs", {"CONFIRM_EH": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Set CONFIRM_EH=", proc.stderr)
        self.assertNotIn("MUTATION", proc.stderr)

    def test_application_failback_accepts_either_valid_active_alias(self):
        for active in ("false", "true"):
            proc = self.run_recovery("wait active", {"ALREADY_ACTIVE": active})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("MUTATION", proc.stderr)
        proc = self.run_recovery("wait krc", {"ALREADY_ACTIVE": "true"})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("already failed forward", proc.stderr)

    def test_active_recovery_does_not_depend_on_the_former_primary_region(self):
        proc = self.run_recovery("wait active", {"ALREADY_ACTIVE": "true", "BLOCK_PRIMARY": "true"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("Original region unavailable", proc.stderr)

    def test_status_explicitly_reports_metadata_only_and_missing_old_alias(self):
        proc = self.run_recovery("status", {"ALREADY_ACTIVE": "true"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertFalse(result["dataReplicated"])
        self.assertEqual(result["primary"], {})
        self.assertEqual(result["secondary"]["properties"]["role"], "PrimaryNotReplicating")
        self.assertIn("new empty namespace", result["failback"])

    def test_malformed_alias_response_fails_explicitly(self):
        proc = self.run_recovery("wait krc", {"PRIMARY_DOC": '{"unexpected":[]}'})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Invalid Geo-DR alias list", proc.stderr)
        self.assertNotIn("MUTATION", proc.stderr)

    def test_missing_detail_pending_count_is_not_treated_as_synchronized(self):
        primary = copy.deepcopy(self.primary)
        del primary["value"][0]["properties"]["pendingReplicationOperationsCount"]
        proc = self.run_recovery("failover krs", {"PRIMARY_DOC": json.dumps(primary)})
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("MUTATION", proc.stderr)


class UploadTests(unittest.TestCase):
    def test_cli_shares_the_application_control_lease(self):
        code = functions_only("sampledata-program.sh")
        requests = []
        store = type("SimpleStorage", (), {"endpoint": "https://storage.invalid"})()
        def request(path, **kwargs):
            requests.append((path, kwargs))
            return b"{}", {}
        store.request = request
        with code["UploadLease"](store) as lease:
            lease.check()
        actions = [kwargs["headers"]["x-ms-lease-action"] for _, kwargs in requests if "headers" in kwargs]
        self.assertEqual(actions, ["acquire", "release"])
        self.assertTrue(all(path.startswith("drtest/_sample_upload.json") for path, _ in requests))
        acquire = requests[1][1]["headers"]
        self.assertEqual(acquire["x-ms-lease-duration"], "60")
        self.assertEqual(acquire["x-ms-proposed-lease-id"], lease.id)

    def test_cli_rejects_an_existing_application_lease(self):
        code = functions_only("sampledata-program.sh")
        store = type("SimpleStorage", (), {"endpoint": "https://storage.invalid"})()
        def request(path, **kwargs):
            if "?comp=lease" in path:
                raise urllib.error.HTTPError(path, 409, "LeaseAlreadyPresent", {}, None)
            return b"{}", {}
        store.request = request
        with self.assertRaisesRegex(RuntimeError, "Another sample upload"):
            with code["UploadLease"](store):
                self.fail("An existing lease must prevent CLI upload")

    def test_cli_lease_loss_is_explicit(self):
        code = functions_only("sampledata-program.sh")
        store = type("SimpleStorage", (), {"endpoint": "https://storage.invalid"})()
        lease = code["UploadLease"](store)
        lease.failed = True
        with self.assertRaisesRegex(RuntimeError, "lease lost"):
            lease.check()

    @classmethod
    def setUpClass(cls):
        cls.code = functions_only("sampledata-program.sh")

    def test_default_layout_is_limited_to_decimal_ten_gb(self):
        expected = self.code["layout"](10, 1, 2000, 1)
        self.assertEqual(sum(name.startswith("large/") for name in expected), 8)
        self.assertEqual(len(expected), 2008)
        self.assertEqual(sum(expected.values()), 10000000000)

    def test_larger_requested_budget_cannot_raise_the_absolute_cap(self):
        expected = self.code["layout"](100, 1, 2000, 1)
        self.assertLessEqual(sum(expected.values()), 10000000000)

    def test_uploader_extracts_pinned_azcopy_without_system_tar(self):
        job = (ROOT / "k8s" / "jobs" / "sampledata-upload.yaml").read_text()
        program = textwrap.dedent(job.split("<<'PY'\n", 1)[1].split("\n              PY", 1)[0])
        payload = b"verified-azcopy"
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            with tarfile.open(path / "azcopy.tar.gz", "w:gz") as archive:
                member = tarfile.TarInfo("azcopy_linux_amd64_10.34.1/azcopy")
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            subprocess.run([sys.executable, "-c", program], cwd=path, check=True, capture_output=True)
            self.assertEqual((path / "azcopy").read_bytes(), payload)
        self.assertNotIn("tar -x", job)

    def test_read_only_verification_skips_azcopy_initialization(self):
        job = (ROOT / "k8s" / "jobs" / "sampledata-upload.yaml").read_text()
        program = textwrap.dedent(job.split("- |\n", 1)[1].split("\n          resources:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [BASH, "-c", program], cwd=directory,
                env=dict(os.environ, UPLOAD_MODE="verify"),
                check=True, text=True, capture_output=True,
            )
            self.assertIn("does not require AzCopy", result.stdout)
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])
        runner = (ROOT / "scripts" / "upload-sampledata.sh").read_text()
        self.assertIn(".spec.template.spec.initContainers[0].env |= map(", runner)

    def test_invalid_budget_rejected(self):
        with self.assertRaises(ValueError):
            self.code["layout"](1, 10, 20000, 1)

    def test_resume_skips_correct_existing_blobs_and_records_manifest(self):
        code = self.code
        expected = {"large/large-000000.bin": 1024, "small/small-000000.bin": 1024}
        writes = []

        class FakeStorage:
            def __init__(self, _):
                pass

            def inventory(self):
                return expected.copy()

            def request(self, path, **kwargs):
                if kwargs.get("method") == "PUT":
                    writes.append(json.loads(kwargs["body"]))
                return None, {}

        with mock.patch.dict(code, {"layout": lambda *args: expected, "Storage": FakeStorage,
                                   "azcopy": mock.Mock(side_effect=AssertionError("Existing blobs must be skipped"))}), \
                mock.patch.dict(os.environ, {"STORAGE_ENDPOINT": "https://example.blob.core.windows.net",
                                             "UPLOAD_MODE": "upload"}), contextlib.redirect_stdout(io.StringIO()):
            code["main"]()
        self.assertEqual(writes[0]["actualFileCount"], 2)
        self.assertEqual(writes[0]["actualBytes"], 2048)
        self.assertTrue(writes[0]["startUtc"] <= writes[0]["endUtc"])

    def test_resume_rejects_wrong_size(self):
        code = self.code

        class FakeStorage:
            def __init__(self, _):
                pass

            def inventory(self):
                return {"large/file.bin": 99}

            def request(self, *args, **kwargs):
                return None, {}

        with mock.patch.dict(code, {"layout": lambda *args: {"large/file.bin": 100}, "Storage": FakeStorage}), \
                mock.patch.dict(os.environ, {"STORAGE_ENDPOINT": "https://example", "UPLOAD_MODE": "upload"}):
            with self.assertRaisesRegex(RuntimeError, "wrong-sized"):
                code["main"]()

    def test_incompatible_existing_manifest_fails_before_upload_or_commit(self):
        code = self.code
        requests = []

        class FakeStorage:
            def __init__(self, _):
                pass

            def inventory(self):
                raise AssertionError("Incompatible manifest must fail before inventory/upload")

            def request(self, path, **kwargs):
                requests.append(kwargs.get("method", "GET"))
                return json.dumps({"expected": {"large/file.bin": 99}, "startUtc": "2026-01-01T00:00:00Z"}).encode(), {}

        with mock.patch.dict(code, {"layout": lambda *args: {"large/file.bin": 100}, "Storage": FakeStorage,
                                   "azcopy": mock.Mock(side_effect=AssertionError("Must not upload"))}), \
                mock.patch.dict(os.environ, {"STORAGE_ENDPOINT": "https://example", "UPLOAD_MODE": "upload"}):
            with self.assertRaisesRegex(RuntimeError, "different layout"):
                code["main"]()
        self.assertEqual(requests, ["GET"])

    def test_final_inventory_mismatch_never_commits_manifest(self):
        code = self.code
        expected = {"large/file.bin": 100}
        cases = [
            ({"large/file.bin": 99}, "inventory mismatch"),
            ({}, "inventory mismatch"),
            ({"large/file.bin": 100, "small/old-plan.bin": 100}, "Unexpected blobs"),
        ]
        for final_inventory, error in cases:
            with self.subTest(inventory=final_inventory):
                inventories = iter([expected.copy(), final_inventory])
                requests = []

                class FakeStorage:
                    def __init__(self, _):
                        pass

                    def inventory(self):
                        return next(inventories)

                    def request(self, path, **kwargs):
                        requests.append(kwargs.get("method", "GET"))
                        return None, {}

                with mock.patch.dict(code, {"layout": lambda *args: expected, "Storage": FakeStorage,
                                           "azcopy": mock.Mock(side_effect=AssertionError("Correct initial blobs should be skipped"))}), \
                        mock.patch.dict(os.environ, {"STORAGE_ENDPOINT": "https://example", "UPLOAD_MODE": "upload"}):
                    with self.assertRaisesRegex(RuntimeError, error):
                        code["main"]()
                self.assertEqual(requests, ["GET"], "A mismatching final inventory must never PUT a manifest")

    def test_secondary_inventory_and_actual_read(self):
        code = self.code
        expected = {"large/file.bin": 1024, "small/file.bin": 1024}
        requests = []

        class FakeStorage:
            def __init__(self, _):
                pass

            def inventory(self):
                return expected

            def request(self, path, **kwargs):
                requests.append(path)
                if path.endswith("manifest.json"):
                    return json.dumps({"expected": expected}).encode(), {}
                return b"x"*1024, {}

        with mock.patch.dict(code, {"layout": lambda *args: expected, "Storage": FakeStorage}), \
                mock.patch.dict(os.environ, {"STORAGE_ENDPOINT": "https://secondary", "UPLOAD_MODE": "verify"}), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            code["main"]()
        self.assertIn("SECONDARY_READ_VERIFIED", output.getvalue())
        self.assertEqual(len(requests), 3)


class PriceTests(unittest.TestCase):
    @staticmethod
    def item(region, **changes):
        item = {
            "armRegionName": region, "serviceName": "Virtual Machines", "armSkuName": "Standard_D4s_v5",
            "skuName": "Standard_D4s_v5", "productName": "Virtual Machines Dsv5 Series", "meterName": "D4s v5",
            "type": "Consumption", "currencyCode": "USD", "tierMinimumUnits": 0, "retailPrice": 1,
            "isPrimaryMeterRegion": True, "meterId": region, "skuId": region,
            "unitOfMeasure": "1 Hour", "effectiveStartDate": "2026-01-01",
        }
        return {**item, **changes}

    def estimate(self, catalog, extra=""):
        (WORK / "catalog.json").write_text(json.dumps(catalog))
        proc = shell(f"bash scripts/estimate-cost.sh --catalog scripts/tests/.run/catalog.json "
                     f"--output scripts/tests/.run/estimate.json {extra}")
        report = json.loads((WORK / "estimate.json").read_text())
        return proc, report

    def test_currency_tiers_windows_spot_and_missing_are_not_zero(self):
        items = [self.item(region) for region in ("koreacentral", "koreasouth")]
        items += [
            self.item("koreacentral", currencyCode="KRW", retailPrice=9999),
            self.item("koreacentral", tierMinimumUnits=10000, retailPrice=0.01),
            self.item("koreacentral", productName="Virtual Machines Dsv5 Series Windows", retailPrice=9999),
            self.item("koreacentral", skuName="Standard_D4s_v5 Spot", retailPrice=0.01),
        ]
        proc, report = self.estimate(items)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(report["aksVmCount"], 4)
        self.assertEqual(report["knownSubtotal"], 2920)
        self.assertGreater(report["unknownItems"], 0)
        self.assertTrue(all("amount" not in row for row in report["items"] if row["status"] == "UNKNOWN"))

    def test_ambiguous_distinct_meters_are_unknown(self):
        proc, report = self.estimate([self.item("koreacentral"), self.item("koreacentral", meterId="other")], "--strict")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertEqual(report["items"][0]["status"], "UNKNOWN")
        self.assertEqual(len(report["items"][0]["candidateMeterIds"]), 2)

    def test_default_cost_topology_has_no_acr_geo_and_seventeen_private_endpoints(self):
        _, report = self.estimate([])
        self.assertFalse(report["enableAcrGeoReplication"])
        self.assertEqual(report["privateEndpointCount"], 17)
        self.assertEqual(report["managedOsDiskCount"], 4)
        self.assertEqual(report["eventHubsStandardTuCount"], 2)
        self.assertEqual(report["dnsResolverInboundEndpointCount"], 0)
        disks = [row for row in report["items"] if "managed OS disk" in row["item"]]
        self.assertEqual(len(disks), 2)
        self.assertTrue(all(row["match"]["productName"] == "Premium SSD Managed Disks" for row in disks))
        self.assertTrue(all(row["match"]["skuName"] == "P6 LRS" for row in disks))
        self.assertTrue(all(row["match"]["meterName"] == "P6 LRS Disk" for row in disks))
        endpoints = [row for row in report["items"] if "private endpoints" in row["item"]]
        self.assertEqual(sorted(row["quantity"] for row in endpoints), [8*730, 9*730])
        self.assertFalse(any(row["item"] == "ACR Premium geo replica" for row in report["items"]))
        _, report = self.estimate([], "--acr-geo")
        self.assertTrue(report["enableAcrGeoReplication"])
        self.assertTrue(any(row["item"] == "ACR Premium geo replica" for row in report["items"]))

    def test_event_hubs_georecovery_disabled_still_bills_two_namespaces_and_four_pes(self):
        _, report = self.estimate([], "--no-event-hubs-georecovery")
        hubs = [row for row in report["items"] if row["item"] == "Event Hubs Standard one TU"]
        self.assertEqual(len(hubs), 2)
        self.assertTrue(all(row["quantity"] == 730 for row in hubs))
        self.assertEqual(report["eventHubsStandardTuCount"], 2)
        self.assertFalse(report["features"]["enableEventHubsGeoRecovery"])
        self.assertEqual(report["privateEndpointCount"], 17)
        _, report = self.estimate([], "--no-event-hubs")
        self.assertEqual(report["eventHubsStandardTuCount"], 0)
        self.assertEqual(report["privateEndpointCount"], 13)

    def test_standard_eh_cost_uses_throughput_and_billable_ingress_not_premium_pus(self):
        items = []
        for region in ("koreacentral", "koreasouth"):
            for meter, unit, price in (("Standard Throughput Unit", "1 Hour", 0.03),
                                       ("Standard Ingress Events", "1M", 0.028)):
                items.append(self.item(region, serviceName="Event Hubs", productName="Event Hubs",
                                       skuName="Standard", meterName=meter, unitOfMeasure=unit,
                                       meterId=region+meter, skuId=region+meter, retailPrice=price))
        proc, report = self.estimate(items, "--event-hubs-ingress-events 2000000")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        hubs = [row for row in report["items"] if row["item"].startswith("Event Hubs Standard")]
        self.assertEqual(len(hubs), 4)
        self.assertTrue(all(row["status"] == "MATCHED" for row in hubs))
        self.assertAlmostEqual(sum(row["amount"] for row in hubs), 2*(730*0.03 + 2*0.028))
        self.assertEqual(report["eventHubsIngressUnitsPerNamespace"], 2000000)

    def test_optional_dns_resolver_bills_only_two_inbound_endpoints(self):
        item = self.item("", serviceName="Azure DNS", productName="Azure DNS", skuName="Private Resolver",
                         meterName="Private Resolver Inbound Endpoint", unitOfMeasure="1", retailPrice=180)
        _, report = self.estimate([item], "--dns-resolver")
        resolvers = [row for row in report["items"] if "DNS Private Resolver" in row["item"]]
        self.assertEqual(len(resolvers), 2)
        self.assertTrue(all(row["quantity"] == 1 and row["status"] == "MATCHED" for row in resolvers))
        self.assertEqual(sum(row["amount"] for row in resolvers), 360)
        self.assertTrue(report["features"]["deployDnsResolver"])
        self.assertEqual(report["dnsResolverInboundEndpointCount"], 2)
        self.assertFalse(any("outbound" in row["item"].lower() for row in report["items"]))
        _, report = self.estimate([], "--dns-resolver")
        resolvers = [row for row in report["items"] if "DNS Private Resolver" in row["item"]]
        self.assertTrue(all(row["status"] == "UNKNOWN" and "amount" not in row for row in resolvers))

    def test_real_regional_nonprimary_meter_and_tiers_are_used_once(self):
        items = [self.item("koreacentral", isPrimaryMeterRegion=False)]
        items += [self.item("koreacentral", isPrimaryMeterRegion=False, tierMinimumUnits=1000, retailPrice=0.5)]
        _, report = self.estimate(items)
        self.assertEqual(report["items"][0]["amount"], 1000 + 460*0.5)
        self.assertEqual(len(report["items"][0]["appliedTiers"]), 2)

    def test_pagination_follows_absolute_nextpagelink_unchanged(self):
        code = functions_only("estimate-cost.sh")
        first = "https://prices.azure.com/api/retail/prices?test=1"
        second = "https://prices.azure.com/api/retail/prices?$skip=1000&currencyCode=USD"
        docs = [dict(Items=[{"id": 1}], NextPageLink=second), dict(Items=[{"id": 2}], NextPageLink=None)]
        urls = []

        def fake_open(url, **_):
            urls.append(url)
            return io.StringIO(json.dumps(docs.pop(0)))

        with mock.patch.object(urllib.request, "urlopen", side_effect=fake_open):
            rows = list(code["pages"](first))
        self.assertEqual(urls, [first, second])
        self.assertEqual(rows, [{"id": 1}, {"id": 2}])

    def test_pagination_loop_is_rejected(self):
        code = functions_only("estimate-cost.sh")
        url = "https://prices.azure.com/api/retail/prices?loop=1"
        with mock.patch.object(urllib.request, "urlopen",
                               return_value=io.StringIO(json.dumps(dict(Items=[], NextPageLink=url)))):
            with self.assertRaisesRegex(RuntimeError, "loop"):
                list(code["pages"](url))


if __name__ == "__main__":
    WORK.mkdir(parents=True, exist_ok=True)
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(WORK)
