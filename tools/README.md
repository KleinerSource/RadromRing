# 来电铃声运行时探针

此探针用于确认目标系统实际在哪个进程调用 `TUCallSoundPlayer`，以及来电声音类型和声音 ID。它只读运行时状态，不替换铃声、不修改联系人或系统设置。

目标设备：iPhone 14 Pro，iOS 17.0（21A329），Relaxin 0.5.3，ElleKit 1.2-1。

## 使用

1. 将越狱设备通过 USB 连接到运行 Frida 的电脑，并确认设备端 Frida 服务可用。
2. 执行 `frida-ps -U`，确认设备进程可见。
3. 分别附加到 `SpringBoard` 和 `MobilePhone`，并在两种目标进程中各进行一次真实蜂窝来电测试：

   ```powershell
   frida -U -n SpringBoard -l tools/probe-call-ringtone.js
   frida -U -n MobilePhone -l tools/probe-call-ringtone.js
   ```

   若进程名不同，先从 `frida-ps -U` 读取实际进程名再附加。

4. 保存 `probe-ready`、`call-sound-request`、`call-sound-descriptor` 和 `descriptor-init` 事件，供确定最终 hook 点与来电声音类型。

探针仅记录是否为来电、是否匹配到联系人、铃声类型与系统声音 ID；不记录来电 UUID、联系人记录 ID、电话号码或联系人姓名。
