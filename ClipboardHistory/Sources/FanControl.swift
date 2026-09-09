import Foundation
import AppKit
import IOKit

/// Apple Silicon 风扇控制（通过 IOKit 用户态接口读写 AppleSMC，无需 kext）。
///
/// 原理（Apple Silicon M1~M5）：
/// - `FNum`   风扇数量（ui8，只读）
/// - `F%dMd`  风扇模式（ui8，读写）：0=自动，1=手动（转速由 F%dTg 决定），3=系统接管。
///            注意 key 大小写随代际变化：M1~M4 是 `F%dMd`，M5 是 `F%dmd`，必须运行时探测。
/// - `F%dTg`  目标转速 RPM（Apple Silicon 为 flt 小端；Intel 为 fpe2 大端，读写）
/// - `F%dMx`  建议最高转速（只读），`F%dAc` 当前转速（只读）
/// - `Ftst`   诊断标志（ui8，M5 上不存在）：置 1 可抑制 thermalmonitord 的回收逻辑，
///            是 M3/M4 上「写模式被固件拒绝（0x82）」时进入手动模式的已知途径。
///
/// 权限：读取无需权限；写入必须 root。App 勾选复选框时通过 osascript
/// `with administrator privileges`（系统授权弹窗，支持 Touch ID）以 root 身份
/// 重新调用自身 `--fanctl` 子命令完成写入。
///
/// 维持：thermalmonitord 每 4s（高负载 250ms）轮询并回收风扇控制权，一次性子进程
/// 写完即退出后模式会被回收回 3，因此 App 侧由 `FanSupervisor` 按期望状态巡检补发。
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

    /// 运行时探测当前机型可用的风扇模式 key（大小写随代际变化：M1/M4 大写 F%dMd，M5 小写 F%dmd）。
    /// 优先尝试小写 key，失败则回退大写。若都读不到返回 nil。
    private static func modeKey(_ fan: Int, conn: io_connect_t) -> (key: String, value: Double)? {
        for fmt in ["F%dmd", "F%dMd"] {
            let key = String(format: fmt, fan)
            if let v = try? readNumber(conn, key) { return (key, v) }
        }
        return nil
    }

    /// 当前是否用户强制模式。
    /// Mode 0 = Auto, 1 = Manual, 2 = Legacy forced, 3 = System (thermalmonitord 接管)。
    /// 仅 Mode 1/2 视为真正的"用户强制"；Mode 3 表示系统在控制，不应打勾。
    static func isForced(_ fan: Int) -> Bool? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        guard let (_, mode) = modeKey(fan, conn: conn) else { return nil }
        // 1 = Manual, 2 = Legacy forced。Mode 3 = System 不算用户强制。
        return mode == 1 || mode == 2
    }

    /// 模式位原始值，仅用于诊断输出（0=自动 1=手动 2=T2 强制 3=系统接管）
    static func modeRaw(_ fan: Int) -> Int? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        return modeKey(fan, conn: conn).map { Int($0.value) }
    }

    // MARK: - 目标转速策略

    /// 勾选后的目标转速 = 建议最高转速 × 该比例。
    /// 不用满速：噪音/功耗随转速更高阶增长，80% 已能换到大部分散热能力。
    static let boostRatio: Double = 0.8

    /// 勾选状态的 UserDefaults 键（UI、巡检器共用）
    static func enabledKey(_ fan: Int) -> String { "fanForceEnabled_\(fan)" }

    /// 勾选后该风扇的目标转速（最高转速的 80%）
    static func targetRPM(_ fan: Int) -> Int? {
        guard let max = maxRPM(fan), max > 0 else { return nil }
        return Int((Double(max) * boostRatio).rounded())
    }

    static func fanName(_ fan: Int) -> String? {
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        guard let (_, bytes) = try? readKey(conn, "F\(fan)ID") else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    // MARK: - 盖子（Clamshell）状态

    private static let lidKey = "MSLD"

    /// 盖子是否合上；`nil` = 本机无法判定（台式机，或两个来源都不可用）。
    ///
    /// 优先读电源管理维护的 `AppleClamshellState`（IOPMrootDomain，合盖瞬间即翻转，
    /// 比等系统睡眠通知更早，能覆盖「外接显示器的合盖模式：机器不睡但盖子合着」）；
    /// 读不到时回退 SMC 的 `MSLD`。两种来源都是只读，开销与一次 SMC 读相当。
    static func isLidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            defer { IOObjectRelease(root) }
            if let obj = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let number = obj as? NSNumber { return number.boolValue }
                if let bool = obj as? Bool { return bool }
            }
        }
        guard let conn = try? openConnection() else { return nil }
        defer { IOServiceClose(conn) }
        return (try? readNumber(conn, lidKey)).map { $0 != 0 }
    }

    // MARK: - 风扇写入（需 root，经 --fanctl CLI 调用）

    private static let ftstKey = "Ftst"

    private static func ftstExists(_ conn: io_connect_t) -> Bool {
        (try? readNumber(conn, ftstKey)) != nil
    }

    private static func ftstIsSet(_ conn: io_connect_t) -> Bool {
        ((try? readNumber(conn, ftstKey)) ?? 0) != 0
    }

    /// 是否还有任一风扇处于用户手动模式（1=手动，2=T2 强制）
    private static func anyFanForced(_ conn: io_connect_t, count: Int) -> Bool {
        for i in 0..<count {
            if let (_, mode) = modeKey(i, conn: conn), mode == 1 || mode == 2 { return true }
        }
        return false
    }

    /// 进入手动模式：先直写 1（M1/M5 可行）；被固件拒绝（0x82：M3/M4 在 Mode 3 下的表现）
    /// 时走 Ftst 诊断解锁——置 Ftst=1 抑制 thermalmonitord 的回收，等模式脱离 3 后重试写 1。
    private static func enterManualMode(_ conn: io_connect_t, fan: Int, mdKey: String) throws {
        do {
            try writeKey(conn, mdKey, [0x01])
            return
        } catch let directError as FanError {
            // 只有固件明确拒绝（0x82：Mode 3 下写模式位的典型错误）才值得走 Ftst 解锁；
            // 权限不足等其它错误立即上抛，避免白等 10 秒解锁窗口。
            if case .keyFailed(_, 0x82) = directError {
                guard ftstExists(conn) else { throw directError }
            } else {
                throw directError
            }
        }

        try? writeKey(conn, ftstKey, [0x01])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            // 必须等模式脱离 3（系统接管）后再写 1，早于此时写仍会被固件拒绝
            if let mode = try? readNumber(conn, mdKey), mode != 3,
               (try? writeKey(conn, mdKey, [0x01])) != nil {
                return
            }
        }
        throw FanError.shellFailed("无法进入手动模式：系统热管理（thermalmonitord）未交出风扇控制权")
    }

    /// 把某个风扇设为手动并指定目标转速（RPM）。仅应在 root 进程（--fanctl 子命令）中调用。
    static func setTargetRPM(_ fan: Int, rpm: Double) throws {
        let conn = try openConnection()
        defer { IOServiceClose(conn) }

        let count = Int(try readNumber(conn, "FNum"))
        guard fan >= 0 && fan < count else { throw FanError.badFanIndex }
        // 运行时探测可用模式 key（大小写随代际变化）
        guard let (mdKey, _) = modeKey(fan, conn: conn) else {
            throw FanError.keyFailed("F\(fan)Md", 0x84)
        }
        let maxRPMValue = try readNumber(conn, "F\(fan)Mx")
        guard maxRPMValue > 0 else { throw FanError.noMaxRPM }
        // 钳制在 [0, 建议最高转速]：Mn/Mx 只是建议区间，超出后固件可能直接拒写
        let target = Swift.max(0, Swift.min(rpm, maxRPMValue))

        try enterManualMode(conn, fan: fan, mdKey: mdKey)

        let (tgType, _) = try readKey(conn, "F\(fan)Tg")
        guard let encoded = encodeNumber(target, type: tgType) else {
            throw FanError.shellFailed("F\(fan)Tg 数据类型 \(fourCCString(tgType)) 无法编码")
        }
        try writeKey(conn, "F\(fan)Tg", encoded)

        // Ftst 解锁会全局抑制系统热伺服，此时未勾选的风扇不会随温度升速，
        // 必须一并给它们安全目标（同样 80%），否则存在过热风险。
        guard ftstIsSet(conn) else { return }
        for i in 0..<count where i != fan {
            guard let otherMax = try? readNumber(conn, "F\(i)Mx"), otherMax > 0 else { continue }
            guard let (otherKey, _) = modeKey(i, conn: conn) else { continue }
            guard (try? writeKey(conn, otherKey, [0x01])) != nil else { continue }
            if let (otherType, _) = try? readKey(conn, "F\(i)Tg"),
               let enc = encodeNumber(otherMax * boostRatio, type: otherType) {
                _ = try? writeKey(conn, "F\(i)Tg", enc)
            }
        }
    }

    /// 恢复系统自动控制。仅应在 root 进程（--fanctl 子命令）中调用。
    static func setAuto(_ fan: Int) throws {
        let conn = try openConnection()
        defer { IOServiceClose(conn) }

        let count = Int(try readNumber(conn, "FNum"))
        guard fan >= 0 && fan < count else { throw FanError.badFanIndex }
        guard let (mdKey, _) = modeKey(fan, conn: conn) else {
            throw FanError.keyFailed("F\(fan)Md", 0x84)
        }
        try writeKey(conn, mdKey, [0x00])

        // 只有「所有风扇都回到自动」才复位 Ftst：仍有风扇处于手动时复位，
        // 系统会把控制权连同剩余勾选一起收回。
        if ftstIsSet(conn) && !anyFanForced(conn, count: count) {
            _ = try? writeKey(conn, ftstKey, [0x00])
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
        if probeSudoSilent(binPath) {
            UserDefaults.standard.set(binPath, forKey: installedKey)
            return
        }

        // 确实需要安装：一次性 osascript 授权弹窗
        let rule = "%admin ALL=(ALL) NOPASSWD: \(binPath) --fanctl *\n"

        // 固定路径的临时文件可被预先占坑（DoS）或在竞态窗口被替换，改用 0700 随机目录
        let tmpDir = try makePrivateTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let tmpFile = (tmpDir as NSString).appendingPathComponent("sudoers")
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

        if osa.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if err.localizedCaseInsensitiveContains("canceled") { throw FanError.cancelled }
            throw FanError.shellFailed("安装 sudo 规则失败: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 缓存安装成功的二进制路径
        UserDefaults.standard.set(binPath, forKey: installedKey)
    }

    /// 当前二进制是否已可免密提权（不触发任何弹窗），供巡检器判断是否值得自动补发
    static func canRunPrivilegedSilently() -> Bool {
        let binPath = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
        guard UserDefaults.standard.string(forKey: installedKey) == binPath else { return false }
        return probeSudoSilent(binPath)
    }

    /// `sudo -n <bin> --fanctl info` 是否成功。进程未启动成功时 terminationStatus 仍是 0，
    /// 必须显式区分「启动失败」与「退出码 0」。
    private static func probeSudoSilent(_ binPath: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        probe.arguments = ["-n", binPath, "--fanctl", "info"]
        probe.standardOutput = Pipe(); probe.standardError = Pipe()
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// 下发 / 取消某个风扇的提速；勾选后目标 = 最高转速的 80%（不是满速）。
    /// - parameter allowSudoersInstall: 巡检器自动补发传 false，避免在后台弹出授权窗口。
    static func apply(_ fan: Int, boost enabled: Bool,
                     allowSudoersInstall: Bool = true,
                     completion: @escaping (Result<Void, FanError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let args: [String]
            if enabled {
                guard let rpm = targetRPM(fan) else {
                    DispatchQueue.main.async { completion(.failure(.noMaxRPM)) }
                    return
                }
                args = ["set", String(fan), String(rpm)]
            } else {
                args = ["auto", String(fan)]
            }

            do {
                if allowSudoersInstall {
                    try ensureSudoersInstalled()
                } else if !canRunPrivilegedSilently() {
                    throw FanError.shellFailed("免密授权尚未生效，请手动勾选一次以完成授权")
                }
                try runPrivileged(args)
                DispatchQueue.main.async { completion(.success(())) }
            } catch let e as FanError {
                DispatchQueue.main.async { completion(.failure(e)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.shellFailed(error.localizedDescription))) }
            }
        }
    }

    // MARK: - 交还控制权（合盖 / 系统睡眠前）

    /// 所有释放命令串在此队列，避免与巡检补发互相覆盖（一边写 1 一边写 0）
    private static let releaseQueue = DispatchQueue(label: "com.clipboard.history.fan.release")

    /// 逐个把风扇交还系统自动控制；同步实现，只能在 releaseQueue 上调用
    private static func performRelease(_ fans: [Int]) -> Bool {
        guard canRunPrivilegedSilently() else { return false }
        var ok = true
        for fan in fans {
            do { try runPrivileged(["auto", String(fan)]) } catch { ok = false }
        }
        return ok
    }

    /// 阻塞式交还控制权：在调用线程最多等 `timeout` 秒。
    /// 只用于「必须赶在系统睡眠前完成」的场景（willSleep 通知）——睡眠不会带走 SMC 的
    /// 手动模式，不交还的话风扇会按手动目标转速一直转到唤醒。
    @discardableResult
    static func releaseAllAndWait(_ fans: [Int], timeout: TimeInterval = 5) -> Bool {
        guard !fans.isEmpty else { return true }
        let done = Flag()
        let sem = DispatchSemaphore(value: 0)
        releaseQueue.async {
            _ = performRelease(fans)
            done.value = true
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return done.value
    }

    /// 异步交还控制权（巡检发现合盖时用，不阻塞主线程）
    static func releaseAll(_ fans: [Int]) {
        guard !fans.isEmpty else { return }
        releaseQueue.async { _ = performRelease(fans) }
    }

    /// 以 root 执行 `--fanctl <args>`；非 0 退出码转成 FanError.shellFailed
    private static func runPrivileged(_ args: [String]) throws {
        let binPath = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", binPath, "--fanctl"] + args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = errText.isEmpty ? "风扇操作失败 (exit=\(process.terminationStatus))"
                                      : errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FanError.shellFailed(msg)
        }
    }

    // MARK: - 辅助

    /// 跨线程传递布尔结果的容器（避免在逃逸闭包里读写局部 var）
    private final class Flag {
        var value: Bool
        init(_ value: Bool = false) { self.value = value }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 0700 私有临时目录：避开 /tmp 固定文件名带来的占坑与竞态风险
    private static func makePrivateTempDirectory() throws -> String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("clipboardhistory.sudoers.XXXXXX")
        var template = [Int8](base.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw FanError.shellFailed("无法创建临时目录")
        }
        return String(cString: template)
    }

    // MARK: - CLI 入口（--fanctl，供提权子进程与调试使用）

    /// 用法：
    ///   --fanctl info            打印风扇信息（无需权限）
    ///   --fanctl lid             打印盖子（合盖）状态（无需权限）
    ///   --fanctl set <fan> <rpm> 设为手动模式并指定目标转速（需 root）
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
                let max = maxRPM(i).map { "\($0)" } ?? "?"
                let cur = actualRPM(i).map { "\($0)" } ?? "?"
                let target = targetRPM(i).map { "\($0)" } ?? "?"
                let mode = modeRaw(i).map { "\($0)" } ?? "未知"
                print("风扇 \(i): 当前 \(cur) RPM / 最大 \(max) RPM / 80% 目标 \(target) RPM / 模式 \(mode)")
            }
            return 0

        case "lid":
            switch isLidClosed() {
            case .some(true):  print("盖子: 已合上")
            case .some(false): print("盖子: 打开")
            case nil:          print("盖子: 无法判定（台式机或本机无该传感器）")
            }
            return 0

        case "set":
            guard sub.count == 3, let fan = Int(sub[1]), let rpm = Double(sub[2]), rpm > 0 else {
                FileHandle.standardError.write(Data("用法: --fanctl set <fan> <rpm>\n".utf8))
                return 1
            }
            do {
                // 目标转速由上层算好传入（App 侧是最高转速的 80%），此处不再自行取最大值
                try setTargetRPM(fan, rpm: rpm)
                print("风扇 \(fan) 已设为手动，目标 \(Int(rpm)) RPM")
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
                try setAuto(fan)
                print("风扇 \(fan) 已恢复系统自动控制")
                return 0
            } catch {
                FileHandle.standardError.write(Data("恢复失败: \(error.localizedDescription)\n".utf8))
                return 1
            }

        default:
            FileHandle.standardError.write(Data("用法: --fanctl info | lid | set <fan> <rpm> | auto <fan>\n".utf8))
            return 1
        }
    }
}

