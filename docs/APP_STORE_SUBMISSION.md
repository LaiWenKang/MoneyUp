# App Store Submission Working Copy

Last reviewed: 24 August 2026

This file is the source of truth for App Store Connect entry. Verify every
claim against the exact archived binary before submission.

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
> whose spending rolls up correctly. See actual and scheduled money flow on a
> finance calendar, explore on-device charts, and track accounts, cards,
> liabilities, and manually valued investments.
>
> Smart entry can read a receipt or screenshot and understand a typed phrase.
> Recognition and suggestions run on your iPhone; images are not retained or
> uploaded. Privacy-redacted Home and Lock Screen widgets open authenticated
> Expense, Income, Transfer, Smart Entry, or Receipt actions without displaying
> financial values.
>
> MoneyUp requires no account and contains no ads or tracking. Its local
> SQLCipher database uses a random device-protected key. Data leaves the app
> only when you explicitly export a spreadsheet-friendly CSV file.
>
> Highlights:
> • fast expense, income, and transfer logging
> • nested monthly budgets with accurate roll-up
> • selectable-period charts and deterministic insights
> • actual and recurring projected finance calendar
> • accounts, cards, loans, brokerages, and manual holdings
> • multi-currency records shown without hidden conversion
> • English and Simplified Chinese
> • encrypted, local-first storage
>
> MoneyUp is a recordkeeping and planning tool, not financial, investment, tax,
> or legal advice.

Version 1.0 release notes:

> Welcome to MoneyUp. Log spending, plan nested budgets, review charts and a
> finance calendar, track accounts and holdings, and export to Numbers or
> Excel—all with encrypted local-first storage and no MoneyUp account.

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
> 查看实际与计划资金流；使用本机图表了解收支；管理账户、卡片、负债和手动
> 估值的投资持仓。
>
> 智能录入可识别收据或截图，也能理解一句话记账。识别与建议均在 iPhone
> 本机运行，图片不会被保留或上传。主屏幕与锁定屏幕的隐私保护小组件不会显示
> 财务金额，可在身份验证后打开支出、收入、转账、智能记账或选择小票操作。
>
> MoneyUp 无需注册，不含广告或追踪。本地 SQLCipher 数据库使用随机、受设备
> 保护的密钥。只有你主动导出时，数据才会生成可供 Numbers 或 Excel 打开的
> CSV 文件。
>
> MoneyUp 是记录与规划工具，不构成财务、投资、税务或法律建议。

1.0 版本说明：

> 欢迎使用 MoneyUp。快速记账、规划多层预算、查看图表与财务日历、管理账户
> 和持仓，并导出至 Numbers 或 Excel；所有核心数据均加密保存在本机，无需注册。

## TestFlight information

Beta description:

> MoneyUp is a private local-first budget app. This founders beta covers fast
> logging, nested budgets, a finance calendar, insights, assets, a redacted
> widget, on-device smart entry, and CSV export in English and Simplified
> Chinese. Use sample data first; portable encrypted restore is still being
> completed.

What to test:

> Follow the in-app Privacy and beta guide. Focus on onboarding, background
> locking, expense/income/transfer logging, nested budget roll-up, schedule
> projections, charts, holdings, widget shortcuts, confirmed deletion, update
> data retention, and CSV export. Hide all private values in feedback images.

Private TestFlight fields are entered by the Account Holder directly in App
Store Connect and are intentionally not stored in Git:

- a monitored feedback email, preferably a dedicated MoneyUp support mailbox;
- the Beta App Review contact's real name and email;
- a reachable review phone number in international `+country-code` format.

Before a public App Store submission, publish a monitored direct contact on the
Support URL and verify that both English and Simplified Chinese users can find
it. TestFlight's private feedback email is sufficient for the two-founder beta
but is not a replacement for a public support contact.

## App Review notes

> MoneyUp does not require an account, credentials, subscription, bank login,
> or network connection. On first launch, MoneyUp creates a protected local
> book after confirming that the iPhone has a device passcode; choose a base
> currency, first account, and optional opening balance. After setup, reopening
> the protected book requires Face ID, Touch ID, or the device passcode.
>
> Suggested review path: add a small expense from the leftmost Log tab; set a
> monthly limit in Plan; verify the transaction in Plan > Calendar and Insights;
> background and reopen the app to see authentication; open Assets to export
> CSV after the plaintext warning; and add privacy-redacted Home and Lock Screen
> widgets.
>
> The receipt reader uses PhotosPicker and Apple's on-device Vision framework.
> The image is not stored or uploaded. The app has no advertising, analytics,
> remote AI, or financial-data backend. The widget contains no financial
> values and only deep-links to the authenticated app.

No demo account is required because there is no account system.

## Privacy answers

For the current binary:

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

1. Today — liquid position, budget progress, and recent sample activity
2. Log — fast, editable entry with smart text
3. Plan > Budget — multi-level budget and remaining amount
4. Plan > Calendar — actual and projected money flow
5. Insights — category and cash-flow charts
6. Assets — accounts, cards, holdings, and net worth
7. Privacy — local encrypted processing and no tracking

Capture both English and Simplified Chinese sets. Use coherent fictional data,
consistent dates, strong contrast, large readable copy, and no claims that are
not visible in the app.

## Final submission checklist

- membership and agreements active;
- bundle identifiers and signing valid for app and widget;
- CI green on submitted commit;
- archive version/build unique and matches release notes;
- exact encrypted `.xcarchive` and dSYMs saved in durable private storage, with
  symbols uploaded to Apple;
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
