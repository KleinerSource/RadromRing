# RandomRing

面向 iPhone 14 Pro / iOS 17.0、RootHide 与 ElleKit 的原生蜂窝来电随机铃声 tweak。

## 功能

- 在“设置 > RandomRing”中启用随机铃声并多选系统已有铃声，包括内置与已导入铃声。
- 每一次来电响铃都重新抽选，并避开上一次的铃声（随机池只有一首时除外）。
- 双卡：设置页按已插入的 SIM 卡数量显示选项；两张卡时可选择共用全局列表，或每张卡使用独立列表。无法识别来电卡槽时使用两个列表的合集。
- 只处理蜂窝来电铃声；能识别到来电对象时，FaceTime 与第三方 VoIP 来电不处理。
- 联系人号码配置了专属铃声时保留系统结果，即使专属铃声与默认铃声相同。
- 停用、选择为空或铃声无效时沿用系统结果。
- 不读改、不写入系统默认铃声，也不修改联系人数据：卸载插件或离开越狱环境后，系统“声音与触感”中的铃声保持用户原先的设置。

偏好设置保存在 `com.kleinersource.randomring` 域中：`enabled`、`selectedToneIDs`（全局列表）、`perSIMEnabled`、`selectedToneIDsSIM1`/`selectedToneIDsSIM2`，以及设置页写入的 `simAccounts`（SIM 订阅 UUID → 卡槽）。

## 安装源

Sileo / Zebra 添加源：`https://kleinersource.github.io/RandomRing/`

`main` 每次构建成功后，Actions 用 `tools/build_repo.py` 生成 `Packages`/`Release` 索引并部署到 GitHub Pages（源中只保留最近一次构建的包）；已添加源的设备刷新后即可更新。仓库需在 Settings › Pages 中把 Source 设为 “GitHub Actions”。

主分支每次推送都会按最新提交信息自动递增版本并回写仓库：`feat:` 升次版本，`!` 或 `BREAKING CHANGE:` 升主版本，其他提交升补丁版本；`build:`、`chore:`、`ci:`、`docs:`、`style:`、`test:` 只递增构建号。更新 `CHANGELOG.md` 后，匹配的版本说明优先取自该文件；没有条目时，Release 说明由上一个标签以来的提交标题生成。

打 `v*` 标签会构建并发布 GitHub Release，同时更新 Sileo 源；源构建会生成 `depiction.json`，在 Sileo 包详情页提供“更新日志”标签。

## 构建

Theos/RootHide 编译只在 GitHub Actions 执行。运行 `.github/workflows/build.yml` 的 `workflow_dispatch`，下载 `RandomRing-roothide` artifact 中的 `.deb`。

## 实现

每次来电响铃都会创建一个 `TLAlertTypeIncomingCall`（类型 1）的 `TLAlert`。配置里没有显式 `toneIdentifier` 时，ToneLibrary 播放用户的默认铃声；联系人专属铃声则以显式 ID 传入。

自 0.6.0 起，RandomRing 只为单个响铃提醒提供铃声，与系统传入联系人专属铃声的方式相同：

- hook `-[TLAlert _initWithConfiguration:toneIdentifier:vibrationIdentifier:]`（所有 TLAlert 的指定初始化方法）。类型 1、配置中没有显式铃声也没有外部铃声文件时，把这一次提醒的铃声参数换成新抽选的铃声；配置对象本身不改。系统缺少该方法时，改为 hook `+[TLAlert alertWithConfiguration:]`，在配置的私有副本上填入铃声。
- 不再 hook `TLToneManager` 的默认铃声查询，任何进程读取到的默认铃声都是用户的真实设置；插件也从不调用任何写入默认铃声的接口。
- 防护：在注入进程中 hook `setCurrentToneIdentifier:forAlertType:[topic:]`，如果有代码试图把插件为某次响铃抽中的铃声保存为来电默认铃声，直接拦截并记录日志。

0.4.x–0.5.0 使用的是替换默认铃声查询返回值的方式（只在内存中，不写入设置），已在 0.6.0 移除。

来电卡槽识别：设置页用 CoreTelephony 的订阅信息检测 SIM 卡并写入 `simAccounts`；tweak 在响铃时找到振铃中的来电（InCallService 用 `TUCallCenter`，callservicesd 用对 `-[TUCall init]` 的弱引用跟踪），用其 `localSenderIdentity` 的 UUID 匹配卡槽。

注入范围为 `callservicesd` 与 `InCallService`，只做 Objective-C 方法替换。诊断信息通过 `NSLog` 以 `RandomRing:` 前缀输出（包括抽中的铃声、卡槽、候选数）。

## 设备验证

目标设备为 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1。0.3.x 的 hook 位于 `TUCallSoundPlayerDescriptor` 层且只注入 `SpringBoard`/`MobilePhone`，设备实测该层与这些进程均不解析来电铃声（SpringBoard 来电时没有类型 1 的查询），因此铃声始终为默认值。0.4.x 改为替换默认查询后随机生效，但短时间内连续来电会复用同一首；0.5.0 改为每次响铃重新抽选，并加入双卡独立列表。0.6.0 不再以任何形式替换默认铃声，只为单次响铃提供铃声；需在设备上确认 iOS 17.0 的来电铃声确实经由 `TLAlert` 创建（日志 `RandomRing: incoming-call alert`），并确认“设置 › 声音与触感 › 电话铃声”在多次来电后保持不变。双卡卡槽识别依赖 CoreTelephony 订阅 UUID 与来电 sender identity UUID 一致，需在设备上确认。
