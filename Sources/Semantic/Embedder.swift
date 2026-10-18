import CoreGraphics
import Foundation

// Not thread-safe: each owner calls it from one serial queue.
final class Embedder {
    private let ctx: OpaquePointer
    // A query's vector depends only on the text and the model, so it outlives an unloaded model.
    // Shared by every embedder of one configuration; the model loads on another queue, hence the lock.
    private static var queryCache: [String: [Float]] = [:]
    private static var queryOrder: [String: [String]] = [:]
    private static let queryLock = NSLock()
    private let model: String

    init?(multimodal: Bool, nCtx: Int32) {
        guard FileManager.default.fileExists(atPath: Paths.model),
              let c = sb_init(Paths.model, multimodal ? Paths.mmproj : nil, nCtx, 1) else { return nil }
        ctx = c
        model = "\(Paths.model)|\(multimodal)|\(nCtx)|"
    }

    deinit { sb_free(ctx) }

    func text(_ s: String) -> [Float]? {
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_text(ctx, s, &out) == 0 ? out : nil
    }

    func query(_ q: String) -> [Float]? {
        let key = model + q
        Self.queryLock.lock()
        let cached = Self.queryCache[key]
        Self.queryLock.unlock()
        if let cached { return cached }
        guard let vector = text("task: search result | query: " + q) else { return nil }
        Self.queryLock.lock()
        defer { Self.queryLock.unlock() }
        if Self.queryCache[key] == nil {
            if Self.queryOrder[model, default: []].count >= 128 { Self.queryCache.removeValue(forKey: Self.queryOrder[model, default: []].removeFirst()) }
            Self.queryOrder[model, default: []].append(key)
            Self.queryCache[key] = vector
        }
        return vector
    }

    func document(title: String, body: String) -> [Float]? {
        text("title: \(title.isEmpty ? "none" : title) | text: \(body)")
    }

    func image(_ cg: CGImage) -> [Float]? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let px = c.data else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rgba = px.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_image(ctx, rgb, Int32(w), Int32(h), &out) == 0 ? out : nil
    }

    func audio(_ pcm: [Float]) -> [Float]? {
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_audio(ctx, pcm, pcm.count, &out) == 0 ? out : nil
    }
}
