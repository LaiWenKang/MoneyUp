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

## 0.7.0 W1 presentation boundary

The Observation and service decomposition is retained as visually neutral.
It changes no palette value, typography, layout, animation, tab identity,
artwork, chart encoding, widget payload, or user-visible string. Views obtain
the same `AppModel` through the Observation environment, but only properties
read by a view participate in its invalidation graph. This state-delivery
change is not evidence for any unperformed screenshot, accessibility, motion,
or physical-device matrix; those presentation gates remain open.

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
prominent control fills use `#34785F` in both appearances. This preserves at
least 4.5:1 contrast with their white foreground and 3:1 separation from the
deep-charcoal canvas; release validation checks both ratios.

## Widget rule

Quick-action widget timelines remain data-free. The 0.7.0 source candidate
offers an opt-in budget-status surface backed by a versioned App Group snapshot
containing only availability/state and an integer percentage. It receives no
amount, payee, account name, holding, balance, transaction, or ledger
identifier. Disabled or unavailable states use honest guidance rather than a
fake statistic; over-budget status uses text and shape as well as color.

The percentage surface still requires the final physical Home/Lock Screen
family, redacted, light, dark, and tinted matrix on the exact signed candidate.
