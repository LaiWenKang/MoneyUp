# MoneyUp 0.7.4 public update

On 9 October 2026 the owner asked for a further UI/UX pass and chose to ship
0.7.3 unchanged and do the pass as 0.7.4, in a "bolder and expressive"
direction. On 11 October the owner asked for 0.7.4 release preparation and
acceptance, without publishing to TestFlight or the App Store yet.

## Baseline

- 0.7.2 (1076.3) is live (Ready for Distribution).
- 0.7.3 (build 1079.5, source ef54a5b) was submitted on 11 October 2026 after
  the owner's physical-iPhone check: Waiting for Review, release after
  approval, submission 82d5d8c6-445d-4c1a-8b2e-f3d29bb84882.
- 0.7.4 is 0.7.3 plus #125 (StoreKit release-gate budget) and #126 (the design
  pass) on main 1163b61, plus this release preparation.

## Changes since 0.7.3

- One headline figure per screen (#126): `.hero` amounts use a 44 pt display
  size scaled with Dynamic Type, on one line, shrinking before a number would
  wrap; the currency code or symbol steps down one size by size only, so colour,
  contrast and VoiceOver text are unchanged. Used on Today, Plan and Assets.
- The lead card washes mist into the elevated surface (`MoneyUpHeroSurface`),
  within the 50% mist the validator proves secondary text against; measured
  5.23:1 light and 5.31:1 dark at its most tinted corner.
- Savings goals and accounts keep a stable identity colour from a palette that
  excludes the warning and danger slots; pace bars keep their status colours.
- Plan's month, currency and period controls sit on the page; goals drop the
  title icon that repeated the dial's symbol; the amount-privacy toolbar action
  is an outline icon-only `Label`, tinted like the other toolbar actions.
- Section chips in Plan and History share one selection highlight that slides
  under the `.selection` spring; press feedback is a 3% scale with a light fade.
  Amounts never animate, and Reduce Motion removes all of it.
- Release tooling (#125): the required StoreKit purchase test has a 20-minute
  budget (passing runs took 167–550 s against 600 s).
- No permission, data use, purchase, privacy answer, entitlement, dependency or
  encryption change.

## Store metadata

- What's New is rewritten for 0.7.4 in English and Simplified Chinese; the
  description, keywords and promotional text are unchanged from 0.7.3.
- The review notes say the update is visual and usability only (the core-flow
  rounds #129–#140 were folded in on 2026-10-17) and keep the camera,
  notification, Siri and lock-cover explanations.
- The 16 screenshots and both App Previews are rendered from this source; the
  previews get their silent stereo AAC track from
  `Scripts/finalize_appstore_movie.swift`. The support review capture is the
  reviewed 0.7.2 file.

## Validation and outstanding gates

- Main 1163b61 (#125 and #126 merged): CI (Core tests, Release assets, iOS
  Simulator build, performance baseline) and the iOS 26 interaction review
  (native review 43m41s) passed; the seven validators pass locally.
- This branch at 663bb97: the seven validators and their 225 tests pass; package
  tests pass; the app unit suite passes 945/945 on iPhone 17 Pro (iOS 26.5) and
  iPhone SE (iOS 27.0) (the four StoreKit tests run in the release gate); all 34
  UI journeys pass on 17 Pro iOS 26.5, SE iOS 27.0, 17 Pro iOS 27.0 and SE iOS
  26.5. The built app and widget report version 0.7.4. CI on the pull request
  (#127) passed all required checks.
- All 16 screenshots differ from 0.7.3 and were checked by eye in both
  languages. One preview frame (about 10 s) shows History's brief loading row,
  as the 0.7.3 preview did.
- Not done yet, by the owner's instruction of 11 October: the TestFlight upload,
  the owner's physical-iPhone check of that build, and App Store Connect
  prepare and submit. This branch merges only after Apple approves 0.7.3.
