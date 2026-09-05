# Product Definition

## North star

MoneyUp is a private, local-first personal finance system that makes detailed
logging easy enough to sustain and turns those records into clear budgeting
decisions.

The daily loop is:

1. Record an expense, income, or transfer in seconds.
2. See its effect on account balances and nested budgets immediately.
3. Understand today's plan-paced flexible amount, cash versus debt, budget pace, and
   what is scheduled next.
4. Retain ownership through documented exports, password-protected portable
   backups, and reviewed imports.

## Target user

The first version serves one person managing multiple currencies, bank and cash
accounts, cards, brokerages, and manually valued, ledger-linked investments.
Household sharing and multi-device sync are excluded until a separate
end-to-end encryption and authorization design is approved.

## Core capabilities

| Capability | Current source behavior |
|---|---|
| Privacy and security | No account or backend; encrypted local database; timed local authentication; redacted locked capture |
| First-run guidance | Four explicit steps: purpose/privacy, base currency, first financial account, and review; Today then offers visible Log and Plan actions |
| Visual system | Adaptive soft green, horned-money identity, original decorative 3D illustrations, exact 2D data graphics, guided empty states, and off-white/deep-charcoal canvases |
| Navigation | Five permanent tabs: Today, History, center Log, Plan, and Assets; the fixed tab bar is the only global tab-navigation control, preserving child gestures; Plan and History use compact adaptive selectors and contextual screens show Back only for a real origin |
| Budget planner | Monthly nested limits classified as Flexible, Bills, Debt, or Goals; roll-up, dated rollover, sinking funds, savings goals, selectable daily/weekly/monthly pace, explicit unbudgeted spending, and a read-only what-if simulator |
| Widgets | Configurable Quick Actions, Budget Status, and Smart Overview for supported Home/Lock families; accessibility Dynamic Type reduces Home density; active/day-boundary refresh preserves reporting-day meaning; absent summary is disabled while present corrupt/future/oversized/contradictory/negative content is wholly stale and extension reads never repair storage; the App Group allowlist is exactly language preference, one bounded atomic summary, and one bounded data-free action-ingress file, with no fourth artifact |
| Hierarchy | Arbitrary-depth model with group/category/subcategory roll-up |
| Insights | Category distribution, trailing monthly cash flow, plain-language readings, tap-to-inspect, History drill-through, and optional explainable local findings |
| Today guidance | Flexible Today shows current-day, next-seven-day, and remaining-period flexibility with days and reserved commitments, plus separate cash, debt, and net-cash position |
| Finance calendar | Indexed actual flows plus recurring forecasts with edit, pause, end, skip, confirm, match, and exactly-once posting |
| Assets | Lifecycle-managed accounts/categories; ledger-linked holdings; dated manual prices; stale warnings; FIFO lots/disposals; currency-separated net-worth history; provider-neutral quote contracts remain inactive/manual-only, allow zero only as an explicit manual/manual-legacy write-down, and require bound source/dedupe/request/provider/currency provenance before any future observation can be used |
| Allowances | Benefit limits remain planning-only, prepaid plans exclusively link already-funded same-currency restricted assets, and reimbursement status is evidence-only; policy-zone civil dates, revisions, claim actions, usage corrections, and restricted/unrestricted presentation remain explicit |
| Portability | Posting-level CSV and native XLSX, mapped CSV/TSV import, metadata-stripped encrypted image/PDF attachments, dated user FX rates, and file-backed chunk-authenticated `.moneyup` backup/restore |
| Easy logging | Stable amount-first center Log, encrypted drafts, up to five images/PDFs, smart defaults, title-or-merchant, notes, refund, exact smart splits, allowance linking, History/edit, and Undo; keyboard Done and Save remain reachable |
| Smart entry | Responsive on-device receipt/screenshot reading, deterministic typed-phrase parsing, explainable evidence search across OCR/PDF text and visual labels, history-based suggestions, and optional review-first Apple on-device matching among at most 16 existing local accounts or categories |
| Configurability | Add or manage categories directly from Log; search full paths, add a child from any active row, and rename, reparent, archive/restore, merge, reassign, or delete arbitrary-depth categories |
| Intelligence | Optional deterministic recurrence/lapse/price, duplicate, anomaly, per-currency projection, and budget-proposal tools; every result is reviewable and local |
| Scale architecture | SQLCipher schema-9 journal/posting/evidence/budget/intelligence indexes plus loan/allowance collections, trigger-maintained store metrics, compact balances, monthly rollover checkpoints, bounded recent activity, and on-demand History/Calendar/export/intelligence loading |
| State architecture | Per-property Observation tracking with injected Ledger, Planning, Assets, Portability, Capture, and Intelligence state services; `AppModel` retains lock and cross-service transaction coordination |
| Languages | English and Simplified Chinese with locale-correct dates and amounts; Settings can follow the iPhone or override the app/widget language |

