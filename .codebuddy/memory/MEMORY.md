# 长期记忆

## 项目：剪贴板历史（macOS 菜单栏 App，Swift + swiftc 直编，无 Xcode 工程）
- 构建：`bash build.sh`（arm64 only，产物 `build/剪贴板历史.app`）；新增源文件需同步加入 `build.sh` 的 `SRC_FILES`。
- 风扇控制走 `--fanctl` 子命令 + `sudo -n` 提权（`main.swift` 在 NSApplication 启动前拦截）；首次授权用 osascript 写 `/etc/sudoers.d/clipboardhistory` 免密规则。
- 风扇策略：勾选后目标转速 = 最高转速 × 用户设定百分比（设置面板滑块，20%~100%，默认 80%，**不是满速**）。百分比存 `FeatureSettings.fanBoostPercent`；`FanControl.boostRatio` 是它的计算属性。2026-09-13 前为写死的 0.8。
- **提权子进程读不到用户设置**：`--fanctl` 以 root 运行，UserDefaults 落在 root 域，所以按比例算出的 RPM（含 Ftst 解锁后其余风扇的兜底目标）必须由 App 侧算好传入，不能在建 root 进程里读 `FeatureSettings`。
- 风扇控制权会被 `thermalmonitord` 回收（4s/250ms 轮询），靠 `FanSupervisor`（每 5s 只读模式位，被回收才补发）维持。详见 2026-09-01.md。
- SMC 手动模式不会随睡眠/合盖清除，风扇会一路转到唤醒；因此 `FanSupervisor` 会在合盖（`AppleClamshellState`）或 `willSleep` 时把所有风扇 `auto` 交还系统（阻塞等待），开盖/唤醒后恢复。设置开关 `fanReleaseWhenClosed` 默认开。详见 2026-09-08.md。
- **风扇处于 SMC 手动/强制模式会阻止 macOS 睡眠**，所以不能只等 `willSleep`（它正因为风扇被强制而不来）→ 必须在**黑屏/锁屏**那一刻就交还控制权。2026-09-09 起 `FanSupervisor` 还监听 `screensDidSleep/Wake`、`sessionDidBecomeActive`、分布式通知 `com.apple.screenIsLocked/Unlocked`；挂起判定 = 合盖 || `CGDisplayIsAsleep(CGMainDisplayID())` || 已锁屏；挂起期间巡检降到 15s。`CGSSessionScreenIsLocked` 已不可用，锁屏只能靠通知。详见 2026-09-09.md。

## 历史窗口渲染与存储架构（2026-09-14 性能重构后，改动前务必遵守）
- **卡片必须用视图池**：`HistoryWindowController` 只建「可见 + 两侧缓冲」约 16 张 `ClipboardItemView`，滚动时按可见 index 区间复用改内容（`rebuildCardPool()` 重建池 / `refreshVisibleCards()` 刷新区间）。改动前是一次性建 200 张（227 ms、1200 子视图）——**不要再退回全量建视图**。
- **卡片视图的 `index` 才是它代表的条目下标**，池数组下标与 `items` 不再一一对应；点击命中一律走 `itemAtWindowPoint`（按 frame.contains + `boundItem`），键盘/滚动定位按 index 数学算（`cardX(for:)`）。
- **卡片背景禁止用 `NSVisualEffectView`**（实时 backdrop 是最大合成开销）：现用 `backgroundView` 普通 layer 半透明纯色（alpha 由 `AppearanceSettings.cardBackgroundAlpha` 映射），选中态靠背景色 + 蓝色描边，阴影必须设 `layer.shadowPath`。
- **窗口 `hasShadow = false`**（非不透明 + 全宽 + 内容每帧变化会被反复重算窗口阴影）；窗口底层那层全宽 `.behindWindow` 毛玻璃保留（实测已不构成开销）。
- 图片：`ThumbnailCache`（ImageIO 降采样到 360px、后台队列、NSCache）供 `layer.contents`，**不要**把原图直接塞进 layer；`ClipboardItem.icon` 有缓存（`NSWorkspace.icon(forFile:)` 很贵，卡片复用时不能每次重算）。
- 预览文本用 `ClipboardItem.previewTextForDisplay`（截断 400 字）+ 标签限 6 行；`formattedTime` 用静态 DateFormatter。
- **历史持久化走 `HistoryStore`**（文件）：`~/Library/Application Support/剪贴板历史/history.json`（元数据，~55KB）+ `images/<uuid>.dat`（原图）；串行后台队列读写，主线程只交快照；图片经 `ClipboardItem.imageDataLoader` 按需读盘。
- **图片数据只认「内存副本 or 读盘 loader」两条路，缺一条就整条图片链路死掉**：`imageDataLoader` 必须保留默认实现（`{ HistoryStore.shared.imageData(fileName:) }`），别改回「只有历史条目才注入」——新抓取条目落盘后 `releaseInMemoryImageData()` 会清掉内存副本，没有 loader 时 `imageData` 永久返回 nil（卡片空白 + 粘贴写不进剪贴板，2026-09-21 修的这个 bug）。相应地，`releaseInMemoryImageData()` 只能对「确认写盘成功」的图片调用（`HistoryStore.write` 返回成功文件集合）。
- **绝不要把历史塞回 UserDefaults**：旧版是单个 60MB blob（解码 914ms）。旧数据迁移由 `HistoryStore.migrateFromUserDefaultsIfNeeded` 完成（先写新存储 → 回读校验 id 集合 → 才删旧 key + 落 `hasMigratedHistoryStoreV2`），已完成迁移（200 条）。
- 性能验收方法（可复现）：临时拿项目源码 + 程序化 `scrollWheel` 驱动窗口，外部每秒采样 `ps -o %cpu= -p 175`（WindowServer）+ `ioreg -r -d 1 -c IOAccelerator -l | sed -n 's/.*"Device Utilization %"=\([0-9]*\).*/\1/p'`（GPU）；干净做法是同进程交替「窗口隐藏 / 可见滚动」对比。2026-09-14 实测：窗口自身只 +1.8 点 WindowServer、GPU 无增长、App 1%。
- 注意：`ps %cpu` 在本机把 **pid 175 当 WindowServer** 是环境相关假设；采样前先 `ps -A -o pid,comm | grep WindowServer` 确认。
