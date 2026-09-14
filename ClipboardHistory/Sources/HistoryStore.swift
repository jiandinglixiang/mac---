import Foundation

/// 历史持久化：元数据 JSON + 图片独立文件。
///
/// 改前整个历史（含图片 base64）是 UserDefaults 里的**单个 60 MB blob**：
/// 解码 200 条实测 914 ms（且发生在主线程），每次剪贴板变化又要在主线程重新编码同量级数据。
/// 现在元数据只有几十 KB（毫秒级），图片按 `images/<uuid>.dat` 单独存放并在卡片真正需要时才读盘，
/// 所有磁盘 IO 与编解码都放到串行后台队列。
final class HistoryStore {

    /// 元数据记录（不含图片字节）
    struct Record: Codable {
        let id: UUID
        let timestamp: Date
        let type: ClipboardItemType
        var textContent: String?
        var imageFileName: String?
        var imageByteCount: Int?
        var fileURLs: [String]?
        var urlString: String?
    }

    /// 旧版 UserDefaults blob 里的一条（图片是 base64 的 `imageData`）
    private struct LegacyItem: Codable {
        let id: UUID
        let timestamp: Date
        let type: ClipboardItemType
        var textContent: String?
        var imageData: Data?
        var fileURLs: [String]?
        var urlString: String?
    }

