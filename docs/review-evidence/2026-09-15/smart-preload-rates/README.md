# Contextual preload and custom transfer rates

## Current behavior

Quick Log shows a grey preview of merchant, amount (when supported), bank/account and category. The main arrow fills all untouched fields. “Choose fields individually” expands separate arrows for name, amount, account and category. Nothing is posted until Save.

The same pure fill policy handles both controls. It preserves manual edits, explicitly cleared fields, parser values, restored draft protections, notes, occurrence date, capture identity and split work. Existing default account/category selections can be replaced only when untouched. An amount cannot move to a different currency or a different bank from its supporting pattern. Stale book results and disabled intelligence settings cannot authorize an apply.

## Available context and prediction rules

- Local transaction history, transaction date, weekday, hour, day of month, and month-end alignment.
- A maximum of 200 entries from the prior 180 days, read through the encrypted chronological index after a 180 ms typing debounce. Computation runs outside the main actor.
- Frequency and 30-day recency decay contribute to ranking; weekday, nearby hour and monthly date context refine it.
- Bank and category are learned jointly from valid simple transactions. Edited bank/category selections constrain prediction.
- Amounts are exact historical amounts, never averages. An amount needs at least two supporting entries and 65% of the context-weighted support within the selected bank/category pattern. Otherwise the amount remains absent.
- Split, multi-account and transfer history is not flattened into a simple predicted transaction. Future entries and incompatible currencies/kinds are excluded.
- MoneyUp currently stores no location history. This version does not access GPS, request location permission, or infer that the user is near a merchant. It does not inspect calendar events or other apps. Predictions stay local.

## Custom rates

Transfer → Use my exchange rate accepts forward or reverse rates and previews the received amount. Checked Decimal arithmetic rounds once to the destination currency's precision. Invalid/overflowing/underflowing results cannot apply. Applying updates the received amount in the existing draft; the entered one-off rate itself is not retained as transaction metadata. Settings → Exchange Rates remains available for reusable user-entered estimates.

## Validation

- 22 core tests passed: CaptureSuggestionEngineTests, HistoryPreloadTests, ManualCurrencyConversionTests.
- 16 iOS tests passed: HistoryPreloadFillTests, HistoryPreloadIntegrationTests, QuickLogSmartFillTests, QuickLogDraftClearingTests, and the preload/rate render test.
- Cases include morning/evening amount selection, month-end alignment across different month lengths, uncertain amounts, partial merchant input, bank/category coherence, cleared fields after draft serialization, parser protection, currency mismatch, and stale bank selection.
- The render test waits for OCR confirmation that the merchant is visible without scrolling. Compact and expanded previews were inspected in English and Simplified Chinese.
- `git diff --check` passed.

## Screenshots

- [English compact preview](preload-en.png)
- [Chinese compact preview](preload-zh-Hans.png)
- [English individual fields](fields-en.png)
- [Chinese individual fields](fields-zh-Hans.png)
- [English manual rate](manual-rate-en.png)
- [Chinese manual rate](manual-rate-zh-Hans.png)

## Remaining acceptance

Physical iPhone tap-through, VoiceOver, large-text layouts, prediction usefulness on a real book, and device latency/battery measurements remain unverified. Location-assisted predictions require a future opt-in design and location history. No TestFlight or App Store build was published.

## Reproduce

```sh
swift test --scratch-path /tmp/moneyup-preload-build --filter 'HistoryPreloadTests|ManualCurrencyConversionTests|CaptureSuggestionEngineTests'
xcodebuild -project MoneyUp.xcodeproj -scheme MoneyUp -configuration Debug -destination 'platform=iOS Simulator,id=<simulator UUID>' -derivedDataPath /tmp/moneyup-context-ios CODE_SIGNING_ALLOWED=NO -only-testing:MoneyUpTests/HistoryPreloadFillTests -only-testing:MoneyUpTests/HistoryPreloadIntegrationTests -only-testing:MoneyUpTests/QuickLogSmartFillTests -only-testing:MoneyUpTests/QuickLogDraftClearingTests -only-testing:MoneyUpTests/QuickLogSmartEntryRenderTests/testHistoryPreloadAndManualRateLayouts test
```
