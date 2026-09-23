# RadromRing

面向 iPhone 14 Pro / iOS 17.0、RootHide 与 ElleKit 的原生蜂窝来电随机铃声 tweak。

## 功能

- 在“设置 > RadromRing”中启用随机铃声并多选系统已有铃声，包括内置与已导入铃声。
- 只处理系统来电铃声；FaceTime 与第三方 VoIP 来电不处理。
- 联系人号码配置了专属铃声时保留系统结果，即使专属铃声与默认铃声相同。
- 每通电话只选择一次；停用、选择为空、铃声无效或必要的来电信息不可用时沿用系统结果。
- 不修改联系人数据或系统默认铃声。

偏好设置保存在 `com.kleinersource.radromring` 域：`enabled` 与 `selectedToneIDs`。

## 构建

Theos/RootHide 编译只在 GitHub Actions 执行。运行 `.github/workflows/build.yml` 的 `workflow_dispatch`，下载 `RadromRing-roothide` artifact 中的 `.deb`。

## 实现

来电铃声由 ToneLibrary 解析：`TLAlertTypeIncomingCall`（类型 1）的提醒若没有显式 `toneIdentifier`，会向 `TLToneManager` 查询当前默认铃声。0.4.0 只替换这一默认查询（`currentToneIdentifierForAlertType:[topic:]` 且类型为 1）的返回值；联系人专属铃声以显式 ID 传入，不经过默认查询，因此保持不变。同一次响铃中 10 秒内的重复查询复用同一选择。

注入范围为 `callservicesd` 与 `InCallService`，只做 ToneLibrary 的 Objective-C 方法替换，不再 hook `TUCallSoundPlayer`（它负责回铃音等固定提示音，并非来电铃声）或 AddressBook C 函数。诊断信息通过 `NSLog` 以 `RadromRing:` 前缀输出。

## 设备验证

目标设备为 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1。0.3.x 的 hook 位于 `TUCallSoundPlayerDescriptor` 层且只注入 `SpringBoard`/`MobilePhone`，设备实测该层与这些进程均不解析来电铃声（SpringBoard 来电时没有类型 1 的查询），因此铃声始终为默认值。0.4.0 需在设备上验证默认铃声随机切换、联系人专属铃声保护、双卡、普通拨出/接听以及停用与空列表回退。
