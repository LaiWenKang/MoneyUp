# Smart Entry and Log improvements after 0.7.1 (1048.1)

Implemented on `codex/smart-entry-log-improvements`, based on local main `7d79c3d`. This is source and simulator evidence; a new TestFlight build has not been uploaded.

## Decisions and behavior

| Feedback / root cause | Implemented behavior |
|---|---|
| Smart Entry appeared after account/category controls; title and description followed attachments. | Amount → Smart Entry → title/description → account/category → date → attachments. Amount remains immediately accessible for manual logging. |
| Log had no explicit way to discard its current form. | “Clear entry” in the Log toolbar asks for confirmation, clears only this unsaved form and its attachments, and keeps the account/category/type selected. Saved transactions and other pending Quick Logs remain intact. |
| The parser chose the first number before recognizing account names. | Resolve existing account/category names before numbers. Number-bearing names such as “Card 1234” stay intact; multiple numbers need an explicit total or manual review. |
| A typed phrase could overwrite corrections and ignored its currency. | Fill empty fields, preserve existing amounts/titles/notes/dates/splits and explicit account/category choices, check currency evidence and monetary precision before formatting, and keep the original phrase visible for correction. |
| Notes shared the financial interpretation path. | `;` or `；` separates description from the transaction phrase. Numbers, dates and refund/income words in notes cannot change the financial fields or enter the optional model context. |

Examples (account/category names must exist in the book):

- `lunch SGD 12.50 Cash Food yesterday; with Sam` fills the amount, local account/category, date, title and description.
- `Card 1234 lunch 12.50` reads 12.50 as the amount.
- `2 coffees total 8.40` / `２杯咖啡 合计：８.４０` reads the explicitly labelled total.
- `2 coffees 8.40`, `coffee -12`, incompatible currency, impossible dates, and unsupported monetary precision stay reviewable; uncertain money is not automatically filled.

The existing deterministic parser and optional bounded Apple on-device matcher remain the implementation. No service, model-provider dependency, schema migration, or automatic transaction posting was added.

## Draft safety

Clearing uses the existing serialized draft-replacement boundary. It waits for earlier draft writes, verifies that the confirmed draft is still current, persists the cleared draft before publication, and preserves the form on storage failure. A current capture's leftover inbox copy is retired to prevent replay; other pending captures are kept. Receipt, history and model suggestions are cancelled, and attachment preparation checks cancellation again before publishing.

## Verification

- All 502 package tests passed: 449 XCTest methods plus 53 Swift Testing tests. Command: `TZ=UTC swift test --scratch-path /tmp/moneyup-smart-entry-spm --build-system native`.
- All 59 selected native iOS tests passed on the final source, covering clear/reopen, stale confirmation, storage failure, pending-capture preservation, exact monetary parsing, manual-field preservation, duplicate review, keyboard behavior, localization and optional assistance. [Machine-readable summary](native-summary.json); raw result: `/tmp/moneyup-smart-delivery.xcresult`.
- All 57 architecture-validator tests passed, including adversarial input-boundary checks. Reviewed inventories include the new local text readers and fill policy; the immutable parser result remains the only model-assistance source.
- Release assets/localization, Swift structure, platform actions, accessible errors, performance signposts, launch safety and `git diff --check` passed. Source test accounting: 1,213 declarations.
- Tests used synthetic data in an isolated iPhone 16 simulator, iOS 27.0, Xcode 27 beta (`27A5252f`). The installed private book was not opened or modified.

An initial package run used a polluted build cache; a fresh native SwiftPM build resolved its signing failure. A parallel run also hit an existing timing threshold and a timezone-sensitive history fixture; the full serial UTC suite passed. A later incremental iOS build crashed while constructing the form. A clean rebuild of the same source passed both affected UI tests; the subsequent combined native run also passed. Clean-build results are the acceptance evidence, and the incremental failure is retained in `/tmp/moneyup-smart-native-final.log`.

Apple references: [Decimal](https://developer.apple.com/documentation/Foundation/Decimal), [Dynamic Type](https://developer.apple.com/videos/play/wwdc2024/10074/).

## Native previews

[English](log-english.png) · [Simplified Chinese, 320-point width](log-chinese.png) · [Accessibility text size](log-large-text.png) · [Amount focus](log-amount-focus.png)

The Smart Entry input and Fill action stack vertically at accessibility text sizes. Placeholder text may truncate at large sizes; entered text remains multiline and VoiceOver acceptance remains open. Screenshots do not establish physical keyboard occlusion or VoiceOver acceptance.

## Physical-device acceptance still open

1. Open Log at ordinary and large text sizes; verify the Smart Entry, title and description placement and keyboard reachability.
2. Try your own English/Chinese phrases and account names. Check every field before Save, including currency and date.
3. Edit amount/title/description, then Fill another phrase; verify those edits stay intact.
4. Cancel Clear, then confirm Clear. Verify only the current unsaved form clears and saved transactions remain unchanged.
5. Clear during receipt recognition, return to Log, and lock/unlock. Verify cleared content does not reappear and other pending Quick Logs remain available.
6. Verify VoiceOver focus, control labels and Dynamic Type with touch on the intended phone.
