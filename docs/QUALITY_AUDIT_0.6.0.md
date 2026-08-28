# MoneyUp 0.6.0 Comprehensive Quality Audit

Audit date: 28 August 2026

Baseline: `b0ac219e0eabf0888358dbb0154b1071c35aed66` (`main`)

Review branch: `codex/complete-release-gates-0.6.0`

## Outcome

**Release decision: blocked on evidence, not on a known unremediated current-
format source defect.** No P0 defect was found. The review and completion pass
fixed the identified P1/P2 correctness, recovery, privacy, input-boundary, race,
and scale problems. Portable archive version 2 is file-backed and independently
authenticates bounded chunks across an envelope that every current accepted book
must fit. SQLCipher schema 6 adds trigger-maintained store totals, normalized
budget attribution, and monthly carry checkpoints. Explicitly retained receipt
pixels are re-encoded without source GPS/EXIF/TIFF device metadata.

Exact-candidate macOS CI/coverage and physical evidence remain open. The latter
includes compatible near-limit version-1 restore memory, version-2 interruption
and peak memory, oldest-device budget/checkpoint performance, power interruption,
accessibility, upgrade/restore, signed TestFlight, App Review, and export
compliance. Source remediation is not a measured or accepted release.

This report does not claim that software can be proven bug-free. It records
what was inspected, what changed, what evidence exists, and what is still
required before a user should trust the candidate with irreplaceable data.

## Authority and reviewed inputs

1. `MoneyUp_Golden_PRD_v1.0_2026-08-26(1).docx` is controlling. The uploaded
   filename/Library label calls it v1.1 in one place, while the document itself
   is titled Golden PRD v1.0 and is effective 26 August 2026. The internal title
   and effective date were used.
2. `MoneyUp-0.4.0-Audit(1).pdf` supplies D-01 through D-23 and the original
   risk evidence.
3. `MoneyUp-PRD-v1.1.pdf` supplies earlier context only where it does not
   conflict with the Golden PRD.
4. Accounting and security invariants take precedence over presentation
   refinements. Later accepted Flexible Today and visual-identity decisions are
   identified as later decisions in `GOLDEN_TRACEABILITY.md`.

Every page of the two PDFs and the rendered Word document was inspected, and
all 97 Golden requirement IDs were extracted and reconciled. The exact matrix
is in [REQUIREMENTS_TEST_MATRIX.md](REQUIREMENTS_TEST_MATRIX.md).

## Scope and inventory

| Item | Audited scope |
|---|---:|
| Baseline tracked files | 175 |
| Current tracked candidate files | 189 |
| Candidate files | 189 |
| Swift files | 119 |
| Swift source/test/manifest lines | 65,083 |
| Declared automated tests | 514 |
| Core test declarations | 252 |
| Persistence test declarations | 49 |
| App-target test declarations | 213 |
| Golden requirements | 97 / 97 traced |
| Runtime Swift package dependencies | 1 |

The inventory covered `.github`, `App`, `Scripts`, `Sources`, `Tests`, `docs`,
the package/project manifests, entitlements, privacy manifest, asset catalogs,
localization catalogs, legal/support files, release workflows, and all tracked
files. All tracked files were checked for emptiness and parseability where a
machine-readable format applies. Every Swift file participated in repository-
wide lexical review; correctness/security/recovery paths were manually traced
across callers, state transitions, persistence operations, and consumers. The
closed pre-completion audit manifest and its review treatment are in
[FILE_REVIEW_INVENTORY.md](FILE_REVIEW_INVENTORY.md).

## Architecture and cross-feature map

| Boundary | Owns | Cross-feature effects reviewed |
|---|---|---|
| SwiftUI app/views | User input, routing, accessibility, disclosure | Log, History, Today, Insights, Plan, Calendar, Assets, Settings, Data Safety |
| `AppModel` (`@MainActor`) | Lifecycle serialization and coherent published state | Draft/save/lock races; account/category lifecycle; schedules; goals; investments; imports; backup/restore; widget publication |
| `MoneyUpCore` | Pure Decimal/accounting/domain rules | Journal balance, minor units, reports, periods, rates, recurrence, rollover, goals, lots/FIFO, CSV/XLSX |
| `MoneyUpPersistence` | SQLCipher actor, normalized indexes, atomic batches, snapshots | Journal pages/events, attachment metadata, quarantine, schema migration, portable archives |
| Locked capture boundary | Separate device-only key and redacted encrypted FIFO | Cold widget/deep link, authenticated draft promotion, exactly-once journal handoff |
| Widget boundary | App Group percentage/state snapshot only | Explicit opt-in, expiry, redaction, lock survival, erase/no-book scrubbing |

The highest-coupling paths were followed end to end:

| Action | Required atomic/consistent consumers |
|---|---|
| Journal save/edit/delete | SQLCipher record and index, revision, draft deletion, attachment link, balances, budget attribution/rollover, reports, History/Calendar, widget snapshot |
| Account/category lifecycle | Journal references, budgets/timeline, schedules, holdings/positions, profile defaults, current draft, historical audit |
| Reporting-zone change/travel | History bounds, period reports, budget month, goals, schedules, rates, snapshots, widget expiry |
| Schedule post/match/edit/delete | Schedule occurrence state, linked journal entry, audit link, derived projections, restore/lifecycle barriers |
| Investment purchase/sale/reprice/correct | Cash and position postings, lots/disposals, holdings, net worth, snapshots, protected deletion rules |
| Restore | Every collection identity/relationship, domain decode, indexes, live replacement rollback, preferences, current UI state |

## Review and test-design methods

- Requirement analysis and a 97-row RTM with at least one named automated or
  manual case per requirement.
