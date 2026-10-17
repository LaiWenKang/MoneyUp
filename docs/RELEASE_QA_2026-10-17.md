# Release QA — 17 October 2026: rounds 1–6 and the accessible monthly cash flow

Reference content: #136 (`qa/rounds-1-6-accessible-monthly-20261016` at
`fdd9743`). The six core-flow PRs, stacked in round order, plus the monthly
change extracted from #136, give the same source tree (`073e7bc`); this QA adds
tests and a QA-only workflow on top. Nothing here changes app code, the ledger,
CI for pull requests or main, or any release workflow.

## What is checked automatically

| Area | Check | Where it runs |
|---|---|---|
| Chinese and English, default and largest text size, 320 and 375 pt | Today and History rendered whole: every amount whole and with its currency code, no raw string key, and after hiding amounts on the same mounted screen no figure left (`ReleaseQARenderTests.testTodayAndHistoryStayWholeAndHideEveryFigureInBothLanguages`) | Every PR (iOS 18.5) and the short-screen lane |
| Same languages and sizes, 375 pt | Log and the transaction editor show no raw string key; the editor's amount hides when amounts are hidden (`testLogAndTheEditorShowNoRawKeysAndTheEditorHidesItsAmount`) | Every PR and the short-screen lane |
| Chinese core flow at Accessibility XL, amounts hidden | Log an expense, see it in History without its amount, find it by search, open it, split it, and type in each field below the amount with the field clear of the keyboard and its Done bar (`MoneyUpJourneyTests.testChineseCoreFlowAtALargeTextSizeKeepsAmountsHiddenAndFieldsClear`) | Every PR (iOS 26.5) and the short-screen lane |
| Short screen (iPhone SE, 667 pt, iOS 26) | The whole UI journey suite, including the keyboard, largest-text, hidden-amount, Chinese and Log-input journeys, plus the release QA renders | `.github/workflows/qa-short-screen.yml`, on `qa/release-candidate-*` pushes or on request |

Already in the suite and kept: Today, History, Plan and Assets hide every
figure when amounts are hidden (`AmountPrivacyRenderTests`); Today and the
Saved banner whole at the largest size (`LargeTextAmountRenderTests`, the AX5
journey); the six monthly rows at AX5 and their live masking
(`TodayCashFlowMonthlyRenderTests`); keyboard journeys in English at the
default size and Accessibility XL.

## What only a physical iPhone can show (owner)

1. **VoiceOver speech** (Settings › Accessibility › VoiceOver on): on Today,
   swipe through the cash-flow card; each month is read as one item with its
   income and spending, and with amounts hidden every figure is read as
   "hidden amount" / "隐藏的金额". In Log, a dimmed Save is read with its
   reason.
2. **Hardware keyboard** (any Bluetooth or Magic Keyboard): in History open an
   entry, turn on the split and Tab through the fields; nothing jumps or hides
   behind the toolbar.
3. **Real device, largest text** (Larger Text at the maximum, Chinese): save
   an entry in Log and open it from History; the amount and Undo stay whole
   and the split line's amount stays above the keypad.

## Not covered by automation

- The QA renders read pixels with Vision; a word broken without a hyphen, or
  Chinese text broken mid-phrase, is not detected; the attached images are
  for eye review.
- The short-screen lane uses the iPhone SE simulator, not hardware; Touch ID
  and true safe-area behaviour are device checks.
