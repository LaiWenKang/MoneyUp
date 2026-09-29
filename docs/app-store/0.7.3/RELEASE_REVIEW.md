# MoneyUp 0.7.3 public update

Owner asked on 29 September 2026 for the remaining native-feature changes to be
landed and for 0.7.3 to reach TestFlight, App Store Connect and public
distribution. The existing France exclusion and the SGD 1 / 5 / 10 support
products are unchanged.

## Baseline

- Last uploaded build: 0.7.2 (1076.3, source 92b1680), processing VALID, in internal
  and external TestFlight testing.
- 0.7.2 was submitted for public review with an automatic release. All 72 half-hourly
  App Store Connect checks from 27 September 21:51 to 29 September 09:59 read
  Waiting for Review. 0.7.1 (1051.1) remains the live version.
- 0.7.3 contains everything in 0.7.2 plus the changes below. Source: `main` after
  pull requests #98 to #116.

## Changes since 0.7.2 (1076.3)

- Log without unlocking after auto-lock (#99): auto-lock now covers the open book
  instead of closing it. A widget, Control Center control or Siri shortcut opens Log
  alone, with no past entries, while the cover is up. Every other screen asks to
  unlock, and a closed book still needs the normal unlock. Widgets, controls and
  Siri carry no financial data.
- Native features: paper receipts scanned with the system document camera (#111);
  local reminders for due scheduled items and an optional daily logging nudge,
  generic text unless the person opts in (#109); Home Screen quick actions (#110);
  a Focus filter that hides amounts, with a Siri tip and a Shortcuts link (#112);
  History search across every date, touch-and-hold preview and a zoom into a
  transaction (#115); a tip on the receipt button and Siri suggestions that learn
  which Log is used (#116).
- Speed: raw-keyed books and no timed wait before the unlock prompt (#104); screens
  keep their content while they refresh (#100); export 35 times faster with identical
  bytes (#101); restore 2.6 times faster (#105).
- Wording, accessibility and motion: VoiceOver reads hidden amounts as "hidden
  amount" (#108); readable exchange-rate dates, one budget-pace vocabulary and an
  honest overspend message (#103); calmer, consistent motion (#102).
- Behaviour: Undo hands the entry back to the form to correct (#107); support
  purchases anchor to the active scene (#98); CSV text that uses only CRLF line
  breaks is quoted correctly (#101).
- Launch safety and test gates: notification replies stay off the main actor so
  launch cannot trap (#113); the StoreKit purchase gate now checks that a tip ends
  finished (#106) and warms up test signing before it judges the flow (#114).

## Data migration

#104 moves the SQLCipher key from passphrase form to raw-key form. It works on a
checked copy: the write-ahead log is folded, the copy is exported in one exclusive
transaction, read back and matched against the original schema and row counts,
flushed, and only then swapped in by atomic rename. On any failure the original book
is untouched and the attempt repeats a day later. `DatabaseKeyFormTests` covers the
failure paths. An update installed over 0.7.2 on a physical iPhone is the real
rehearsal, so the TestFlight notes ask testers to confirm their entries, budgets and
accounts.

## Store metadata

- Screenshots, previews and the support review capture are the reviewed 0.7.2 files,
  byte for byte (checked with `cmp`). 0.7.3 adds controls they do not show, such as
  the receipt button and search across dates; it removes nothing they show.
- Description, What's New, keywords and review notes are rewritten for 0.7.3 in
  English and Simplified Chinese. The review notes explain the camera and
  notification permissions, the Focus filter and the lock-cover behaviour.
- Privacy answers do not change: nothing is collected, uploaded or shared. Camera
  images are read on the device; reminders are local notifications.

## Validation and outstanding gates

- On this source the seven validators exit 0, the script tests pass (137, including
  the release-configuration tests against `release.json`), and the validator suites
  in `Tests` pass (64).
- Branch protection on `main` requires Core tests, iOS Simulator build, native
  review, Release assets and the iPhone Simulator performance baseline to pass
  before a pull request merges; this release goes through the same gate.
- Not claimed by this note: the signed upload, Apple's processing of it, Beta App
  Review, App Review, and physical-iPhone acceptance (upgrade from 0.7.2, receipt
  scan, reminders, Focus filter, and Log from a widget after auto-lock). Each is
  recorded separately when it happens.
- Not built: Siri with an amount ("Log $5 coffee"). It would put amounts in Siri
  requests and awaits an owner decision.
