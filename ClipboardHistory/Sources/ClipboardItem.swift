import Cocoa

// 剪贴板项数据类型
enum ClipboardItemType: Codable {
    case text
    case image
    case file
    case url
    case unknown
}

/// 卡片预览文本的显示上限：改前把完整内容整段塞进多行标签（实测最长 7005 字），
/// 文本布局是打开/滚动卡顿的主要来源之一，因此这里按显示需要截断。
let previewTextDisplayLimit = 400

// 剪贴板历史项
final class ClipboardItem: NSObject {
    let id: UUID
    let timestamp: Date
    let type: ClipboardItemType
    var textContent: String?
    var fileURLs: [String]?
    var urlString: String?

    /// 图片原图在 HistoryStore `images/` 目录中的文件名（nil = 该条没有图片数据）
    var imageFileName: String?
    /// 图片原始字节数：用于卡片体积显示与去重比较，避免为此读磁盘
    var imageByteCount: Int?

    /// 图片数据加载器（由 HistoryStore 注入，从磁盘按需读取），避免历史图片全部常驻内存
    var imageDataLoader: ((String) -> Data?)?

    /// 仅缓存「刚抓取、尚未落盘」的图片数据；历史里的图片一律按需从磁盘读
    private var inMemoryImageData: Data?

    var imageData: Data? {
        get {
            if let data = inMemoryImageData { return data }
            guard let name = imageFileName, let loader = imageDataLoader else { return nil }
            return loader(name)
        }
        set {
            inMemoryImageData = newValue
            imageByteCount = newValue?.count
            if newValue != nil, imageFileName == nil {
                imageFileName = "\(id.uuidString).dat"
            }
        }
    }

    /// 图片已落盘后释放内存副本（历史里的图片统一按需读盘）
    func releaseInMemoryImageData() {
        guard imageFileName != nil else { return }
        inMemoryImageData = nil
    }

    init(type: ClipboardItemType, textContent: String? = nil, imageData: Data? = nil,
         fileURLs: [URL]? = nil, urlString: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.textContent = textContent
        self.fileURLs = fileURLs?.map { $0.path }
        self.urlString = urlString
        super.init()
        if let imageData {
            self.imageData = imageData
        }
    }

    /// 从持久化元数据恢复（图片数据按需读盘，不在此处加载）
    init(id: UUID, timestamp: Date, type: ClipboardItemType, textContent: String?,
         imageFileName: String?, imageByteCount: Int?, fileURLs: [String]?, urlString: String?) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.textContent = textContent
        self.imageFileName = imageFileName
        self.imageByteCount = imageByteCount
        self.fileURLs = fileURLs
        self.urlString = urlString
        super.init()
    }

    // 获取显示文本
    var displayText: String {
        switch type {
        case .text:
            return textContent?.prefix(100).description ?? ""
        case .image:
            return "图片"
        case .file:
            let count = fileURLs?.count ?? 0
            if count == 1, let fileName = fileURLs?.first?.split(separator: "/").last {
                return "\(fileName)"
            }
            return "\(count) 个文件"
        case .url:
            return urlString ?? ""
        case .unknown:
            return "未知类型"
        }
    }

    // 获取预览文本（完整内容，仅用于非 UI 场景）
    var previewText: String {
        switch type {
        case .text:
            return textContent ?? ""
        case .image:
            return "图片数据 (\(formatBytes(imageByteCount ?? 0)))"
        case .file:
            return fileURLs?.joined(separator: "\n") ?? ""
        case .url:
            return urlString ?? ""
        case .unknown:
            return ""
        }
    }

    /// 卡片上实际显示的预览文本：超长内容截断，避免 TextKit 对整段文本做换行布局
    var previewTextForDisplay: String {
        switch type {
        case .text:
            let text = textContent ?? ""
            guard text.count > previewTextDisplayLimit else { return text }
            return String(text.prefix(previewTextDisplayLimit)) + "…"
        case .image:
            return "图片数据 (\(formatBytes(imageByteCount ?? imageData?.count ?? 0)))"
        case .file:
            return fileURLs?.joined(separator: "\n") ?? ""
        case .url:
            return urlString ?? ""
        case .unknown:
            return ""
        }
    }

    /// 图标缓存：卡片池会在滚动中反复 configure 同一条目，
    /// 而 `NSWorkspace.icon(forFile:)` 要走 IconServices + 磁盘，不能每次都重算
    private var cachedIcon: NSImage?

    // 获取图标
    var icon: NSImage? {
        if let cachedIcon { return cachedIcon }
        let image: NSImage?
        switch type {
        case .text:
            image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        case .image:
            // 图片类型左上角显示通用图标，实际图片显示在预览区
            image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .file:
            if let firstFile = fileURLs?.first {
                image = NSWorkspace.shared.icon(forFile: firstFile)
            } else {
                image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            }
        case .url:
            image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        case .unknown:
            image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        }
        cachedIcon = image
        return image
    }

    // 格式化字节大小
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // 时间格式化（formatter 复用：改前每次调用都新建 DateFormatter，滚动复用卡片时会反复构造）
    private static let timeOfDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var formattedTime: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            return "今天 " + Self.timeOfDayFormatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            return "昨天 " + Self.timeOfDayFormatter.string(from: timestamp)
        } else {
            return Self.dateTimeFormatter.string(from: timestamp)
        }
    }
}
