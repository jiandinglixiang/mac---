import Cocoa

// 提权/调试子命令入口：--fanctl（在启动 NSApplication 之前处理，root 下可独立运行）
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--fanctl" {
    exit(FanControl.runCLI(CommandLine.arguments))
}

// 应用程序入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
