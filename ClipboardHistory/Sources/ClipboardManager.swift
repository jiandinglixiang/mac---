import Cocoa
import UniformTypeIdentifiers

class ClipboardManager {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    private(set) var history: [ClipboardItem] = []
    private let maxHistorySize = 200
    private let userDefaults = UserDefaults.standard
    private let historyKey = "clipboardHistory"
    private var ignoreChangesRemaining: Int = 0

    struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
        let changeCount: Int
    }
    
    init() {
        lastChangeCount = pasteboard.changeCount
        loadHistory()
    }
    
    // 开始监听剪贴板
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        
        print("开始监听剪贴板变化")
    }
    
    // 停止监听
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        saveHistory()
        print("停止监听剪贴板")
    }
    
    // 检查剪贴板变化
    private func checkPasteboard() {
        let changeCount = pasteboard.changeCount
        
        if changeCount != lastChangeCount {
            lastChangeCount = changeCount
            if ignoreChangesRemaining > 0 {
                ignoreChangesRemaining -= 1
                return
            }
            captureClipboard()
        }
    }
    
    // 捕获剪贴板内容
    private func captureClipboard() {
        // 获取剪贴板中的所有类型
        guard let types = pasteboard.types else { return }
        
        var newItem: ClipboardItem?
        
        // 优先处理文件
        if types.contains(.fileURL) {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                newItem = ClipboardItem(type: .file, fileURLs: urls)
            }
        }
        // 处理图片
        else if types.contains(.tiff) || types.contains(.png) {
            if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                newItem = ClipboardItem(type: .image, imageData: imageData)
            }
        }
        // 处理 URL
        else if types.contains(.URL) {
            if let urlString = pasteboard.string(forType: .URL) {
                newItem = ClipboardItem(type: .url, urlString: urlString)
            }
        }
        // 处理文本
        else if types.contains(.string) {
            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                // 检查是否是 URL
                if let url = URL(string: text), url.scheme != nil {
                    newItem = ClipboardItem(type: .url, urlString: text)
                } else {
                    newItem = ClipboardItem(type: .text, textContent: text)
                }
            }
        }
        
        // 添加到历史记录
        if let item = newItem {
            addToHistory(item)
        }
    }
    
    // 添加到历史记录
    private func addToHistory(_ item: ClipboardItem) {
        // 避免重复添加相同内容
        if let lastItem = history.first {
            if areItemsEqual(lastItem, item) {
                return
            }
        }
        
        history.insert(item, at: 0)
        
        // 限制历史记录数量
        if history.count > maxHistorySize {
            history.removeLast()
        }
        
        saveHistory()
        
        print("添加剪贴板项: \(item.type)")
    }
    
    // 比较两个项是否相同
    private func areItemsEqual(_ item1: ClipboardItem, _ item2: ClipboardItem) -> Bool {
        if item1.type != item2.type {
            return false
        }
        
        switch item1.type {
        case .text:
            return item1.textContent == item2.textContent
        case .url:
            return item1.urlString == item2.urlString
        case .file:
            return item1.fileURLs == item2.fileURLs
        case .image:
            // 简单比较图片数据大小
            return item1.imageData?.count == item2.imageData?.count
        case .unknown:
            return false
        }
    }
    
    // 将项目复制回剪贴板
    func copyToClipboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        
        switch item.type {
        case .text:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let urls = item.fileURLs?.compactMap({ URL(fileURLWithPath: $0) }) {
                pasteboard.writeObjects(urls as [NSPasteboardWriting])
            }
        case .url:
            if let urlString = item.urlString {
                pasteboard.setString(urlString, forType: .string)
            }
        case .unknown:
            break
        }
        
        // 更新 changeCount 以避免重复捕获
        lastChangeCount = pasteboard.changeCount
    }

    /// 复制当前剪贴板内容（尽量完整保留所有 pasteboard types），用于“粘贴后恢复剪贴板”。
    func snapshotPasteboard() -> PasteboardSnapshot {
        let currentItems = pasteboard.pasteboardItems ?? []
        let copiedItems: [NSPasteboardItem] = currentItems.map { item in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                } else if let str = item.string(forType: type) {
                    newItem.setString(str, forType: type)
                }
            }
            return newItem
        }
        return PasteboardSnapshot(items: copiedItems, changeCount: pasteboard.changeCount)
    }

    /// 恢复剪贴板到指定快照。
    func restorePasteboard(from snapshot: PasteboardSnapshot) {
        ignoreChangesRemaining += 1
        pasteboard.clearContents()
        if !snapshot.items.isEmpty {
            _ = pasteboard.writeObjects(snapshot.items)
        }
        lastChangeCount = pasteboard.changeCount
    }
    
    // 保存历史记录
    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(history)
            userDefaults.set(data, forKey: historyKey)
        } catch {
            print("保存历史记录失败: \(error)")
        }
    }
    
    // 加载历史记录
    private func loadHistory() {
        if let data = userDefaults.data(forKey: historyKey) {
            do {
                let decoder = JSONDecoder()
                history = try decoder.decode([ClipboardItem].self, from: data)
                print("加载了 \(history.count) 条历史记录")
            } catch {
                print("加载历史记录失败: \(error)")
            }
        }
    }
    
    // 清空历史记录
    func clearHistory() {
        history.removeAll()
        saveHistory()
        print("历史记录已清空")
    }
    
    // 删除指定项
    func deleteItem(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
        saveHistory()
    }
}
