#!/usr/bin/env bash
# Run the pre-PR validation gate. Validate-only — never writes.
#
#   1. prettier:verify
#   2. lint
#   3. test:unit (LWC Jest)
#   4. sf project deploy validate --manifest manifest/package.xml
#      --test-level RunLocalTests, with --coverage-formatters text-summary so
# the gate prints coverage for the package it just validated

source "$(dirname "$0")/_common.sh"
require_sf
resolve_org

run npm run prettier:verify
run npm run lint
run npm run test:unit

# Regenerate the manifest from the source tree so it's a complete, current
# mirror before validating against it — matches deploy-core.sh
# keeps newly authored components from being silently skipped.
run sf project generate manifest \
  --source-dir force-app \
  --output-dir manifest \
  --name package

# Validate (check-only) and print coverage for the package that just validated
#. --coverage-formatters text-summary makes the validate emit a
# coverage summary to the console for the validated package, rather than reading
# back stale persisted org coverage. Coverage files go to a temp dir we discard.
COVERAGE_DIR="$(mktemp -d)"
run sf project deploy validate \
  --manifest manifest/package.xml \
  --test-level RunLocalTests \
  --coverage-formatters text-summary \
  --results-dir "$COVERAGE_DIR" \
  --target-org "$NS_ORG"
# The formatter writes the summary to a file rather than stdout, so surface it
# in the gate's output, then discard the temp dir.
echo "--- Apex coverage summary (validated package) ---"
cat "$COVERAGE_DIR/coverage/text-summary.txt" 2>/dev/null \
  || echo "(coverage summary not produced)"
rm -rf "$COVERAGE_DIR"
