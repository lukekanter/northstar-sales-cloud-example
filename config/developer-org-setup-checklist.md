# Developer Edition manual Setup checklist

Salesforce Developer Edition orgs do not allow the following feature toggles
to be flipped via the Metadata API — every checkbox here has to be enabled
in Setup, in the browser, by hand. Work through them before deploying so
the org reflects an "everything-on" baseline.

The list is the same set referenced in `docs/deployment.md`.

## Required toggles

- [ ] **Quotes** — Setup → Quote Settings → check **Enable Quotes** → Save.
      This activates the `Quote` and `QuoteLineItem` objects required by
      issues 0013, 0022, 0033.
- [ ] **Orders** — Setup → Order Settings → check **Enable Orders** → Save.
      Required by issues 0014, 0023, 0034.
- [ ] **Contracts** — Setup → Contract Settings → confirm Contract Numbering
      is on and set the default contract term as desired. Contracts are
      enabled by default on DE; this is a confirmation, not a flip.
      Required by issues 0015, 0024.
- [ ] **State and Country Picklists** — Setup → State and Country/Territory
      Picklists → **Enable State and Country/Territory Picklists**
      (Configure → Activate). Required for realistic Account/Lead address
      data.
- [ ] **Collaborative Forecasting** — Setup → Forecast Settings →
      **Enable Forecasts**. Add the Opportunity Revenue forecast type.
      Required for the revenue scenarios.
- [ ] **Chatter** — Setup → Chatter Settings → confirm **Enable** is on
      (default on DE). Then Setup → Feed Tracking → enable feed tracking
      on Account, Opportunity, Lead, and Case so automation that posts to
      the feed has somewhere to land.

## Verification

Once all six toggles are on, retrieving the `Settings` metadata should
include `Quote.settings`, `Order.settings`, `Forecasting.settings`,
`AddressSettings.settings`, and `Chatter*.settings`:

```bash
sf project retrieve start \
  --metadata Settings \
  --target-org "$NS_ORG"
```

If any expected `*Settings` file is missing from the retrieve output, the
matching toggle is still off — go back to Setup.

## Status

Verified enabled on the current DE org and captured in `force-app/.../settings/`:

| Toggle                    | Settings file                   | Confirmed flag                              |
| ------------------------- | ------------------------------- | ------------------------------------------- |
| Quotes                    | `Quote.settings-meta.xml`       | `<enableQuote>true</enableQuote>`           |
| Orders                    | `Order.settings-meta.xml`       | `<enableOrders>true</enableOrders>`         |
| Contracts                 | `Contract.settings-meta.xml`    | present (enabled by default on DE)          |
| Collaborative Forecasting | `Forecasting.settings-meta.xml` | `<enableForecasts>true</enableForecasts>`   |
| State & Country Picklists | `Address.settings-meta.xml`     | org default `<orgDefault>true</orgDefault>` |
| Activities                | `Activities.settings-meta.xml`  | present, reminders/recurring enabled        |
| Chatter                   | `Chatter.settings-meta.xml`     | `<enableChatter>true</enableChatter>`       |

These files are committed as the deployable end state; on a brand-new org you
still flip the toggles above by hand first (a deploy can't enable them from a
disabled state).

## Action Plans permission sets

Action Plans V4 (integrated into `force-app/`) ships five
permission sets. They deploy with the package but are **not auto-assigned** —
grant the admin user access after the deploy:

```bash
# Minimum to administer/build Action Plans and templates:
sf org assign permset -n Action_Plans_Admin --target-org "$NS_ORG"

# The full set (assign as needed for the persona being tested):
#   Action_Plans_Admin            — full admin (objects, templates, settings)
#   Action_Plans_Creator          — create/run Action Plans
#   Action_Plans_Template_Creator — author Action Plan templates
#   Action_Plans_Import_Export     — import/export templates
#   Action_Plans_User             — view/work assigned Action Plan tasks
```

`Action_Plans_Admin` is the one the acceptance criteria call out; the others
are assigned per the persona you're exercising.

## Scheduling the async jobs

The async classes are deployed but **not auto-scheduled** (no CRON
metadata, per the issue non-goal). After deploying, schedule them once per org
from an anonymous Apex window (`sf apex run`), adjusting the cron expressions
to your maintenance window:

```apex
// Daily renewal-creation fallback — creates Renewal Opps for Activated
// contracts that have entered their per-tier renewal window.
System.schedule(
  'Northstar Renewal Creation (daily)',
  '0 0 2 * * ?',                       // 02:00 every day
  new RenewalCreationScheduler()
);

// Weekly contract health recalculation from open-case load.
System.schedule(
  'Northstar Contract Health Recalc (weekly)',
  '0 0 3 ? * SUN',                     // 03:00 every Sunday
  new ContractHealthRecalcBatch()
);
```

`ProvisioningCompletedSubscriber` needs no scheduling — it runs from the
`ProvisioningCompletedTrigger` whenever a `Provisioning_Completed__e` is
published. To verify the scheduled jobs: **Setup → Scheduled Jobs**, or
`SELECT CronJobDetail.Name, State, NextFireTime FROM CronTrigger`.
