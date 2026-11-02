# Portal Deployment: v1.0.11-portal.8

Prerelease: Traffic Manager defaults to Weighted routing with KRC weight 90 and
KRS weight 10, both endpoints enabled. These are relative DNS selection weights,
not an exact HTTP request ratio. No new Azure deployment or live DR validation
was performed for this release. ARM success only starts the asynchronous app
bootstrap; verify app and sample completion separately.

Failover disables KRC after backend recovery. Failback enables both endpoints
to restore 90:10. DR data verification uses the target regional address rather
than a randomly selected Traffic Manager endpoint.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.8%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.8%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.8%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.8%2FuiFormDefinition.json)

Source assets: v1.0.11. See ../../README.md for the lab and publication gates.

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
hash-verified image/runbook assets. Preview the form in Azure Portal using synthetic values
only, including blank inputs, reserved IDs, weak passwords and mismatched confirmation.
Do not submit a deployment just to check the form. Never automate a filled secret form.