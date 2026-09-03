# MoneyUp Visual System

MoneyUp uses adaptive soft green on warm off-white or deep charcoal. The
horned-money emblem is the product identifier: one architectural pair of cow
horns above exactly three ascending folded-money pillars. It must not be
replaced by the retired three-bars-and-arrow mark or turned into a cartoon
mascot.

## Information rule

- Financial quantities use text, monospaced digits, and precise flat 2D charts,
  bars, rules, labels, and selection states.
- Dimensional illustration is decorative only. It may establish hierarchy or
  atmosphere, but it must never encode an amount, percentage, status, forecast,
  or comparison.
- Color never carries status by itself. Overspend also uses a label and warning
  glyph; chart selections expose exact text values and accessible drill-through.
- Large Dynamic Type switches dense horizontal groups to vertical layouts.
- No decorative asset is required to understand or operate a screen.

## 0.7.0 W6 design primitives

`MoneyUpTypography` defines Dynamic Type-relative financial-value roles with
monospaced digits. The `moneyUpFinancialValue` modifier consumes that policy
and the shared `MoneyUpMotion.financialValue` decision at runtime, disabling
animation for its value subtree so a displayed amount is never delayed behind
interpolated digits. Quick Log confirmation animation and transition also use
the shared motion policy. Reduce Motion removes MoneyUp-owned movement while
native tab and sheet transitions remain system-owned.

`MoneyUpCard` now supports `flat`, `raised`, and `floating` elevation. `raised`
remains the source-compatible default and retains the previous surface, radius,
padding, and border in the standard accessibility environment. Every style uses
an opaque semantic color rather than a material. Reduce Transparency removes
the floating shadow and replaces the accent gradient with a solid primary
border; Increase Contrast strengthens and widens the boundary. Explicit
per-call background colors remain caller-owned. `MoneyUpFeedback` permits
supplemental haptics only for consequential completion or failure. Its resolver
suppresses those haptics unless the caller simultaneously renders visible
status. Quick Log and locked capture use that boundary, and release validation
rejects direct `sensoryFeedback` calls elsewhere. Navigation, selection, and
presentation receive no MoneyUp-added haptic.

These source policies and focused tests are not screenshot or physical-device
evidence. Light/dark, Dynamic Type, VoiceOver, Reduce Motion, Reduce
Transparency, Increase Contrast, and current/oldest-device review remain open.

## 0.7.0 W1 presentation boundary

The Observation and service decomposition is retained as visually neutral.
It changes no palette value, typography, layout, animation, tab identity,
artwork, chart encoding, widget payload, or user-visible string. Views obtain
the same `AppModel` through the Observation environment, but only properties
read by a view participate in its invalidation graph. This state-delivery
change is not evidence for any unperformed screenshot, accessibility, motion,
or physical-device matrix; those presentation gates remain open.

## 0.7.0 W6 contrast palette

Every semantic colorset is keyed by light/dark appearance and normal/high
contrast. The reviewed values are frozen byte-for-byte after one dark-normal
`BrandAction` correction for elevated-canvas contrast; every other normal slot
is unchanged. W6 also adds high-contrast variants and ordered chart roles.

| Token | Light normal | Dark normal | Light high | Dark high |
|---|---:|---:|---:|---:|
| `AccentColor` | `#34785F` | `#82CEAE` | `#1F6047` | `#A4E7CA` |
| `BrandAction` | `#34785F` | `#347F60` | `#245F49` | `#377B61` |
| `BrandBackground` | `#F7F9F6` | `#101512` | `#FCFDFB` | `#080B09` |
| `BrandMist` | `#D4EAD8` | `#3C6349` | `#B8D9C4` | `#557D64` |
| `BrandSurface` | `#EEF4F0` | `#18211D` | `#E7EDE8` | `#121A16` |
| `BrandSurfaceElevated` | `#FAFBF9` | `#202923` | `#F3F6F2` | `#17201B` |
| `ChartSeries1` | `#117733` | `#59C69B` | `#075F29` | `#7EE0B2` |
| `ChartSeries2` | `#1F6680` | `#68B7D0` | `#00536D` | `#8AD7EE` |
| `ChartSeries3` | `#8C6500` | `#E0B44C` | `#725000` | `#FFD071` |
| `ChartSeries4` | `#7A3E9D` | `#C68BE0` | `#633080` | `#E2A9F5` |
| `ChartSeries5` | `#A53F5B` | `#E7899D` | `#8B2947` | `#FFA8B8` |
| `ChartSeries6` | `#332288` | `#9A8EE0` | `#24126E` | `#B9AEFF` |

