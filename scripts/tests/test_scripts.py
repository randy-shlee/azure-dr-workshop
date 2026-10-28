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
import unittest
import urllib.request
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
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
    return subprocess.run([BASH, "-c", command], cwd=ROOT, env=env, text=True, capture_output=True)


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
            self.assertIn("enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'", text)
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
region_rg() { echo rg; }; cfg() { echo pg; }
az() { if [[ "$*" == *"replica promote"* ]]; then echo "$*" >&2; else echo Replica; fi; }
pg_switchover secondary
""")
        self.assertIn("--promote-mode switchover --promote-option planned", proc.stderr)
        self.assertNotIn("--promote-mode standalone", proc.stderr)
        self.assertNotEqual(proc.returncode, 0, "Mock remains Replica, so postcondition must fail")

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
  *"rest --method patch"*) :;;
  *"rest --method get"*)
    printf '%s\\n' '{"properties":{"provisioningState":"Succeeded","geoDataReplication":{"locations":[{"locationName":"koreasouth","roleType":"Primary","replicaState":"Active"},{"locationName":"koreacentral","roleType":"Secondary","replicaState":"Active"}]}}}';;
  *"aks command invoke"*)
    if [[ "$*" == *"get deployment drtest-app"* ]]; then
      jq -nc '{exitCode:0,logs:({metadata:{generation:1},status:{observedGeneration:1,updatedReplicas:1,availableReplicas:1,replicas:1}}|tojson)}'
    elif [[ "$*" == *"get service drtest-app"* ]]; then
      ip=203.0.113.10; [[ "$*" != *"krs-aks"* ]] || ip=203.0.113.20
      jq -nc --arg ip "$ip" '{exitCode:0,logs:({status:{loadBalancer:{ingress:[{ip:$ip}]}}}|tojson)}'
    elif [[ "$*" == *"kubectl apply -f app-secrets.json"* ]]; then
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
                         "enableEventHubsGeoReplication": True},
            "postgres": {"writerEndpoint": "writer.example", "readerEndpoint": "reader.example"},
            "trafficManager": {"id": "/tm/test", "fqdn": "test.trafficmanager.net"},
        }
        for key, region in (("primary", "krc"), ("secondary", "krs")):
            self.config[key] = {
                "region": region, "location": "koreacentral" if key == "primary" else "koreasouth",
                "aks": {"name": region + "-aks"}, "identity": {"clientId": "client-" + region},
                "publicIp": {"name": "pip-" + region, "address": "203.0.113.10" if key == "primary" else "203.0.113.20"}, "eventHubs": {"host": "eh.example", "id": "/eh/test"},
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
            self.assertEqual(config["STORAGE_READ_MODE"], "primary" if region == "krc" else "secondary")
            self.assertEqual(config["PG_HOST"], "writer.example")
            self.assertEqual(config["PG_DB"], "postgres")
            self.assertEqual(config["EH_NAMESPACE"], "eh.example")
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

    def test_application_deploy_requires_private_build_pool(self):
        proc = self.run_script("app-deploy.sh", {"ACR_AGENT_POOL": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("VNet-connected ACR Tasks pool", proc.stderr)

    def test_customer_workshop_manual_apply_block(self):
        image = "acr.example/drtest-app:workshop-test"
        proc = self.run_script("gen-app-config.sh", {"APP_IMAGE": image})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        state = WORK / "state"
        state.mkdir(exist_ok=True)
        for region in ("krc", "krs"):
            result = subprocess.run(
                [shutil.which("kubectl"), "kustomize", str(WORK / "overlays" / region)],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            (state / f"app-{region}.yaml").write_text(result.stdout)
        guide = (ROOT / "workshop" / "labs" / "04-application.md").read_text(encoding="utf-8")
        section = guide.split("## 4-3.", 1)[1].split("## 4-4.", 1)[0]
        block = section.split("```bash\n", 1)[1].split("```", 1)[0]
        calls = WORK / "workshop-apply-calls.txt"
        calls.unlink(missing_ok=True)
        command = """
