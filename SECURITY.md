# MoneyUp Security Policy and Threat Model

MoneyUp handles sensitive financial data. Security claims here distinguish
implemented controls from planned work and known limits.

## Founders Beta 0.6.0 source controls

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
| Opt-in App Group widget snapshot restricted to percentage/state only | Implemented; signing/device gate open |
| On-device receipt reading; optional metadata-stripped SQLCipher-encrypted retention; no upload | Implemented; exact-candidate and physical fixture evidence open |
| Plaintext CSV/XLSX warning and user-selected destination | Implemented |
| Destructive recovery reset with explicit confirmation | Implemented |
| App privacy manifest with no tracking or collected-data declarations | Implemented |
| System-backup exclusion for ciphertext whose key cannot migrate | Implemented |
| Confirmed deletion for transactions, schedules, and holdings | Implemented |
| Wrong-key, plaintext-leak, decimal round-trip, and atomic-rollback tests | Test coverage present; exact-candidate execution open |
| Separate encrypted, no-balance Quick Capture inbox while locked | Implemented |
| File-backed chunk-authenticated portable backup and transactional restore | Implemented with v1 compatibility and test coverage; exact-candidate/physical execution open |
| Previewable local CSV/Qianji import with atomic commit | Implemented with test coverage; exact-candidate execution open |
| SQLCipher schema-6 journal/posting/receipt/budget indexes, store metrics, and compact exact balances | Implemented; exact-candidate tests open |
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
and string matching over the user's own records. No remote model receives a
receipt, an amount, or a payee.

The opt-in budget-status widget does not change the network guarantee. The app
writes a versioned availability/state plus integer percentage to
`group.com.laiwenkang.MoneyUp`; the extension reads it locally. The snapshot
contains no amount, payee, account name, holding, balance, transaction, book,
or ledger identifier. Disabling the setting or erasing the profile scrubs it
and known legacy prototype keys.

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
6. If the protected key and database no longer match, the app refuses to read
   records. A separately confirmed reset removes the inaccessible database and
   key; it never guesses, downgrades encryption, or silently overwrites data.

## Storage and integrity

- SQLCipher is configured with cipher memory security, full synchronous writes,
  WAL journaling, secure deletion, and foreign-key enforcement.
- The database uses a versioned schema and rejects a schema newer than the app
  supports.
- Schema 6 stores journal/posting lookup indexes, exact account/currency balance
  rows, bounded receipt metadata, trigger-maintained store totals, and historical
  budget-attribution indexes inside SQLCipher. Routine mutations update each
  projection in the same transaction; rebuild is reserved for migration,
  restore, or repair.
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
rollback archive if post-commit loading fails. Legacy version-1 archives remain
readable within their compatibility limit and require near-limit physical-memory
measurement before release. MoneyUp cannot recover a forgotten archive
password. CSV and XLSX exports are readable and useful in Numbers or Excel, but
neither is a full-fidelity restore format. The live database directory remains
excluded from system backup because its device-bound key cannot migrate.

## App Group capability

Both `com.laiwenkang.MoneyUp` and `com.laiwenkang.MoneyUp.Widget` must carry the
single reviewed entitlement `group.com.laiwenkang.MoneyUp`. The release
validator rejects other source entitlements. The TestFlight workflow also
requires both embedded distribution profiles and both signed bundles to carry
exactly that group before Apple validation or upload. Registering and enabling
the capability in the Apple Developer account remains an account-holder gate.

## Reporting a vulnerability

Do not open a public issue containing exploit details, keys, financial data, or
private screenshots. Use GitHub private vulnerability reporting for this
repository when available. Otherwise, contact the repository owner through
their GitHub profile and exchange details privately.