Release validation parses those keys rather than relying on asset order. It
requires meaningful graphical colors to separate from every app canvas by at
least 3:1, white-bearing action fills by at least 4.5:1 and from background,
surface, and elevated canvases by at least 3:1, and adjacent chart series
(including the wrap from 6 to 1) to remain separated by CIE76 Delta E 30 under
standard, full-severity protan, and full-severity deutan simulation. An
in-memory mutation replays the former dark action and must fail the elevated
canvas threshold.
Chart data marks, including the aggregate Other bar, use validated palette
slots and remain fully opaque; selection uses a primary dashed rule rather than
dimming unselected geometry. The release gate composites every rendered series
pixel against all three semantic canvases, requires at least 3:1, rejects
opacity in either BarMark path, and executes in-memory mutations that
reintroduce `0.34` opacity or bypass the shared selection policy. The policy
declaration itself is closed and mutation-tested: line width must be positive,
and its dashed encoding must contain only positive segments.

The automated color-vision heuristic covers standard, protan, and deutan only;
it does not assert a tritan threshold or clinical perception equivalence.
Labels, income/expense symbols and shapes, grouping/position, exact amount
annotations, dashed selection rules, and accessible values remain mandatory so
meaning is not color-only. Tritan/blue-yellow filtering, grayscale, and
VoiceOver remain explicit physical acceptance gates.

Widget semantic colors mirror the four app appearance/contrast modes without
changing the versioned data-free/bounded snapshot payload. The exact signed
candidate still needs the physical light, dark, high-contrast, grayscale,
tinted, and VoiceOver matrix.

## Assets

| Asset | Purpose | Source sizes |
|---|---|---|
| `MoneyUpBrandMark` | App, launch, calculation, and widget identity | 384 / 768 / 1152 px template PNG |
| `MoneyUpMoneyWorld` | Onboarding, Today, History, Assets, and guided empty states | 256 / 512 / 768 px adaptive light/dark PNG |
| `MoneyUpScenarioStudio` | Plan empty state and budget what-if simulator | 256 / 512 / 768 px adaptive light/dark PNG |

The dimensional source assets were created with OpenAI's built-in
image-generation mode on 26 August 2026. The production prompts specified isolated objects,
adult premium fintech materials, `#34785F` forest green, `#82CEAE`
mint, warm off-white highlights, subtle architectural horns, and explicit bans
on text, numbers, currency symbols, fake data, arrows, faces, mascots, blue,
gold, and watermarks. On 26 August 2026 the approved image-generation CLI
fallback removed the uniform light/dark source backdrops, preserved the
appearance-specific rendering, and emitted 8-bit RGBA production cutouts.
The production asset contract requires genuine alpha with decontaminated edges;
release validation decodes the PNG scanlines and requires substantial fully
transparent and fully opaque regions. Generated checkerboards and baked
light/dark rectangles are rejected. `MoneyUpIllustration` uses onboarding, hero, empty, and inline roles
instead of arbitrary screen-specific heights, and inline decoration disappears
at accessibility text sizes.

Accent and filled-action green are separate semantic roles. Dark appearance
keeps the bright `#82CEAE` mint for links, icons, and decorative emphasis, while
prominent fills use `#347F60`; light normal remains `#34785F`. Each action fill
keeps at least 4.5:1 contrast with white and 3:1 separation from background,
surface, and elevated canvases; release validation checks every pairing.

## Widget rule

Quick-action widget timelines remain data-free. The 0.7.1 source candidate
offers opt-in Budget Status and Smart Overview surfaces backed by a versioned
App Group snapshot containing only state, bounded percentages/counts, expiry,
and optional next-commitment timing. It receives no amount, payee, account
name, holding, balance, transaction, or ledger identifier. Disabled or
unavailable states use honest guidance rather than a fake statistic;
over-budget and review states use text and shape as well as color.

The widget surfaces still require the final physical Home/Lock Screen
family, redacted, light, dark, and tinted matrix on the exact signed candidate.
