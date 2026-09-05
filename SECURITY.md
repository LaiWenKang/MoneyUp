# MoneyUp Security Policy and Threat Model

MoneyUp handles sensitive financial data. Security claims here distinguish
implemented controls from planned work and known limits.

## Founders Beta 0.7.1 source controls

"Implemented" below describes the source-integrated candidate. Exact-candidate
Mac CI, signed-entitlement inspection, physical-device checks, beta evidence,
and App Review remain separate release gates.

| Control | Status |
|---|---|
| Balanced domain model and validated decoding | Implemented with test coverage; exact-candidate execution open |
| No ads, financial telemetry, remote AI, or application backend | Implemented |
| SQLCipher 4.18 full-database encryption | Implemented and pinned |
| Random 256-bit app-generated, device-bound database key | Implemented |
| Non-synchronizing Keychain item with `WhenPasscodeSetThisDeviceOnly` and user presence | Implemented |
| Configurable timed auto-lock and decoded-state clearing | Implemented |
| App-switcher privacy cover while inactive | Implemented |
| iOS file protection for the database | Implemented |
| Privacy-redacted quick-action widget with no financial values | Implemented |
| Exact App Group allowlist: non-financial language preference, atomic schema-4 redacted summary, and bounded data-free quick-action ingress file | Implemented; signing/device gate open |
| On-device receipt reading; optional metadata-stripped SQLCipher-encrypted retention; no upload | Implemented; exact-candidate and physical fixture evidence open |
| Plaintext CSV/XLSX warning and user-selected destination | Implemented |
| Destructive recovery reset with explicit confirmation | Implemented |
| App privacy manifest with no tracking or collected-data declarations | Implemented |
| System-backup exclusion for ciphertext whose key cannot migrate | Implemented |
| Confirmed deletion for transactions, schedules, and holdings | Implemented |
| Wrong-key, plaintext-leak, decimal round-trip, and atomic-rollback tests | Test coverage present; exact-candidate execution open |
| Separate encrypted, no-balance Quick Capture inbox while locked | Implemented |
| File-backed chunk-authenticated portable backup and transactional restore | Implemented with v1 compatibility and test coverage; exact-candidate/physical execution open |
| Missing-device-key detection and keyless `.moneyup` recovery transaction | Implemented with isolated validation, crash-resume, and rollback tests; physical passcode-removal drill open |
| Previewable local CSV/Qianji import with atomic commit | Implemented with test coverage; exact-candidate execution open |
| SQLCipher schema-9 journal/posting/receipt/budget/intelligence/evidence indexes, store metrics, and compact exact balances | Implemented; exact-candidate tests open |
| Optional explainable local intelligence with review-only actions and derived-data opt-out clearing | Implemented; exact-candidate and physical review open |
| Default-on, explicitly opt-out Foundation Models ordinal matching over at most 16 existing names per list, with no financial/free-text output | Implemented; Xcode 26 compile and eligible-device behavior gates open |
| Optional end-to-end-encrypted device sync | Explicitly deferred from 1.0 |

## Privacy guarantee

MoneyUp does not operate a runtime service that receives raw financial records.
The app processes records locally and makes no financial-data network request.
Data leaves the app only when the user invokes an export and chooses a
destination.

Smart entry does not change this. Receipt text recognition runs through the
on-device Vision framework. The selected source is transient by default. When
the user explicitly enables encrypted retention, MoneyUp applies orientation,
bounds the longest edge, and re-encodes new JPEG/PNG pixels without copying GPS,
EXIF, TIFF device, caption, or edit-history metadata into SQLCipher. The image
never enters a draft, diagnostic log, widget, CSV, or XLSX export and is never
transmitted. Typed-phrase parsing and category suggestions are plain arithmetic
and string matching over the user's own records. On eligible devices, Apple's
default on-device system language model is enabled unless the user opts out and
receives only a bounded context after
parsed financial spans are removed plus at most 16 existing local names per
list. Its generated shape contains only literal-range ordinals; it receives no
image or receipt bytes and cannot return any financial field or free text. Unavailability,
cancellation, error, staleness, or an invalid ordinal preserves the exact-rule
result. No remote model receives a receipt, an amount, or a payee.

