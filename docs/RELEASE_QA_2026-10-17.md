# Release QA — 17 October 2026: rounds 1–6 and the accessible monthly cash flow

Reference content: #136 (`qa/rounds-1-6-accessible-monthly-20261016` at
`fdd9743`). The six core-flow PRs, stacked in round order, plus the monthly
change extracted from #136, give the same source tree (`073e7bc`); this QA adds
tests and a QA-only workflow on top. Nothing here changes app code, the ledger,
CI for pull requests or main, or any release workflow.

## What is checked automatically

| Area | Check | Where it runs |
|---|---|---|
| Chinese and English, default and largest text size, 320 and 375 pt | Today and History rendered whole: every amount keeps its currency code on its line, no value is cut with "…", no raw string key, and after hiding amounts on the same mounted screen no figure left (`ReleaseQARenderTests.testTodayAndHistoryStayWholeAndHideEveryFigureInBothLanguages`) | Every PR (iOS 18.5) |
| Same languages and sizes, 375 pt | Log and the transaction editor: no value cut with "…", no raw string key, the editor's amount shown whole and hidden when amounts are hidden (`testLogAndTheEditorShowNoRawKeysAndTheEditorHidesItsAmount`) | Every PR (iOS 18.5) |
| Chinese core flow at Accessibility XL, amounts hidden | Log an expense, see it in History without its amount, find it by search, open it, split it, and type in each field below the amount with the field clear of the keyboard and its Done bar (`MoneyUpJourneyTests.testChineseCoreFlowAtALargeTextSizeKeepsAmountsHiddenAndFieldsClear`) | Every PR (iOS 26.5) and the short-screen lane |
| Short screen (iPhone SE, 667 pt, iOS 26) | The whole UI journey suite, including the keyboard, largest-text, hidden-amount, Chinese and Log-input journeys, and the keyboard and focus unit tests | `.github/workflows/qa-short-screen.yml`, on `qa/release-candidate-*` pushes or on request |

Already in the suite and kept: Today, History, Plan and Assets hide every
figure when amounts are hidden (`AmountPrivacyRenderTests`); Today and the
Saved banner whole at the largest size (`LargeTextAmountRenderTests`, the AX5
journey); the six monthly rows at AX5 and their live masking
(`TodayCashFlowMonthlyRenderTests`); keyboard journeys in English at the
default size and Accessibility XL.

The renders draw a window far taller than the screen and read it with
Vision. On iOS 26.5 such windows are not always composited (parts render
black), so the renders run on iOS 18.5. Vision misses default-size text in
one image that tall, so each render is read in overlapping screen-shaped
strips (`FormValuesLargeTextRenderTests.readTallRender`). Amounts are matched
by their digits because OCR can read a separator either way. A field's own
placeholder may end in "…" in a narrow field and is not counted (the person
sees what goes there once they type); a word hyphenated because it is wider
than the screen (a long payee) is attached for review rather than counted as
a fault.

## Found by this QA and fixed

On the first short-screen run (iPhone SE, iOS 26.5), History at the largest
text size broke the range name one letter a line ("T/o/d/a/y", "今/天"), put
"Spent SGD" above "1,234.56", and set every row's currency code on one line and
its figure on the next. Fixed in #139 (`HistoryLargeTextRenderTests`).

On the first iOS 18.5 run, Log and the editor at the largest text size cut
the chosen account to "…" ("W…D" in Chinese) and the category to "F…d", and
the editor cut the amount being corrected to "1234…". Fixed in #140
(`FormValuesLargeTextRenderTests`). The same rows are on main and in the 0.7.3
source; neither was introduced by this stack.

Seen and left as they are: at the largest size a long placeholder ends in "…"
("Description…", Smart Entry's "e.g. …"), and in Chinese the editor's
compact time picker reaches the screen edge; both are system field and
picker behaviour, and the field's value shows whole once entered.

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
