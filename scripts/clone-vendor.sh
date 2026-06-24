#!/usr/bin/env bash
#
# clone-vendor.sh — fetch the five upstream accelerators into vendor/ at the
# commit hashes that were reviewed for this project. Idempotent: re-running
# fetches and checks out the pinned SHA whether or not the clone already exists.
#
# vendor/ is gitignored (see .gitignore). These clones are disposable — the
# permanent attribution lives in LICENSES/.
# No vendor source is copied into force-app/ here; that happens per-accelerator
# in issues 0033–0036.
#
# Usage:  ./scripts/clone-vendor.sh
#
set -euo pipefail

# Resolve repo root from this script's location so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor"

# accelerator dir | git url | pinned upstream commit SHA
# SHAs pin the versions reviewed on 2026-05-20; bump intentionally in the
# per-accelerator integration issues and update package-integration-notes.md.
VENDORS=(
  "Quicker-Quotes|https://github.com/SalesforceLabs/Quicker-Quotes.git|d1c406ea12a29b2c47f8c09ee135841cd1fd71b5"
  "sfdc-generate-order|https://github.com/caretgrowth/sfdc-generate-order.git|81ba86113cb379a8b7558ddff1f4b23f809e933d"
  "sfdc-copy-oli-fields-to-qli|https://github.com/douglascayers/sfdc-copy-opportunity-line-item-custom-fields-to-quote-line-items.git|17c53b4e564bc06940667de708fe5421573d9499"
  "ActionPlansV4|https://github.com/SalesforceLabs/ActionPlansV4.git|ef5a417a3fd243ee9c0e2dead1b9e4a7dcbd6fe8"
  "sfdc-trigger-framework|https://github.com/kevinohara80/sfdc-trigger-framework.git|b7e36c76a3608674979e44fe3a823b55016fff7c"
)

mkdir -p "$VENDOR_DIR"

clone_or_pin() {
  local dir="$1" url="$2" sha="$3"
  local target="$VENDOR_DIR/$dir"

  if [ ! -d "$target/.git" ]; then
    echo "→ cloning $dir"
    # Shallow clone of the default branch, then fetch the exact pinned SHA so
    # the checkout is reproducible regardless of where the branch has moved.
    git clone --depth 1 "$url" "$target"
  else
    echo "→ updating $dir"
  fi

  echo "  pinning $dir @ $sha"
  # Fetch just the pinned commit (works even on a shallow clone) and check it
  # out detached. If the SHA is already present this is a no-op.
  if ! git -C "$target" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    git -C "$target" fetch --depth 1 origin "$sha"
  fi
  git -C "$target" checkout --quiet --detach "$sha"
}

for entry in "${VENDORS[@]}"; do
  IFS='|' read -r dir url sha <<<"$entry"
  clone_or_pin "$dir" "$url" "$sha"
done

echo
echo "Done. vendor/ now contains:"
# Plain ls (bypass any user alias) for stable, scriptable output.
command ls -1 "$VENDOR_DIR"
