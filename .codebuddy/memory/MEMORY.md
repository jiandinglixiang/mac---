# 长期记忆

## 项目：剪贴板历史（macOS 菜单栏 App，Swift + swiftc 直编，无 Xcode 工程）
- 构建：`bash build.sh`（arm64 only，产物 `build/剪贴板历史.app`）；新增源文件需同步加入 `build.sh` 的 `SRC_FILES`。
- 风扇控制走 `--fanctl` 子命令 + `sudo -n` 提权（`main.swift` 在 NSApplication 启动前拦截）；首次授权用 osascript 写 `/etc/sudoers.d/clipboardhistory` 免密规则。
- 风扇策略：勾选后目标转速 = 最高转速 × `FanControl.boostRatio`（当前 0.8，**不是满速**）。
- 风扇控制权会被 `thermalmonitord` 回收（4s/250ms 轮询），靠 `FanSupervisor`（每 5s 只读模式位，被回收才补发）维持。详见 2026-09-01.md。
