import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Avatars and BIMI logos, loaded once and kept.
///
/// Two tiers: a memory cache sized in bytes so a long scroll cannot grow without bound,
/// and a disk cache so a relaunch draws faces immediately. Requests for the same URL
/// coalesce into one download, which matters in a list where the same sender repeats.
actor ImageCache {
    static let shared = ImageCache()

    private let memory: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.totalCostLimit = 24 * 1024 * 1024   // ~24 MB of decoded avatars
        c.countLimit = 500
        return c
    }()

    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared          // attachment images need the session cookie
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    func image(for url: URL, maxPixel: CGFloat) async -> PlatformImage? {
        let key = Self.key(url, maxPixel: maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let task = inFlight[key] { return await task.value }

        let task = Task<PlatformImage?, Never> { [directory, session] in
            let file = directory.appendingPathComponent(key)

            // Disk first: decoding a local file beats a round trip every time.
            if let data = try? Data(contentsOf: file), let image = Self.decode(data, maxPixel: maxPixel) {
                return image
            }
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let image = Self.decode(data, maxPixel: maxPixel) else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
        }
        return image
    }

    /// Downsamples while decoding, so a 1024px Google avatar never becomes a 4 MB bitmap
    /// behind a 38pt circle.
    private static func decode(_ data: Data, maxPixel: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if canImport(UIKit)
        return PlatformImage(cgImage: cg)
        #else
        return PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private static func cost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    private static func key(_ url: URL, maxPixel: CGFloat) -> String {
        let raw = url.absoluteString + "@\(Int(maxPixel))"
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 36)
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// A remote image that falls back to its placeholder rather than to empty space,
/// and never animates in on a cache hit (which would make every scroll flicker).
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let loaded = await ImageCache.shared.image(for: url, maxPixel: size * Platform.scale)
        guard let loaded else { didLoad = true; return }
        if didLoad {
            withAnimation(Theme.Motion.quick) { image = loaded }
        } else {
            image = loaded
            didLoad = true
        }
    }
}
