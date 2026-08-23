# MoneyUp Security Policy and Threat Model

MoneyUp handles highly sensitive personal finance data. Security claims in the
product, documentation, and code must distinguish between controls that are
implemented and controls that are planned.

## Current status

Foundation 0.1 contains only the finance domain, tests, export encoder, and a
non-persistent UI shell. It is **not ready for real financial data**.

| Control | Status |
|---|---|
| Balanced domain model and validated decoding | Implemented |
| No analytics, ads, remote AI, or application backend | Implemented |
| Repository ignores common financial export and credential files | Implemented |
| SQLCipher database encryption | Planned next |
| Random per-installation database key | Planned next |
| Keychain and Face ID/passcode protection | Planned next |
| App-switcher blur and configurable automatic lock | Planned next |
| Privacy-redacted widgets | Planned |
| Password-protected encrypted backup and restore | Planned |
| End-to-end-encrypted device sync | Future and optional |

## Intended privacy guarantee

MoneyUp should be able to make this verifiable statement:

> Raw financial records are processed locally. MoneyUp does not operate a
> service that receives them. Data leaves the device only through an explicit
> user action, and optional remote backups contain ciphertext encrypted with a
> key MoneyUp does not possess.

The guarantee does not cover:

- a compromised, jailbroken, or maliciously managed operating system;
- another person using the device while it is unlocked and MoneyUp is open;
- screenshots, screen recordings, or plaintext exports created by the user;
- disclosure performed by the spreadsheet, cloud drive, or recipient chosen
  by the user after export;
- traffic metadata from optional market-price lookup, even when holdings are
  not uploaded directly.

## Threats and required controls

| Threat | Required mitigation |
|---|---|
| Device backup or file extraction | SQLCipher plus iOS file protection |
| Database key theft | Random 256-bit key in Keychain; never source code or preferences |
| Casual physical access | Face ID/passcode gate and inactivity timeout |
| Lock-screen disclosure | Privacy-sensitive widget redaction; values hidden by default |
| App-switcher snapshot | Replace sensitive UI with a privacy cover when inactive |
| Logs and crash reports | Never log amounts, payees, notes, holdings, or encryption material |
| Plaintext export | Explicit warning, recent authentication, and user-selected destination |
| Malicious or malformed import | Versioned schema, size limits, validation, and transactional import |
| Supply-chain compromise | Minimize dependencies, pin reviewed versions, run CI and dependency review |
| Developer/operator access | No raw-data backend and no financial telemetry endpoint |

## Planned key lifecycle

1. Generate a cryptographically random database key on the device.
2. Store it in Keychain with an accessibility policy equivalent to
   `WhenUnlockedThisDeviceOnly` and local user-presence access control.
3. Open the SQLCipher database only after successful local authentication.
4. Remove decrypted key material from long-lived application state when the
   app locks.
5. Do not synchronize this device key. Portable backups use an independent key
   derived from a user-held recovery secret and authenticated encryption.
6. Test first launch, lockout, biometric changes, reinstall, backup recovery,
   key rotation, and interrupted migration.

## Reporting a vulnerability

Do not open a public issue containing exploit details, keys, financial data, or
screenshots of private records. Use GitHub private vulnerability reporting for
this repository when available. Otherwise, contact the repository owner through
their GitHub profile first and exchange details privately.
