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

## 设备验证

目标设备为 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1。0.3.0 曾注入 `callservicesd`，用户报告首次通话失败；之后已移除该进程过滤。0.3.1 仅注入 `SpringBoard`，但设备测试仍使用固定铃声。0.3.2 将 hook 范围扩展到 `SpringBoard` 和 `MobilePhone`，并持续等待 TelephonyUtilities 的 Objective-C 类出现；仍不注入 `callservicesd`。该版本需在设备上验证默认铃声随机切换、联系人专属铃声保护、双卡与回退行为。
