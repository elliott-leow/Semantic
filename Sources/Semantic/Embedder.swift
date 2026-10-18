import Accelerate
import CoreGraphics
import Foundation

// Not thread-safe: each owner calls it from one serial queue.
final class Embedder {
    private let ctx: OpaquePointer
    private var queryCache: [String: [Float]] = [:]
    private var queryOrder: [String] = []

    init?(multimodal: Bool, nCtx: Int32) {
        guard FileManager.default.fileExists(atPath: Paths.model),
              let c = sb_init(Paths.model, multimodal ? Paths.mmproj : nil, nCtx, 1) else { return nil }
        ctx = c
    }

    deinit { sb_free(ctx) }

    func text(_ s: String) -> [Float]? {
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_text(ctx, s, &out) == 0 ? out : nil
    }

    func query(_ q: String) -> [Float]? {
        if let cached = queryCache[q] { return cached }
        guard let vector = text("task: search result | query: " + q) else { return nil }
        if queryOrder.count >= 128 { queryCache.removeValue(forKey: queryOrder.removeFirst()) }
        queryOrder.append(q)
        queryCache[q] = vector
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
        var ok = false
        let rgb = [UInt8](unsafeUninitializedCapacity: w * h * 3) { dst, count in
            var s = vImage_Buffer(data: px, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
            ok = vImageConvert_RGBA8888toRGB888(&s, &d, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            count = ok ? w * h * 3 : 0
        }
        guard ok else { return nil }
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_image(ctx, rgb, Int32(w), Int32(h), &out) == 0 ? out : nil
    }

    func audio(_ pcm: [Float]) -> [Float]? {
        var out = [Float](repeating: 0, count: DIM)
        return sb_embed_audio(ctx, pcm, pcm.count, &out) == 0 ? out : nil
    }
}
