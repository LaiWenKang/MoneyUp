# MoneyUp Security Policy and Threat Model

MoneyUp handles sensitive financial data. Security claims here distinguish
implemented controls from planned work and known limits.

## Founders Beta 0.4.1 controls

| Control | Status |
|---|---|
| Balanced domain model and validated decoding | Implemented and tested |
| No ads, financial telemetry, remote AI, or application backend | Implemented |
| SQLCipher 4.18 full-database encryption | Implemented and pinned |
| Random 256-bit app-generated, device-bound database key | Implemented |
| Non-synchronizing Keychain item with `WhenPasscodeSetThisDeviceOnly` and user presence | Implemented |
| Configurable timed auto-lock and decoded-state clearing | Implemented |
| App-switcher privacy cover while inactive | Implemented |
| iOS file protection for the database | Implemented |
| Privacy-redacted widget with no financial values | Implemented |
| On-device receipt reading with no image retention or upload | Implemented |
| Plaintext CSV warning and user-selected destination | Implemented |
| Destructive recovery reset with explicit confirmation | Implemented |
| App privacy manifest with no tracking or collected-data declarations | Implemented |
| System-backup exclusion for ciphertext whose key cannot migrate | Implemented |
| Confirmed deletion for transactions, schedules, and holdings | Implemented |
| Wrong-key, plaintext-leak, decimal round-trip, and atomic-rollback tests | Implemented |
| Separate encrypted, no-balance Quick Capture inbox while locked | Implemented |
| Password-protected portable backup and transactional restore | Implemented and tested |
| Previewable local CSV/Qianji import with atomic commit | Implemented and tested |
| Optional end-to-end-encrypted device sync | Not implemented |

## Privacy guarantee

MoneyUp does not operate a runtime service that receives raw financial records.
The app processes records locally and makes no financial-data network request.
Data leaves the app only when the user invokes an export and chooses a
destination.

Smart entry does not change this. Receipt text recognition runs through the
on-device Vision framework, the selected image is held only long enough to
read it and is never written to the database or transmitted, and typed-phrase
parsing and category suggestions are plain arithmetic and string matching over
the user's own records. No remote model receives a receipt, an amount, or a
payee.

The guarantee does not cover:

- a compromised, jailbroken, or maliciously managed operating system;
- another person looking at the device while it is unlocked and MoneyUp is
  already open;
- screenshots, screen recordings, or readable CSV exports created by the user;
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
   immediate. Receipt images are never part of the draft. A transaction
   commit and removal of its pre-save draft occur in one database transaction.
6. If the protected key and database no longer match, the app refuses to read
   records. A separately confirmed reset removes the inaccessible database and
   key; it never guesses, downgrades encryption, or silently overwrites data.

## Storage and integrity

- SQLCipher is configured with cipher memory security, full synchronous writes,
  WAL journaling, secure deletion, and foreign-key enforcement.
- The database uses a versioned schema and rejects a schema newer than the app
  supports.
- Multi-record setup and reconciliation operations use a single immediate
  transaction and roll back as a unit on failure.
- Decoding revalidates monetary and ledger invariants. App startup additionally
  checks category hierarchy and all account references before showing data.
- User-controlled CSV cells that could be interpreted as spreadsheet formulas
  are neutralized before export.

## Portable recovery and remaining limits

The live Keychain key uses a this-device-only policy. Before deleting the app or
changing devices, the user can create a `.moneyup` archive encrypted and
authenticated with an independent password. Restore validates the candidate and
rolls the current logical store back if loading fails. MoneyUp cannot recover a
forgotten archive password. CSV export is readable and useful in Numbers or
Excel, but it is not a full-fidelity restore format. The live database directory
remains excluded from system backup because its device-bound key cannot migrate.

## Reporting a vulnerability

Do not open a public issue containing exploit details, keys, financial data, or
private screenshots. Use GitHub private vulnerability reporting for this
repository when available. Otherwise, contact the repository owner through
their GitHub profile and exchange details privately.
