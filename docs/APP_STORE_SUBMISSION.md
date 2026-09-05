# App Store Submission Working Copy

Last reviewed: 4 September 2026 for the 0.7.1 source candidate

This file is the source of truth for App Store Connect entry. Verify every
claim against the exact archived binary before submission.

Status: working copy for the source-integrated 0.7.1 beta candidate. No 1.0
binary, screenshots, privacy answers, review notes, App Review approval, or
public release is represented here as complete.

## App Review crash-resolution working note

Do not resubmit the rejected 0.3.0 (1005.1) binary. Apple's attached report for
that build is a `0x8BADF00D` scene-creation watchdog termination on iPhone 17
Pro Max / iOS 26.6: the main thread was waiting in
`SecItemCopyMatching` -> `LAContext.evaluateAccessControl` while opening the
encrypted book.

Use this note only after the exact replacement build passes CI, signed archive
validation, installation, and the `LAUNCH-01-WATCHDOG` physical matrix below:

> We identified the launch crash in build 0.3.0 (1005.1) as a scene-creation
> watchdog termination while the main thread waited for user-presence Keychain
> authentication. In the replacement build, authenticated Keychain access,
> the normal protected-book startup erase-intent check, and SQLCipher database
> construction execute away from the main/UI actor. Device-only user-presence
> protection is unchanged. We added executable main-thread regression tests and a release
> gate that also requires dSYM output. We tested cold launch, delayed and
> cancelled authentication, passcode fallback, background/foreground, and
> repeated relaunch on the submitted build.

Remove any final sentence whose named physical test has not actually passed,
and replace “replacement build” with the exact App Store Connect version/build
before sending the note.

## Product setup

- Platform: iOS, iPhone only for the first release
- Primary category: Finance
- Price: Free
- Accounts: none
- Ads, tracking, analytics, in-app purchases: none
- Minimum OS: iOS 18
- Languages: English and Simplified Chinese
- Bundle ID: `com.laiwenkang.MoneyUp`
- Widget bundle ID: `com.laiwenkang.MoneyUp.Widget`
- Shared App Group: `group.com.laiwenkang.MoneyUp` (exactly three artifacts: one
  nonfinancial language preference, one atomic bounded schema-4 summary `Data`
  value, and one bounded data-free quick-action ingress JSON file; no fourth key
  or file, exact due date, or financial record field)
- App Store record name: `MoneyUp: CowCome`
- Installed Home Screen name: `MoneyUp`
- Privacy policy: <https://github.com/LaiWenKang/MoneyUp/blob/main/PRIVACY.md>
- Support: <https://github.com/LaiWenKang/MoneyUp/blob/main/SUPPORT.md>

The App Store record and both explicit identifiers were created on the
activated team on 24 August 2026. Do not create a duplicate record or change
either bundle ID after users install a release.

## English metadata

Name: **MoneyUp: CowCome**

Subtitle: **Private budget & spending**

Promotional text:

> Log spending quickly, plan nested budgets, see cash flow and insights, and
> keep your financial records encrypted on your iPhone.

Keywords:

`budget,expense,spending,money,finance,tracker,calendar,assets,cashflow,private`

Description:

