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
The 0.5.1 asset contract requires genuine alpha with decontaminated edges;
release validation decodes the PNG scanlines and requires substantial fully
transparent and fully opaque regions. Generated checkerboards and baked
light/dark rectangles are rejected. `MoneyUpIllustration` uses onboarding, hero, empty, and inline roles
instead of arbitrary screen-specific heights, and inline decoration disappears
at accessibility text sizes.

## Widget rule

The current widget timeline owns no financial snapshot. Its horned mark,
ambient bars, dimensional action glyphs, and soft-green layers are deliberately
data-free. A future opt-in budget-status widget may show a real percentage only
after its setting, migration, persistence, redaction, and lock-screen tests are
implemented; fake sample statistics must never be used as decoration.
