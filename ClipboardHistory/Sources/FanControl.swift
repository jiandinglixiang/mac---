import Foundation
import IOKit

/// Apple Silicon 风扇控制（通过 IOKit 用户态接口读写 AppleSMC，无需 kext）。
///
/// 原理（Apple Silicon M1/M2/M3）：
/// - `FNum`   风扇数量（ui8，只读）
/// - `F%dMd`  风扇模式（ui8，读写）：0x00=自动，0x01=强制
/// - `F%dTg`  目标转速 RPM（fpe2 或 flt，读写）：写最大值即满速
/// - `F%dMx`  最高转速（只读），`F%dAc` 当前转速（只读），`F%dID` 风扇名称
///
/// 权限：读取无需权限；写入必须 root。App 勾选复选框时通过 osascript
/// `with administrator privileges`（系统授权弹窗，支持 Touch ID）以 root 身份
/// 重新调用自身 `--fanctl` 子命令完成写入。
enum FanControl {

    // MARK: - 错误

    enum FanError: LocalizedError {
        case serviceNotFound
        case ioFailed(String, kern_return_t)
        case keyFailed(String, UInt8)      // SMC 返回非 0（如 0x84 = key 不存在）
        case badLayout
        case badFanIndex
        case noMaxRPM
        case cancelled
        case shellFailed(String)

        var errorDescription: String? {
            switch self {
            case .serviceNotFound: return "未找到 AppleSMC 服务（非 Apple Silicon？）"
            case .ioFailed(let op, let kr): return "\(op) 失败 (kern_return=\(kr))"
            case .keyFailed(let key, let r): return "SMC key \(key) 读写被拒绝 (result=0x\(String(r, radix: 16)))"
            case .badLayout: return "SMC 数据结构布局异常"
            case .badFanIndex: return "风扇序号超出范围"
            case .noMaxRPM: return "无法读取风扇最大转速"
            case .cancelled: return "用户取消了授权"
            case .shellFailed(let msg): return msg
            }
        }
    }

    // MARK: - SMC 协议结构（布局须与 C 的 SMCKeyData_t 完全一致，共 80 字节）

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    private struct SMCKeyData {
        struct Vers {
            var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        // (version, length, cpuPLimit, gpuPLimit, memPLimit)
        typealias PLimitData = (UInt16, UInt16, UInt32, UInt32, UInt32)
        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
            // 显式补齐到 12 字节：Swift 内嵌结构按 size(9) 排布后续字段，
            // 而 C 按 sizeof(12) 排布，不补齐会导致 result/data32/bytes 偏移错位
            var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
        }
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData: PLimitData = (0, 0, 0, 0, 0)
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let bytes: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                              UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func openConnection() throws -> io_connect_t {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { throw FanError.badLayout }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanError.serviceNotFound }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { throw FanError.ioFailed("IOServiceOpen", kr) }
        return conn
    }