- File/directory/configuration inventory, dependency provenance review, and
  static scans for unsafe error suppression, force operations, dynamic SQL,
  runtime networking, secrets, raw diagnostics, stale schemas, dead settings,
  unbounded file reads, non-finite dates, and unchecked arithmetic.
- Equivalence partitions for transaction kinds, account/category kinds,
  currencies, CSV dialects, date grammars, archive versions, queue states, and
  valid/malformed relationship classes.
- Boundary cases at zero/nonzero, currency minor units, Decimal magnitude,
  byte/row/count caps, exact period ends, seven-day stale price, schedule
  occurrence boundaries, archive version/KDF/password limits, and file-size
  sentinels.
- Positive and negative cases for wrong password, tamper, duplicates,
  cancellation, missing/orphan references, ambiguous dates, malformed quotes,
  garbage numeric suffixes, archived targets, overflow, clock rollback, and
  unsupported future schemas.
- Interaction/race cases for lock/save, draft debounce/save, scan/lock,
  erase/commit, restore/profile/goal/schedule barriers, stale generations,
  capture promotion/removal/onboarding, concurrent rate/goal writes, an older
  projection crossing a newer journal commit, and lock during atomic import.
- Stress fixtures for 10,000 journal entries, 20,000 accepted import rows,
  bounded recurrence, large receipt metadata indexes, extreme Decimal values,
  and multi-page sparse History matches.
- Interruption reasoning and deterministic checkpoints around SQLCipher commit,
  restore replacement, draft persistence, capture handoff, schedules, goals,
  investments, and snapshots. Actual process termination/power removal still
  requires the physical cases below.

## Findings fixed on the review branch

