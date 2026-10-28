#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
groups=(); for key in primaryResourceGroup secondaryResourceGroup globalResourceGroup; do groups+=("$(cfg ".$key")"); done
printf 'Subscription: %s\nResource groups: %s\n' "$SUBSCRIPTION_ID" "${groups[*]}"
suffixes=(krc krs global)
for i in "${!groups[@]}"; do
  group="${groups[$i]}"
  [[ "$group" == "rg-$PREFIX-${suffixes[$i]}" ]] || die "Unexpected workshop resource group: $group"
  if [[ "${REQUIRE_OWNER_TAG:-false}" == true ]]; then
    owner="$(az group show -n "$group" --query tags.owner -o tsv)"
    [[ "$owner" == "$OWNER_EMAIL" ]] || die "Owner tag mismatch: $group"
  fi
done
confirm "DELETE $SUBSCRIPTION_ID ${groups[*]}"
budget_name="$(jq -r 'if has("budgetName") then .budgetName // empty else .prefix + "-drtest-budget" end' "$CONFIG_FILE")"
if [[ -n "$budget_name" ]]; then
  note "Subscription budget $budget_name is not part of any resource group."
  confirm "DELETE BUDGET $budget_name" CONFIRM_BUDGET
else
  note 'This deployment has no subscription budget; budget cleanup is skipped.'
fi
bootstrap_role="$(jq -r '.bootstrap.operatorRoleId // empty' "$CONFIG_FILE")"
if [[ -n "$bootstrap_role" ]]; then
  [[ "$bootstrap_role" == "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/"* &&
     "${bootstrap_role##*/}" =~ ^[a-fA-F0-9-]{36}$ ]] || die 'Unexpected bootstrap role scope or ID.'
  role_name="$(az role definition list --name "${bootstrap_role##*/}" --query '[0].roleName' -o tsv)"
  [[ "$role_name" == "$PREFIX-workshop-bootstrap" ]] || die 'Bootstrap role name mismatch; refusing deletion.'
  confirm "DELETE BOOTSTRAP ROLE $role_name" CONFIRM_BOOTSTRAP_ROLE
fi
for group in "${groups[@]}"; do az group delete -n "$group" --yes --no-wait; done
for group in "${groups[@]}"; do az group wait -n "$group" --deleted --interval 20 --timeout 7200; done
if [[ -n "$budget_name" ]]; then
  az rest --method delete --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Consumption/budgets/$budget_name?api-version=2026-06-01" -o none
fi
if [[ -n "$bootstrap_role" ]]; then
  for attempt in {1..12}; do
    if az role definition delete --name "${bootstrap_role##*/}"; then break; fi
    (( attempt < 12 )) || die 'Bootstrap custom-role cleanup failed; inspect remaining role assignments/permissions before retrying.'
    sleep 10
  done
fi
rm -f "$CONFIG_FILE"
note 'Named resource groups and any configured subscription budget/bootstrap custom role deleted. Deployment history and retained audit logs are not deleted.'
