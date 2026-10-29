# Portal Deployment: v1.0.11-portal.4

Live-validation candidate, not a final release. GitHub Release state determines
publication. ARM success only starts asynchronous app bootstrap; app readiness,
10 GB sample replication, failover, failback and cleanup need separate evidence.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.4%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.4%2Fazuredeploy.json)

## Change And Evidence

- v1.0.11-portal.2 failed in actual Portal deployment: Automation rejected the GitHub Release content link.
- Import probes did not resolve the error by changing hash encoding or case. Bypassing the Release redirect with the same bytes and hash succeeded without running the probe.
- v1.0.11-portal.3 stayed draft: anonymous raw download exposed Git newline normalization, so it was not promoted.
- This candidate publishes the unchanged packaged runbook at an immutable raw GitHub URL. A local .gitattributes disables newline conversion only for that packaged file.
- Source bytes, Git clean-filter bytes and manifest SHA256 were checked. Automation retains contentHash validation; no hash check was removed.
- The image remains the unchanged v1.0.11 Release asset. Image and runbook hashes are in portal-manifest.json.
- Local checks: 215 compiled resource invariants and Portal contracts, including the raw runbook URI, file existence, byte hash and Git attributes, passed.
- Existing runtime evidence: 47 app, 66 operational and 11 bootstrap tests passed. No runtime application code or image was changed by these publication corrections.
- Complete cloud deployment and workshop scenarios for this candidate are not yet proven. Do not mark latest or stable.

Preserve previous tags and assets. Any further fix requires a new immutable candidate.
See the [workshop entry](../../README.md) and [security scope](../../../SECURITY.md).