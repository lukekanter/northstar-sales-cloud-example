# vendor/

This directory holds **disposable clones** of the upstream open-source
accelerators that the Northstar build vendors in. Per `docs/SPEC.md` §4 and §11
these accelerators are cloned from GitHub source (not installed from
AppExchange), reviewed, and then selectively copied into `force-app/` by the
per-accelerator integration issues (0033–0036).

## Why this folder is gitignored

The raw clones are large and change upstream; checking them in would bloat the
repo and blur the line between "our code" and "their code". `.gitignore`
therefore ignores everything under `vendor/` **except** this `README.md` and
`.gitkeep`, so the folder exists on a fresh checkout but stays empty until you
re-clone.

What _is_ tracked permanently:

- `LICENSES/` — exact copies of each accelerator's LICENSE (attribution that
  must survive even when the clones are wiped).
- `docs/package-integration-notes.md` — the repo URL, pinned commit SHA,
  license, and source folder for each accelerator.

## How to (re-)clone

```bash
./scripts/clone-vendor.sh
```

The script is idempotent and pins each clone to the reviewed commit SHA
recorded in `docs/package-integration-notes.md`. Wiping `vendor/` and re-running
the script restores the exact reviewed state.