> MoneyUp is a private, local-first budget and personal-finance app for iPhone.
>
> Record expenses, income, and transfers in seconds. Build multi-level budgets
> whose spending rolls up correctly. See a plan-paced Flexible Today amount
> drawn only from allocations you classify as flexible, inspect the exact
> arithmetic behind it, and try private budget scenarios without changing
> your records, inspect on-device charts, and track accounts, cards,
> liabilities, savings goals, and manually priced ledger-linked investments
> with lots and currency-separated history.
>
> Smart entry can read a receipt or screenshot and understand a typed phrase.
> Recognition and suggestions run on your iPhone; images are never uploaded
> and are retained in encrypted storage only when you explicitly choose to keep
> one with a transaction. On eligible devices, Apple on-device assistance is
> enabled by default and can suggest a reviewed match from existing local
> account or category names, with an explicit Settings opt-out; exact
> rules keep control of financial fields and saving. Retained images are
> re-encoded without source location
> or camera metadata. Privacy-redacted Home and Lock Screen widgets open Expense, Income,
> Transfer, Refund, Smart Entry, or Receipt actions without displaying financial
> values. Basic actions can use a separate encrypted capture inbox while the
> full book remains locked. Optional Budget Status and Smart Overview
> configurations receive only bounded state, a bounded reporting-period token,
> budget and allowance percentages, review and active expense-commitment counts, expiry,
> and a reporting-calendar-derived due-day distance - never an exact due date,
> amount, payee, account name, holding, symbol, quote, balance,
> transaction/book/ledger identifier, note, attachment, or extracted evidence.
>
> MoneyUp requires no account and contains no ads or tracking. Its local
> SQLCipher database uses a random device-protected key. Data leaves the app
> only when you explicitly export a posting-level CSV/native XLSX or encrypted
> `.moneyup` backup. Reviewed Qianji/generic CSV/TSV import, including manual
> column mapping, stays on device.
>
> Highlights:
> • fast expense, income, and transfer logging
> • nested monthly budgets with accurate roll-up
> • dated rollover, sinking funds, and savings goals
> • Flexible Today with protected bills, debt, goals, and explicit exclusions
> • tappable charts, filtered History drill-through, and deterministic insights
> • a read-only on-device budget what-if simulator
> • actual and recurring finance calendar with post/match lifecycle
> • accounts, cards, loans, brokerages, and ledger-linked holdings with FIFO lots
> • multi-currency records shown without hidden conversion
> • English and Simplified Chinese
> • encrypted, local-first storage
>
> MoneyUp is a recordkeeping and planning tool, not financial, investment, tax,
> or legal advice.

Version 1.0 release notes:

> Welcome to MoneyUp. Log spending, review Flexible Today, simulate a
> budget scenario, manage rollover and goals, review tappable charts and a
> finance calendar, track ledger-linked holdings, and export to Numbers or
> Excel - all with encrypted local-first storage and no MoneyUp account.

## Simplified Chinese metadata

名称：**MoneyUp: CowCome**

副标题：**私密预算与支出记录**

推广文本：

> 快速记账、规划多层预算、查看资金流与洞察，并将财务记录加密保存在你的
> iPhone 上。

关键词：

`预算,记账,支出,财务,消费,资金流,日历,资产,账本,隐私`

描述：

> MoneyUp 是一款注重隐私、本地优先的 iPhone 预算与个人财务应用。
>
> 快速记录支出、收入和转账；创建可正确向上汇总的多层预算；在财务日历中
> 查看实际与计划资金流；使用本机图表了解收支；管理预算结转、储蓄目标、
> 账户、卡片、负债，以及与账本关联并按手动价格估值的投资持仓。
>
> 智能录入可识别收据或截图，也能理解一句话记账。识别与建议均在 iPhone
> 本机运行，图片绝不会上传，且只有你明确选择随交易保留时，才会移除源文件中的
> 位置与相机元数据并重新编码后写入加密存储。在符合条件的设备上，Apple 本机辅助
> 功能对新用户和既有用户默认开启，并可在“设置”中明确关闭；它只能从现有本机账户或
> 分类名称中提出需检查的匹配，确定性规则仍控制所有财务字段与保存。
> 主屏幕与锁定屏幕的隐私保护小组件不会显示
> 财务金额，可打开支出、收入、转账、退款、智能记账或小票操作。可选的“预算状态”
> 与“智能概览”只接收一个原子化 schema 4 快照，其中可包含有界的状态、预算／津贴
> 百分比、待检查项／有效支出承诺数量、到期时间，以及根据报告日历计算的相对到期天数；
> 不包含精确到期日期、金额、商户、账户名称、持仓、证券代码、行情、余额、交易／账本
> 标识符、备注、附件或提取的证据。账本锁定时，
> 基本操作可写入独立的加密快速记录收件箱，而完整余额仍保持锁定。
>
> MoneyUp 无需注册，不含广告或追踪。本地 SQLCipher 数据库使用随机、受设备
> 保护的密钥。只有你主动操作时，数据才会生成可供 Numbers 或 Excel 打开的
> CSV／原生 XLSX 文件或加密的 `.moneyup` 备份。在本机检查后，也可导入钱迹风格或
> 通用 CSV／TSV 文件，并为未知格式手动映射列。
>
> MoneyUp 是记录与规划工具，不构成财务、投资、税务或法律建议。

