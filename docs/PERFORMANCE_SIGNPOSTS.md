# MoneyUp performance signpost runbook

MoneyUp exposes a closed set of domain-payload-free `OSSignposter` intervals for
the 0.7.1 performance review. They never attach a count, domain identifier, file
path, error detail, financial value, or user-entered text. The five measured journeys
end with exactly one fixed `outcome=success`, `outcome=failure`, or
`outcome=cancelled` label so failed and abandoned samples cannot be mistaken for
successful budget evidence. Low-level operation messages remain empty.

The subsystem is `com.laiwenkang.MoneyUp` and the category is `Performance`.
The shared wrapper first checks whether signposting is enabled, so an ordinary
Release run pays only the disabled-path check and begin/end call-site overhead.
Every active interval receives its own signpost ID so concurrent operations can
overlap safely.

## Closed operation map

| Instruments name | Measured production boundary |
|---|---|
| `StoreOpen` | SQLCipher store initialization, including directory/file-protection setup |
| `Unlock` | One production Keychain/store-open invocation through return or throw; this intentionally nests `StoreOpen` |
| `LedgerLoad` | Recovering app-book load from the opened store |
| `Save` | One public encrypted-store upsert or transactional write |
| `HistoryPage` | One bounded indexed journal page query and decode |
| `HistoryQuery` | One deterministic in-memory History filter pass |
| `CSVExport` | CSV rendering from a prepared ledger snapshot |
| `XLSXExport` | XLSX rendering from a prepared ledger snapshot |
| `ArchiveExport` | Streaming authenticated portable-archive creation |
| `ArchiveRestore` | Authenticated transactional replacement from a portable archive |
| `ReceiptProcessing` | Deterministic processing of already-recognized receipt text |
| `Projection` | One deterministic month-end projection engine invocation |
| `DeterministicIntelligence` | The three review-only recurrence, duplicate, and anomaly detector passes |
| `UnlockToFirstUsefulContent` | Owner-authentication return through SQLCipher open, validation, model publication, and insertion of an active, uncovered, ready Today hierarchy marker. Success is a SwiftUI `onAppear` proxy, not a claim that Core Animation presented a pixel; onboarding, failure, lock, or backgrounding resolve as non-success. |
| `TransactionSaveToPublication` | One valid Log submission through atomic commit, draft/revision handling, derived-state publication, and saved-state/dismissal-request publication. This is an exact state boundary, not a pixel-presentation claim. |
| `HistoryQueryToContent` | One generation-owned initial History task after the 250 ms debounce through both bounded page and complete per-currency-summary state publication. Pagination cannot begin until this interval resolves. |
| `HistoryPageToContent` | One later-page query through generation-checked appended-row and cursor state publication; it is intentionally distinct from the initial query distribution. |
| `CalendarDateComputation` | Exactly one synchronous computation for a matching selected-date request after its indexed SQLCipher read returns: selected-day interval, bounded schedule occurrences, and per-currency flows. Database wait and hidden/loading/body recomputations are excluded. |

The existing `QuickLogReceipt` intervals separately measure selection to
suggestions and image sanitization. Their metadata is limited to fixed outcome
labels. `ReceiptProcessing` neither duplicates OCR/photo timing nor claims to
measure Vision, image decoding, or peak resident memory.

## Source gates

Run these before creating a candidate:

```sh
python3 -m unittest discover \
  -s Tests/PerformanceSignpostsValidatorTests \
  -p 'test_*.py'
python3 Scripts/validate_performance_signposts.py
python3 Scripts/validate_swift_structure.py
python3 Scripts/validate_release_assets.py
```

The validator pins all 18 names and every reviewed wrapper and direct
`OSSignposter` occurrence, requires complete interval ownership, rejects
alternate signposters, escaped identifiers, direct/indirect aliases, event
emission, underscored C APIs, a payload-bearing wrapper API, or unreviewed
metadata. Every `receiptSignposter` and centralized `signposter` identifier use
is globally counted. Mutation tests include an escaped `emitEvent` carrying a
runtime financial value. The Swift mapping test independently pins the public
operation and outcome inventories.

## Physical-device collection gate

1. Use the exact Release candidate on the oldest supported iPhone and a current
   iPhone. Record the build SHA, device model, iOS version, thermal state, power
   state, fixture profile, and whether the run is first or subsequent unlock.
2. Use only the fictional 10,000-entry/20-schedule QA book from
   [`FIRST_TEST.md`](FIRST_TEST.md). Never profile a real financial book.
3. In Instruments, record the Points of Interest / `os_signposts` data for the
   `com.laiwenkang.MoneyUp` subsystem and `Performance` category. Capture cold
   and warm unlock/load plus first useful Today content, a representative save
   through state publication, History search/filter and later page content,
   Calendar date computation, CSV/XLSX export, archive/restore drills, receipt
   processing, projection, and intelligence refresh.
4. Inspect the detail pane before retaining the trace. The performance category
   must contain only the names in the table. Messages must be empty or exactly
   `outcome=success`, `outcome=failure`, or `outcome=cancelled`; only successful
   journey samples qualify for p50/p95 budgets. Stop the run and file a privacy
   defect if any amount, currency, account/category,
   payee, note, transaction/record ID, archive password/path, receipt text,
   error detail, or other user-controlled value appears.
5. Export the Instruments trace and retain it with the environment record,
   privacy inspection result, and p50/p95 summaries. Keep first unlock separate
   from subsequent unlocks and do not compare results across different fixture,
   device, OS, build, or thermal identities without labeling the difference.

Source validation and simulator tests do not close a performance release gate.
The Golden p95 budgets, receipt peak-memory observation, scrolling/jank review,
archive near-limit behavior, and physical-device gates remain open until the
exact-candidate evidence above and the rest of `FIRST_TEST.md` are complete.