| ID | Sev. | Finding and resolution | Regression evidence source |
|---|---:|---|---|
| A-001 | P1 | CSV parsing accepted prefix numbers/ambiguous decorations and weak row/date/quote boundaries. It now requires full tokens, locale-aware dates, consistent flow/type columns, physical line reporting, a 20,000-row cap, a 128-byte amount cap, and SHA-256 fingerprints. | `TransactionCSVImporterTests` negative/boundary suite |
| A-002 | P1 | Skipped import rows could leak proposed categories/trading accounts, and a matching archived category could receive new postings. Candidate state now rolls back per failed row and active target checks are enforced. | `testSkippedImportRowCannotLeakItsProposedCategoryIntoLaterCommit`; `testImportNeverPostsToArchivedCategoryWithMatchingName` |
| A-003 | P1 | Restore identity/relationship validation missed duplicate logical IDs, exact revision suffixes, unordered inverse-rate duplicates, duplicate split IDs, and transaction-kind-specific split categories. All are rejected before live replacement. | `testRestoreRejectsMalformedRelationshipWithoutChangingLiveSnapshot`; `testRestoreRejectsDuplicateLogicalIDsWithoutChangingLiveSnapshot`; `testRestoreRejectsRecordPayloadIDMismatchWithoutChangingLiveSnapshot`; `testRestoreRejectsDuplicateUnorderedExchangeRatePairOnSameDay` |
| A-004 | P1 | A crash/failure after locked-capture draft persistence but before inbox removal could later promote the same capture after its transaction committed. Queue append/remove now return authoritative counts; Save removes any surviving source copy before journal commit while the SQLCipher draft remains retryable. | `testReviewedCaptureRemovalFailureCannotCreateDuplicateTransaction`; `testLockAfterCaptureHandoffCommitsExactlyOnceAndLeavesNoQueueCopy` |
| A-005 | P1 | Restore, import, and locked-capture reads trusted metadata or one-shot `FileHandle` reads. `BoundedFileReader` now loops partial reads through an exact max+1 sentinel; all three call sites enforce limits. | `testBoundedFileReaderConsumesToEOFAndStopsOneBytePastTheLimit` plus import/capture envelope tests |
| A-006 | P1 | Locked capture/UI amount work could parse before rejecting oversized input. All money text now has a 128-byte pre-parse ceiling; payee/note/date/count/uniqueness are bounded. | `testLockedCaptureRejectsUnboundedOrInvalidEnvelopeFields`; oversized CSV token test |
| A-007 | P1 | Schedule, savings-goal, and investment lifecycle dates admitted non-finite values in some construction/mutation/decode paths. All affected boundaries now reject them before mutation. | `testScheduleRejectsNonFiniteLifecycleDatesAtEveryWriteBoundary`; goal/investment non-finite suites |
| A-008 | P1 | Investment disposals did not centrally validate finite dates, positive exact amounts, currency consistency, realized arithmetic, or deterministic sequence. The model now validates and throws without consuming lots on failure. | Expanded `InvestmentPortfolioTests` |
| A-009 | P1 | Recovery quarantine did not fully reject parent cycles/kind mismatches, shared investment positions, or ledger mismatches. Relationship validation/quarantine now prevents affected data entering calculations. | account/investment restore and book-validation tests |
| A-010 | P1 | Auto-lock treated clock rollback/invalid elapsed time as not expired. It now fails closed at negative/non-finite elapsed time and exact timeout. | `testAutoLockUsesExactBoundaryAndTreatsClockRollbackAsUnsafe`; `testZeroDelayAndInvalidLifecycleClockLockImmediately` |
| A-011 | P2 | Receipt media sniffing could mislabel unrelated ISO-base media/random bytes. JPEG/PNG signatures and HEIC `ftyp` box/brand validation are now exact; unknown media is rejected. | `ReceiptAttachmentTests` |
| A-012 | P2 | Some write/domain errors were not guaranteed safe/localized, and successful backup/restore retained passwords in SwiftUI state. Safe presentation coverage was expanded and passwords clear after success. | safe-error tests; `DataSafetyView` review |
| A-013 | P2 | Category suggestion ties depended on input order. Tie-breaking is stable and deterministic. | `testEqualCountAndRecencyTieIsDeterministicAcrossInputOrder` |
| A-014 | P2 | Decimal keyboards lacked a reliable Done route and some Quick Log write failures were inline-only. Shared keyboard toolbars and an accessible alert/field errors were added. | source review; physical accessibility case remains open |
| A-015 | P2 | CI did not retain coverage/failure evidence and mutable tool/action resolution weakened reproducibility. Actions are commit-pinned, XcodeGen is checksum-verified, Xcode 16.4 build 16F6 and Simulator SDK 18.5 are exact-checked, warnings are errors, and core logs, both coverage reports, and the app-model result bundle are retained. | `.github/workflows/ci.yml`; exact run open |
| A-016 | P2 | Portable archive input checks lacked independent PBKDF vectors and strict malformed version/KDF/password coverage. These boundaries and tests were added. | `testPortableArchivePBKDFMatchesIndependentSHA256Vectors` and archive negative tests |
| A-017 | P3 | A no-op OCR downcast produced a warning and schema documentation still named an old schema. The cast was removed and docs were aligned to the then-current schema 4/current collections; A-048 records the later schema-6 completion. | static review and release validator |
| A-018 | P1 containment | Backup and restore used unrelated literal size policy and could present an archive as ready even when the same UI would reject it. Named policy limited new seals to 64 MB, retained a 250 MB v1-open/import ceiling, and added safe bilingual errors. This containment was superseded by A-047's current-format streaming envelope. | portable archive boundary assertions; `testStorageMetricsMatchExactSnapshotByteTotals`; release validator |
| A-019 | P1 | TestFlight validated one exported IPA but used a second `exportArchive` operation for upload, so the transferred bytes were not proven identical. The workflow now pins and cross-job compares Xcode build/SDK/runner-image identity, exports once, records the IPA SHA-256, validates and `altool`-uploads that same path, and checks recovery-tree entry type/path/mode/symlink target/file size/content for the xcarchive (including dSYMs) and export directory plus exact IPA bytes after decryption. Owner, timestamps, xattrs, and ACLs are intentionally outside that digest. The validator rejects weaker toolchain checks, missing tree proof, or a second export/upload binary. | `.github/workflows/testflight.yml`; `Scripts/validate_release_assets.py`; local symlink/mode/dSYM round-trip fixture passed; authenticated exact-candidate run open |
| A-020 | P1 | Locked-capture promotion could cross lock/restore/onboarding boundaries or replay a handoff, and its save API did not bind the submitted mode to the redacted route the user opened. Promotion now participates in lifecycle serialization, preserves FIFO provenance, treats a duplicate append retry as idempotent even at the 100-item capacity boundary, removes the authoritative inbox item before journal commit while retaining the encrypted draft for retry, resumes queued promotion after first-run onboarding, and accepts only the exact eligible requested mode. | `testLockWaitsForCapturePromotionAndKeepsOneDurableDraft`; `testRestoreCannotCrossCapturePromotionHandoff`; `testReviewedCaptureRemovalFailureCannotCreateDuplicateTransaction`; `testLockedCaptureDuplicateRetryRemainsIdempotentAtCapacity`; `testCompletingFirstRunOnboardingPromotesExistingLockedCapture`; `testLockedCaptureRejectsMismatchedAndProtectedRoutes` |
| A-021 | P1 | Restore accepted several internally decodable but relationally impossible books. Pre-replacement validation now rejects duplicate physical singletons, hierarchy cycles/kind mismatches, malformed or duplicate system roles, unauthorized system-account postings, schedule/link disagreement, unowned/shared investment events or positions, ledger-currency mismatches, and unaudited budget-attribution remaps. | Strict restore suite from `testRestoreRejectsDuplicatePhysicalSingletonRecords` through `testRestoreBudgetAttributionRequiresExactPostingOrAuditedRemap`; `testValidRestoreCommitsAfterIsolatedValidation` |
| A-022 | P1 | Editing a confirmed schedule could retain stale occurrence identity when an effective term changed. Every posting-relevant term now invalidates confirmation/resolution, while a whitespace-normalized no-op preserves it. | `testEditingConfirmedScheduleTermsInvalidatesTheOldOccurrence`; `testEveryEffectiveScheduleTermInvalidatesConfirmation`; `testNoOpScheduleEditPreservesConfirmedOccurrenceIdentity` |
| A-023 | P1 | Privacy state could expose underlying controls to assistive input, extend the auto-lock deadline on inactive-to-background transition, or leave the latest debounced draft unflushed. The inactive cover now removes underlying hit-testing/accessibility, records the first inactive instant, and immediately flushes the latest encrypted draft. | `testAutoLockDeadlineStartsWhenInactiveAndBackgroundCannotExtendIt`; `testBecomingInactiveFlushesLatestQuickLogDraftWithoutDebounce`; physical app-switcher/VoiceOver gate remains open |
| A-024 | P2 | Receipt grids decoded full-size attachments, and several UI dates followed the device zone instead of the book's reporting zone. Receipt thumbnails now downsample with orientation and size/input limits; shared reporting-date formatting and paged History bounds retain the book-zone civil day. | `ReceiptThumbnailDecoderTests`; `testReportingDateFormattingUsesBookTimeZoneAcrossTravelBoundary`; `testPagedHistoryWidensIndexAcrossExtremeOriginAndReportingZones` |
| A-025 | P1 | Missing Keychain material could be silently replaced while SQLCipher main/WAL/SHM or locked-capture ciphertext still existed, and backup/restore could omit an outstanding capture inbox. Key creation now fails closed on every database artifact, existing capture ciphertext requires its original key, and portable backup/restore is blocked until the capture inbox is reviewed. | `testDatabaseKeyCreationRequiresEveryCiphertextArtifactToBeAbsent`; `testDatabaseKeyPolicyChecksMainWALAndSharedMemoryPaths`; `testBackupAndRestoreBlockWhileLockedCaptureInboxIsPending` |
| A-026 | P1/P2 | Historical corrections rejected required archived endpoints, while Insights/History used category names or a single ID for duplicate-name and Other drill-through; changing category scope could also retain the prior scope's currency boundary. Corrections now retain only the archived ledger items already present; chart identity/filtering use exact stable ID sets including every Other member, and category-scope mutation clears stale posting currency. | archived split/transfer correction tests; `testDuplicateNamesKeepDistinctSelectionIdentityAndExactOtherMembers`; `testCategorySetUsesStableIDsAndTheSamePostingCurrency`; `testEmptyCategorySetFailsClosedInsteadOfMatchingAllHistory`; `testChangedCategoryScopeClearsItsPreviousPostingCurrencyBoundary` |
| A-027 | P1 | Import deduplication could conflate sources, let corrected external IDs create a second entry, or omit transfer destination/received-value semantics. Canonical source namespaces, hashed case-sensitive external identities, legacy compatibility scoped to the same source, and complete transfer/FX fingerprints now govern preview and atomic commit. | CSV identity/fingerprint tests in `TransactionCSVImporterTests`; `testCorrectedExternalImportIDCannotCreateASecondEntry`; `testImportFingerprintNamespaceCanonicalizesSourceButSeparatesSources`; semantic transfer/FX dedupe tests |
| A-028 | P1 | Lazy books could mutate only the recent journal window, lose the entry's original civil-day context during schedule/import attribution, trust stale/forged attribution rows at startup, or leave a closed-month carry checkpoint stale after merge/edit/date/delete history. Historical mutations now fetch the required complete/targeted data, scheduled/imported entries preserve origin context, startup uses bounded targeted recovery plus strict exact-posting/audited-remap validation, and affected checkpoints recompute atomically through the attributed civil month. | `testLazyJournalEditsAndDeletesEntryOlderThanRecentCacheExactly`; `testScheduledBudgetAttributionPreservesPlus14AndMinus12CivilMonths`; `testCSVImportBudgetAttributionPreservesPlus14AndMinus12CivilMonths`; `testRecoveringStartupFailsBudgetProjectionClosedForInvalidAttribution`; `testTargetedJournalRecoveryBatchesIDsAndChecksPayloadIdentity`; `testMergeThenHistoricalAmountDateAndDeleteRecomputeCheckpointExactly` |
| A-029 | P1 | An older async projection could publish across a journal commit; already-published balances/reports/widget percentages/reference counts/recent entries/count could remain actionable while a writer crossed its commit boundary; a failed retained-journal write could leave the widget unavailable despite an unchanged durable book; and a lock deferred during standalone CSV import was never resumed. Writers now invalidate in-flight reads before suspending, fail published derived state/widget/reference-currentness/recent-cache currentness closed before commit, clear the lazy cache/count so stale rows cannot render, block destructive “unused” decisions on stale references, revision-check publication, republish the coherent precommit retained state after failure, coalesce/defer refresh through mutation end, and apply the deferred import lock after its exact atomic commit. | `testProjectionReadCannotPublishBetweenJournalCommitAndRefresh`; `testPublishedProjectionFailsClosedBeforeJournalCommitAndRecovers`; `testRetainedJournalWriteFailureRepublishesCoherentPrecommitWidget`; `testLockDeferredDuringCSVImportAppliesAfterExactCommit` |
| A-030 | P1 containment | Erase deleted ciphertext before its keys, so interruption could leave readable data under retained Keychain material, and an interrupted cross-store erase had no durable resume contract. Erase now persists a Keychain intent before destruction; startup completes that intent before any store/key open; the main database key is deleted before main/WAL/SHM, then the capture key/inbox, and the marker is cleared last. Mark failure performs no destructive step, every later failure retains the marker for idempotent retry, and pending/unreadable intent denies and forgets locked-capture routing. Erase cannot overtake an already-accepted capture append: it returns without destruction and must be retried after the append finishes. The two stores still cannot form one atomic Keychain/filesystem transaction, so physical interruption evidence remains open. | `testEraseDuringPendingCommitWaitsThenRemovesTheCommittedDatabase`; `testErasePersistsIntentBeforeDeletingMainKeyAndClearsItLast`; `testEraseIntentWriteFailurePerformsNoDestructiveStep`; `testPendingEraseFailureLeavesIntentAndBookArtifactsCryptographicallyErased`; `testStartupCompletesPendingEraseBeforeOpeningReplacementStore`; `testStartupCleanupFailureKeepsEraseIntentAndNeverOpensDatabase`; `testStartupRetriesClearFailureIdempotentlyBeforeOpeningOnce`; `testPendingEraseIntentDeniesAndForgetsLockedCaptureRoute`; `testEraseIntentReadFailureFailsClosedForLockedCapture`; `testAcceptedLockedCaptureWriteBlocksEraseUntilAppendFinishes`; physical power-loss case remains open |
| A-031 | P1 | A new-write password cap could have made an older v1 portable archive with a longer password unrestorable, while using an unbounded password directly in every PBKDF round exposed a restore cost multiplier. New seals now cap normalized UTF-8 password bytes; v1 open preserves the historical no-length policy, performs HMAC-SHA256's equivalent one-time reduction for keys over 64 bytes, and retains canonical-Unicode key compatibility. | `testPortableArchivePBKDFMatchesIndependentSHA256Vectors`; `testPortableArchiveBoundsTheNormalizedPasswordBytes`; `testPortableArchiveOpensLegacyLongPasswordVersionOneArchive` |
| A-032 | P1 | A queued compact projection could capture the journal revision only after its unstructured task started and thereby adopt a writer's newer revision; a successful older task could also clear a newer deferred-refresh marker after an actor reentrancy gap. Scheduling now snapshots the revision before enqueue, publication requires that exact revision, and successful publication clears the marker in the same actor turn so a superseding writer retains recovery ownership. | `testQueuedProjectionCannotAdoptAWriterRevisionBeforeItsTaskStarts`; adjacent projection race tests; source review of the final revision-guarded actor turn (no dedicated post-publish/pre-return hook) |
| A-033 | P1 | Immediate encrypted backup could cancel a pending debounced Quick Log draft and snapshot an older or absent form revision, making the latest user input unrecoverable after power loss. Backup now awaits the draft-write chain, writes the exact in-memory draft with error propagation, and only then snapshots and seals the store. | `testImmediateBackupFlushesLatestQuickLogDraftIntoLiveStoreAndArchive` |
| A-034 | P1 | An authenticated restore candidate could amplify budget-attribution validation by making every remapped entry rescan a long shared supersession lineage and lifecycle graph, with no cancellation or aggregate work limits. Restore now applies record/revision/attribution/posting/audit/reference ceilings, observes cancellation in bounded batches, rejects cycles, forks/shared ancestry, and nonfunctional lifecycle graphs, indexes disjoint revision chains so total lineage traversal is linear, and answers each valid remap reachability query from an interval index. Normal startup uses the same cancellation-aware linear graph rules without the restore-only archive ceilings. | `testRestoreAcceptsAFunctionalMultiHopLifecycleRemap`; `testRestoreRejectsSharedLineageAmplificationBeforePerEntryTraversal`; `testRestoreIdentityValidationObservesCancellation`; `testRestoreCandidateRecordLimitBoundaries` |
| A-035 | P1 | Restore identity limits were applied only after copying the candidate into a disposable database, record replacement did not observe cancellation throughout, canceling a task could interrupt the compensating live-store rollback/reload, and a pre-replacement failure could republish an intentionally cleared retained journal as a current empty book. Identity validation now runs before the temporary-store copy with explicit parent-cancellation propagation; replacement checks cancellation before and during its transaction and rolls back on error; pre-replacement failure restores the unchanged retained projection; once live replacement has occurred, a fresh uncanceled recovery task restores the pre-restore snapshot, rebuilds its indexes, and reloads one coherent book before returning the original cancellation/error. | `testSnapshotRestoreCancellationRollsBackUnlessRecoveryIsUninterruptible`; `testRestoreIdentityValidationObservesCancellation`; `testCancellationAtRestoreCommitBoundaryLeavesLiveSnapshotUnchanged`; `testCancellationAfterRestoreCommitRecoversJournalIndexesAndBalance`; `testRetainedRestoreFailureRepublishesTheUnchangedJournal` |
| A-036 | P1 | Recovering-load account quarantine and core budget-cycle validation re-walked parent chains from each node, making a deep valid hierarchy quadratic and able to make authenticated book opening appear hung; invalid cycle/orphan descendants also needed one consistent classification. Both paths now use iterative memoized tri-state/tri-color traversal, account screening observes cancellation every 256 inspections, descendants inherit invalidity, category reassign/merge validation reuses that classifier, and retained account/holding checks reuse one indexed account map. | `testAccountHierarchyScreeningHandlesDeepChainsAndInvalidDescendants` (12,000 levels); `testDeepAcyclicHierarchyIsAcceptedWithoutQuadraticTraversal` (10,000 nodes); existing lifecycle hierarchy tests; source review of shared account-index consumers |
| A-037 | P1 | Typed journal `RecordWrite` construction suppressed decode cancellation/failure into a missing normalized index, and the SQL write boundary could then persist a journal payload without its chronological/posting/balance projection. Journal construction now propagates cancellation and rejects undecodable or physical-ID-mismatched payloads; normal writes require the derived index before `BEGIN`; restore/migration index derivation also preserves cancellation instead of treating it as malformed data. | `testCancelledJournalRecordWriteCannotLoseItsNormalizedIndex`; `testNormalWriteRejectsAnUnindexedJournalPayloadBeforeCommit`; normalized-ledger/index diagnostics tests |
| A-038 | P1 | A direct-UUID payload stored under a different physical key could survive a later canonical update/delete and resurrect stale state; duplicate logical accounts could also trap eager defensive lookups. Normal writes and restore now require the exact canonical payload UUID as physical key. Recovery preserves legacy ciphertext but reports and excludes each noncanonical alias; an exact canonical non-journal row remains authoritative, while a journal alias also quarantines its canonical twin from every live aggregate/read path and a receipt alias makes cascade deletion fail closed. Shared History/XLSX lookups remain nontrapping if independently handed duplicate accounts. | `testUUIDIdentifiedWritesAndRecoveryRejectPhysicalAliases`; `testLegacyLowercaseJournalAndReceiptAliasesAreQuarantined`; `testRecoveringStartupQuarantinesAliasedAccountIdentityWithoutResurrection`; `testRecoveringStartupExcludesCanonicalJournalTwinFromEveryReadPath`; `testRestoreCandidateRejectsSingleLowercaseUUIDPhysicalKey`; `testDuplicateAccountIdentityCannotTrapHistoryLookup`; `xlsxDuplicateAccountIdentityUsesFirstValueWithoutTrapping` |
| A-039 | P1 | Cancellation during recovering journal decode or page decode could be swallowed as a malformed row and return a truncated success to History, mutation, or recovery callers. Both read paths now propagate `CancellationError` and cannot publish a partial page as complete. | `testCancelledRecoveringJournalFetchCannotReturnATruncatedSuccess`; `testCancelledJournalPageCannotReturnATruncatedSuccess` |
| A-040 | P1 privacy | The original root overlay did not cover SwiftUI sheets above its presentation controller, and inactive/active, startup, failed-recovery, authentication-cancellation, or deferred-mutation callback order could briefly reveal decoded controls or leave the unlock UI permanently covered. A scene-level shield window now covers sheets as well as the root; the first inactive event immediately hides/disables the underlying accessibility/hit-test tree, launching/failed states participate in expiry, and every cancellation/failure/deferred-lock ordering clears decoded state before revealing locked UI. | `testLaunchingStateTracksExpiredInactivityAndKeepsAuthenticationCover`; `testCancelledStartupAuthenticationClearsCoverInBothCallbackOrders`; `testCancelledAuthenticationClearsDecodedRecoveryState`; `testFailedStartupCompletesDeferredLockBeforeRemovingCover`; `testFailedRecoveryStateAutoLocksAtBackgroundDeadline`; `testExpiredAutoLockKeepsPrivacyCoverWhileRestoreDrains`; source review of `ScenePrivacyShield`; physical sheet/app-switcher/multiwindow/VoiceOver gate remains open |
| A-041 | P1 | CSV review deduplicated raw names before case/diacritic normalization, so variants such as `Cash`/`CASH` or `Café`/`Cafe` could trap dictionary construction; import resolution could also accept or fall through to hidden system/investment-position accounts. One resolver now normalizes and deduplicates every reviewed name domain, and commit resolution permits only active non-system source/destination accounts and kind-correct non-system categories. | `testReviewedNamesCollapseCaseAndDiacriticVariantsInEveryDomain`; `testImportCannotFallThroughWrongCurrencyMappingToHiddenPosition`; `testImportRejectsMaliciousSystemAccountAndCategoryMappings` |
| A-042 | P1 | Backup could materialize an unbounded database before learning that the archive was too large, while strict domain validation during backup could either lose a quarantined raw row or make an otherwise exportable recovery copy unavailable. A constant-memory SQL metrics pass and shallow byte-preserving validation contained that path; A-047 later replaces the snapshot materialization and 32 MB containment ceiling with the v2 streaming envelope. | `testStorageMetricsMatchExactSnapshotByteTotals`; `testBackupPreservesQuarantinedRawRowsWithoutRunningStrictRestoreDecode`; A-047 |
| A-043 | P1 | An authenticated archive could place excessive work inside one legal top-level row and reach expensive domain decode or SQL replacement before rejection. Restore now bounds top-level record count and aggregate record-ID bytes, per-record collection/ID/payload bytes, and every nested journal-posting, holding-activity, savings movement/reset, schedule-resolution, Quick Log split, budget-timeline, and lifecycle journal/schedule/holding reference shape before domain/SQL work. Domain encode/decode/write boundaries enforce their matching per-record caps; aggregate nested validation stays cancellation-aware. | `testRestoreWorkLimitsRejectOversizedNestedRowsBeforeDomainDecode`; `testLifecycleAuditRejectsCombinedAffectedRecordOverflowOnEncodeAndDecode`; `testScheduleLifecycleValidationPreservesCancellation`; `testInvestmentLedgerIntegrityPreservesCancellation` |
| A-044 | P1 | Archive derivation/open and isolated restore work could continue after caller cancellation; a crash could accumulate unique validation databases; and even a wrong-password attempt could race past the latest debounced draft. PBKDF, seal/open, schedule/investment replay, snapshot fetch, and detached App tasks now preserve cancellation; restore uses one owned validation directory and scavenges only its exact legacy UUID children at startup and before reuse; every attempt durably flushes the latest draft before archive authentication. | `testPortableArchivePBKDFChecksCancellationDuringDerivation`; `testPortableArchiveSealAndOpenPreserveDetachedCancellation`; `testScheduleLifecycleValidationPreservesCancellation`; `testInvestmentLedgerIntegrityPreservesCancellation`; `testRestoreScavengesPowerLossValidationArtifacts`; `testWrongPasswordRestorePersistsLatestDraftAcrossCloseAndReopen` |
| A-045 | P1 | Locked-capture recovery treated temporary Keychain/file unavailability like definitive key loss or invalid ciphertext and could discard a recoverable capture after a stale check. Recovery now distinguishes retryable unavailability; a successful or retryable recheck clears/downgrades the stale unrecoverable marker, while destructive discard occurs only after a fresh definitive missing-key/invalid-ciphertext result. | `testLockedCaptureRecoveryNeverDeletesAfterTransientOrStaleFailure` |
| A-046 | P1 | SQLite rollback failure was suppressed, allowing callers to continue through a transaction whose durable state was indeterminate. Restore rollback failure now closes/poisons the connection and maps a restore-indeterminate error; generic write/remove-all rollback failure likewise closes and maps transaction-state-indeterminate. Reopen proves the old committed snapshot remains readable, while the in-process model fails closed. | `testRestoreRollbackFailureClosesConnectionAndReopenRecoversOldSnapshot`; `testWriteRollbackFailureClosesConnectionAndReopenRecoversOldSnapshot` |
| A-047 | P1 | The 32 MB backup payload ceiling and whole-book snapshot/archive copies could deny recovery to a valid receipt-heavy book. Archive version 2 now writes a fixed authenticated header plus 1 MiB AES-GCM frames directly from a SQL cursor, binds frame index/length/count to reject truncation/append/duplication/reorder, imports through owned files, and decode-inserts into one rollback-safe SQL transaction. Current writes are capped at 100,000 records/512 MB payload, and v1 remains readable. | `testPortableArchiveVersionTwoStreamsMultipleChunksAndRejectsFrameDamage`; `testBudgetAttributionIndexOverridesRewrittenJournalAndStreamsArchive`; physical near-limit/interruption gate open |
| A-048 | P1 | Normal startup decoded every budget attribution and recurring rollover replay began at the earliest activation month. Schema 6 now maintains normalized attribution entry/posting indexes with semantic SHA-256 integrity fingerprints, applies historical category overrides in bounded SQL, sends only mismatches/remaps to the exact audit validator, and persists one authoritative opening-carry checkpoint per reporting month. Backdated mutations retain the explicit full-recompute path. | `testBudgetAttributionIndexOverridesRewrittenJournalAndStreamsArchive`; existing attribution-integrity/checkpoint regressions; oldest-device p95 gate open |
| A-049 | P2 privacy | Explicit attachment previously preserved original GPS/EXIF/TIFF device metadata. The source is now transient for OCR; retention applies orientation, bounds the longest edge to 4,096 pixels, and re-encodes JPEG/PNG pixels without copying source properties. Bilingual UI/privacy/security copy states the boundary. | `testSanitizerRemovesLocationEXIFAndDeviceMetadata`; `testSanitizerAppliesOrientationAndBoundsRetainedPixels`; physical Photos/network gate open |

