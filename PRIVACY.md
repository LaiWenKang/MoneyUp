# MoneyUp Privacy Policy

Effective: 25 August 2026

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
recognition. The selected image is held only while text is recognized; MoneyUp
does not add the image to its database or upload it. Typed smart entry and
category suggestions also run on the device.

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
chooses a destination in the iOS file picker. CSV exports are readable
plaintext; password-protected `.moneyup` archives are encrypted. After export,
the selected storage provider or recipient controls the file, and MoneyUp can
no longer protect it. CSV/Qianji import parsing and matching run locally;
MoneyUp does not upload imported files.

The app may offer a user-initiated link to this policy. Opening an external
link is governed by the browser and destination site's privacy practices.

## Retention and deletion

Financial records remain in the encrypted local database until the user
deletes individual supported records or erases the app's data. Deleting the
app removes its local container. MoneyUp has no server copy to retrieve or
delete.

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

生效日期：2026 年 8 月 25 日

MoneyUp 是一款本地优先的个人财务应用。核心隐私原则很简单：财务记录在
用户的 iPhone 上处理，不会发送到 MoneyUp 服务器。

## MoneyUp 处理的数据

用户可在 MoneyUp 中输入账户名称与余额、交易、预算、计划收支、投资持仓、
备注、商户、分类及相关财务信息。这些信息存储在设备上的加密数据库中。
MoneyUp 无需注册，也没有接收这些记录的应用后端。

可选的收据与截图识别使用 Apple 的本机文字识别。所选图片只在识别文字时
短暂保留，不会写入 MoneyUp 数据库或上传。文字智能录入和分类建议也完全
在设备上运行。

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
数据。CSV 导出文件是可直接读取的明文，`.moneyup` 备份则受密码加密。导出后，
文件由用户选择的存储服务或接收方管理，MoneyUp 无法继续保护该文件。CSV／钱迹
导入的解析与匹配仅在本机进行，MoneyUp 不会上传导入文件。

应用可提供由用户主动打开的本政策链接。外部链接受浏览器及目标网站的隐私
规则约束。

## 保留与删除

财务记录会保留在本机加密数据库中，直到用户删除受支持的单条记录或抹掉应用
数据。删除应用会移除其本地容器。MoneyUp 没有可供取回或删除的服务器副本。

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
