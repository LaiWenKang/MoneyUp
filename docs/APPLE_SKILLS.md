# Apple platform skills for the coding assistant

`.claude/skills/apple/` vendors the MIT-licensed
[claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills)
library (164 skills across 23 categories: SwiftUI data flow and layout,
Swift 6.2 concurrency, HIG and accessibility audits, snapshot and flow
testing, App Store metadata and review, release checklists, design, UX writing,
SF Symbols, typography, performance and privacy manifests).

How it is used here:

- Claude Code discovers each category `SKILL.md` as a project skill and routes
  to sub-skills on demand, so the library adds no persistent context cost.
- Nothing in the folder is compiled, linked or shipped. The validators that
  scan Swift sources ignore `.claude/` explicitly; the template Swift files in
  the library are reference material only.
- Refresh by re-copying the upstream `skills/` directory and the `LICENSE`;
  record the upstream commit in this file when doing so.

Vendored from upstream `main` on 22 September 2026.

Skills most relevant to MoneyUp's current work: `design` (animation patterns,
UX writing, SF Symbols, typography), `ios` (UI review, accessibility audit,
navigation), `swiftui` (data flow, layout and containers, Charts),
`testing` (snapshot tests, flow walkthroughs), `release-review`, `app-store`.
