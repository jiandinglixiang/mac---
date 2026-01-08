import Cocoa
import UniformTypeIdentifiers

// 剪贴板项数据类型
enum ClipboardItemType: Codable {
    case text
    case image
    case file
    case url
    case unknown
}

// 剪贴板历史项
class ClipboardItem: NSObject, Codable {
    let id: UUID
    let timestamp: Date
    let type: ClipboardItemType
    var textContent: String?
    var imageData: Data?
    var fileURLs: [String]?
    var urlString: String?
    
    init(type: ClipboardItemType, textContent: String? = nil, imageData: Data? = nil, fileURLs: [URL]? = nil, urlString: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.textContent = textContent
        self.imageData = imageData
        self.fileURLs = fileURLs?.map { $0.path }
        self.urlString = urlString
        super.init()
    }
    
    // 获取显示文本
    var displayText: String {
        switch type {
        case .text:
            return textContent?.prefix(100).description ?? ""
        case .image:
            return "📷 图片"
        case .file:
            let count = fileURLs?.count ?? 0
            if count == 1, let fileName = fileURLs?.first?.split(separator: "/").last {
                return "📄 \(fileName)"
            }
            return "📄 \(count) 个文件"
        case .url:
            return "🔗 \(urlString ?? "")"
        case .unknown:
            return "未知类型"
        }
    }
    
    // 获取预览文本
    var previewText: String {
        switch type {
        case .text:
            return textContent ?? ""
        case .image:
            return "图片数据 (\(formatBytes(imageData?.count ?? 0)))"
        case .file:
            return fileURLs?.joined(separator: "\n") ?? ""
        case .url:
            return urlString ?? ""
        case .unknown:
            return ""
        }
    }
    
    // 获取图标
    var icon: NSImage? {
        switch type {
        case .text:
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        case .image:
            if let data = imageData, let image = NSImage(data: data) {
                return image
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .file:
            if let firstFile = fileURLs?.first {
                return NSWorkspace.shared.icon(forFile: firstFile)
            }
            return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        case .url:
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        case .unknown:
            return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        }
    }
    
    // 格式化字节大小
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    // 时间格式化
    var formattedTime: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(timestamp) {
            formatter.dateFormat = "HH:mm:ss"
            return "今天 " + formatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            formatter.dateFormat = "HH:mm:ss"
            return "昨天 " + formatter.string(from: timestamp)
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: timestamp)
        }
    }
}
