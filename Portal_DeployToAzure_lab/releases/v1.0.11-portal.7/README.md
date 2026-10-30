# Portal Deployment: v1.0.11-portal.7

Immutable prerelease package with parallel regional Search/application preparation
and overlapping sample upload/replication. ARM success only starts the asynchronous
app bootstrap; verify app and sample completion separately.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.7%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.7%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.7%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.7%2FuiFormDefinition.json)

Source image and tool pins: v1.0.11. Bootstrap source is bundled from the repository
for this tag. See ../../README.md for the lab and completion checks.

## Credential form

- Admin ID is visible and defaults to pgadmin + the current UTC MMdd (for example pgadmin1030).
- Password remains hidden, requires confirmation, and has no default.
- Password rules are shown above the input: 12-128 characters; at least 3 of uppercase,
  lowercase, digits and symbols; no admin ID within the password (case-insensitive).
- ID length, letters/digits and reserved names are checked before submission.
- Approved public CIDRs are comma separated without spaces or JSON brackets.
- Deployment-record location is handled internally as Korea Central; no region input or region-list API is used.
- No expiry date is requested; the lifecycle expiry tag is left empty and resources are not automatically deleted.
- Subscription deployment scope is passed as an ARM ID, not a bare GUID.
- These input checks do not prove Azure policy, quota, permissions or deployment success.

Use a new prefix for a new environment; do not redeploy the full template over an
existing environment. This publication does not certify live failover/failback.