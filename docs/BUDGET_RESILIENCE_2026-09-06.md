# Budget calculation resilience and local update procedure

The reported incident is persistent `DV-004` on Today and Plan after an update,
category changes, and unpinning/re-pinning. Retry did not recover the installed
book. The device's underlying failing record has not been inspected. This work
fixes independently reproduced defects and makes remaining failures actionable;
it does not certify the user's existing book or promise that every future error
is impossible.

## Changes and financial constraints

- Current-month checkpoints supply exact opening carry without requiring an
  unnecessary closed-month projection. Signed carry and merge mappings remain
  authoritative; earlier months still require complete spending history.
- Category labels and the ordering of unique monthly overrides do not determine
  whether two budget configurations agree. IDs, membership, parents, limits,
  allocation modes, purposes, pacing, rollover, and every override remain checked.
  This accepts legacy name-only differences without rewriting records or history.
- Reporting-time-zone changes reanchor civil reporting months and rollover
  activation months. Profile, live budget nodes, and configuration history commit
  in one SQLCipher transaction. Revision IDs, money, currency scopes, opening
  carries, mappings, transactions, and origin contexts remain unchanged.
- A zone change that would switch the current budget month is refused with an
  explanation. Invalid source history is not repaired by guessing its old zone.
- Pins and budget display preferences preserve valid financial caches. Other
  profile changes keep their existing invalidation rules. Widget publication is
  deferred until a lifecycle mutation has published its complete state.
- Plan waits for saves and discards superseded reads. Cancellation shows no
  calculation failure and cannot be mistaken for a malformed draft or history.
- Budget-projection failures are isolated from successfully calculated balances
  and spending reports. Failed shared reads stop automatic retry loops; an
  explicit retry starts a new attempt. A failed read does not become a false zero.
- Stable, non-financial diagnostic codes distinguish the failing area. Persistent
  history issues lead to Backup and recovery; temporary updates show progress.

No database schema change, transaction rewrite, or automatic destructive repair
is included.

## Diagnostics

| Code | Meaning |
|---|---|
| DV-004 | Unclassified budget calculation failure |
| DV-012 | Budget history or attribution integrity needs review |
| DV-013 | Current financial configuration disagrees with history |
| DV-014 | Invalid or incompatible reporting-month boundaries |
| DV-015 | Budget-history currency mismatch |
| DV-016 | Invalid category hierarchy or monthly configuration |
| DV-017 | Exact monetary arithmetic failed |
| DV-018 | Required data could not be read |
| DV-019 | A calculation is waiting for a save or data refresh |

These codes contain no amounts, names, notes, or record identifiers. Logging
retains the existing stable-operation/error-type boundary. In Backup and
recovery, budget history and attribution warnings are grouped with budgets.

## Regression coverage and execution evidence

`BudgetCheckpointAvailabilityTests` covers delayed refresh, upgrades, category
moves and renames, re-pinning, Today/Plan agreement, signed carry, mandatory prior
history, and reopening without changing transaction records.

`BudgetReportingConfigurationTests` checks meaningful configuration equality,
duplicate/missing nodes, financial mismatches, month boundaries, multiple time
zones including DST and the date line, and exact preservation of carry and IDs.

`BudgetResilienceTests` checks legacy label-only differences, strict financial
mismatch rejection, backup availability with inconsistent budget history, atomic
time-zone writes and failures, cache preservation during repeated pin/display
changes, draft/history cancellation safety, mutation-time reads, isolation of
budget failures, bounded retry, and payload-free diagnostic classification.

The iOS 26 review workflow includes both app regression classes. Full domain,
app-target, performance, and iOS 26 execution results for the exact candidate are
recorded in [PR #53](https://github.com/LaiWenKang/MoneyUp/pull/53). Test declarations
alone are not execution evidence. Simulator tests do not establish physical
unlock, migration, VoiceOver, or the integrity of the user's existing book.

## For the installed app

1. Preserve the current installation. Export an encrypted `.moneyup` backup to
   Files or your Mac, outside MoneyUp's own container, and keep the password.
   Backup export does not require the budget calculation to succeed. If export
   fails too, retain the exact error and keep the installation intact.
2. Install the fixed TestFlight build **over the existing app** after it has been
   uploaded and assigned to your tester group. A GitHub PR or green CI does not
   update an installed iPhone app. Confirm the build number in TestFlight.
3. On first unlock, check Today and Plan in the intended month and currency.
   Check existing amounts before making further budget changes. Verify an
   ordinary category rename and unpin/re-pin cycle leaves financial totals
   unchanged, then reopen once to check persistence.
4. If a history-review code remains, preserve the backup and share the code.
   The local diagnostic checker can inspect a copy and produce a redacted report;
   enter the backup password only in its hidden local prompt. Do not repeatedly
   restore the same inconsistent book, reset the app, or downgrade as a repair.
5. Before later beta updates or major category reorganizations, create a fresh
   encrypted backup. Keep reporting month and currency explicit. Test migration
   and category workflows on a separate development installation when possible.

Existing inconsistent financial history may still need a case-specific repair
based on the actual records. It must not be replaced by an inferred balance or
an older backup without reviewing the consequences.
