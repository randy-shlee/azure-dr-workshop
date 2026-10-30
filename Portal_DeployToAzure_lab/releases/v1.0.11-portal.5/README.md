# Portal Deployment: v1.0.11-portal.5

Prerelease validation candidate, not a stable release. GitHub Release state determines
publication. This candidate has not undergone a new cloud deployment. ARM success only
starts the asynchronous app bootstrap; verify app and sample completion separately.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.5%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.5%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.5%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.5%2FuiFormDefinition.json)

Source assets: v1.0.11. See ../../README.md for the lab.

## Validation evidence

- Portal sandbox rendered the visible dated admin ID, password rules and confirmation.
- The deployment-record location defaults to Korea Central; resource regions remain unchanged.
- Form expression tests and the official Portal form schema passed local validation.
- Portal contracts and unchanged image/runbook source-asset checks passed.
- Git preserves the hash-pinned form and runbook bytes without newline conversion.
- A new full deployment, failover, failback and cleanup are not proven for this candidate.
- Publish as a prerelease, not latest or stable. Preserve previous tags and assets.

## Credential form

- Admin ID is visible and defaults to pgadmin + the current UTC MMdd (for example pgadmin1030).
- Password remains hidden, requires confirmation, and has no default.
- Password rules are shown above the input: 12-128 characters; at least 3 of uppercase,
  lowercase, digits and symbols; no admin ID within the password (case-insensitive).
- ID length, letters/digits and reserved names are checked before submission.
- Approved public CIDRs are comma separated without spaces or JSON brackets.
- These input checks do not prove Azure policy, quota, permissions or deployment success.

Before promoting the lab button, publish and verify both immutable JSON URLs and the
unchanged image/runbook assets. Preview the form in Azure Portal using synthetic values
only, including blank inputs, reserved IDs, weak passwords and mismatched confirmation.
Do not submit a deployment just to check the form. Never automate a filled secret form.