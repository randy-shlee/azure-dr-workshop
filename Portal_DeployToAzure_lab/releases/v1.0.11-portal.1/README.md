# Portal Deployment: v1.0.11-portal.1

Not published or cloud-validated. Publish the exact tag-pinned template and both
hash-verified Release assets before using this button. ARM success only starts
the asynchronous app bootstrap; verify app and sample completion separately.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.1%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.1%2Fazuredeploy.json)

## Validation and Scope

Source assets: v1.0.11; internal image tag: `drtest-app:v1.0.11`.
Both assets are unchanged under the portal Release tag v1.0.11-portal.1.
A separate public v1.0.11 Release is not required for this portal flow.

- Application base: digest-pinned official Python 3.12 Alpine; non-root UID/GID 10001.
- 2026-10-29 Trivy 0.76.1 audit of the exact archive: Alpine 3.24.3, 38 OS packages, 0 known findings.
- Actual installed Python packages, including pip: no known vulnerabilities in pip-audit.
- 47 app tests passed in the identical final image; source hashes and native libpq loading verified.
- Default Uvicorn HTTP/security behavior and container DNS/certificate-verified HTTPS passed.
- Portal contracts and 215 compiled template resource invariants passed.
- Azure deployment and DR execution: not run. Existing Bicep BCP081 schema warnings remain.
- The full operational shell suite is not green: existing DNS/mock failures and a documentation-block extraction error remain.

These audits cover the app image, not the separate Azure CLI sample Job image or AKS host kernel.
Zero known findings is not a security guarantee. See [security scope](../../../SECURITY.md).
Older v1.0.10 and v1.0.10-portal.1 remain blocked; do not reuse their assets.

## Upload Assets

The Git-ignored staging directory is `.state/releases/v1.0.11-portal.1/`.
The image archive is 49,847,456 bytes. The two asset checksums are:

```text
c2ef7881df8eae334d49953aaeba81c85d7b618892fcb1c7d41ec54504ce52d3  app-image.tar.gz
4cc5b9e67138e24e867f057e94ac4f2123f268420901edc65c58e1bf8792e067  workshop-bootstrap.ps1
```

`SHA256SUMS` contains these same values. Do not rebuild, retag or recompress the staged image.
The checked-in template and manifest bind the portal URLs to these exact bytes.

## Publication Gates

1. Review the intended source/docs/template changes and staged diff. Do not stage private files or all local changes indiscriminately.
2. Commit the reviewed files and publish the exact `v1.0.11-portal.1` Git tag. Verify that it contains the reviewed source and template.
3. From the repository root, create a draft Release using the prepared command below. It refuses to create a missing tag.
4. Review the draft, publish the Release when approved, then verify anonymous downloads and SHA256 for both assets and the tag-pinned raw template.
5. Validate Portal infrastructure, automatic app/sample completion, DR and cleanup in an approved isolated environment before customer use.

Create an unpublished draft Release with the command below. Keep it as a draft until the publication gates are approved:

```bash
gh release create v1.0.11-portal.1 \
	--repo randy-shlee/azure-dr-workshop \
	--verify-tag --draft \
	--title "Azure Portal DR Workshop v1.0.11-portal.1" \
	--notes-file Portal_DeployToAzure_lab/releases/v1.0.11-portal.1/README.md \
	.state/releases/v1.0.11-portal.1/app-image.tar.gz \
	.state/releases/v1.0.11-portal.1/workshop-bootstrap.ps1 \
	.state/releases/v1.0.11-portal.1/SHA256SUMS
```

The button is unusable until the public tag/template and Release assets exist.
See the [workshop entry](../../README.md) for the customer workflow.