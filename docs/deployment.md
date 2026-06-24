# Deploying Northstar Cloud Systems to a fresh org

This is the clean-room install path: from an empty **Developer Edition** org to a
fully deployed, sample-data-seeded Northstar org.

## 1. Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`).
- [Node.js](https://nodejs.org/) + `npm` (for Prettier, ESLint, and LWC Jest).
- A Salesforce **Developer Edition** org (sign up at
  <https://developer.salesforce.com/signup>).

Install the local dev dependencies once:

```bash
npm install
```

## 2. Authenticate the org

```bash
sf org login web --alias northstar-dev --instance-url https://login.salesforce.com
sf config set target-org northstar-dev
```

## 3. Enable the manual Setup toggles

Some Sales Cloud features (Quotes, Orders, Forecasting, State & Country
picklists, …) cannot be turned on through the Metadata API — they must be
enabled by hand in Setup **before** deploying. Work through
[`config/developer-org-setup-checklist.md`](../config/developer-org-setup-checklist.md)
first.

## 4. Deploy the metadata

The dashboards use a placeholder running user that is substituted at deploy time
from your authenticated org, so you never have to hand-edit a username:

```bash
export NS_DASHBOARD_RUNNING_USER="$(sf org display --json | jq -r .result.username)"
sf project deploy start --source-dir force-app --test-level RunLocalTests
```

`NS_DASHBOARD_RUNNING_USER` is read by the `replacements` entry in
`sfdx-project.json` and swapped into the dashboard metadata during the deploy.

> The five vendored accelerators are already part of `force-app/`, so they ride
> this same deploy — there is nothing to install from AppExchange. (The
> `vendor/` clones produced by `scripts/clone-vendor.sh` are only an upstream
> reference; they are gitignored and not required to deploy.)

## 5. Post-deploy wiring

Grant the Action Plans permission sets and seed their org-default setting:

```bash
./scripts/deploy-vendor.sh
```

## 6. Seed the sample data (optional)

Load the eight sample scenarios (Leads → renewals → support) and verify the
expected automation fired:

```bash
./scripts/deploy-sample-data.sh
```

## 7. Validate-only (no writes)

To run the full pre-change gate (Prettier, ESLint, LWC Jest, and a check-only
deploy with local Apex tests) against the org without writing to it:

```bash
./scripts/validate.sh
```

## Notes & gotchas

- **Edition/features.** Built and tested on Developer Edition. The deploy runs
  local Apex tests (`RunLocalTests`); all packaged Apex meets the 75% coverage
  gate.
- **Dynamic dashboards.** Developer Edition caps dynamic dashboards at three.
  This build ships three dynamic dashboards and one static
  (`Northstar_Renewal_Risk`), whose running user is templatized as in step 4 so
  the deploy never references a user that doesn't exist in your org.
- **My Domain.** My Domain is org-specific and is not shipped — your org keeps
  its own.
- **Re-running.** The sample-data seed is idempotent and safe to re-run.
