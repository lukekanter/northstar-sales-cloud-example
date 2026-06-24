#!/usr/bin/env bash
# Seed the eight Northstar sample scenarios into
# the Developer Edition org and verify the expected automation fired.
#
# Scenarios (records named `[Sn] ...`):
#   S1 Inbound Commercial Lead        S5 Closed Won Standard Deal
#   S2 Enterprise Lead Converted      S6 Closed Won Provisioning Exception
#   S3 Opportunity Enters Proposal    S7 Contract Activation
#   S4 Discounted Enterprise Quote    S8 Renewal Risk Case
#
# The seed is idempotent (each scenario is skipped when already present), so
# this is safe to re-run. Run order matters: products & price books
# and all triggers/flows must be deployed first.
#
# Usage:
#   ./scripts/deploy-sample-data.sh            # seed, then verify
#   ./scripts/deploy-sample-data.sh --seed-only
#   ./scripts/deploy-sample-data.sh --verify-only
#   ./scripts/deploy-sample-data.sh --allow-empty   # back-compat no-op flag

source "$(dirname "$0")/_common.sh"
require_sf
resolve_org

MODE="all"
case "${1:-}" in
  --allow-empty)
    # Back-compat: callers (bootstrap docs / scaffolding pipelines) pass this to
    # intentionally skip seeding. Honor it as a true no-op so those runs stay
    # side-effect-free, even though real sample data now exists.
    echo "deploy-sample-data.sh: --allow-empty — skipping seed/verify (no-op)."
    exit 0
    ;;
  --seed-only) MODE="seed" ;;
  --verify-only) MODE="verify" ;;
  "") MODE="all" ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Usage: $0 [--seed-only|--verify-only|--allow-empty]" >&2
    exit 2
    ;;
esac

HERE="$(dirname "$0")"

if [[ "$MODE" == "seed" || "$MODE" == "all" ]]; then
  # Prerequisite DATA the scenarios depend on (these are seed records, not
  # deployed metadata, so deploy-core does NOT create them). Both are idempotent:
  # - product catalog & price books: S3-S6 build OLIs/QLIs from them; the
  #     scenario seed hard-errors without them.
  # - Action Plan templates: the Closed Won onboarding subflow no-ops
  #     without them, so S5 would create an Order but no onboarding ActionPlan
  # and verification would fail.
  echo "==> Seeding prerequisite data (product catalog, Action Plan templates)..."
  run sf apex run --file "$HERE/apex/seed_product_catalog.apex" --target-org "$NS_ORG"
  run sf apex run --file "$HERE/apex/seed_action_plan_templates.apex" --target-org "$NS_ORG"

  echo "==> Seeding sample scenarios into '$NS_ORG'..."
  # The seed script seeds ONE scenario per run (each Closed Won / activation
  # chain fires too much downstream automation to fit all eight in a single
  # transaction's SOQL limit). Loop until it reports ALL_SEEDED — at most one
  # pass per scenario, plus light re-drives, then idempotent no-ops.
  all_seeded=0
  for _ in $(seq 1 9); do
    out="$(sf apex run --file "$HERE/apex/seed_sample_data.apex" --target-org "$NS_ORG")"
    echo "$out" | grep -E 'S[1-8] (seeded|already|pending|purged|re-driven|blocked|WARNING)|SEEDED_ONE|ALL_SEEDED' || true
    if echo "$out" | grep -q 'ALL_SEEDED'; then
      all_seeded=1
      break
    fi
  done
  if [[ "$all_seeded" -ne 1 ]]; then
    # Still claiming/repairing after the bounded loop — the seed never converged
    # (an unexpected partial state or a repair that can't complete). Fail loudly
    # so callers don't treat incomplete sample data as success.
    echo "deploy-sample-data.sh: seed loop did not reach ALL_SEEDED after 9 passes — sample data is incomplete." >&2
    exit 4
  fi
fi

if [[ "$MODE" == "all" ]]; then
  # Onboarding Action Plans are queueable and the provisioning-exception Case is
  # platform-event driven — give the async work a moment to settle before verify.
  echo "==> Waiting for async automation (Action Plans, provisioning events)..."
  sleep 15
fi

if [[ "$MODE" == "verify" || "$MODE" == "all" ]]; then
  echo "==> Verifying expected automation..."
  run sf apex run --file "$HERE/apex/verify_sample_scenarios.apex" --target-org "$NS_ORG"
fi