The App Group does not change the network guarantee. Its exact allowlist is the
non-financial app-language preference, one atomic schema-4 redacted Budget
Status/Smart Overview value, and one bounded data-free quick-action ingress
file. The snapshot may contain state, a bounded reporting-period token, bounded
budget and allowance percentages, bounded review and active expense-commitment
counts, expiry, and a reporting-calendar-derived relative due-day distance. The
ingress file may contain only its schema/authority metadata, admission state,
opaque handoff tokens, and one of six closed action values. Neither artifact may
contain an exact due date, amount, payee, account name, holding, symbol, quote,
balance, transaction/book/ledger identifier, note, attachment, or extracted
evidence. No other App Group key or file is approved. Disabling summaries or
erasing the profile scrubs the summary and known legacy prototype keys;
authoritative erase/restore boundaries invalidate old quick-action ingress.

The guarantee does not cover:

- a compromised, jailbroken, or maliciously managed operating system;
- another person looking at the device while it is unlocked and MoneyUp is
  already open;
- screenshots, screen recordings, or readable CSV/XLSX exports created by the user;
- disclosure by the spreadsheet, cloud drive, or recipient selected after
  export;
- device passcodes or biometrics shared with another person;
- source-build or dependency modifications made outside this repository.

## Key lifecycle

1. On first launch, MoneyUp generates 32 random bytes with the system secure
   random generator.
2. The key is stored in the app's Keychain namespace. It does not synchronize
   and becomes unavailable if the device passcode is removed.
3. Subsequent reads require Face ID, Touch ID, or the device passcode through a
   local-authentication context.
4. The key opens SQLCipher only after authentication. The temporary Swift
   buffer is overwritten immediately after the store opens.
5. When the configured auto-lock delay expires (one minute by default), the app
   flushes the latest Log form/defaults to SQLCipher, closes the store, drops
   decoded models, and returns to the locked screen. The app-switcher cover is
   immediate. Receipt images are never part of the draft. When retention is
   explicitly selected, the encrypted attachment, transaction, and removal of
   its pre-save draft are committed in one database transaction.
6. Removing the device passcode can permanently destroy the this-device-only
   key; deleting MoneyUp removes both its key and local ciphertext. MoneyUp
   warns about both cliffs during setup, in Security and Data Safety, and until
   the first portable backup is exported.
7. If the Keychain item is missing beside any surviving main/WAL/SHM artifact,
   MoneyUp publishes a dedicated device-key recovery state. It never creates a
   replacement key beside that ciphertext and never labels the book as empty.
8. In that state, a user first ensures the device has a passcode, then can
   restore a password-protected `.moneyup` archive. MoneyUp copies and fully
   validates it in an isolated randomly keyed
   SQLCipher store before any live mutation. Wrong password, tamper,
   cancellation, or validation failure leaves the old ciphertext and Keychain
   untouched. After validation, a non-secret artifact-mask marker,
   device-bound replacement key, and same-volume file transaction let startup
   finish or roll back every interruption. Both immediate completion and
   startup resume recheck that the old-book capture inbox is empty before
   removing the marker; a late capture forces rollback. The external archive
   is never modified. A separately confirmed erase remains the last resort.

## Storage and integrity

- SQLCipher is configured with cipher memory security, full synchronous writes,
  WAL journaling, secure deletion, and foreign-key enforcement.
- The database uses a versioned schema and rejects a schema newer than the app
  supports.
- Schema 9 stores journal/posting lookup indexes, exact account/currency balance
  rows, bounded receipt metadata and evidence-search fields, trigger-maintained
  store totals, historical budget-attribution indexes, derived intelligence
  indexes, and additive loan/allowance records inside SQLCipher. Routine
  mutations update each
  projection in the same transaction; rebuild is reserved for migration,
  restore, or repair.
- Allowance archive history is additive inside the existing schema-9 encrypted
  payload and does not require a SQL migration. Current-format plans bind a
  supported per-plan marker, effective-dated transition timeline, and current
  state; partial, null, unsupported, unordered, or inconsistent forms fail
  closed. Fully legacy archived records infer the earliest boundary consistent
  with plan start, usage, and reconciliation evidence. A forged payload stripped
  of both new fields is indistinguishable from that genuine legacy shape under
  backward compatibility; SQLCipher and authenticated archive provenance, not
  the additive marker alone, is the security boundary.
- Every live negative posting from a restricted-allowance account must have
  exactly one semantically valid usage or expiry authorization. Normal recovery
  uses the complete normalized history of affected restricted accounts plus
  referenced evidence, converges account/plan/journal quarantine to a monotonic
  fixed point, and retains all raw encrypted rows. Invalid prepaid evidence is
  excluded with its plan; an ordinary benefit-limit or reimbursement expense is
  retained when only its allowance metadata is invalid. Strict restore rejects
  the equivalent candidate instead of installing a partial graph.