1.0 版本说明：

> 欢迎使用 MoneyUp。快速记账、规划多层预算、管理结转与储蓄目标、查看图表
> 与财务日历、管理与账本关联的持仓，并导出至 Numbers 或 Excel；所有核心
> 数据均加密保存在本机，无需注册。

## TestFlight information

Beta description:

> MoneyUp is a private local-first budget app. This founders beta covers fast
> logging, nested budgets, a finance calendar, insights, assets, a redacted
> widget, Flexible Today, rollover and savings goals, a read-only budget
> simulator, chart drill-through, on-device smart entry, indexed
> History/edit/refunds/splits, ledger-linked investments, encrypted
> backup/restore, reviewed CSV/XLSX portability, configurable app language,
> visible transaction details, category management, expiring benefit/prepaid/
> reimbursement allowances, and optional explainable
> local recurrence, duplicate, anomaly, projection, and budget suggestions in
> English and Simplified Chinese. Use sample
> data first while physical upgrade and restore drills are completed.

What to test:

> Follow the in-app Privacy and beta guide. Focus on onboarding, background
> locking, locked capture, expense/income/transfer/refund logging, History/edit,
> nested budget roll-up, Flexible Today classification/arithmetic, the what-if simulator,
> schedule edit/post/match, chart inspection/drill-through, rollover/goals,
> holding purchases/sales/repricing/lots, privacy-safe Budget Status and Smart
> Overview widgets (including large text, stale/disabled states, and reporting-
> day refresh), restricted prepaid account ownership/historical funding, policy-
> zone dates, benefit-usage corrections, evidence-only reimbursement status,
> shortcuts, confirmed deletion, language selection, visible merchant/title and
> multiline notes, category create/rename/archive/restore/merge/reassign/delete,
> intelligence opt-out and rebuild, evidence-backed recurrence/duplicate/anomaly
> findings, currency-separated projections, reviewed budget proposals, update
> data retention, encrypted restore, and CSV/XLSX export plus mapped import. Hide all private
> values in feedback images.

Private TestFlight fields are entered by the Account Holder directly in App
Store Connect and are intentionally not stored in Git:

- a monitored feedback email, preferably a dedicated MoneyUp support mailbox;
- the Beta App Review contact's real name and email;
- a reachable review phone number in international `+country-code` format.

Before a public App Store submission, publish a monitored direct contact on the
Support URL and verify that both English and Simplified Chinese users can find
it. TestFlight's private feedback email is sufficient for the founder/co-tester
beta but is not a replacement for a public support contact.

## App Review notes

