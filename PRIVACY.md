# MoneyUp Privacy Policy

Effective for the cloud-backup candidate: 8 September 2026

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
never added to drafts, widgets, or readable CSV/XLSX exports, and is never uploaded for recognition. Retained receipt images are included inside encrypted cloud archives only if the user enables cloud backup. Typed
smart entry and category suggestions also run on the device.

Optional Smart Entry matching is enabled by default for new and existing
profiles, with an explicit Settings opt-out. On eligible devices, it uses only
Apple's default on-device system language model. MoneyUp first removes
parsed monetary, date, currency, and exact-name spans, then supplies a bounded
context plus at most 16 existing local names per list. The model can return
only bounded ordinals into those closed lists; it cannot return free text or
any financial field, and every match remains a visible suggestion until the
user reviews it.
If the model is unavailable, cancelled, fails, or returns an invalid ordinal,
MoneyUp silently keeps the deterministic rule-based result. No custom model
provider, server, tool, image, or receipt data is used.

MoneyUp's local App Group has an exact three-artifact allowlist: the chosen
non-financial app-language preference; one atomic, versioned schema-4 Budget
Status/Smart Overview snapshot when the user explicitly enables summaries; and
one bounded data-free quick-action ingress JSON file. The snapshot may contain state, a bounded
reporting-period token, bounded budget and allowance percentages, bounded review
and active expense-commitment counts, expiry, and a reporting-calendar-derived
relative due-day distance. The ingress file contains only schema/authority
metadata, admission state, opaque handoff tokens, and one of six fixed action
types. Neither contains an
exact due date, amount, payee, account name, holding, symbol, quote, balance,
transaction/book/ledger identifier, note, attachment, or extracted evidence;
no other App Group key or file is approved. Disabling summaries or erasing the
book removes the snapshot, and erase/restore boundaries invalidate old action
requests. Quick-action widget timelines remain free of financial values.

## Collection, tracking, and advertising

MoneyUp does not include advertising, analytics SDKs, cross-app tracking,
remote generative AI, or financial-data telemetry. It does not sell personal
data. Local-only operation does not transmit financial records. Optional cloud
backup sends encrypted archives and limited backup metadata directly to Apple
after the user enables it. The App Store privacy answers for the cloud-enabled
release must be reviewed before distribution; the earlier local-only disclosure
is not evidence that no data leaves the device when cloud backup is enabled.

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

## Optional separate-account iCloud backup

In builds configured for this feature, the user can connect an Apple Account
through Apple's hosted web sign-in without changing the iPhone's system iCloud
account. MoneyUp does not receive the Apple password. The CloudKit web session
token, user-chosen connection label, and independent archive recovery password
are stored in device-only Keychain storage. The recovery password is not sent
to Apple and is required to restore archives on another device.

After explicit opt-in, MoneyUp creates encrypted portable archives while open
and unlocked and uploads them to the selected account's private CloudKit
storage. An archive contains the book, saved receipt attachments, the current
draft, and readable pending Quick Logs. Outside the encrypted archive, Apple
receives opaque backup/book identifiers, creation times, ciphertext sizes, and
integrity hashes. Apple also processes the network and account information
needed to operate iCloud. No financial names, amounts, currencies, notes, or
receipt content are sent as readable backup metadata.

Before reporting a backup as successful, MoneyUp downloads its encrypted file
and authenticates it locally with the recovery password. This verification uses
additional data transfer and does not restore or overwrite the current book.

Backups are versioned. Interrupted uploads are retained locally in encrypted
form for retry and are not shown as completed recovery points. Sessions can
expire; backup pauses until the user reconnects. Connecting a different account
requires new backup consent. Disconnecting removes the saved connection and
recovery password from this device and stops new transfers, while keeping the
local book and completed cloud backups. Earlier backups still require their
original recovery password. Users can delete selected completed backups in
MoneyUp after confirmation. No cloud transfer occurs in an unconfigured build
or without the user's backup opt-in, except the account verification and backup
listing/download actions the user explicitly starts.

## Exports and links

MoneyUp shares data when the user deliberately starts an export and chooses
a destination in the iOS file picker, or explicitly enables optional iCloud
backup to the separately connected Apple Account. CSV and XLSX exports are readable
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
local container. Completed cloud backups remain in the connected Apple Account
until the user deletes them. Local erase also clears cloud connection credentials
and local unfinished-upload files; it does not delete completed cloud backups.
MoneyUp does not hold a developer-accessible server copy of the book.

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

云端备份候选版本生效日期：2026 年 9 月 8 日

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
组件或可读的 CSV／XLSX 导出，也不会为识别而上传。仅当用户启用云端备份时，已保留的收据图片才会包含在加密云端备份中。文字智能录入和分类建议仍完全在设备上运行。

