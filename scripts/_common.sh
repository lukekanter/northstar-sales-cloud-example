#!/usr/bin/env bash
# Shared helpers for the Northstar Sales Cloud shell scripts.
#
# Each script should source this near the top:
#   source "$(dirname "$0")/_common.sh"
#
# Provides:
#   - `set -euo pipefail`
#   - require_sf  : abort if the `sf` CLI is missing
#   - resolve_org : populate NS_ORG, honoring (in order)
#       1. an explicit NS_ORG env var,
#       2. the alias from `sf config get target-org`,
#     and aborting if neither is set. The recommended alias for this project
# is `northstar-dev`.
#   - run         : echo a command before executing it (auditable logs)

set -euo pipefail

require_sf() {
  command -v sf >/dev/null || {
    echo "sf CLI not installed." >&2
    exit 1
  }
}

# Populate NS_ORG. Honors an explicit env override, then falls back to
# whatever `sf` has been configured to use. Fails loudly if neither is set.
resolve_org() {
  if [[ -n "${NS_ORG:-}" ]]; then
    return 0
  fi
  # `|| true` is load-bearing: under `set -euo pipefail`, a non-zero exit
  # anywhere in the pipeline (sf erroring, no default configured, sed
  # producing nothing under pipefail) would abort the shell here and the
  # actionable fallback message below would never print.
  local sf_default=""
  sf_default="$(sf config get target-org --json 2>/dev/null \
    | sed -nE 's/.*"value":[[:space:]]*"([^"]+)".*/\1/p' \
    | head -1 \
    || true)"
  if [[ -n "$sf_default" ]]; then
    NS_ORG="$sf_default"
    return 0
  fi
  echo "NS_ORG is unset and no default target-org configured." >&2
  echo "Set: export NS_ORG=northstar-dev  or  sf config set target-org=northstar-dev" >&2
  exit 1
}

# Echo a command, then run it. Every `sf` invocation goes through this so
# build logs are reproducible.
run() {
  echo "+ $*"
  "$@"
}