## Remaining blockers and source-remediation evidence

### O-001 — P1 source remediated; archive physical evidence remains open

Version 2 closes the current-book availability and whole-book-copy defects in
source. Trigger-maintained metrics enforce a 100,000-record/512 MB stored-payload
envelope at every current write. Production backup streams one SQL row into a
bounded record encoder and 1 MiB authenticated frames; SwiftUI exports the file
without converting it to one `Data`/`FileWrapper`. Restore imports to an owned
file, authenticates each header-bound frame, and decode-inserts into a single
SQLCipher transaction. Frame-count, index, and length authentication rejects
truncation, append, duplication, and reordering. Every accepted current book has
a complete v2 representation within the 640 MB archive ceiling.

Version 1 remains intentionally compatible through 250 MB. CryptoKit's v1
single-box format and outer JSON/base64 envelope are memory-mapped but cannot be
made chunk-authenticated without changing that historical format. This is no
longer a current-format backup-availability defect, but compatible near-limit v1
peak memory must be measured on the oldest supported iPhone. Version-2 near-limit
memory, force termination, corruption, cancellation, and power-loss cases also
remain required. Until those pass, POR-04/POR-05/SEC-05/QA-05 remain physical
release gates rather than source-closure claims.

### O-002 — P1 evidence: exact-candidate compilation/tests/coverage not run

