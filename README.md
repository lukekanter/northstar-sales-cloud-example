# Northstar Cloud Systems — example Sales Cloud org

**Looking for a realistic, openly available Salesforce org to test a tool, app,
or managed package against under production-like conditions — before pointing it
at a real production org?** That's exactly what this repository is.

A source-controlled Salesforce **Sales Cloud** org for a fictional mid-market
B2B SaaS company, **Northstar Cloud Systems**. It models a realistic RevOps
subscription business end to end: Leads → qualification/conversion →
Opportunities → Products → Quotes → approvals → Orders → Contracts →
provisioning → renewals → support/escalation.

The org is intentionally **realistic rather than pristine** — it blends
declarative automation (flows, validation rules) with an Apex trigger
framework, integrates several open-source accelerators from source, and carries
the kind of overlapping, evolved automation a real org accumulates over time.

## What it's good for

- A realistic target for **testing org-analysis and metadata tooling** against
  something closer to a production org than a sample app.
- A plausible environment for **testing org-agnostic Salesforce features and
  managed packages** before installing them somewhere that matters.
- A reference for a moderately complex, source-deployable Sales Cloud build.

## Quick start

Deploys to a fresh **Developer Edition** org. You need the
[Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`),
[Node.js](https://nodejs.org/) + `npm`, and `jq`.

```bash
# 1. Install local dev tooling (Prettier, ESLint, LWC Jest)
npm install

# 2. Authenticate your Developer Edition org
sf org login web --alias northstar-dev --instance-url https://login.salesforce.com
sf config set target-org northstar-dev

# 3. Enable the manual Setup toggles that can't be set via metadata
#    (Quotes, Orders, Forecasting, State & Country picklists, …) — see
#    config/developer-org-setup-checklist.md

# 4. Deploy. The static dashboard's running user is filled in from your org,
#    so you never hand-edit a username.
export NS_DASHBOARD_RUNNING_USER="$(sf org display --json | jq -r .result.username)"
sf project deploy start --source-dir force-app --test-level RunLocalTests

# 5. Post-deploy wiring (Action Plans permission sets) and optional sample data
./scripts/deploy-vendor.sh
./scripts/deploy-sample-data.sh
```

The five vendored accelerators are already part of `force-app/`, so they deploy
with everything else — nothing to install from AppExchange. For the full
step-by-step walkthrough, edition notes, and gotchas, see
[docs/deployment.md](docs/deployment.md).

## Vendored accelerators & licenses

Five upstream open-source projects are integrated from source; each keeps its
license under [LICENSES/](LICENSES/). Provenance (repo, pinned commit, license,
and what changed vs upstream) is documented in
[docs/package-integration-notes.md](docs/package-integration-notes.md).

| Accelerator            | Upstream                                                    | License      |
| ---------------------- | ----------------------------------------------------------- | ------------ |
| Quicker Quotes         | SalesforceLabs/Quicker-Quotes                               | BSD 3-Clause |
| Generate Order         | caretgrowth/sfdc-generate-order                             | MIT          |
| Copy OLI fields to QLI | douglascayers/sfdc-copy-opportunity-line-item-custom-fields | BSD 3-Clause |
| Action Plans V4        | SalesforceLabs/ActionPlansV4                                | BSD 3-Clause |
| Trigger framework      | kevinohara80/sfdc-trigger-framework                         | MIT          |

## License

The original metadata and code in this repository are released under the
[MIT License](LICENSE). The five vendored components above retain their own
upstream licenses under [LICENSES/](LICENSES/).
