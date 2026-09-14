import Cocoa
import ImageIO

/// 卡片缩略图缓存。
///
/// 改前是把剪贴板原图（实测最大 852x1752，11 张合计 10.3 Mpx ≈ 39 MB 纹理）直接塞进
/// `layer.contents`，由合成器每帧缩放合成。这里改用 ImageIO 一次性降采样到卡片预览区尺寸，
/// 并把生成放到后台队列，避免滚动时新卡片进入视口造成主线程卡顿。
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "com.clipboard.history.thumbnail", qos: .userInitiated)
    /// 约 2 倍卡片预览区尺寸（预览区约 160x90 点），保证 Retina 下不糊
    private let maxPixelSize: CGFloat = 360

    private init() {
        cache.countLimit = 80
    }

    /// 取缩略图。
    /// - Parameter completion: 始终在主线程回调；命中缓存时同步回调，未命中时后台生成后回调。
    func thumbnail(for item: ClipboardItem, completion: @escaping (CGImage?) -> Void) {
        let key = item.id.uuidString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached.image)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let image = Self.makeThumbnail(item, maxPixelSize: self.maxPixelSize)
            if let image {
                self.cache.setObject(Box(image), forKey: key)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 条目被删除时清理缓存
    func remove(id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func makeThumbnail(_ item: ClipboardItem, maxPixelSize: CGFloat) -> CGImage? {
        guard let data = item.imageData else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