These rows describe source implementation in the unified candidate. They do
not close the exact-candidate Mac CI, physical iPhone, TestFlight, closed-beta,
or App Store gates. See [Golden PRD traceability](GOLDEN_TRACEABILITY.md).

The merged 0.7.0 W1 state migration was deliberately behavior-neutral. W2 uses
those service seams for optional, local intelligence and answers the approved
configurability delta: app-language choice, visible transaction title/details,
category creation from Log, and full category management. The existing
`JournalEntry.payee` and `note` fields retain compatibility: the UI presents
them as title-or-merchant and description-or-notes rather than adding a second
ambiguous transaction-title payload.

## Product rules

- "Smart" features must be deterministic or on-device, explainable, and
  optional. Raw transactions are never sent to a remote language model.
- Eligible Foundation Models assistance is on by default with an explicit
  opt-out. The deterministic parser alone owns amount, date, currency,
  merchant text, and save behavior; the default on-device system model may
  return only a bounded ordinal into a
  stable list of existing names, and failure leaves the parser result intact.
  Accepting a match immediately updates the recoverable encrypted draft; no
  transaction exists until the user taps Save.
- Intelligence findings are advice for review, not autonomous financial
  actions. Schedule offers remain editable until the user saves them, and a
  budget proposal changes nothing until the user accepts an explicit diff.
- Categories answer **why money moved**. Accounts answer **where money lives**.
  Tags capture context and must not replace either hierarchy.
- A credit card is a liability account. A debit card is a payment instrument
  linked to an asset account.
- Asset account setup asks for the current balance and permits an explained
  negative overdraft. Card and loan setup asks for a non-negative amount owed.
- Every unfamiliar flow explains what the choice means, why it matters, what
  is required, and the next action; a disabled control must never be the only
  explanation of what is wrong.
- Soft green identifies MoneyUp and positive directional graphics. Semantic
  surfaces adapt to light/dark mode without pure white or pure black as the
  primary canvas. Dimensional artwork is decorative only; charts, diagrams,
  simulator results, labels, and accessibility values remain precise 2D data.
- Transfers, credit-card repayments, and investment funding are not expenses.
- A budget limit is a cap, not proof that the money is discretionary. Only an
  allocation explicitly classified as Flexible contributes to Flexible Today;
  unclassified upgrades show a setup state instead of a number.
- A scheduled item remains a forecast until posted or matched to an actual
  transaction.
- The app database is the source of truth. Spreadsheets are exports or reviewed
  imports, not live writable replicas.
- The first public version is free. StoreKit, CloudKit sync, automatic market
  prices, bank aggregation, shared books, remote AI, and two-way spreadsheet
  editing are outside the approved 1.0 boundary.

## Initial quality targets

- Median routine expense entry below eight seconds after onboarding.
- No financial-data network requests in strict local mode.
- Journal balance invariant holds for every committed entry and every currency.
- Budget parent totals exactly equal direct plus descendant spending.
- Encrypted archive round trips retain identifiers, decimal values, currencies,
  and timestamps without drift; CSV import is explicitly a reviewed migration,
  not a full-fidelity restore.
- Core screens and workflows pass English and Simplified Chinese UI checks.
- Sensitive content is absent from logs, notifications, lock-screen widgets,
  and app-switcher snapshots by default.
- Performance budgets and the seven-day usability target are promotion gates
  measured on the exact candidate; source configuration alone does not pass
  them.
