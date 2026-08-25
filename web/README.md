# MoneyUp for the browser

A local-first, encrypted budget book that runs entirely in your browser. Same
product as the iOS app, same ledger rules, different platform.

## Run it

There is no build step. Any static server works, and the app must be served
over `http://localhost` or HTTPS because Web Crypto is unavailable on `file://`.

```bash
cd web
npm run serve          # or: python3 -m http.server 8080
```

Then open <http://localhost:8080>. Add it to your home screen to run it
fullscreen and offline.

```bash
npm test               # domain, budget, report, crypto, parser, CSV
```

## How your data is protected

On first run you choose a passphrase. MoneyUp generates a random 256-bit data
key, wraps it with a key derived from that passphrase (PBKDF2-SHA256, 600,000
iterations, random salt), and stores only the wrapped form. Every record is
then encrypted individually with AES-GCM and written to IndexedDB. The
unwrapped key is held non-extractable in memory and dropped when you lock or
when the tab is hidden.

Nothing is uploaded. There is no account, no server, and no analytics. Data
leaves only through an explicit CSV export, which is readable plaintext.

**This is a weaker guarantee than the iOS app's, and deliberately so.** iOS
keeps the same random key in the Keychain, released only on Face ID or the
device passcode and protected by the Secure Enclave. A browser has no
equivalent, so the passphrase is the whole of the protection:

- a weak passphrase is a weak book;
- there is **no recovery** — forget the passphrase and the data is gone;
- another script running on the same origin could read decrypted state while
  the app is unlocked, so only ever serve this from an origin you control;
- clearing site data deletes the book, and browsers may evict storage under
  pressure unless the origin is persisted.

Export a CSV snapshot regularly and protect it.

## What is here, and what is not

Implemented: exact decimal money, balanced journal entries, multi-currency
accounts and transfers, arbitrary-depth budgets with roll-up, period reporting
that keeps every currency, typed-phrase entry, category suggestions, CSV
export, English and Simplified Chinese, and an installable offline PWA.

Not yet: receipt OCR (iOS uses Apple's Vision framework; the browser
equivalent needs a WASM OCR engine), the finance calendar, investment
holdings, and recurring transactions.

## Keeping it in sync with iOS

`src/domain.js`, `src/budget.js`, `src/report.js`, and `src/parse.js` are ports
of `Sources/MoneyUpCore`. They carry the same invariants — amounts are never
binary floating point, an unbalanced entry cannot be constructed, a parent
budget caps its descendants, and no report silently drops a currency — and the
test suites mirror each other case for case. Change one side and change the
other.