- Reimbursement status is evidence-only and forward-only: pending may become
  approved or rejected, approved may become reimbursed, and terminal states do
  not reopen. Those updates never create a receivable, deposit, cash movement,
  income, or journal mutation; actual incoming money uses the ordinary ledger
  workflow.
- Normal unlock retains only bounded recent activity plus compact reference and
  balance state; whole-book operations page from the encrypted store on demand.
- Multi-record setup and reconciliation operations use a single immediate
  transaction and roll back as a unit on failure.
- Decoding revalidates monetary and ledger invariants. App startup additionally
  checks category hierarchy and all account references before showing data.
- User-controlled CSV cells that could be interpreted as spreadsheet formulas
  are neutralized before export; native XLSX emits user text only as inline
  string cells and never as formulas.

## Portable recovery and remaining limits

The live Keychain key uses a this-device-only policy. Before deleting the app or
changing devices, the user can create a `.moneyup` archive encrypted and
authenticated with an independent password. Version 2 streams a SQL cursor into
independently authenticated 1 MiB AES-GCM chunks and binds the header, index,
length, and total chunk count; production export/import remains file-backed.
Current writes enforce the archive's 100,000-record/512 MB stored-payload
envelope. Restore validates in an isolated SQLCipher store, replaces the live
logical store transactionally, and uses a separate encrypted file-backed
rollback archive if post-commit loading fails. Confirmation is available only
after full isolated validation and a privacy-safe replacement preview. Its
ticket binds the preview to the staged ciphertext SHA-256; commit verifies a
bounded private copy against that digest before touching the live store. Cancel,
wrong password, tamper, unsupported schema, or a staged-file swap therefore
cannot reach replacement and never modifies the user-selected archive.
Before candidate-model load, a stable-order SQL cursor reduces stored rows into
bounded validation state with cooperative cancellation; production restore does
not materialize a second whole-book snapshot. Nested allowance history is
screened before domain decode at 4,096 usages, 4,096 reconciliations, and 512
archive transitions per plan; aggregate usage, reconciliation, archive-transition,
and cadence-period work is each capped at 100,000. A plan may require at most
`10,000 + 2 × maxPolicyRevisions` period work (11,024 at the 512-revision cap),
and weekday work is counted exactly in constant time from weekdays rather than
calendar-day iteration. Relationship validation then rejects unauthorized, multiply claimed,
or semantically mismatched restricted debits before replacement. Exact-candidate
near-limit runtime and peak-memory evidence remains a production release gate.
Staging, validation, verified-commit, and rollback ciphertext ownership is
deterministic, permission-bound, and scavenged exactly on startup so
interruption cannot accumulate artifacts. The rollback archive and a writer
interrupted mid-export remain inside one private owned directory. Legacy
version-1 archives remain readable within their compatibility limit and require
near-limit physical-memory measurement before release. MoneyUp cannot recover a
forgotten archive password. CSV and XLSX exports are readable and useful in
Numbers or Excel, but neither is a full-fidelity restore format. The live
database directory remains excluded from system backup because its device-bound
key cannot migrate.

When the live key is already missing, restore uses a separate filesystem
transaction because the old logical store cannot open. The candidate remains
SQLCipher-encrypted throughout, no password or replacement key enters the
manifest, and old ciphertext is retained until the installed candidate opens
and passes the normal strict domain load. The reviewed ticket is privately
reverified before key creation; preview copy states that current counts are
inaccessible. Marker removal is the authority boundary for restored capture
preference/promotion, ready state, widget, and intelligence. Physical
passcode-removal and interruption evidence is still a release gate; this source
implementation does not claim that device result.

## App Group capability

Both `com.laiwenkang.MoneyUp` and `com.laiwenkang.MoneyUp.Widget` must carry the
single reviewed entitlement `group.com.laiwenkang.MoneyUp`. The release
validator rejects other source entitlements. The TestFlight workflow also
requires both embedded distribution profiles and both signed bundles to carry
exactly that group before Apple validation or upload. Registering and enabling
the capability in the Apple Developer account remains an account-holder gate.
Within that container, the only approved artifacts are the language preference,
the single schema-4 widget-summary value, and the bounded quick-action ingress
file; adding any key, file, or field requires a new privacy review and gate.

## Reporting a vulnerability

Do not open a public issue containing exploit details, keys, financial data, or
private screenshots. Use GitHub private vulnerability reporting for this
repository when available. Otherwise, contact the repository owner through
their GitHub profile and exchange details privately.
