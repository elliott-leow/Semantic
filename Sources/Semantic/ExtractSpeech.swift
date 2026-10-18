import AVFoundation
import Speech

final class WaitBox<T>: @unchecked Sendable { var value: T? }

// On-device transcripts of audio files and video soundtracks, for exact-word search.
// Never asks for permission: the indexer is a background child process.
extension Extract {
    static var speechReady: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable { return true }
        return (SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer())?.supportsOnDeviceRecognition == true
    }

    // Runs async framework calls from the synchronous indexer (never called on a queue they need).
    static func wait<T>(timeout: Double = 60, _ f: @escaping () async throws -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = WaitBox<T>()
        Task.detached { box.value = try? await f(); sem.signal() }
        return sem.wait(timeout: .now() + timeout) == .success ? box.value : nil
    }

    // mono 16 kHz float PCM of the first `seconds` of the file's first audio track;
    // [] when there is no audio track, nil when the file cannot be decoded
    static func soundtrack(_ url: URL, seconds: Double) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = wait({ try await asset.loadTracks(withMediaType: .audio) }) else { return nil }
        guard let track = tracks.first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var pcm: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            guard n > 0 else { continue }
            let start = pcm.count
            pcm.append(contentsOf: repeatElement(0, count: n))
            let status = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress! + start * 4) }
            guard status == kCMBlockBufferNoErr else { return nil }
        }
        guard reader.status == .completed else { return nil }
        return pcm
    }

    static func pcmBuffer(_ pcm: [Float]) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, pcm.count))), let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: pcm.count) }
        return buf
    }

    // Transcript in 30 s windows as media passages (loc = window start in seconds, shown as "At m:ss").
    // nil means the file could not be read or recognition failed; [] means no speech.
    static func transcriptResult(_ url: URL, maxSeconds: Double = 600) -> (passages: [Passage], seconds: Double)? {
        guard let pcm = soundtrack(url, seconds: maxSeconds) else { return nil }
        let seconds = Double(pcm.count) / 16000
        guard seconds >= 1 else { return ([], seconds) }
        var words: [(Double, String)]?
        if #available(macOS 26, *) { words = analyzerWords(pcm) }
        if words == nil { words = recognizerWords(pcm) }
        guard let words else { return nil }
        var windows: [Double: [String]] = [:]
        for (t, w) in words { windows[(t / 30).rounded(.down) * 30, default: []].append(w) }
        return (windows.keys.sorted().map { Passage(text: windows[$0]!.joined(separator: " "), src: .media, loc: $0) }, seconds)
    }

    // macOS 26+ SpeechAnalyzer, only with an already installed model for the user's language
    @available(macOS 26, *)
    static func analyzerWords(_ pcm: [Float]) -> [(Double, String)]? {
        let seconds = Double(pcm.count) / 16000
        return wait(timeout: 120 + seconds) { () async throws -> [(Double, String)]? in
            guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return nil }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let src = pcmBuffer(pcm), let input = convert(src, to: fmt) else { return nil }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collect = Task { () async throws -> [(Double, String)] in
                var out: [(Double, String)] = []
                for try await r in transcriber.results { out.append((r.range.start.seconds, String(r.text.characters))) }
                return out
            }
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            feed.yield(AnalyzerInput(buffer: input))
            feed.finish()
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collect.value
        } ?? nil
    }

    static func convert(_ buf: AVAudioPCMBuffer, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        guard let conv = AVAudioConverter(from: buf.format, to: fmt),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 4096) else { return nil }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true
            s.pointee = .haveData
            return buf
        }
        return err == nil && status != .error ? out : nil
    }

    private final class Listener: NSObject, SFSpeechRecognitionTaskDelegate {
        var words: [(Double, String)] = []
        var ok = false
        let done = DispatchSemaphore(value: 0)

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
            words += result.bestTranscription.segments.map { ($0.timestamp, $0.substring) }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            let e = task.error as NSError?
            // 1110: no speech detected, which is a result, not a failure
            ok = successfully || !words.isEmpty || (e?.domain == "kAFAssistantErrorDomain" && e?.code == 1110)
            done.signal()
        }
    }

    static func recognizerWords(_ pcm: [Float]) -> [(Double, String)]? {
        guard let rec = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), rec.supportsOnDeviceRecognition, rec.isAvailable else { return nil }
        rec.queue = OperationQueue() // the indexer blocks the main thread while waiting
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let listener = Listener()
        let task = rec.recognitionTask(with: req, delegate: listener)
        var i = 0
        while i < pcm.count {
            let n = min(16000 * 5, pcm.count - i)
            if let b = pcmBuffer(Array(pcm[i..<(i + n)])) { req.append(b) }
            i += n
        }
        req.endAudio()
        guard listener.done.wait(timeout: .now() + 120 + Double(pcm.count) / 16000) == .success else { task.cancel(); return nil }
        return listener.ok ? listener.words : nil
    }
}