The Linux review environment has no `swift`, `xcodebuild`, `xcodegen`,
`swiftlint`, `semgrep`, or Apple Simulator. Therefore none of the 514 declared
tests, warnings-as-errors compilation, app/widget build, or coverage reports
has run against this exact candidate SHA at the time of this report. Baseline
workflow status predating these changes is not candidate evidence.

Required resolution: push this branch, run the pinned CI workflow, inspect all
failures/warnings, publish the two coverage artifacts, review uncovered
critical branches, and repeat on the final SHA.

### O-003 — P1 release evidence: physical and exact-binary gates remain open

Open cases include real background termination/power loss, 0.5.1-to-0.6.0
TestFlight installation, clean-device restore, passcode/biometry/Keychain
behavior, app-switcher and widget privacy, all widget families/appearances,
English/Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce Motion,
oldest/current iPhones, receipt/photo-picker behavior, and the Golden p95
budgets with 10,000 entries and 20 schedules. Near-limit v2/v1 archive memory,
monthly checkpoint behavior, receipt metadata fixtures, and archive interruption
are included in that device work. The cross-store key-first erase
sequence also needs interruption at each Keychain/filesystem boundary. The
workflow now fails closed unless TestFlight preflight/signing share the pinned
Xcode build, SDK, and runner image, and unless the archive/dSYM/export tree and
IPA survive the encrypted recovery round trip; no authenticated dispatch has
yet supplied that evidence. The exact TestFlight IPA, App Review
metadata/screenshots, and export-compliance classification require
release-owner/legal confirmation; repository settings are not proof of those
external facts. `FIRST_TEST.md` is the execution runbook; a document is not a
pass result.