可选的智能记账匹配对新用户和既有用户默认开启，并可在“设置”中明确关闭。在符合条件的
设备上，它只使用 Apple 默认的本机系统语言模型。MoneyUp 会先移除已解析的金额、日期、
币种及精确名称片段，再提供有界文字
上下文，以及每个列表最多 16 个现有本机名称。模型只能返回这些封闭列表中的有界序号，
不能返回自由文字或任何财务字段；每项匹配都只作为可见建议，需由用户检查。若模型不可用、被取消、失败或
返回无效序号，MoneyUp 会静默保留确定性规则结果。此功能不使用任何供应商服务、服务器、
工具、图片、收据数据、自定义模型或自定义模型供应商。

MoneyUp 的本机 App Group 只允许三类资料：非财务性的应用语言偏好；用户明确
启用小组件摘要后，为“预算状态”和“智能概览”写入的一个原子化、带版本的
schema 4 快照；以及一个有界的快捷操作接入文件。快照可包含状态、有界的报告期标记、
预算与津贴百分比、待检查项与有效支出承诺数量、到期时间，以及根据报告日历
计算的相对到期天数。该 JSON 接入文件不含财务资料，只包含架构版本／权限元数据、
接纳状态、不透明交接令牌与六种固定操作之一。
两者均不含精确到期日期、金额、商户、账户名称、持仓、证券代码、行情、余额、交易／
账本标识符、备注、附件或提取的证据；不允许其他 App Group 键或文件。关闭摘要或抹掉
账本会删除快照，抹掉／恢复边界会使旧快捷操作请求失效。快捷操作小组件的时间线
仍不包含任何财务数值。

## 收集、追踪与广告

MoneyUp 不包含广告、分析 SDK、跨应用追踪、远程生成式 AI 或财务数据遥测，
也不会出售个人数据。本地模式不会传输财务记录。用户启用可选云端备份后，
加密备份及有限的备份元数据会直接发送给 Apple。云端版本的 App Store 隐私申报
必须在分发前重新核对。

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

## 可选的独立账户 iCloud 备份

在已配置此功能的版本中，用户可通过 Apple 托管的网页登录连接另一个 Apple 账户，
不会更改 iPhone 的系统 iCloud 账户。MoneyUp 不会接收 Apple 密码。CloudKit 网页会话令牌、
用户自定义的连接标签及独立的备份恢复密码只保存在本设备的钥匙串中。恢复密码不会发送给
Apple，更换设备后需要该密码才能恢复备份。

用户明确启用后，MoneyUp 会在应用打开并解锁时创建加密便携备份，并上传至所选账户的
私有 CloudKit 存储空间。备份包含账本、已保存的收据附件、当前草稿及可读取的待处理快捷记账。
加密文件之外的元数据仅包含不透明的备份／账本标识、创建时间、密文大小及完整性哈希。
Apple 还会处理提供 iCloud 服务所需的账户及网络信息。备份元数据不会以明文发送金融名称、
金额、币种、备注或收据内容。

MoneyUp 会在报告备份成功前下载其加密文件，并使用恢复密码在本机验证。
此过程会产生额外的数据传输，不会恢复或覆盖当前账本。

备份按版本保留。未完成的上传会以加密形式留在本机等待重试，不会显示为已完成的恢复时间点。
会话过期时会暂停备份，直到用户重新连接。连接其他账户后必须重新同意备份。断开连接会停止
新传输，并移除此设备保存的连接及恢复密码；本机账本和已完成的云端备份仍会保留。较早的
备份仍需要原来的恢复密码。用户可在 MoneyUp 中确认删除指定云端备份。擦除本机数据还会
移除本机的云端连接凭证和未完成上传文件，但不会删除已完成的云端备份。

未配置云端功能的版本不会进行云端传输。已配置的版本仅会在用户明确发起账户验证、备份
列表／下载操作或同意备份后传输。云端版本的 App Store 隐私申报须在分发前重新核对，
不能继续以“数据从不离开设备”作为启用云端备份后的说明。

## 导出与链接

只有用户主动发起导出并在 iOS 文件选择器中指定目标，或明确启用所连接 Apple
账户的可选云端备份后，MoneyUp 才会分享数据。CSV 与 XLSX 导出文件是可直接读取的明文，`.moneyup` 备份则受密码加密。导出后，
文件由用户选择的存储服务或接收方管理，MoneyUp 无法继续保护该文件。CSV／钱迹
导入的解析与匹配仅在本机进行，MoneyUp 不会上传导入文件。

应用可提供由用户主动打开的本政策链接。外部链接受浏览器及目标网站的隐私
规则约束。

## 保留与删除

财务记录会保留在本机加密数据库中，直到用户删除受支持的单条记录或抹掉应用
数据。删除交易会同时删除其关联的加密收据图片；用户也可在确认后单独删除收据
图片。删除应用会移除其本地容器。已完成的云端备份会保留在用户连接的 Apple
账户中，直到用户将其删除。MoneyUp 不持有开发者可读取的账本服务器副本。

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