source scripts/common.sh
load_config
aks_run() {
  local key="$1" command="$2" marker="$3" secret="$4" manifest="$5" expected
  [[ "$marker" == --file && "$command" == *"kubectl apply -f app-secrets.json"* ]]
  [[ "$command" != *workshop-pg* && "$command" != *workshop-krc* && "$command" != *workshop-krs* ]]
  if [[ "$key" == primary ]]; then expected=workshop-krc; else expected=workshop-krs; fi
  jq -e --arg redis "$expected" '.kind=="Secret" and .metadata.namespace=="drtest" and
    .stringData.PG_PASSWORD=="workshop-pg" and .stringData.REDIS_KEY==$redis' "$secret" >/dev/null
  grep -Fq "$APP_IMAGE" "$manifest"
  printf '%s\\n' "$key" >>"$WORKSHOP_CALLS"
}
"""
        proc = shell(command + block, self.environment | {
            "APP_IMAGE": image, "PG_PASSWORD": "workshop-pg",
            "REDIS_KEY_KRC": "workshop-krc", "REDIS_KEY_KRS": "workshop-krs",
            "WORKSHOP_CALLS": calls.as_posix(),
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["primary", "secondary"])
        self.assertFalse(list(state.glob("workshop-app.*")), "Workshop temporary Secrets must be removed.")

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

    def test_eh_ga_active_replica_state_is_accepted(self):
        proc = self.run_script("eh-georeplication.sh promote krs")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("already primary in koreasouth", proc.stderr)

    def test_eh_manual_configuration_can_enable_disabled_bicep_geo(self):
        self.config["features"]["enableEventHubsGeoReplication"] = False
        self.config["primary"]["eventHubs"]["maxReplicationLagSeconds"] = 777
        self.environment["CONFIRM"] = "CONFIGURE EH GEO test"
        proc = self.run_script("eh-georeplication.sh configure")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads((WORK / "config.json").read_text())
        self.assertTrue(result["features"]["enableEventHubsGeoReplication"])
        self.assertIn("second Premium PU", proc.stderr)
        self.assertIn("ENABLE_EH_GEO_REPLICATION=true", proc.stderr)

    def test_eh_manual_configuration_rejects_invalid_async_lag(self):
        self.config["features"]["enableEventHubsGeoReplication"] = False
        self.config["primary"]["eventHubs"]["maxReplicationLagSeconds"] = 0
        self.environment["CONFIRM"] = "CONFIGURE EH GEO test"
        proc = self.run_script("eh-georeplication.sh configure")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("300..86400", proc.stderr)
        result = json.loads((WORK / "config.json").read_text())
        self.assertFalse(result["features"]["enableEventHubsGeoReplication"])


class UploadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = functions_only("sampledata-program.sh")

    def test_default_layout_is_actual_9953_gib(self):
        expected = self.code["layout"](100, 10, 20000, 1)
        self.assertEqual(sum(name.startswith("large/") for name in expected), 8)
        self.assertEqual(len(expected), 20008)
        self.assertEqual(sum(expected.values()) / 1024**3, 99.53125)

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

    def test_default_cost_topology_has_no_acr_geo_and_fifteen_private_endpoints(self):
        _, report = self.estimate([])
        self.assertFalse(report["enableAcrGeoReplication"])
        self.assertEqual(report["privateEndpointCount"], 15)
        self.assertEqual(report["managedOsDiskCount"], 4)
        self.assertEqual(report["eventHubsPremiumPuCount"], 2)
        self.assertEqual(report["dnsResolverInboundEndpointCount"], 0)
        disks = [row for row in report["items"] if "managed OS disk" in row["item"]]
        self.assertEqual(len(disks), 2)
        self.assertTrue(all(row["match"]["productName"] == "Premium SSD Managed Disks" for row in disks))
        self.assertTrue(all(row["match"]["skuName"] == "P6 LRS" for row in disks))
        self.assertTrue(all(row["match"]["meterName"] == "P6 LRS Disk" for row in disks))
        endpoints = [row for row in report["items"] if "private endpoints" in row["item"]]
        self.assertEqual(sorted(row["quantity"] for row in endpoints), [7*730, 8*730])
        self.assertFalse(any(row["item"] == "ACR Premium geo replica" for row in report["items"]))
        _, report = self.estimate([], "--acr-geo")
        self.assertTrue(report["enableAcrGeoReplication"])
        self.assertTrue(any(row["item"] == "ACR Premium geo replica" for row in report["items"]))

    def test_event_hubs_geo_disabled_keeps_two_private_endpoints_but_one_pu(self):
        _, report = self.estimate([], "--no-event-hubs-geo")
        hubs = [row for row in report["items"] if row["item"].startswith("Event Hubs Premium")]
        self.assertEqual(len(hubs), 1)
        self.assertEqual(hubs[0]["region"], "koreacentral")
        self.assertEqual(hubs[0]["quantity"], 730)
        self.assertEqual(report["eventHubsPremiumPuCount"], 1)
        self.assertFalse(report["features"]["enableEventHubsGeoReplication"])
        self.assertEqual(report["privateEndpointCount"], 15)
        _, report = self.estimate([], "--no-event-hubs")
        self.assertEqual(report["eventHubsPremiumPuCount"], 0)
        self.assertEqual(report["privateEndpointCount"], 13)

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