### O-004 — P1 source remediated; oldest-device p95 evidence remains open

Schema 6 stores original attribution day/timestamp/postings in normalized SQL.
Healthy startup checks compact counts/integrity and does not materialize the
attribution history. Any day/posting mismatch or lifecycle remap triggers the
existing exact JSON/audit validator, retaining fail-closed behavior for crafted
or exceptional books. Closed-month projection reads only the requested indexed
day range, and the first healthy replay each month persists an opening-carry
checkpoint. Recurring unlocks begin at the latest checkpoint; backdated edits
explicitly load/recompute the affected history.

The 10,000-entry/20-schedule cold-start, checkpoint creation, subsequent unlock,
backdated invalidation, and rollover p95 measurements remain mandatory on the
oldest/current supported iPhones. Until measured, TOD-01/PLN-02/PLN-07/QA-04
remain physical performance gates.

### O-005 — P2 source remediated; physical privacy evidence remains open

Explicit retention no longer stores original image bytes. The sanitizer applies
orientation, bounds the longest edge, and re-encodes a fresh JPEG/PNG without
copying the source property dictionary. Automated fixtures assert removal of
GPS, EXIF user comments, and TIFF make/model and verify bounded orientation.
Privacy, security, and bilingual UI copy now describe this behavior. A physical
Photos fixture plus exact-binary network observation still must confirm the
integrated picker/OCR/retention path.