    /// 发送一条 SMC 命令并校验结果
    private static func call(_ conn: io_connect_t, _ input: inout SMCKeyData, op: String) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent,
                                           &input, MemoryLayout<SMCKeyData>.stride,
                                           &output, &outSize)
        guard kr == kIOReturnSuccess else { throw FanError.ioFailed(op, kr) }
        guard output.result == 0 else { throw FanError.keyFailed(fourCCString(input.key), output.result) }
        return output
    }

    private static func readKey(_ conn: io_connect_t, _ key: String) throws -> (type: UInt32, bytes: [UInt8]) {
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = kSMCGetKeyInfo
        let info = try call(conn, &input, op: "GetKeyInfo(\(key))")
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = kSMCReadKey
        let out = try call(conn, &input, op: "ReadKey(\(key))")
        let size = min(Int(info.keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return (info.keyInfo.dataType, bytes)
    }

    private static func writeKey(_ conn: io_connect_t, _ key: String, _ bytes: [UInt8]) throws {
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = kSMCGetKeyInfo
        let info = try call(conn, &input, op: "GetKeyInfo(\(key))")
        guard Int(info.keyInfo.dataSize) == bytes.count else {
            throw FanError.shellFailed("\(key) 长度不匹配（期望 \(info.keyInfo.dataSize) 字节）")
        }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = kSMCWriteKey
        var buf = SMCKeyData.Bytes(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &buf) { ptr in
            for i in 0..<min(bytes.count, 32) { ptr[i] = bytes[i] }
        }
        input.bytes = buf
        _ = try call(conn, &input, op: "WriteKey(\(key))")
    }

    // MARK: - 数值编解码（fpe2 = 14.2 定点大端；flt = IEEE754 小端）

    private static func decodeNumber(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case fourCC("fpe2") where bytes.count >= 2:
            return Double((Int(bytes[0]) << 8) | Int(bytes[1])) / 4.0
        case fourCC("flt ") where bytes.count >= 4:
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case fourCC("ui8 ") where !bytes.isEmpty:
            return Double(bytes[0])
        case fourCC("ui16") where bytes.count >= 2:
            return Double((Int(bytes[0]) << 8) | Int(bytes[1]))
        default:
            return nil
        }
    }

    private static func encodeNumber(_ value: Double, type: UInt32) -> [UInt8]? {
        switch type {
        case fourCC("fpe2"):
            let raw = UInt16(max(0, min(value, 16383.75)) * 4.0)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case fourCC("flt "):
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                    UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        case fourCC("ui8 "):
            return [UInt8(max(0, min(value, 255)))]
        default:
            return nil
        }
    }

    private static func readNumber(_ conn: io_connect_t, _ key: String) throws -> Double {
        let (type, bytes) = try readKey(conn, key)
        guard let v = decodeNumber(type: type, bytes: bytes) else {
            throw FanError.shellFailed("\(key) 数据类型 \(fourCCString(type)) 无法解析")
        }
        return v
    }

    // MARK: - 风扇信息（只读，无需权限）

    /// 风扇数量；无风扇或 SMC 不可用时返回 0
    static func fanCount() -> Int {
        guard let conn = try? openConnection() else { return 0 }
        defer { IOServiceClose(conn) }
        return Int((try? readNumber(conn, "FNum")) ?? 0)
    }

    static func maxRPM(_ fan: Int) -> Int? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        return (try? readNumber(conn, "F\(fan)Mx")).map { Int($0) }
    }

    static func actualRPM(_ fan: Int) -> Int? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        return (try? readNumber(conn, "F\(fan)Ac")).map { Int($0) }
    }

    /// 当前是否强制模式；读取失败（部分机型无 F%dMd）返回 nil
    static func isForced(_ fan: Int) -> Bool? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        return (try? readNumber(conn, "F\(fan)Md")).map { $0 != 0 }
    }

    static func fanName(_ fan: Int) -> String? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        guard let (_, bytes) = try? readKey(conn, "F\(fan)ID") else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    // MARK: - 风扇写入（需 root，经 --fanctl CLI 调用）

    /// 设置满速 / 恢复自动。仅应在 root 进程（--fanctl 子命令）中调用。
    static func setFullSpeed(_ fan: Int, enabled: Bool) throws {
        let conn = try openConnection()
        defer { IOServiceClose(conn) }

        let count = Int(try readNumber(conn, "FNum"))
        guard fan >= 0 && fan < count else { throw FanError.badFanIndex }

        if enabled {
            let max = try readNumber(conn, "F\(fan)Mx")
            guard max > 0 else { throw FanError.noMaxRPM }
            // Apple Silicon 方式：强制模式 + 目标转速=最大值
            if (try? writeKey(conn, "F\(fan)Md", [0x01])) != nil {
                let (tgType, _) = try readKey(conn, "F\(fan)Tg")
                guard let encoded = encodeNumber(max, type: tgType) else {
                    throw FanError.shellFailed("F\(fan)Tg 数据类型 \(fourCCString(tgType)) 无法编码")
                }
                try writeKey(conn, "F\(fan)Tg", encoded)
            } else {
                // 回退（个别机型无 F%dMd）：写最低转速为最大值
                // ponytail: 回退路径未经真机验证（本机 M1 Pro 支持 F%dMd），仅在无 Md key 的机型兜底
                let (mnType, _) = try readKey(conn, "F\(fan)Mn")
                guard let encoded = encodeNumber(max, type: mnType) else {
                    throw FanError.shellFailed("F\(fan)Mn 数据类型无法编码")
                }
                try writeKey(conn, "F\(fan)Mn", encoded)
            }
        } else {
            if (try? writeKey(conn, "F\(fan)Md", [0x00])) != nil {
                // 恢复自动即可，目标转速由系统接管
            } else {
                let (mnType, _) = try readKey(conn, "F\(fan)Mn")
                if let encoded = encodeNumber(0, type: mnType) {
                    try writeKey(conn, "F\(fan)Mn", encoded)
                }
            }
        }
    }

    // MARK: - App 侧：sudoers 免密提权（首次安装一次性授权，后续免弹窗）

    private static let sudoersFile = "/etc/sudoers.d/clipboardhistory"
    private static let installedKey = "fanControlSudoersInstalledPath"

    /// 当前二进制路径的 sudoers 规则是否已安装（用 UserDefaults 缓存，避免重复读系统文件）
    private static var sudoersNeedsInstall: Bool {
        UserDefaults.standard.string(forKey: installedKey) != (Bundle.main.executableURL?.path ?? "")
    }

    /// 通过 osascript 一次性提权写入 sudoers 免密规则。
    static func ensureSudoersInstalled() throws {
        let binPath = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
        guard sudoersNeedsInstall else { return }

        // 前置探针：UserDefaults 无记录但 sudo -n 实际已生效（上次安装遗留的规则）
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        probe.arguments = ["-n", binPath, "--fanctl", "info"]
        probe.standardOutput = Pipe(); probe.standardError = Pipe()
        try? probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus == 0 {
            UserDefaults.standard.set(binPath, forKey: installedKey)
            return
        }

        // 确实需要安装：一次性 osascript 授权弹窗
        let rule = "%admin ALL=(ALL) NOPASSWD: \(binPath) --fanctl *\n"

        let tmpFile = "/tmp/clipboardhistory.sudoers.tmp"
        try rule.write(toFile: tmpFile, atomically: true, encoding: .utf8)

        let cp = "cp \(shellQuote(tmpFile)) \(sudoersFile) && chmod 0440 \(sudoersFile)"
        let escaped = cp.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        let errPipe = Pipe()
        osa.standardError = errPipe
        osa.standardOutput = Pipe()
        try osa.run()
        osa.waitUntilExit()

        try? FileManager.default.removeItem(atPath: tmpFile)

        if osa.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if err.localizedCaseInsensitiveContains("canceled") { throw FanError.cancelled }
            throw FanError.shellFailed("安装 sudo 规则失败: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 缓存安装成功的二进制路径
        UserDefaults.standard.set(binPath, forKey: installedKey)
    }

    static func applyFullSpeed(_ fan: Int, enabled: Bool, completion: @escaping (Result<Void, FanError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let subArgs: String
            if enabled {
                guard let rpm = maxRPM(fan) else {
                    DispatchQueue.main.async { completion(.failure(.noMaxRPM)) }
                    return
                }
                subArgs = "set \(fan) \(rpm)"
            } else {
                subArgs = "auto \(fan)"
            }

            do {
                try ensureSudoersInstalled()

                let binPath = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = ["-n", binPath, "--fanctl"] + subArgs.split(separator: " ").map(String.init)
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe()
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let msg = errText.isEmpty ? "风扇操作失败 (exit=\(process.terminationStatus))" : errText.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async { completion(.failure(.shellFailed(msg))) }
                }
            } catch let e as FanError {
                DispatchQueue.main.async { completion(.failure(e)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.shellFailed(error.localizedDescription))) }
            }
        }
    }

    // MARK: - 辅助

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - CLI 入口（--fanctl，供提权子进程与调试使用）

    /// 用法：
    ///   --fanctl info            打印风扇信息（无需权限）
    ///   --fanctl set <fan> <rpm> 强制风扇满速/指定转速（需 root）
    ///   --fanctl auto <fan>      恢复系统自动控制（需 root）
    static func runCLI(_ args: [String]) -> Int32 {
        guard MemoryLayout<SMCKeyData>.stride == 80 else {
            FileHandle.standardError.write(Data("SMC 数据结构布局异常\n".utf8))
            return 1
        }
        let sub = Array(args.dropFirst(2))

        switch sub.first {
        case "info":
            let count = fanCount()
            print("风扇数量: \(count)")
            for i in 0..<count {
                let name = fanName(i) ?? "?"
                let max = maxRPM(i).map { "\($0)" } ?? "?"
                let cur = actualRPM(i).map { "\($0)" } ?? "?"
                let mode = isForced(i).map { $0 ? "强制" : "自动" } ?? "未知"
                print("风扇 \(i) [\(name)]: 当前 \(cur) RPM / 最大 \(max) RPM / 模式: \(mode)")
            }
            return 0

        case "set":
            guard sub.count == 3, let fan = Int(sub[1]), let rpm = Double(sub[2]), rpm > 0 else {
                FileHandle.standardError.write(Data("用法: --fanctl set <fan> <rpm>\n".utf8))
                return 1
            }
            do {
                try setFullSpeed(fan, enabled: true)
                print("风扇 \(fan) 已强制满速（目标 \(Int(rpm)) RPM）")
                return 0
            } catch {
                FileHandle.standardError.write(Data("设置失败: \(error.localizedDescription)\n".utf8))
                return 1
            }

        case "auto":
            guard sub.count == 2, let fan = Int(sub[1]) else {
                FileHandle.standardError.write(Data("用法: --fanctl auto <fan>\n".utf8))
                return 1
            }
            do {
                try setFullSpeed(fan, enabled: false)
                print("风扇 \(fan) 已恢复系统自动控制")
                return 0
            } catch {
                FileHandle.standardError.write(Data("恢复失败: \(error.localizedDescription)\n".utf8))
                return 1
            }

        default:
            FileHandle.standardError.write(Data("用法: --fanctl info | set <fan> <rpm> | auto <fan>\n".utf8))
            return 1
        }
    }
}
