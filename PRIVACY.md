# MoneyUp Privacy Policy

Effective: 1 September 2026

MoneyUp is a local-first personal-finance app. Its core privacy rule is simple:
financial records are processed on the user's iPhone and are not sent to a
MoneyUp server.

## Data MoneyUp handles

MoneyUp lets a user enter account names and balances, transactions, budgets,
scheduled items, investment holdings, notes, payees, categories, and related
financial details. This information is stored in an encrypted database on the
device. MoneyUp does not require a MoneyUp account and does not operate an
application backend that receives these records.

The optional receipt and screenshot reader uses Apple's on-device text
recognition. The selected image is transient by default. If the user explicitly
chooses to keep the receipt for that transaction, MoneyUp applies its displayed
orientation, limits its dimensions, and re-encodes the pixels without the
source GPS, EXIF, camera/device, caption, or edit-history metadata before storing
it in the encrypted database and password-protected portable backups. It is
never added to drafts, widgets, readable CSV/XLSX exports, or uploaded. Typed
smart entry and category suggestions also run on the device.

Optional Smart Entry matching is off by default. On eligible devices, it uses
only Apple's default on-device system language model. MoneyUp first removes
parsed monetary, date, currency, and exact-name spans, then supplies a bounded
context plus at most 16 existing local names per list. The model can return
only bounded ordinals into those closed lists; it cannot return free text or
any financial field, and every match remains a visible suggestion until the
user reviews it.
If the model is unavailable, cancelled, fails, or returns an invalid ordinal,
MoneyUp silently keeps the deterministic rule-based result. No custom model
provider, server, tool, image, or receipt data is used.

If the user explicitly enables budget status for widgets, MoneyUp shares only
an availability/state value and an integer percentage through its local App
Group. That snapshot contains no amount, payee, account name, holding, balance,
transaction, book, or ledger identifier. Disabling the setting or erasing the
book removes the snapshot. Quick-action widgets remain free of financial
values.

## Collection, tracking, and advertising

MoneyUp does not include advertising, analytics SDKs, cross-app tracking,
remote generative AI, or financial-data telemetry. It does not sell personal
data. Under Apple's App Privacy definition, the app declares that it does not
collect data because app data is not transmitted off the device to MoneyUp or
a third party.

Apple may process limited installation, crash, and beta-feedback information
when a user installs a beta through TestFlight. That processing is controlled
by Apple and the user's Apple settings and is subject to Apple's privacy
policy. MoneyUp does not add a separate crash-reporting service.

## Storage and security

The local database is encrypted with SQLCipher. A random app-generated,
device-bound key is protected by the iOS Keychain, requires device-owner
presence, does not sync, and is restricted to that device. MoneyUp hides
financial content immediately when inactive, then closes the database and
clears decoded state after the user-configured auto-lock delay.

Because the live device-bound key cannot migrate, MoneyUp excludes its database
directory from system backup. A user can explicitly create a portable
`.moneyup` archive protected by an independent password and restore it
transactionally. MoneyUp cannot recover a forgotten archive password. Deleting
the app before making and verifying an archive can permanently remove the book.

## Exports and links

MoneyUp shares data only after the user deliberately starts an export and
chooses a destination in the iOS file picker. CSV and XLSX exports are readable
plaintext; password-protected `.moneyup` archives are encrypted. After export,
the selected storage provider or recipient controls the file, and MoneyUp can
no longer protect it. CSV/Qianji import parsing and matching run locally;
MoneyUp does not upload imported files.

The app may offer a user-initiated link to this policy. Opening an external
link is governed by the browser and destination site's privacy practices.

## Retention and deletion

Financial records remain in the encrypted local database until the user
deletes individual supported records or erases the app's data. Deleting the
transaction also deletes its linked encrypted receipt image; a receipt image
can also be deleted separately after confirmation. Deleting the app removes its
local container. MoneyUp has no server copy to retrieve or delete.

## Security limits

MoneyUp cannot protect information from a compromised or maliciously managed
device, someone who can use an already-unlocked phone, shared device passcodes
or biometrics, user-created screenshots, or files after export.

## Children

MoneyUp is a general budgeting tool and is not directed to children. It does
not knowingly collect personal information from children or any other user.

## Changes and contact

Material changes to this policy will be dated here and reflected in the app's
privacy disclosure. For privacy questions, open an issue at
<https://github.com/LaiWenKang/MoneyUp/issues> without including financial data,
receipts, private screenshots, keys, addresses, or other sensitive details.
Security vulnerabilities should use GitHub private vulnerability reporting
when available.

---

# MoneyUp 隐私政策（简体中文）

生效日期：2026 年 9 月 1 日

MoneyUp 是一款本地优先的个人财务应用。核心隐私原则很简单：财务记录在
用户的 iPhone 上处理，不会发送到 MoneyUp 服务器。

