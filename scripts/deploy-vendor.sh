#!/usr/bin/env bash
# Post-deploy wiring for the vendor accelerators (Quicker Quotes, Generate
# Order, Copy-OLI-to-QLI, Action Plans V4).
#
# Each accelerator's metadata is copied into force-app/ by its integration
# issue, so the metadata itself rides the normal package deploy. This script
# performs the post-deploy steps the deploy can't do for you (e.g. permission
# set assignments). Steps are filled in per accelerator:
# - Action Plans V4........ (done — assigns AP permission sets)
# - Quicker Quotes......... (pending)
# - Generate Order......... (pending)
# - Copy-OLI-to-QLI........ (pending)
#
# Pass `--allow-empty` in scaffolding contexts where a no-op is intentional.

set -euo pipefail
source "$(dirname "$0")/_common.sh"
require_sf
resolve_org

# --- Action Plans V4 ---------------------------------------
# AP metadata deploys with force-app; here we grant the admin user the AP
# admin permission set. A *duplicate* assignment errors harmlessly and is
# ignored, but any other failure (bad org/auth, missing permset after a failed
# metadata deploy) must abort — otherwise we'd report success while the admin
# user is left without Action Plans access.
echo "deploy-vendor.sh: assigning Action Plans permission set (Action_Plans_Admin)…"
if ! assign_out="$(sf org assign permset -n Action_Plans_Admin --target-org "$NS_ORG" 2>&1)"; then
  if printf '%s' "$assign_out" | grep -qiE 'already assigned|already has|duplicate'; then
    echo "  (Action_Plans_Admin already assigned — continuing)"
  else
    printf '%s\n' "$assign_out" >&2
    echo "deploy-vendor.sh: ERROR — Action_Plans_Admin assignment failed (not a duplicate)." >&2
    exit 1
  fi
fi
# Other AP permission sets (Creator / Template_Creator / Import_Export / User)
# are assigned per-persona via config/developer-org-setup-checklist.md.

# Seed the Action Plans org-default custom setting. In a source-deployed org the
# managed-package post-install script never runs, so the hierarchy setting can
# be missing on first Flow/invocable use — which makes the package default
# (Unassigned_Task_Assigned_to_Owner__c = true) silently not apply. The vendor's
# own initializer inserts the correct defaults (its insert path is fine; only
# its return value is affected by the upstream shadow bug, which we don't rely
# on here), so call it once to seed the setting idempotently.
echo "deploy-vendor.sh: seeding Action Plans org-default settings…"
if ! seed_out="$(printf '%s\n' 'ActionPlansUtilities.checkOrgDefaultCustomSetting(true);' \
    | sf apex run --target-org "$NS_ORG" 2>&1)"; then
  printf '%s\n' "$seed_out" >&2
  echo "deploy-vendor.sh: ERROR — seeding Action Plans settings failed." >&2
  exit 1
fi

# --- Quicker Quotes ----------------------------------------
# The QQ metadata is copied into force-app/ (adapted from SalesforceLabs/
# Quicker-Quotes @ d1c406e, BSD 3-Clause — see
# docs/package-integration-notes.md), so it rides the normal package deploy.
# We ALSO deploy the QQ
# source paths on their own here so a QQ-specific failure (a vendor Apex/flow
# regression, a renamed Northstar field the entry flow binds to) surfaces
# clearly instead of being buried in the full-org deploy output. Re-deploying
# the same components is idempotent. QQ_Tests + QQ_SetupAccessCheckTest give
# the per-class coverage the QQ_ Apex classes need (the latter covers
# QQ_SetupAccessCheck, the invocable the QQ_New_Quote2 first-run gate calls).
echo "deploy-vendor.sh: deploying Quicker Quotes (QQ_*) source separately…"
QQ_SRC=(
  force-app/main/default/classes/QQ_CreateQuotePdf.cls
  force-app/main/default/classes/QQ_SearchPricebookEntries.cls
  force-app/main/default/classes/QQ_UpsertAndDeleteQuoteLineItems.cls
  force-app/main/default/classes/QQ_SetupAccessCheck.cls
  force-app/main/default/classes/QQ_SetupAccessCheckTest.cls
  force-app/main/default/classes/QQ_Tests.cls
  force-app/main/default/aura/QQ_GlobalAction
  force-app/main/default/aura/QQ_NavigateToRecord
  force-app/main/default/lwc/qqProductsTable
  force-app/main/default/lwc/qqProductsSearchModal
  force-app/main/default/flexipages/QQ_New_Quote.flexipage-meta.xml
  force-app/main/default/flows/QQ_New_Quote2.flow-meta.xml
  force-app/main/default/flows/QQ_Edit_Quote.flow-meta.xml
  force-app/main/default/flows/QQ_Config_Settings_First_Run.flow-meta.xml
  force-app/main/default/quickActions/Account.QQ_New_Quote_Account.quickAction-meta.xml
  force-app/main/default/quickActions/Contact.QQ_New_Quote_Contact.quickAction-meta.xml
  force-app/main/default/quickActions/Opportunity.QQ_New_Quote_Opportunity.quickAction-meta.xml
  force-app/main/default/quickActions/QQ_New_Quote_Global.quickAction-meta.xml
  force-app/main/default/quickActions/Quote.QQ_Edit_Quote.quickAction-meta.xml
  force-app/main/default/objects/QQ_Config__c
  force-app/main/default/objects/QQ_Quote_Template__c
  force-app/main/default/objects/Account/fields/QQ_Default_Price_Book__c.field-meta.xml
  force-app/main/default/staticresources/QQ_ProductsTableIcons
  force-app/main/default/staticresources/QQ_ProductsTableIcons.resource-meta.xml
  force-app/main/default/staticresources/QQ_QuoteActionIcon.resource-meta.xml
  force-app/main/default/tabs/QQ_New_Quote.tab-meta.xml
)
qq_dir_args=()
for p in "${QQ_SRC[@]}"; do qq_dir_args+=(--source-dir "$p"); done
run sf project deploy start \
  "${qq_dir_args[@]}" \
  --test-level RunSpecifiedTests \
  --tests QQ_Tests \
  --tests QQ_SetupAccessCheckTest \
  --target-org "$NS_ORG"

if [[ "${1:-}" == "--allow-empty" ]]; then
  exit 0
fi

echo "deploy-vendor.sh: Generate Order / Copy-OLI steps are not implemented" >&2
echo "  yet (issues 0034-0035). Action Plans (0036) and Quicker Quotes (0033)" >&2
echo "  are done. Pass --allow-empty to suppress this non-zero exit." >&2
exit 3