    private enum StoreError: Error {
        case verificationFailed
        case badFileName(String)
    }

    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "com.clipboard.history.store", qos: .utility)
    private let fileManager = FileManager.default
    private let legacyKey = "clipboardHistory"
    private let migrationKey = "hasMigratedHistoryStoreV2"

    let rootURL: URL
    let imagesURL: URL
    let metadataURL: URL

    /// 上一次成功落盘的元数据 id 序列，用于跳过「内容没变」的重复写盘
    private var lastWrittenIDs: [UUID] = []

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        rootURL = base.appendingPathComponent("剪贴板历史", isDirectory: true)
        imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        metadataURL = rootURL.appendingPathComponent("history.json")
        createDirectoriesIfNeeded()
    }

    // MARK: - 读取

    /// 读取历史元数据，主线程回调（图片数据按需读盘，不在这里加载）
    func load(completion: @escaping ([ClipboardItem]) -> Void) {
        queue.async {
            let records = self.readRecords()
            let items = records.map { self.makeItem(from: $0) }
            if !items.isEmpty {
                self.lastWrittenIDs = records.map { $0.id }
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// 读原图数据（供 ClipboardItem 的按需 loader 调用，可能在任意线程）
    func imageData(fileName: String) -> Data? {
        guard isValidFileName(fileName) else { return nil }
        return try? Data(contentsOf: imagesURL.appendingPathComponent(fileName))
    }

    // MARK: - 写入

    /// 保存历史快照。
    /// - 调用方（主线程）只做轻量快照：把条目转成值类型记录，并挑出「尚未落盘」的图片数据；
    ///   真正的 JSON 编码、图片落盘与写盘合并都在后台串行队列完成。
    func save(_ snapshot: [ClipboardItem]) {
        var records: [Record] = []
        records.reserveCapacity(snapshot.count)
        var pendingImages: [(fileName: String, data: Data)] = []
        var itemsToRelease: [ClipboardItem] = []

        for item in snapshot {
            records.append(makeRecord(from: item))
            guard item.type == .image, let fileName = item.imageFileName else { continue }
            if !fileExists(fileName), let data = item.imageData {
                pendingImages.append((fileName, data))
                itemsToRelease.append(item)
            }
        }

        let ids = records.map { $0.id }
        queue.async {
            guard ids != self.lastWrittenIDs else { return }
            self.lastWrittenIDs = ids
            self.write(records: records, pendingImages: pendingImages)
            guard !itemsToRelease.isEmpty else { return }
            // 图片已落盘：释放内存副本，历史里的图片统一按需读盘
            DispatchQueue.main.async {
                itemsToRelease.forEach { $0.releaseInMemoryImageData() }
            }
        }
    }

    /// 删除某条历史对应的图片文件
    func removeImage(fileName: String) {
        guard isValidFileName(fileName) else { return }
        queue.async {
            try? self.fileManager.removeItem(at: self.imagesURL.appendingPathComponent(fileName))
        }
    }

    /// 清空所有历史数据（元数据 + 图片目录）
    func clear() {
        queue.async {
            self.lastWrittenIDs = []
            try? self.fileManager.removeItem(at: self.metadataURL)
            try? self.fileManager.removeItem(at: self.imagesURL)
            self.createDirectoriesIfNeeded()
        }
    }

    // MARK: - 旧数据迁移

    /// 把旧的 `UserDefaults["clipboardHistory"]`（60 MB blob）迁到文件存储。
    /// 幂等且不丢数据：先写新存储 → 回读校验条数与 id 集合一致 → 才删除旧 key 并落迁移标记；
    /// 任一步失败都保留旧数据（下次启动重试），不阻塞启动流程。
    func migrateFromUserDefaultsIfNeeded(completion: @escaping () -> Void) {
        queue.async {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: self.migrationKey) else {
                DispatchQueue.main.async { completion() }
                return
            }
            guard let legacyData = defaults.data(forKey: self.legacyKey) else {
                defaults.set(true, forKey: self.migrationKey)
                DispatchQueue.main.async { completion() }
                return
            }

            do {
                let legacyItems = try JSONDecoder().decode([LegacyItem].self, from: legacyData)
                let records = try self.writeLegacy(legacyItems)

                let readBackData = try Data(contentsOf: self.metadataURL)
                let readBack = try JSONDecoder().decode([Record].self, from: readBackData)
                guard readBack.count == records.count,
                      Set(readBack.map { $0.id }) == Set(records.map { $0.id }) else {
                    throw StoreError.verificationFailed
                }

                self.lastWrittenIDs = records.map { $0.id }
                defaults.removeObject(forKey: self.legacyKey)
                defaults.set(true, forKey: self.migrationKey)
                print("历史数据已迁移到文件存储：\(records.count) 条")
            } catch {
                print("历史数据迁移失败（已保留旧数据，下次启动重试）：\(error)")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - 内部实现

    private func createDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    private func isValidFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.contains("..")
    }

    private func fileExists(_ fileName: String) -> Bool {
        isValidFileName(fileName) && fileManager.fileExists(atPath: imagesURL.appendingPathComponent(fileName).path)
    }

    private func makeRecord(from item: ClipboardItem) -> Record {
        Record(id: item.id,
               timestamp: item.timestamp,
               type: item.type,
               textContent: item.textContent,
               imageFileName: item.imageFileName,
               imageByteCount: item.imageByteCount,
               fileURLs: item.fileURLs,
               urlString: item.urlString)
    }

    private func makeItem(from record: Record) -> ClipboardItem {
        let item = ClipboardItem(id: record.id,
                                 timestamp: record.timestamp,
                                 type: record.type,
                                 textContent: record.textContent,
                                 imageFileName: record.imageFileName,
                                 imageByteCount: record.imageByteCount,
                                 fileURLs: record.fileURLs,
                                 urlString: record.urlString)
        if record.imageFileName != nil {
            item.imageDataLoader = { [weak self] name in
                guard let self else { return nil }
                return self.imageData(fileName: name)
            }
        }
        return item
    }

    private func readRecords() -> [Record] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        do {
            return try JSONDecoder().decode([Record].self, from: data)
        } catch {
            print("历史元数据解析失败：\(error)")
            return []
        }
    }

    /// 写盘（仅可在 queue 上调用）
    private func write(records: [Record], pendingImages: [(fileName: String, data: Data)]) {
        createDirectoriesIfNeeded()
        for image in pendingImages {
            guard isValidFileName(image.fileName) else { continue }
            do {
                try image.data.write(to: imagesURL.appendingPathComponent(image.fileName), options: .atomic)
            } catch {
                print("图片写入失败 \(image.fileName)：\(error)")
            }
        }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            print("历史元数据写入失败：\(error)")
        }
    }

    /// 迁移写入：图片落盘 + 元数据落盘（仅可在 queue 上调用）
    private func writeLegacy(_ legacyItems: [LegacyItem]) throws -> [Record] {
        createDirectoriesIfNeeded()
        var records: [Record] = []
        records.reserveCapacity(legacyItems.count)

        for legacy in legacyItems {
            var fileName: String?
            var byteCount: Int?
            if legacy.type == .image, let data = legacy.imageData, !data.isEmpty {
                let name = "\(legacy.id.uuidString).dat"
                try data.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
                fileName = name
                byteCount = data.count
            }
            records.append(Record(id: legacy.id,
                                  timestamp: legacy.timestamp,
                                  type: legacy.type,
                                  textContent: legacy.textContent,
                                  imageFileName: fileName,
                                  imageByteCount: byteCount,
                                  fileURLs: legacy.fileURLs,
                                  urlString: legacy.urlString))
        }

        let data = try JSONEncoder().encode(records)
        try data.write(to: metadataURL, options: .atomic)
        return records
    }
}