## MoneyUp 处理的数据

用户可在 MoneyUp 中输入账户名称与余额、交易、预算、计划收支、投资持仓、
备注、商户、分类及相关财务信息。这些信息存储在设备上的加密数据库中。
MoneyUp 无需注册，也没有接收这些记录的应用后端。

可选的收据与截图识别使用 Apple 的本机文字识别。所选图片默认只在识别期间
短暂保留；只有用户明确选择为该笔交易保留收据时，MoneyUp 才会按显示方向处理、
限制图片尺寸，并仅重新编码像素，不保留源文件中的 GPS、EXIF、相机／设备、说明或
编辑历史元数据，然后写入加密数据库及受密码保护的便携备份。图片不会进入草稿、
组件、可读的 CSV／XLSX 导出，也不会上传。文字智能录入和分类建议也完全在设备上运行。

可选的智能记账匹配默认关闭。在符合条件的设备上，它只使用 Apple 默认的本机系统
语言模型。MoneyUp 会先移除已解析的金额、日期、币种及精确名称片段，再提供有界文字
上下文，以及每个列表最多 16 个现有本机名称。模型只能返回这些封闭列表中的有界序号，
不能返回自由文字或任何财务字段；每项匹配都只作为可见建议，需由用户检查。若模型不可用、被取消、失败或
返回无效序号，MoneyUp 会静默保留确定性规则结果。此功能不使用任何供应商服务、服务器、
工具、图片、收据数据、自定义模型或自定义模型供应商。

只有用户明确启用小组件预算状态时，MoneyUp 才会通过本机 App Group 共享
可用性／状态与整数百分比。该快照不含金额、商户、账户名称、持仓、余额、
交易、账本或账本标识符。关闭此设置或抹掉账本会删除该快照；快捷操作小组件
仍不包含任何财务数值。

## 收集、追踪与广告

MoneyUp 不包含广告、分析 SDK、跨应用追踪、远程生成式 AI 或财务数据遥测，
也不会出售个人数据。按照 Apple 的“App 隐私”定义，由于应用数据不会传输
到设备之外的 MoneyUp 或第三方，应用声明“不收集数据”。

当用户通过 TestFlight 安装测试版时，Apple 可能处理有限的安装、崩溃和测试
反馈信息。该处理由 Apple 与用户的 Apple 设置控制，并受 Apple 隐私政策约束。
MoneyUp 不另行接入崩溃报告服务。

## 存储与安全

本地数据库使用 SQLCipher 加密。每次安装会生成随机密钥，并由 iOS 钥匙串
保护；读取密钥需要设备所有者验证，密钥不会同步且仅限此设备。应用进入非活跃
状态时会立即隐藏财务内容，并在用户设置的自动锁定时间后关闭数据库、清除已解码状态。

由于实时数据库的设备绑定密钥无法迁移，MoneyUp 会将数据库目录排除在系统备份
之外。用户可主动创建由独立密码保护的 `.moneyup` 便携备份，并以事务方式恢复。
MoneyUp 无法找回遗忘的备份密码。若未先创建并验证备份就删除应用，账本可能永久丢失。

## 导出与链接

只有用户主动发起导出并在 iOS 文件选择器中指定目标后，MoneyUp 才会分享
数据。CSV 与 XLSX 导出文件是可直接读取的明文，`.moneyup` 备份则受密码加密。导出后，
文件由用户选择的存储服务或接收方管理，MoneyUp 无法继续保护该文件。CSV／钱迹
导入的解析与匹配仅在本机进行，MoneyUp 不会上传导入文件。

应用可提供由用户主动打开的本政策链接。外部链接受浏览器及目标网站的隐私
规则约束。

## 保留与删除

财务记录会保留在本机加密数据库中，直到用户删除受支持的单条记录或抹掉应用
数据。删除交易会同时删除其关联的加密收据图片；用户也可在确认后单独删除收据
图片。删除应用会移除其本地容器。MoneyUp 没有可供取回或删除的服务器副本。

## 安全限制

MoneyUp 无法防范已被攻破或恶意管理的设备、可操作已解锁手机的人、共享的
设备密码或生物识别、用户主动创建的截图，以及导出后的文件泄露。

## 儿童

MoneyUp 是通用预算工具，不面向儿童，也不会主动收集儿童或任何其他用户的
个人信息。

## 变更与联系

本政策如有重大变更，将在此更新日期，并同步反映在应用隐私说明中。如有隐私
问题，请访问 <https://github.com/LaiWenKang/MoneyUp/issues> 提交问题，但不要
包含财务数据、收据、隐私截图、密钥、地址或其他敏感信息。安全漏洞应在可用时
使用 GitHub 私密漏洞报告功能提交。
