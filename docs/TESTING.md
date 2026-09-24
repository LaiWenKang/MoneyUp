# MoneyUp testing map

Each layer proves something the others cannot. A change is not done until
every layer that covers it passes, and a release is not submitted until the
device lane passes on a physical iPhone.

| Layer | Where | What it proves | How to run |
|---|---|---|---|
| Domain and property tests | `Tests/MoneyUpCoreTests` (incl. `FuzzAndPropertyTests`) | Money, parsing, import/export, and profile invariants hold for seeded random and hostile input: no crash, no NaN, conservation, idempotence, CRLF/LF parity | `swift test --parallel` |
| Persistence | `Tests/MoneyUpPersistenceTests` | SQLCipher store integrity, bounds, migrations | `swift test --parallel` |
| App model and cross-feature | `Tests/MoneyUpAppTests` (incl. `CrossFeatureAndStressTests`) | Every entry kind × split × currency × favourite balances per currency and undoes exactly; locked-capture routing matrix; rapid-save and favourite-churn stress; 5,000-entry projection; injected store failures leave nothing half-applied | `xcodebuild -scheme MoneyUp … test` |
| Lifecycle, interruption, security | `Tests/MoneyUpAppTests` (`AppModelTests`, `PlatformQuickLogActionTests`, …) | Erase/restore/key-cliff interruption at every checkpoint, crash replay of widget ingress, locked-capture isolation | same |
| Render evidence | `…RenderTests`, `QuickLogFavouriteAppTests` | Screens and widget cards in light/dark, English/Chinese, AX5 | same; export attachments with `xcresulttool` |
| End-to-end journeys | `Tests/MoneyUpUITests/MoneyUpJourney*` | Real taps through the running app: every tab, log/undo, favourites, save-as-favourite, widget route while locked, unlock into Log, conflicts, relaunch, locking mid-entry, rapid taps, Smart Entry, History search, Settings, Chinese, AX5, and accessibility audits of every tab | `xcodebuild -scheme MoneyUpColdLaunch … CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test` |
| Performance baselines | `Tests/MoneyUpPerformanceTests` | 10,000-entry open/save/query/export/restore timings on a fixed simulator | `MoneyUpPerformance` scheme (CI) |
| Device lane | `Scripts/run_device_lane.sh` | The device-only failures the simulator cannot reproduce (the 1064.1 type-depth crash): crash guards plus every journey on a connected iPhone | `DEVELOPMENT_TEAM=<id> Scripts/run_device_lane.sh` |
| Static validators | `Scripts/validate_*.py` + their tests | Privacy boundary, pinned reviewed code, launch safety, localisation, contrast, structure limits | `python3 Scripts/validate_<name>.py`, `python3 -m unittest discover -s Scripts/tests` |

## The UI-test harness

`App/MoneyUp/MoneyUpUITestHarness.swift` exists only in Debug builds (the
Release binary contains no trace of it). Launching with `-MoneyUpUITest`
opens a seeded, fixed-key temporary book through the normal startup path,
so lock, unlock, locked capture, and routing run production code; only the
Face ID prompt a simulator cannot answer is replaced. Options:
`-MoneyUpUITestReset`, `-MoneyUpUITestFavourites`, `-MoneyUpUITestStartLocked`.

Journeys deliver widget links with `XCUIDevice.shared.system.open`, the way the
system does. `XCUIApplication.open(_:)` relaunches the app without its launch
arguments and would silently test a different app.

## Bugs these layers found (2026-09-24)

- CSV import rejected every Windows-style (CRLF) file, including MoneyUp's own
  ledger export: Swift reads `"\r\n"` as one `Character`. Fixed in
  `DelimitedRecordParser`; `testCSVImportIsIdenticalForLFCRLFAndCRLineEndings`
  fails without the fix.
- Log's keyboard toolbar (tabs / Notes / Save / Done) rendered only some of
  the time, so Log sometimes had no way to hide the keyboard; and when it did
  render, it covered the Smart Entry row, Fill included, which the list
  never scrolled clear of. Log now pins Save with a hide-keyboard button above
  the keypad and has no keyboard toolbar. The Smart Entry journey asserts Fill
  is reachable with the keypad up.
- Focusing Smart Entry or a split line never scrolled it into view: their
  scroll ids sat inside their Form rows, where `scrollTo` cannot find them,
  so the phrase and its Fill button stayed behind the keypad. The ids are now
  on the rows, and focused fields land in the upper third of the list.
- Journeys run with the shipped default (amounts hidden). A simulator that
  had amounts shown hid the two bugs above.
- Accessibility: the amount-privacy eye, History filter/clear, and the budget,
  calendar, and asset month chevrons had glyph-sized tap targets; the kind
  menu clipped its label at the largest text size; Assets read net worth,
  account balances, and group subtotals as bare figures with no context.
