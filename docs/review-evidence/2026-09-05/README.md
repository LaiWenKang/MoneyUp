# Audit evidence

These files characterize existing behavior at commit
`5b0ef2078ff2c15d76145ab3cdd9411ca9727336`. They are diagnostic evidence,
not the proposed implementation or its acceptance tests.

The historical probe is preserved as budget-semantics-probe.swift.txt, with its
recorded output beside it. It describes the audited commit, not the redesigned
implementation. Current executable regressions are in Tests/MoneyUpCoreTests
and Tests/MoneyUpAppTests.

The four hierarchy cases execute the actual core. The final merge example applies
the addition operation from `AppModelLedgerValidation.swift` to core values;
it does not execute the app's asynchronous category lifecycle or persistence.

The selected XCTest run could not compile because the active Command Line Tools
installation lacks XCTest. Native iOS interaction and relaunch tests were not run.

The independent browser concept was checked for:

- Child allocation editing: SGD 300 → 400 changed the parent SGD 600 → 700 and
  overall plan SGD 800 → 900 immediately.
- Global daily-guidance hiding with identical budget/spending/remaining values.
- Global re-enabling retained a hidden Food parent and visible child guidance.
- An unfinished SGD 50 edit survived switching to Display and back.
- Saving SGD 50 displayed the child's SGD 70 overspend and recomputed ancestors.
- Negative input was rejected with a visible validation error.
- A simulated SGD 1,000 expense changed only the hypothetical result.
- Light/dark appearance and phone-width layout (360-pixel outer viewport;
  328-pixel concept container) and a 736-pixel outer viewport were inspected.
- No horizontal overflow was observed in the measured concept root.

The browser wrapper did not propagate reduced-motion emulation to its sandboxed
frame, so runtime reduced-motion behavior is unverified; the fragment contains
the media-query override and an additional motion reduction control. These checks
do not establish production SwiftUI behavior or durable preference persistence.
