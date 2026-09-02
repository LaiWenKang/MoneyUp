# MoneyUp 0.7.1 — Complete Feedback Follow-up

Source identity: **Founders Beta 0.7.1, build 10**.

This release includes every nonblank item from the 0.6.0 feedback list while
preserving MoneyUp's local-only, encrypted, exact-Decimal, balanced-ledger, and
five-tab product contracts.

| Feedback | 0.7.1 behavior |
|---|---|
| Keyboard blocks lower Log fields | Quick Log follows focus inside a scroll reader, keeps amount/account/title/notes/split fields reachable, supports interactive keyboard dismissal and the Done toolbar, and preserves the draft. |
| Date/time and categories are not smart defaults | A new untouched capture uses the actual injected current time. Defaults prefer a still-valid user setting, then deterministic local payee affinity, then an active leaf category; every field stays editable. |
| Widget capture needs categories and details | Authenticated widget and shortcut actions open the same full Quick Log, including account, category, title, notes, date/time, transfer, and splits. While the protected book is locked, the separate encrypted inbox accepts amount plus optional title/notes and offers “Unlock and review now”; protected account/category IDs are chosen only after intentional unlock. |
| Title/description/notes matter in History | History rows show title or merchant, notes, and the complete hierarchical category path. The same values remain searchable and editable. |
| History should be smarter and retain Calendar | History opens on Today with complete spending, income, refunds, and signed net totals per currency. Seven days, Month, All, advanced filters, paging, and direct Calendar access remain available. |
| Minimal, advanced, professional | Existing five-tab navigation is unchanged. The new capability lives in compact segmented scopes, inline pace labels, and dedicated Loan/Benefits drill-downs rather than new permanent tabs or dashboards. |
| Loan and repayment tracking | Loan Center attaches a plan to a loan liability account and shows remaining principal, total advanced, principal paid, interest, fees, opening date, APR, term, debt-total inclusion, repayment/drawdown history, notes, and finish-at-zero. Repayments separate principal, interest, and fees and post one balanced journal entry. |
| Daily-expiring company allowances | Benefits supports daily, weekdays-only, weekly, or monthly cadence; start/end dates; eligible expense categories; usage notes/history; and no, capped, or full rollover. Daily plus no rollover expires unused value each day. Allowances are planning-only and never create fake income or net worth. |
| Divide monthly plans into daily/weekly guidance | Each flexible budget node can remain Monthly or expose an exact Daily/Weekly pace from the positive remainder and remaining civil days. The amount is currency-rounded once and never changes the actual monthly budget. |
| More detailed subcategories | Expense and income categories support arbitrary depth, display full paths, and can be safely reparented. Kind mismatches and parent cycles are rejected; expense budget relationships update atomically. |

## Accounting and privacy decisions

- Loan principal remains authoritative in the liability ledger account. Loan
  metadata never becomes a competing balance.
- Interest and fees are explicit expense postings. A repayment cannot silently
  overpay principal, and a loan cannot close above zero.
- Allowances are benefits, not money owned by the user. Logging their use alone
  does not change cash, income, spending, or net worth.
- No remote model, analytics SDK, backend, currency conversion, or tracking was
  added. Smart defaults use only deterministic on-device data.
- Amounts remain exact `Decimal`; all journal entries balance independently by
  currency; currencies are never silently mixed or converted.

## Release evidence

Locally completed on this source candidate:

- release-asset validation, including 1,258 bilingual strings;
- architecture and Swift structure fitness;
- offline/privacy/recovery mutation gates;
- 55 Python adversarial validator tests;
- 742 declared Swift tests: 692 XCTest and 50 Swift Testing declarations;
- clean patch whitespace validation.

Still required on the exact release-truth commit:

- macOS Xcode build and all Swift test targets in GitHub Actions;
- unsigned app/widget Simulator build;
- signed archive and TestFlight processing;
- physical iPhone keyboard, migration, restore, accessibility, performance,
  widget, lock-state, bilingual, and seven-day beta evidence.

Source implementation or declared tests must not be reported as physical or
signed evidence.
