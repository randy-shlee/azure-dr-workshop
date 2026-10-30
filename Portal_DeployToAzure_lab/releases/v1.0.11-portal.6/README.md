# Portal Deployment: v1.0.11-portal.6

Prerelease validation candidate, not a stable release. GitHub Release state determines
publication. This candidate has not undergone a new cloud deployment. ARM success only
starts the asynchronous app bootstrap; verify app and sample completion separately.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.6%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.6%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.6%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.6%2FuiFormDefinition.json)

Source assets: v1.0.11. See ../../README.md for the lab and publication gates.

## Validation evidence

- Form expression tests, official Portal form schema and packaged asset contracts passed.
- The public Portal deployment-option function reproduced the old location exception with
    a bare subscription GUID and returned correct options with the corrected subscription ARM ID.
- Deployment-record location is internally Korea Central; location and expiry controls are removed.
- The lifecycle expiry tag is empty; this does not schedule deletion or extend any approved budget.
- Image and runbook bytes are unchanged from v1.0.11.
- No new full cloud deployment, failover, failback or cleanup was performed.
- Publish as a prerelease, not latest or stable. Preserve previous tags and assets.

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

Before promoting the lab button, publish and verify both immutable JSON URLs and the
unchanged image/runbook assets. Preview the form in Azure Portal using synthetic values
only, including blank inputs, reserved IDs, weak passwords and mismatched confirmation.
Do not submit a deployment just to check the form. Never automate a filled secret form.