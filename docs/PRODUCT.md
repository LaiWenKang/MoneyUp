# Product Definition

## North star

MoneyUp is a private, local-first personal finance system that makes detailed
logging easy enough to sustain and turns those records into clear budgeting
decisions.

The daily loop is:

1. Record an expense, income, or transfer in seconds.
2. See its effect on account balances and nested budgets immediately.
3. Understand what is safe to spend today, cash versus debt, budget pace, and
   what is scheduled next.
4. Retain ownership through documented exports; add portable encrypted backup
   through password-protected backups and reviewed imports.

## Target user

The first version serves one person managing multiple currencies, bank and cash
accounts, cards, brokerages, and manually valued investments. Household sharing
is excluded until a separate end-to-end encryption and authorization design is
approved.

## Core capabilities

| Capability | Founders Beta 0.5.0 behavior |
|---|---|
| Privacy and security | No account or backend; encrypted local database; timed local authentication; redacted locked capture |
| First-run guidance | Four explicit steps: purpose/privacy, base currency, first financial account, and review; Today then offers visible Log and Plan actions |
| Visual system | Adaptive soft green, horned-money identity, original decorative 3D illustrations, exact 2D data graphics, guided empty states, and off-white/deep-charcoal canvases |
| Navigation | Five permanent tabs: Today, History, center Log, Plan, and Assets |
| Budget planner | Monthly nested limits, roll-up, pace, explicit unbudgeted spending, and a read-only what-if simulator |
| Widgets | Configurable, privacy-redacted Home and Lock Screen entry points |
| Hierarchy | Arbitrary-depth model with group/category/subcategory roll-up |
| Insights | Category distribution, trailing monthly cash flow, plain-language readings, tap-to-inspect, and History drill-through |
| Today guidance | Safe to Spend arithmetic, scheduled commitments and exclusions, plus separate cash, debt, and net-cash position |
| Finance calendar | Actual transactions and recurring projected occurrences |
| Assets | Assets, liabilities, cards, loans, accounts, and manual holdings |
| Portability | Enriched CSV export, authenticated `.moneyup` backup/restore, and preview-first Qianji/generic CSV import |
| Easy logging | Center Log tab, amount first, encrypted drafts, smart defaults, refund, History/edit, and Undo |
| Smart entry | On-device receipt and screenshot reading, typed-phrase parsing, and category suggestions learned from the user's own history |
| Languages | English and Simplified Chinese with locale-correct dates and amounts |

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
- A scheduled item remains a forecast until posted or matched to an actual
  transaction.
- The app database is the source of truth. Spreadsheets are exports or reviewed
  imports, not live writable replicas.

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
