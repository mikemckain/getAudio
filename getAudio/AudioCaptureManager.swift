import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate
import AppKit

enum AudioFormat: String, CaseIterable {
    case m4a = "M4A"
    case wav = "WAV"

    var ext: String {
        switch self {
        case .m4a: return "m4a"
        case .wav: return "wav"
        }
    }
}

enum AudioSource: String, CaseIterable {
    case system = "System"
    case mic = "Mic"
}

enum SortOrder: String, CaseIterable {
    case dateNewest = "Newest"
    case dateOldest = "Oldest"
    case nameAZ = "A → Z"
    case nameZA = "Z → A"
}

@MainActor
class AudioCaptureManager: ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordings: [Recording] = []
    @Published var audioLevels: [Float] = []
    @Published var playbackLevels: [Float] = []
    var levelAppendCount: Int = 0

    @Published var sortOrder: SortOrder = .dateNewest {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            loadRecordings()
        }
    }

    @Published var audioFormat: AudioFormat = .m4a {
        didSet {
            UserDefaults.standard.set(audioFormat.rawValue, forKey: "audioFormat")
        }
    }

    @Published var audioSource: AudioSource = .system {
        didSet {
            UserDefaults.standard.set(audioSource.rawValue, forKey: "audioSource")
            if audioSource == .mic {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        }
    }

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private let audioQueue = DispatchQueue(label: "com.mike.getAudio.audio")
    private var playbackTimer: Timer?
    private var playbackPlayer: AVAudioPlayer?
    private var micEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var micOutputURL: URL?
    private var currentRecordingLevel: Float = 0
    private var levelTimer: Timer?
    private static let maxLevels = 120

    var recordingsDirectory: URL {
        didSet {
            UserDefaults.standard.set(recordingsDirectory.path, forKey: "recordingsDirectory")
            try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            loadRecordings()
        }
    }

    struct Recording: Identifiable, Hashable {
        let id = UUID()
        var url: URL
        var duration: TimeInterval
        var name: String { url.deletingPathExtension().lastPathComponent }

        var formattedDuration: String {
            let m = Int(duration) / 60
            let s = Int(duration) % 60
            return String(format: "%d:%02d", m, s)
        }

        static func == (lhs: Recording, rhs: Recording) -> Bool { lhs.url == rhs.url }
        func hash(into hasher: inout Hasher) { hasher.combine(url) }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "recordingsDirectory") {
            recordingsDirectory = URL(fileURLWithPath: saved)
        } else {
            recordingsDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/getAudio")
        }
        if let savedSort = UserDefaults.standard.string(forKey: "sortOrder"),
           let order = SortOrder(rawValue: savedSort) {
            sortOrder = order
        }
        if let savedFormat = UserDefaults.standard.string(forKey: "audioFormat"),
           let fmt = AudioFormat(rawValue: savedFormat) {
            audioFormat = fmt
        }
        if let savedSource = UserDefaults.standard.string(forKey: "audioSource"),
           let src = AudioSource(rawValue: savedSource) {
            audioSource = src
        }
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        loadRecordings()
    }

    func loadRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        recordings = files
            .filter { ["m4a", "wav", "mp3"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                switch sortOrder {
                case .dateNewest, .dateOldest:
                    let d0 = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    let d1 = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    return sortOrder == .dateNewest ? d0 > d1 : d0 < d1
                case .nameAZ:
                    return a.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(
                        b.deletingPathExtension().lastPathComponent) == .orderedAscending
                case .nameZA:
                    return a.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(
                        b.deletingPathExtension().lastPathComponent) == .orderedDescending
                }
            }
            .map { url in
                let player = try? AVAudioPlayer(contentsOf: url)
                return Recording(url: url, duration: player?.duration ?? 0)
            }
    }

    func startRecording() async throws {
        let filename = Self.dateFormatter.string(from: Date()) + "." + audioFormat.ext
        let outputURL = recordingsDirectory.appendingPathComponent(filename)

        // Immediate UI response
        audioLevels = []
        levelAppendCount = 0
        currentRecordingLevel = 0
        isRecording = true

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 47.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.audioLevels.append(self.currentRecordingLevel)
                self.levelAppendCount += 1
                if self.audioLevels.count > Self.maxLevels {
                    self.audioLevels.removeFirst(self.audioLevels.count - Self.maxLevels)
                }
            }
        }

        do {
            if audioSource == .mic {
                try startMicRecording(outputURL: outputURL)
            } else {
                try await startSystemRecording(outputURL: outputURL)
            }
        } catch {
            levelTimer?.invalidate()
            levelTimer = nil
            isRecording = false
            throw error
        }
    }

    private func startSystemRecording(outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw NSError(domain: "getAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.channelCount = 2
        config.sampleRate = 48000
        config.width = 2
        config.height = 2

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let output = try AudioStreamOutput(outputURL: outputURL, format: audioFormat) { [weak self] level in
            Task { @MainActor in
                self?.currentRecordingLevel = level
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
    }

    private func startMicRecording(outputURL: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Write to WAV first for mic (convert to M4A later if needed)
        let writeURL = audioFormat == .m4a
            ? outputURL.deletingPathExtension().appendingPathExtension("wav")
            : outputURL
        let file = try AVAudioFile(forWriting: writeURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
            let level = min(rms * 8, 1.0)
            Task { @MainActor [weak self] in
                self?.currentRecordingLevel = level
            }
        }

        try engine.start()
        self.micEngine = engine
        self.micFile = file
        self.micOutputURL = outputURL
    }

    func stopRecording() async {
        // Immediate UI response
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        audioLevels = []

        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
            await streamOutput?.finish()
            self.streamOutput = nil
        }

        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.micEngine = nil
            self.micFile = nil

            // Convert WAV to target format if needed
            if let outputURL = micOutputURL, audioFormat != .wav {
                let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
                if audioFormat == .m4a {
                    await convertAudio(from: wavURL, to: outputURL, format: "m4af", dataFormat: "aac", bitRate: "320000")
                }
            }
            self.micOutputURL = nil
        }

        loadRecordings()
        NSSound(named: "Pop")?.play()
    }

    private func convertAudio(from source: URL, to dest: URL, format: String, dataFormat: String, bitRate: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [source.path, dest.path, "-f", format, "-d", dataFormat, "-b", bitRate]
            process.terminationHandler = { _ in
                try? FileManager.default.removeItem(at: source)
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        loadRecordings()
    }

    func renameRecording(_ recording: Recording, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let ext = recording.url.pathExtension
        let newURL = recording.url.deletingLastPathComponent().appendingPathComponent(trimmed + "." + ext)
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return false }

        do {
            try FileManager.default.moveItem(at: recording.url, to: newURL)
            loadRecordings()
            return true
        } catch {
            return false
        }
    }

    func startPlayback(_ recording: Recording) -> Bool {
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.isMeteringEnabled = true
            player.play()
            playbackPlayer = player
            isPlaying = true
            playbackLevels = []
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 47.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let player = self.playbackPlayer else { return }
                    if !player.isPlaying {
                        self.stopPlayback()
                        return
                    }
                    player.updateMeters()
                    let avg = player.averagePower(forChannel: 0)
                    // Convert dB to linear (0-1), dB range roughly -60 to 0
                    let linear = pow(10, avg / 20)
                    let level = min(linear * 4.5, 1.0)
                    self.playbackLevels.append(level)
                    if self.playbackLevels.count > Self.maxLevels {
                        self.playbackLevels.removeFirst(self.playbackLevels.count - Self.maxLevels)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackPlayer?.stop()
        playbackPlayer = nil
        isPlaying = false
        playbackLevels = []
    }

    func revealRecording(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}

class AudioStreamOutput: NSObject, SCStreamOutput {
    private let assetWriter: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private var sessionStarted = false
    private let onLevel: @Sendable (Float) -> Void
    private let format: AudioFormat

    init(outputURL: URL, format: AudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        self.onLevel = onLevel
        self.format = format

        let fileType: AVFileType
        let settings: [String: Any]
        let writerURL: URL

        switch format {
        case .m4a:
            writerURL = outputURL
            fileType = .m4a
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        case .wav:
            writerURL = outputURL
            fileType = .wav
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }

        assetWriter = try AVAssetWriter(outputURL: writerURL, fileType: fileType)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput.expectsMediaDataInRealTime = true
        assetWriter.add(audioInput)
        assetWriter.startWriting()
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }

        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }

        // Extract RMS level for waveform
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        data.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPointer in
            var rms: Float = 0
            vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(floatCount))
            let level = min(rms * 8, 1.0) // Scale up for visible waveform
            onLevel(level)
        }
    }

    func finish() async {
        audioInput.markAsFinished()
        if assetWriter.status == .writing {
            await assetWriter.finishWriting()
        }

    }
}
