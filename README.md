# RadromRing

面向 iPhone 14 Pro / iOS 17.0、RootHide 与 ElleKit 的原生蜂窝来电随机铃声 tweak。

## 功能

- 在“设置 > RadromRing”中启用随机铃声并多选系统已有铃声，包括内置与已导入铃声。
- 每一次来电响铃都重新抽选，并避开上一次的铃声（随机池只有一首时除外）。
- 双卡：设置页按已插入的 SIM 卡数量显示选项；两张卡时可选择共用全局列表，或每张卡使用独立列表。无法识别来电卡槽时使用两个列表的合集。
- 只处理蜂窝来电铃声；能识别到来电对象时，FaceTime 与第三方 VoIP 来电不处理。
- 联系人号码配置了专属铃声时保留系统结果，即使专属铃声与默认铃声相同。
- 停用、选择为空或铃声无效时沿用系统结果。
- 不修改联系人数据或系统默认铃声。

偏好设置保存在 `com.kleinersource.radromring` 域中：`enabled`、`selectedToneIDs`（全局列表）、`perSIMEnabled`、`selectedToneIDsSIM1`/`selectedToneIDsSIM2`，以及设置页写入的 `simAccounts`（SIM 订阅 UUID → 卡槽）。

## 安装源

Sileo / Zebra 添加源：`https://kleinersource.github.io/RadromRing/`

`main` 或开发分支 `codex/random-ringtone-implementation` 每次构建成功后，Actions 用 `tools/build_repo.py` 生成 `Packages`/`Release` 索引并部署到 GitHub Pages（源中只保留最近一次构建的包）；已添加源的设备刷新后即可更新。仓库需在 Settings › Pages 中把 Source 设为 “GitHub Actions”，并在 Settings › Environments › `github-pages` 的部署分支规则中允许开发分支。

## 构建

Theos/RootHide 编译只在 GitHub Actions 执行。运行 `.github/workflows/build.yml` 的 `workflow_dispatch`，下载 `RadromRing-roothide` artifact 中的 `.deb`。

## 实现

来电铃声由 ToneLibrary 解析：每次响铃都会创建一个 `TLAlertTypeIncomingCall`（类型 1）的 `TLAlert`，其配置若没有显式 `toneIdentifier`，会向 `TLToneManager` 查询当前默认铃声。自 0.5.0 起，`+[TLAlert alertWithConfiguration:]` 被 hook：类型 1 且无显式铃声/外部铃声文件时，复制一份配置并填入新抽选的铃声，因此每次响铃都不同。联系人专属铃声以显式 ID 传入，保持不变。默认查询（`currentToneIdentifierForAlertType:[topic:]`）同样被替换，作为未经过 `alertWithConfiguration:` 的后备路径；其结果在抽选后 2 秒内（不滑动延长）复用。

来电卡槽识别：设置页用 CoreTelephony 的订阅信息检测 SIM 卡并写入 `simAccounts`；tweak 在响铃时找到振铃中的来电（InCallService 用 `TUCallCenter`，callservicesd 用对 `-[TUCall init]` 的弱引用跟踪），用其 `localSenderIdentity` 的 UUID 匹配卡槽。

注入范围为 `callservicesd` 与 `InCallService`，只做 Objective-C 方法替换。诊断信息通过 `NSLog` 以 `RadromRing:` 前缀输出（包括抽中的铃声、卡槽、候选数）。

## 设备验证

目标设备为 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1。0.3.x 的 hook 位于 `TUCallSoundPlayerDescriptor` 层且只注入 `SpringBoard`/`MobilePhone`，设备实测该层与这些进程均不解析来电铃声（SpringBoard 来电时没有类型 1 的查询），因此铃声始终为默认值。0.4.x 改为替换默认查询后随机生效，但短时间内连续来电会复用同一首；0.5.0 改为每次响铃重新抽选，并加入双卡独立列表。双卡卡槽识别依赖 CoreTelephony 订阅 UUID 与来电 sender identity UUID 一致，需在设备上确认。
