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

目标设备为 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1。0.3.0 已从设备移除；它注入 `callservicesd` 后用户报告首次通话失败。当前源码的 0.3.1 修改为只允许 `SpringBoard` 加载，但尚未通过 GitHub Actions 构建或设备验证。完成无 tweak 通话基线确认后，再构建和验证双卡来电、联系人专属铃声、关闭开关、空列表及铃声删除后的回退行为。
