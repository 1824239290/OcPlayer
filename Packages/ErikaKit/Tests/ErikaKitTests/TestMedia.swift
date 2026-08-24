import AVFoundation
import CoreVideo
import Foundation

/// 造一个真视频文件：1 秒、30 帧、H.264 + AAC 静音，用于无窗口环境下验证内核真的能 demux/decode。
/// 不进仓库、不联网，跑完即删。
enum TestMedia {

    /// 造一个「有画面 + 有声音」的 mp4：H.264 视频轨 + AAC 正弦音轨，用于验证渲染与音频推送。
    static func makeMovieWithTone(seconds: Int = 2) async throws -> URL {
        try await makeMovie(toneFrequencies: [440], seconds: seconds)
    }

    /// 两条不同频率音轨的 mp4（音轨枚举 / 切换测试用）。
    static func makeMovieWithTwoTones(seconds: Int = 2) async throws -> URL {
        try await makeMovie(toneFrequencies: [440, 880], seconds: seconds)
    }

    private static func makeMovie(toneFrequencies: [Float], seconds: Int) async throws -> URL {
        let video = try makeShortMovie(seconds: seconds)
        let audios = try toneFrequencies.map { try makeTone(seconds: Double(seconds), frequency: $0) }
        defer {
            try? FileManager.default.removeItem(at: video)
            audios.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return try await mux(video: video, audios: audios)
    }

    /// 44.1 kHz 单声道正弦，写成 AAC/m4a。
    private static func makeTone(seconds: Double, frequency: Float = 440) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-tone-\(UUID().uuidString).m4a")
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = 0.25 * sinf(2 * .pi * frequency * Float(index) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// 把独立的视频轨和若干条音轨合成一个 mp4（直通，不重编码）。
    private static func mux(video: URL, audios: [URL]) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-av-\(UUID().uuidString).mp4")
        let composition = AVMutableComposition()

        func insert(_ url: URL, mediaType: AVMediaType) async throws {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first,
                  let slot = composition.addMutableTrack(withMediaType: mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw CocoaError(.fileWriteUnknown) }
            let duration = try await asset.load(.duration)
            try slot.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                     of: track, at: .zero)
        }

        try await insert(video, mediaType: .video)
        for audio in audios {
            try await insert(audio, mediaType: .audio)
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // export(to:as:) 是 macOS 15+ 的新 API；本仓库下限是 14，老系统上测试直接跳过合成。
        guard #available(macOS 15, iOS 18, *) else { throw CocoaError(.featureUnsupported) }
        try await session.export(to: output, as: .mp4)
        return output
    }

    static func makeShortMovie(seconds: Int = 1, fps: Int = 30,
                              width: Int = 320, height: Int = 180) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = seconds * fps
        for frame in 0..<total {
            while !videoInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let buffer = try pixelBuffer(width: width, height: height,
                                         gray: UInt8(truncatingIfNeeded: frame * 8))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                timescale: CMTimeScale(fps)))
        }
        videoInput.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private static func pixelBuffer(width: Int, height: Int, gray: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let size = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            memset(base, Int32(gray), size)
        }
        return buffer
    }
}