// MARK: - 手动模式保持（App 侧）

/// thermalmonitord 每 4s（高负载 250ms）轮询并回收风扇控制权：一次性 sudo 子进程
/// 写完就退出，模式很快被回收回 3，表现为「勾上了没多久又自己弹回」。
///
/// 巡检器只做两件事：
/// 1. 每 5s 只读一次模式位（读 SMC 无需 root，开销极小）；
/// 2. 仅当某个「期望手动」的风扇已被回收时，才重新走一次提权下发。
/// 这样既能把控制权持续夺回，又不会无谓地反复调 sudo。
final class FanSupervisor {

    static let shared = FanSupervisor()

    /// 挂起（已交还系统控制）的原因
    enum SuspendReason { case lid, systemSleep, displayOff, screenLocked, screenSaver, offConsole }

    /// 期望处于手动（80%）状态的风扇序号
    private(set) var boosted: Set<Int> = []
    /// 已交还系统控制、停止补发（合盖、黑屏、锁屏或系统睡眠）
    private(set) var isSuspended = false
    private(set) var suspendReason: SuspendReason?
    private var timer: Timer?
    private var busy = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    /// 是否已锁屏（CGSSessionScreenIsLocked 已从 CGSessionCopyCurrentDictionary 移除，
    /// 只能靠 loginwindow 的分布式通知维护；漏通知时由 sessionDidBecomeActive 兜底）
    private var screenLocked = false
    /// 屏保是否正在运行（系统不保证发出 didstop，亮屏通知里会一并清掉）
    private var screenSaverActive = false

