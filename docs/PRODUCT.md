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

| Capability | Unified Founders Beta 0.6.0 source behavior |
|---|---|
| Privacy and security | No account or backend; encrypted local database; timed local authentication; redacted locked capture |
| First-run guidance | Four explicit steps: purpose/privacy, base currency, first financial account, and review; Today then offers visible Log and Plan actions |
| Visual system | Adaptive soft green, horned-money identity, original decorative 3D illustrations, exact 2D data graphics, guided empty states, and off-white/deep-charcoal canvases |
| Navigation | Five permanent tabs: Today, History, center Log, Plan, and Assets |
| Budget planner | Monthly nested limits classified as Flexible, Bills, Debt, or Goals; roll-up, dated rollover, sinking funds, savings goals, pace, explicit unbudgeted spending, and a read-only what-if simulator |
| Widgets | Configurable privacy-redacted entry points; locked basic capture; optional budget percentage/state shared through the single reviewed App Group with no financial record fields |
| Hierarchy | Arbitrary-depth model with group/category/subcategory roll-up |
| Insights | Category distribution, trailing monthly cash flow, plain-language readings, tap-to-inspect, and History drill-through |
| Today guidance | Flexible Today uses only explicitly flexible allocations and their commitments, plus separate cash, debt, and net-cash position |
| Finance calendar | Indexed actual flows plus recurring forecasts with edit, pause, end, skip, confirm, match, and exactly-once posting |
| Assets | Lifecycle-managed accounts/categories; ledger-linked holdings; dated prices; stale warnings; FIFO lots/disposals; currency-separated net-worth history |
| Portability | Posting-level CSV and native XLSX, mapped CSV/TSV import, encrypted receipt attachments, dated user FX rates, and authenticated `.moneyup` backup/restore |
| Easy logging | Amount-first center Log, encrypted drafts, smart defaults, refund, exact splits, date-indexed History/edit, and Undo; keyboard Done, Save, and tab navigation remain reachable |
| Smart entry | Responsive fast-first on-device receipt and screenshot reading with immediate progress and visible populated suggestions, typed-phrase parsing, and category suggestions learned from the user's own history |
| Scale architecture | SQLCipher schema-4 journal/posting indexes, compact exact balances, bounded recent activity, and on-demand History/Calendar/export loading |
| Languages | English and Simplified Chinese with locale-correct dates and amounts |

These rows describe source implementation in the unified candidate. They do
not close the exact-candidate Mac CI, physical iPhone, TestFlight, closed-beta,
or App Store gates. See [Golden PRD traceability](GOLDEN_TRACEABILITY.md).

## Product rules

- "Smart" features must be deterministic or on-device, explainable, and
  optional. Raw transactions are never sent to a remote language model.
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