## Independent 0.4.0 audit closure map

All D-01 through D-23 have a source-level correction and regression/manual
anchor in the current tree. Their exact-candidate execution state remains open.

| Audit ID | Source-level closure | Evidence anchor |
|---|---|---|
| D-01 | Locale-matched editable amount and unchanged reconciliation no-op | amount parser/keyboard and account-balance tests |
| D-02 | Purchases move cash to a ledger-linked position | investment no-double-count tests |
| D-03 | Currency minor units/new-write magnitude/checked Decimal | `MoneyTests`, write-boundary tests |
| D-04 | Foreign spending is retained/disclosed; dated rates are explicit | period/rate/Plan cases |
| D-05 | Malformed records quarantine while raw data remains recoverable | persistence quarantine/recovery cases |
| D-06 | Shared Gregorian half-open boundaries | financial-period and midnight tests |
| D-07 | `DerivedValue` propagates unavailable state rather than zero | invalid budget/goal/net-worth tests |
| D-08 | Account/source/destination currency labels | Quick Log source plus physical label case |
| D-09 | Refund route/UI/parser reverse expense | refund factory/parser/filter/report cases |
| D-10 | Direct/bounded occurrence lookup and range-scoped Calendar query | recurrence and Calendar cases |
| D-11 | Retired inert lock flag; real archive lifecycle actions | profile migration/lifecycle cases |
| D-12 | Latin word boundaries, retained CJK substring matching | smart-entry boundary cases |
| D-13 | Locale-aware smart/receipt amount grammar | smart/receipt comma-decimal cases |
| D-14 | Trailing 12-month trend independent of selected period | trend-context tests |
| D-15 | Key retrieval and SQLCipher open run in a detached task | `AppModel.start`; physical unlock p95 open |
| D-16 | Currency formatter cache keyed by locale/currency | `MoneyFormatterCache`; physical scroll open |
| D-17 | Shared `accountsByID` index used by rows | `AppModel.accountsByID`, `TransactionRow` |
| D-18 | Budget tree cache keyed by revision/profile | budget-cache invalidation test |
| D-19 | Calendar performs one indexed range load for the selected day | `CalendarView.loadSelectedActuals` |
| D-20 | Normalized journal/posting indexes, bounded recent cache, keyset pages | 10,000-entry persistence/history tests |
| D-21 | Widget uses semantic adaptive assets/styles | widget appearance matrix open |
| D-22 | CSV begins with BOM | exporter/importer tests |
| D-23 | Empty Calendar omits flow; multiple currencies are labeled | daily-flow tests and physical UI case |