    /// 巡检间隔：正常 5s；挂起期间拉长到 15s，减少后台唤醒，让系统能真正睡下去
    private var pollInterval: TimeInterval { isSuspended ? 15 : 5 }

    private init() {
        let count = FanControl.fanCount()
        boosted = Set((0..<count).filter { UserDefaults.standard.bool(forKey: FanControl.enabledKey($0)) })

        let nc = NSWorkspace.shared.notificationCenter
        // 系统睡眠：SMC 的手动模式不会随睡眠消失，不交还的话风扇会按 80% 目标一路转到唤醒，
        // 因此这里必须同步（阻塞最多 5s）等释放命令下发完，比定时器轮询可靠。
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspend(reason: .systemSleep, wait: true)
        })
        // 睡眠会重置 Ftst 与手动模式，唤醒后必须补发
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.start()
            self?.resumeIfPossible()   // 盖子仍合着 / 屏幕仍锁着时不会恢复
            self?.refresh()
            // 唤醒瞬间显示器可能还没点亮，稍后再试一次，避免风扇恢复被拖到下一个巡检周期
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.resumeIfPossible()
                self?.refresh()
            }
        })
        // 屏幕睡眠（锁屏后黑屏）与锁屏：风扇被强制时系统根本走不到 willSleep——「风扇转着」
        // 本身就是睡不下去的原因，等 willSleep 永远不会来。必须在黑屏/锁屏这一刻就交还
        // 控制权，系统才能接着进入休眠；回来（亮屏/解锁/唤醒）后再自动恢复提速。
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspend(reason: .displayOff, wait: false)
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // 屏保/锁屏结束时屏幕一定会亮，这里顺手清掉可能漏发的 didstop 标志
            self?.screenSaverActive = false
            self?.resumeIfPossible()
        })
        // 回到自己的会话（解锁 / 从快速用户切换切回）：兜住漏发的解锁通知
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.resumeIfPossible()
        })

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.suspend(reason: .screenLocked, wait: false)
        })
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.resumeIfPossible()
        })
        // 屏保运行 = 人已离开（且屏保本身耗电发热）。系统不保证发出 didstop，
        // 因此额外监听 willstop，并在 screensDidWake 里兜底清除标志。
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.screenSaverActive = true
            self?.suspend(reason: .screenSaver, wait: false)
        })
        for stopName in ["com.apple.screensaver.didstop", "com.apple.screensaver.willstop"] {
            distributedObservers.append(dnc.addObserver(forName: Notification.Name(stopName), object: nil, queue: .main) { [weak self] _ in
                self?.screenSaverActive = false
                self?.resumeIfPossible()
            })
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(nc.removeObserver)
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.forEach(dnc.removeObserver)
    }

    /// 记录用户意图：写 UserDefaults，并启/停巡检
    func setBoosted(_ fan: Int, _ on: Bool) {
        if on {
            boosted.insert(fan)
            // 用户主动勾选 = 现在就要提速，清掉合盖/黑屏/锁屏/睡眠挂起
            isSuspended = false
            suspendReason = nil
            restartTimer()
        } else {
            boosted.remove(fan)
        }
        UserDefaults.standard.set(on, forKey: FanControl.enabledKey(fan))
        if boosted.isEmpty {
            stop()
        } else {
            start()
            refresh()
        }
    }

    /// 「合盖/睡眠时恢复系统控制」开关被改动后重新评估（关掉开关要立刻恢复提速）
    func releaseSettingDidChange() {
        if !FeatureSettings.fanReleaseWhenClosed && isSuspended {
            isSuspended = false
            suspendReason = nil
            restartTimer()
        }
        refresh()
    }

    // MARK: - 挂起 / 恢复

    /// 是否应保持「已交还系统控制」：开关打开且人不在这台机器前
    /// （合盖 / 黑屏 / 锁屏 / 屏保 / 会话已切走）
    private func shouldStayReleased() -> Bool {
        guard FeatureSettings.fanReleaseWhenClosed else { return false }
        if FanControl.isLidClosed() == true { return true }
        if isDisplayAsleep() { return true }
        if screenLocked || screenSaverActive { return true }
        if isSessionOffConsole() { return true }
        return false
    }

    /// 主显示器是否已进入节能（黑屏）
    private func isDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 本会话是否不在控制台：覆盖快速用户切换、登录窗口、远程桌面（ARD/VNC）接管等
    /// 锁屏通知不会发的场景。无 GUI 会话时查不到，按「在控制台」处理（不误伤）。
    private func isSessionOffConsole() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        guard let onConsole = dict[kCGSessionOnConsoleKey as String] as? Bool else { return false }
        return !onConsole
    }

    /// 交还控制权并停止补发。
    /// - parameter wait: 是否阻塞当前线程等待下发完成（系统睡眠前必须等，合盖轮询则不需要）
    private func suspend(reason: SuspendReason, wait: Bool) {
        guard FeatureSettings.fanReleaseWhenClosed else { return }
        // 已挂起时只有「需要等待」的场景（系统睡眠）才值得再发一次：合盖后的异步释放
        // 可能还没跑完系统就睡了，setAuto 幂等，重发一次确保睡眠前已交还控制权
        guard !isSuspended || wait else { return }
        // 必须释放「全部」风扇而不是只释放勾选的：M3/M4 走 Ftst 解锁时
        // setTargetRPM 会把未勾选的风扇一并设成手动 80%，只释放勾选的那些会导致
        // 其余风扇继续手动，且 setAuto 里的 anyFanForced 检查会因此拒绝复位 Ftst。
        let count = FanControl.fanCount()
        let fans = count > 0 ? Array(0..<count) : Array(boosted)
        isSuspended = true
        suspendReason = reason
        restartTimer()   // 挂起后降低巡检频率，避免后台反复唤醒把系统拖住
        if wait {
            // 阻塞主线程是有意为之：willSleep 通知处理完系统才会睡，异步补发赶不上
            FanControl.releaseAllAndWait(fans, timeout: 5)
        } else {
            FanControl.releaseAll(fans)
        }
        NotificationCenter.default.post(name: .fanStateDidChange, object: nil)
    }

    /// 挂起期间每轮巡检判断是否已开盖，是则恢复提速
    private func resumeIfPossible() {
        guard isSuspended, !shouldStayReleased() else { return }
        isSuspended = false
        suspendReason = nil
        restartTimer()
        refresh()
        NotificationCenter.default.post(name: .fanStateDidChange, object: nil)
    }

    /// App 启动 / 唤醒后恢复上次勾选（只有免密授权已生效时才真正下发）
    func resume() {
        guard !boosted.isEmpty else { return }
        start()
        refresh()
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 按当前状态（是否挂起）重建巡检定时器
    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        start()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !boosted.isEmpty, !busy else { return }
        if isSuspended {
            // 并发竞态自愈：挂起瞬间若有补发命令仍在飞，可能把某个风扇又写成手动；
            // 这里再检查并释放一次（幂等），确保合盖后不留任何手动风扇
            let stillForced = Array(boosted).filter { FanControl.isForced($0) == true }
            if !stillForced.isEmpty { FanControl.releaseAll(stillForced) }
            resumeIfPossible()
            return
        }
        // 合盖但机器没睡（外接显示器的合盖模式）：交还控制权，不再与 thermalmonitord 抢
        if shouldStayReleased() {
            suspend(reason: .lid, wait: false)
            return
        }
        // isForced 为 nil 表示 SMC 读取失败，此时不要补发，避免刷屏
        let lost = boosted.filter { !(FanControl.isForced($0) ?? true) }
        guard !lost.isEmpty else { return }
        // 尚未授权时静默跳过：等用户手动勾选走一次授权流程即可
        guard FanControl.canRunPrivilegedSilently() else { return }
        busy = true
        applyNext(Array(lost))
    }

    private func applyNext(_ queue: [Int]) {
        guard let fan = queue.first else {
            busy = false
            return
        }
        // 补发途中被挂起（系统睡眠/合盖）：立刻停手，否则会和释放命令互相打架
        guard !isSuspended else { busy = false; return }
        FanControl.apply(fan, boost: true, allowSudoersInstall: false) { [weak self] result in
            guard let self else { return }
            if case .failure = result {
                // 免密授权失效（App 被移动/重装等）：放弃该风扇的期望状态，避免后台反复失败
                self.boosted.remove(fan)
                UserDefaults.standard.set(false, forKey: FanControl.enabledKey(fan))
                NotificationCenter.default.post(name: .fanStateDidChange, object: nil)
            }
            self.applyNext(Array(queue.dropFirst()))
        }
    }
}

extension Notification.Name {
    /// 风扇状态被后台巡检器改变（补发成功/放弃），UI 需要重新同步
    static let fanStateDidChange = Notification.Name("fanStateDidChange")
}
