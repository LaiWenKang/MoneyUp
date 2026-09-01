# MoneyUp automated performance baseline

This source-configured W4.1 baseline observes optimized production paths before
the required physical-device run. It is a regression evidence mechanism, not a
release-budget substitute. An exact candidate has evidence only after its CI
job completes and the retained artifacts are reviewed.

## Fixture and measured paths

`MoneyUpPerformanceTests` creates one logically/domain-deterministic encrypted
fixture before any XCTest measurement block. It consumes the committed W2
`intelligence-v1` oracle, verifies its SHA-256
`4c33ed9e0b8082a6c5af936fe7399195c30f4045a01583bad5c6eaccd6945fa5`,
canonically reproduces the generator's complete 10,000-row KWD/SGD/USD CSV,
and verifies logical-payload SHA-256
`92fe646bbcc7e52fc11a340266a194d3d18b1b147ef70ff53ffab1026a495df5`.
The store contains those exact 10,000 journal entries, 10,000 matching
budget-attribution records, and exactly 20 schedules named `Fixture Schedule
01` through `Fixture Schedule 20`. SQLCipher salts, pages, and resulting file
bytes are not claimed to be deterministic. Mutating measurements use database
copies or empty destination stores prepared before measurement; export input
and restore archives are also prepared before the operation they measure.

Before measurement, the harness checks exact recurrence/lapse/price,
duplicate, and anomaly finding signatures against the oracle; verifies all
three observation currencies and transfer/split intelligence exclusions; and
checks the persisted refund, transfer, split, ledger, count, and relationship
invariants. This reuses the W2 intelligence-v1 scale corpus. It does not claim
the broader transaction-lifecycle/operation coverage of the upcoming W5
QA-v2 fixture.

The serial Release suite records an isolated store open+close lifecycle (each
invocation closes and releases its store), compact store load, save against a
10,000-entry store, bounded History page/query, CSV plus XLSX export, streaming
archive, transactional restore, bounded receipt-text processing, journal plus
20-schedule projection, and indexed intelligence retrieval/detection at the
production 5,000-observation cap. XCTest
collects clock, CPU, memory, and logical storage-write metrics wherever its iOS
test runner supports them. There are three recorded XCTest measurement
iterations; mutating inputs also reserve XCTest's one unrecorded warm-up
invocation. There is no absolute memory ceiling or timing threshold in this
observational baseline.

Receipt measurement starts after deterministic OCR lines exist; Vision/photo
decoding, camera/photo-picker behavior, real receipt accuracy, peak resident
memory under Instruments, thermal/energy behavior, and UI scrolling remain
physical work.

## CI execution and retained evidence

CI generates the Xcode project, requires Xcode 16.4 build 16F6 and the iOS 18.5
Simulator SDK/runtime, erases and boots one exact iPhone 16 Pro Simulator, then
runs only `MoneyUpPerformanceTests` from the `MoneyUpPerformance` scheme in
Release with parallel testing disabled and one worker.

The `iphone-simulator-performance-baseline` artifact retains:

- `MoneyUpPerformanceTests.xcresult`, including the fixture-manifest
  attachment and raw XCTest measurements;
- `performance-metrics.json` and `performance-summary.json`, exported by
  Apple's `xcresulttool`;
- `performance-environment.json`, binding source SHA, Xcode/build, SDK,
  runtime, Simulator device/UDID, runner image/hardware, fixture counts,
  oracle/corpus digests, configuration, iteration count, and serial-execution
  state;
- `performance-evidence-manifest.json`, binding every exported evidence file
  to a size and SHA-256 and confirming raw-result presence;
- `performance-tests.log` and the discovered runtime inventory.

The raw result bundle is authoritative when an exported summary is incomplete.
No result may be compared across different source, runner, toolchain, runtime,
configuration, fixture-profile, or iteration identities without labeling that
difference.

## Release-evidence boundary

Simulator measurements can expose large regressions and preserve a reviewable
starting point, but physical-device gates remain open. In particular, this
suite does not close the Golden p95 budgets for unlock/authentication, first
useful tab content, History debounce-to-content, save, Calendar computation, or
sustained interaction on the oldest supported iPhone. It also does not close
receipt/photo memory, archive near-limit memory/interruption, checkpoint-first
unlock, subsequent unlock, backdated invalidation, or current-device runs.

Execute and retain the physical 10,000-entry/20-schedule procedure in
[`FIRST_TEST.md`](FIRST_TEST.md) before promotion. A green Simulator job means
only that the logically deterministic harness completed and emitted evidence
on that exact environment.
