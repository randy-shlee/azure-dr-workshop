# Portal Deployment: v1.0.11-portal.2

Live-validation candidate, intended for a public prerelease, not a final release.
GitHub Release state is authoritative for publication; all assets must be public
before automatic bootstrap can work. ARM success only starts the asynchronous
app bootstrap; verify app and sample completion separately.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.2%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.2%2Fazuredeploy.json)

## Candidate Evidence

- Source image and runbook: unchanged v1.0.11 assets, pinned by SHA256 in the manifest.
- App tests: 47 passed. Operational tests: 66 passed. Bootstrap tests: 11 passed.
- Builder safety and Bash syntax checks passed.
- Operational regression fixes only: explicit mock curl and direct Secret-transfer verification replace stale manual-document extraction.
- Portal resource invariants: 215; asset and automatic bootstrap contracts passed.
- App image audits: no known OS or Python package vulnerabilities on 2026-10-29.
- The separate Azure CLI Job image and AKS host kernel were not included in that app-image audit.
- Live Azure infrastructure, data replication, failover, failback and cleanup: not yet proven.

## Publication Policy

Keep this candidate as a prerelease, not latest or stable, until live evidence has
been reviewed. Preserve v1.0.11-portal.1 and older blocked candidates unchanged.
Any runtime or template fix requires a new immutable candidate; never move this tag
or overwrite its assets. See the [workshop entry](../../README.md) and
[security scope](../../../SECURITY.md).