## Dependency and supply-chain review

| Component | Resolution | Review result / residual risk |
|---|---|---|
| SQLCipher.swift / SQLCipher 4.18.0 | Exact Git revision `f879fffaaa3ad3541a77830daad4a28726dfa927`; official binary target/checksum in upstream manifest | Only runtime package; no MoneyUp runtime networking. License/notices are present. The upstream wrapper/release was inspected, but a binary XCFramework is not equivalent to a reproducible source build or independent binary audit. |
| XcodeGen 2.46.0 | CI downloads the official release and verifies SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` | CI-only build tool; checksum pinned. |
| `actions/checkout` 7.0.1 | Commit `3d3c42e5aac5ba805825da76410c181273ba90b1` | Immutable CI pin, `persist-credentials: false`. |
| `actions/upload-artifact` 7.0.1 | Commit `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` | Immutable CI pin. |

Primary references: [SQLCipher.swift 4.18.0](https://github.com/sqlcipher/SQLCipher.swift/releases/tag/4.18.0),
[SQLCipher 4.18.0](https://github.com/sqlcipher/sqlcipher/releases/tag/v4.18.0),
[XcodeGen releases](https://github.com/yonaskolb/XcodeGen/releases),
[checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), and
[upload-artifact 7.0.1](https://github.com/actions/upload-artifact/releases/tag/v7.0.1).

No SBOM/CVE scanner (`syft`, `osv-scanner`, `trivy`) was available. That is a
residual evidence gap, not evidence of no vulnerabilities.

## Local verification completed

| Check | Result |
|---|---|
| `Scripts/validate_release_assets.py` | Pass: bilingual localization, offline boundary, privacy manifest, Info.plist, icons/brand, docs, fixture, project, and TestFlight workflow checks |
| Workflow parse/shell/recovery fixture | Pass: both YAML files parse, every embedded `run` block passes Bash syntax, and a local encrypted archive/export/IPA round trip preserves a dSYM, symlink, executable mode, type/path/mode/target/size/content tree digests, and exact IPA bytes; owner/timestamps/xattrs/ACLs are outside the digest and this is not a signed TestFlight run |
| Localization/JSON/plist parsing | Pass |
| `git diff --check` | Pass |
| Tracked empty-file scan | Pass |
| Runtime-network API/source scan | Pass: no runtime networking path found |
| TODO/FIXME and merge-marker scan | Pass in shipped source/configuration |
| Dynamic SQL review | User data is prepared/bound; `sqlite3_exec` use is limited to constant schema/transaction/PRAGMA statements |
| Force/precondition review | Remaining cases are static validated literals, nonempty system buffers, immutable journal preconditions, or test-only construction; no user-data force unwrap was accepted silently |
| Secret-pattern/config review | No committed credential/private-key payload found by local pattern inspection; dedicated secret scanner unavailable |

These are static/local results. They do not replace compiler, test, coverage,
Simulator, signed-binary, or physical evidence.

## Coverage and promotion decision

- Requirement traceability: 97/97.
- Test-source inventory: 514 declarations (252 core, 49 persistence, 213 app
  target; XCTest methods plus Swift Testing `@Test` declarations).
- Exact-branch executed tests: 0 in this environment.
- Exact-branch line/function/branch coverage: unavailable until CI runs.
- Source-remediated findings awaiting CI/physical evidence: O-001 archive scale,
  O-004 budget-attribution/checkpoint scale, and O-005 receipt metadata.
- Open evidence P1s: O-002 exact-candidate CI and O-003
  physical/exact-binary/release-owner gates.

**Do not promote to wider TestFlight or App Review.** First make every
exact-candidate CI job green and review coverage gaps. Then run the complete
physical archive/performance/privacy/accessibility/upgrade matrix and reconcile
the same candidate SHA/build before any promotion decision.
