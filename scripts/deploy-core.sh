#!/usr/bin/env bash
# Deploy the Northstar build to the Developer Edition org.
#
# WRITES TO THE ORG. This script refuses to run unless the
# caller explicitly passes `--yes`. Use scripts/validate.sh first to confirm
# the deploy is clean.
#
# Deploy model: the manifest is *generated* from the source tree on
# every run, then deployed. This keeps manifest/package.xml an exact, complete
# mirror of force-app/ (no hand-maintained allowlist, no silently-skipped
# components) and never drifts as new metadata is authored. The repo's stock
# baseline has been curated so a full-tree deploy validates clean.

source "$(dirname "$0")/_common.sh"
require_sf
resolve_org

if [[ "${1:-}" != "--yes" ]]; then
  echo "Refuse: pass --yes to write to $NS_ORG" >&2
  exit 2
fi

# 1. Regenerate the manifest from the current source tree.
run sf project generate manifest \
  --source-dir force-app \
  --output-dir manifest \
  --name package

# 2. Deploy everything the manifest now lists, running local Apex tests.
run sf project deploy start \
  --manifest manifest/package.xml \
  --test-level RunLocalTests \
  --target-org "$NS_ORG"
