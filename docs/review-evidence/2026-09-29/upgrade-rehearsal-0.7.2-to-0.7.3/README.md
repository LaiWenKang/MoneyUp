# Upgrade rehearsal: a real 0.7.2 book opened by 0.7.3 (2026-09-29)

0.7.3 re-keys the encrypted book on the first unlock after an update: a book keyed with the earlier
passphrase form is copied, verified and swapped for one keyed with the raw 32-byte key (PR #104). The
unit tests for that move build their "old" book with 0.7.3's own test helper. This rehearsal runs the
move on bytes written by the real 0.7.2 store instead.

It is a Mac-side data check. It does not replace the owner's physical-iPhone check of build 1077.1.

## Method

- **0.7.2** is commit `92b1680`, the source of build 1076.3. `fixture-writer-0.7.2.swift.txt` ran there
  as a throwaway XCTest (`swift test`, macOS, Xcode 27 toolchain). It wrote a used book with the real
  0.7.2 `EncryptedRecordStore`:
  - 14 accounts, 2,400 journal entries in batches of 200, 150 of them edited in place and 100 deleted
    (2,300 remain), 6 PDF receipt attachments, 3 savings goals and 1 unfinished quick-log draft;
  - a key with a NUL byte, a quote byte and a 0xFF byte (the shapes a random Keychain key can take);
  - five last account renames that stay in the write-ahead log.
  - Two copies: `walpending` (book, `-wal` and `-shm` copied while the store was still open, as after
    a killed app; the writer proves the book file alone lacks the last saves) and `clean` (after a
    normal close). A clean copy was read back through the 0.7.2 store and matched before the manifest
    was written.
  - `fixture-manifest.json` holds the expected result: SHA-256 over every record (collection, id,
    payload, timestamp), record counts, per-account balances, journal index counts and the schema
    version. The key is omitted; the writer derives it from a fixed string.
- **0.7.3** is commit `d286cbb`, the source of build 1077.1. `fixture-reader-0.7.3.swift.txt` ran there.
  Each scenario copies the fixture bytes, opens them with the 0.7.3 store and compares with the manifest.

## Result: 7 of 7 scenarios pass (6.4 s)

| Scenario | What was asserted |
| --- | --- |
| Clean 0.7.2 book | The copy is passphrase-keyed. The first unlock moves it to the raw key. Digest, counts, balances, index counts and schema version equal the manifest. Only `moneyup.sqlite` is left in the folder. A write, a delete and a reopen afterwards persist. |
| Book with frames still in the log | Same, and the five renames that only the log held are in the moved book. |
| Move fails after the copy (injected) | Both books keep every record and stay passphrase-keyed; only the deferral marker is left beside them. Opening within a day does not copy again. With the marker aged two days, the move completes and clears itself. |
| Stale 1 MiB copy and `-journal` beside a log-carrying book | The stale files are replaced, the book is intact and moved, the folder ends with one file. |
| Wrong key | Both books refuse to open ("not a database"), no copy is created, and the right key still opens with nothing lost. |
| Backup of a moved book | A portable backup exports, and restores into a fresh book with identical record contents (timestamps aside). |

Measured on the Mac, so not a device figure:

| Book | First unlock including the key move | Next unlock | File |
| --- | --- | --- | --- |
| clean | 0.29 s | 1.0 ms | 7,380,992 to 6,799,360 bytes |
| write-ahead log pending | 0.32 s | 1.1 ms | 6,340,608 to 6,799,360 bytes (log folded in) |

## Static check of the upgrade path (`92b1680` to `d286cbb`, 160 files)

- No persisted key was removed or renamed. UserDefaults additions are the Focus-filter restore and
  applied flags, the reminder preferences and the Siri tip. The Keychain service, the App Group
  identifier and the database file name are unchanged.
- The record schema stays at version 10. No entitlement changed. The only Info.plist-level additions
  are the camera usage description for the receipt scanner (`project.yml` and both `InfoPlist.strings`)
  and the file-timestamp reason in the privacy manifest.

## What this does not cover

iOS Data Protection on the moved file and its folder, the Keychain-held key behind Face ID or the
device passcode, backup exclusion in a real container, low-storage behaviour, and timing on an iPhone.
An update installed over 0.7.2 on a physical iPhone stays the definitive rehearsal for those.

After the move the book is raw-keyed, so installing the older 0.7.2 build over 0.7.3 (for example
from TestFlight's previous builds) cannot open it. Testers should update forward only.

## Files

- `fixture-writer-0.7.2.swift.txt`, `fixture-reader-0.7.3.swift.txt`: the throwaway tests, stored as
  text so they are never compiled with the app.
- `fixture-manifest.json`: expected digest, counts and balances (key omitted).
- `writer-run.txt`, `reader-run.txt`: the relevant lines of the two `swift test` runs.