> MoneyUp does not require an account, credentials, subscription, bank login,
> or network connection. On first launch, a four-step guide explains the local
> privacy model, base currency, first financial account, optional current
> balance or amount owed, and a final review before creating the protected
> local book. After setup, Today shows clear Log and Plan actions. Reopening the
> protected book requires Face ID, Touch ID, or the device passcode.
>
> Suggested review path: add a small expense from the center Log tab; set a
> monthly limit in Plan, classify its purpose, inspect Flexible Today and its
> arithmetic; try the
> read-only budget simulator; tap an Insights bar and verify filtered History;
> verify the transaction in Plan > Calendar;
> background long enough to reach the configured auto-lock delay and reopen to
> see authentication; use Settings to create an encrypted backup and preview an
> import; open Assets to export CSV and XLSX after the plaintext warning; and add
> privacy-redacted Home and Lock Screen widgets.
>
> Evidence capture uses PhotosPicker, the system PDF picker, and Apple's
> on-device Vision/PDF frameworks. Files are never uploaded and are stored in
> SQLCipher only after the user explicitly saves the transaction. Image
> metadata is removed; bounded OCR, PDF text, filenames, and visual labels are
> searchable only inside the encrypted book and never change financial facts.
> Attachment bytes and search text never enter drafts, widgets, readable
> exports, logs, or diagnostics. The app has no advertising, analytics,
> remote AI, or financial-data backend. The widget contains no financial
> amounts in quick-action timelines. Its basic actions can open a separate
> encrypted Quick Capture form; this contains no balances or database key and
> moves into the full ledger only after authenticated unlock. If the reviewer
> explicitly enables **Allow widget summaries** in Settings, the atomic bounded
> schema-4 App Group summary for Budget Status and Smart Overview contains only
> state, a reporting-period token, budget/allowance percentages, review/active
> expense-commitment counts, expiry, and a reporting-calendar-derived relative
> due-day distance. The App Group's only other artifacts are one nonfinancial
> language preference and one bounded data-free quick-action ingress JSON file;
> that file contains only schema/authority and admission metadata, opaque tokens,
> and one of six closed action values. There is no fourth key or file. None
> contains an exact due date or any financial record field listed above.

No demo account is required because there is no account system.

## Privacy answers

Intended answers for the candidate, subject to exact-binary verification:

- Tracking: No
- Data collected by the developer or third parties through the app: No
- Tracking domains: none
- Privacy policy URL: required and listed above

Re-evaluate these answers before every release. Adding analytics, remote price
quotes, sync, support uploads, hosted AI, or a backend can change the answers.

## Encryption and compliance

MoneyUp includes SQLCipher 4.18.0 and uses industry-standard encryption for
local financial data. Complete App Store Connect's export-compliance questions
truthfully. If Apple requires documentation for the selected storefronts,
submit it and wait for approval before TestFlight Beta App Review or App Review.
Do not set `ITSAppUsesNonExemptEncryption` to a guessed value merely to bypass
the questionnaire.

Declare EU Digital Services Act trader status even if the app is not offered
in the EU. The account holder must make the legal self-assessment; engineering
must not guess it.

## Screenshot plan

Capture 6.9-inch portrait screenshots in an accepted current size, with no
alpha channel and no real financial data. Apple currently permits 1–10 images.

1. Today — Flexible Today, cash versus debt, budget pace, and compact dimensional artwork
2. Log — fast, editable entry with smart text
3. Plan > Budget — multi-level budget, remaining amount, and what-if simulator
4. Plan > Calendar — actual and projected money flow
5. Insights — tappable category and cash-flow charts with selected values
6. Assets — accounts, cards, holdings, and net worth
7. Privacy — local encrypted processing and no tracking

Capture both English and Simplified Chinese sets. Use coherent fictional data,
consistent dates, the approved adaptive soft-green identity in light and dark
mode, strong contrast, large readable copy, and no claims that are not visible
in the app. Do not substitute pure-white or pure-black canvases for MoneyUp's
semantic surfaces.

## Final submission checklist

- membership and agreements active;
- bundle identifiers and signing valid for app and widget;
- the registered App Group is enabled on both App IDs, and source/profile/signed
  entitlements all contain only `group.com.laiwenkang.MoneyUp`;
- CI green on submitted commit;
- archive version/build unique and matches release notes;
- exact encrypted release recovery bundle—`.xcarchive`, dSYMs, complete export
  directory, validated IPA, and SHA-256 manifest—saved in durable private
  storage; the IPA hash matches the uploaded candidate, and App Store Connect
  symbol/crash processing is verified for that exact build;
- export compliance complete;
- privacy policy/support links publicly accessible without sign-in;
- App Privacy and age-rating answers complete;
- content-rights and trader-status declarations complete;
- accessibility common-task matrix tested before declaring any labels;
- screenshots and metadata localized;
- support URL publishes a monitored direct contact and private review contact
  information is current;
- encrypted backup/restore release gate passed;
- manual release selected for 1.0.
