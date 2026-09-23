# RadromRing

面向 iPhone 14 Pro（`iPhone15,2`）、iOS 17.0（`21A329`）、Relaxin 0.5.3 / ElleKit 1.2-1 的 RootHide tweak。

当前包是只读运行时探针：它确认来电铃声相关类、进程、声音类型和声音 ID；不会改铃声或联系人。取得目标设备的调用记录后，再将诊断 hook 替换成随机铃声逻辑和“设置”配置页。

## GitHub Actions 构建

所有 Theos/RootHide 编译都由 `.github/workflows/build.yml` 中的 GitHub Actions 完成。构建成功后，下载 `RadromRing-probe-roothide` artifact 中的 `.deb`。

## 设备验证

安装探针包后，进行至少一次未知来电和一次设置了专属铃声的联系人来电。探针日志位于：

```text
/var/mobile/Library/Caches/RadromRingProbe.log
```

日志只含声音类型/声音 ID、来电状态和联系人匹配状态；不记录来电 UUID、联系人记录 ID、电话号码或联系人姓名。将日志取回后即可确定正式 tweak 的目标进程、selector 和联系人专属铃声判定点。
