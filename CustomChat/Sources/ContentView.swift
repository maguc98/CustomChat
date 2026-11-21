import SwiftUI
import CoreTransferable
import PhotosUI
import UIKit
import CoreImage
import AVKit
import UniformTypeIdentifiers
import AudioToolbox
import SherpaOnnx


private enum ChatMotion {
    static let press = Animation.spring(response: 0.30, dampingFraction: 0.62, blendDuration: 0.08)
    static let layout = Animation.spring(response: 0.46, dampingFraction: 0.84, blendDuration: 0.10)
    static let text = Animation.easeInOut(duration: 0.24)
    static var cinematic: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ChatRevealModifier(progress: 0), identity: ChatRevealModifier(progress: 1)),
            removal: .modifier(active: ChatExitModifier(progress: 0), identity: ChatExitModifier(progress: 1))
        )
    }
}
private struct ChatRevealModifier: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.opacity(Double(progress))
            .scaleEffect(0.94 + 0.06 * progress, anchor: .bottom)
            .blur(radius: (1 - progress) * 8)
            .offset(y: (1 - progress) * 16)
    }
}
private struct ChatExitModifier: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.opacity(Double(progress))
            .scaleEffect(0.97 + 0.03 * progress, anchor: .center)
            .blur(radius: (1 - progress) * 6)
            .offset(y: (1 - progress) * -9)
    }
}
private struct FluidPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .rotation3DEffect(.degrees(configuration.isPressed && !reduceMotion ? -1.1 : 0),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.72)
            .saturation(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.91 : 1)
            .shadow(color: Color(hex: 0x6C8FB8).opacity(configuration.isPressed ? 0.10 : 0),
                    radius: configuration.isPressed ? 7 : 0, x: 0, y: 3)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : ChatMotion.press,
                       value: configuration.isPressed)
    }
}
private extension AnyTransition {
    static var chatCinematic: AnyTransition { ChatMotion.cinematic }
}

private extension Notification.Name {
    static let customChatScrollToBottom = Notification.Name("customchat.scrollToBottom")
}

enum ChatRole: String, CaseIterable, Codable, Equatable {
    case other = "对方"
    case me = "我"
}

enum ChatMessageKind: String, Codable, Equatable { case text, image, redPacket, transfer, paymentReceipt, call, voice }

private let waveformSampleCount = 40

final class VoiceCaptureManager: ObservableObject {
    @Published private(set) var samples = Array(repeating: 0.075, count: waveformSampleCount)
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var hasCapture = false
    @Published private(set) var modelStatus = "首次使用将下载约 168 MB 中文模型"
    @Published private(set) var isModelInstalled = false
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadingFileName = ""
    @Published private(set) var modelDownloadError: String?
    @Published var transcript = ""

    var onFailure: (() -> Void)?
    private let engine = AVAudioEngine()
    private let inferenceQueue = DispatchQueue(label: "com.maguc98.customchat.sherpa.inference", qos: .userInitiated)
    private var recognizer: SherpaOnnxRecognizer?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var startedAt: Date?
    private var captured: [Double] = []
    private var finalizedSentences: [String] = []
    private var currentPartial = ""
    private var lastDuration: Double = 0
    private var lastWaveform: [Double] = []
    private var smoothedLevel: Double = 0.075
    private var tapInstalled = false

    private struct ModelFile {
        let name: String
        let url: URL
        let minimumBytes: Int
    }

    private static var modelDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("CustomChat/SpeechModel", isDirectory: true)
    }

    private static let modelFiles = [
        ModelFile(
            name: "encoder.int8.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/resolve/main/encoder.int8.onnx")!,
            minimumBytes: 100_000_000
        ),
        ModelFile(
            name: "decoder.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/resolve/main/decoder.onnx")!,
            minimumBytes: 1_000_000
        ),
        ModelFile(
            name: "joiner.int8.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/resolve/main/joiner.int8.onnx")!,
            minimumBytes: 500_000
        ),
        ModelFile(
            name: "tokens.txt",
            url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/resolve/main/tokens.txt")!,
            minimumBytes: 5_000
        )
    ]

    func refreshModelStatus() {
        let fm = FileManager.default
        isModelInstalled = Self.modelFiles.allSatisfy { item in
            let url = Self.modelDirectory.appendingPathComponent(item.name)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            return size >= item.minimumBytes
        }
        if isModelInstalled {
            modelStatus = "中文离线模型已就绪"
        } else if !isDownloadingModel {
            modelStatus = "尚未下载中文模型"
        }
    }

    func downloadModel() async {
        guard !isDownloadingModel, !isRecording, !isPreparing else { return }
        isDownloadingModel = true
        modelDownloadError = nil
        modelStatus = "正在准备下载中文模型…"
        do {
            _ = try await prepareLocalModel()
            await MainActor.run {
                self.isModelInstalled = true
                self.isDownloadingModel = false
                self.modelStatus = "中文离线模型已就绪"
                self.downloadProgress = 1
                self.downloadingFileName = ""
            }
        } catch {
            await MainActor.run {
                self.isDownloadingModel = false
                self.isModelInstalled = false
                self.modelStatus = "模型下载失败"
                self.downloadingFileName = ""
                self.modelDownloadError = error.localizedDescription
            }
        }
    }

    func start(onDenied: @escaping () -> Void) {
        guard !isRecording, !isPreparing, !isFinalizing else { return }
        isPreparing = true
        modelStatus = "正在检查本地中文模型…"

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isPreparing = false
                    self.modelStatus = "需要麦克风权限"
                    onDenied()
                }
                return
            }

            Task {
                do {
                    let paths = try await self.prepareLocalModel()
                    await MainActor.run {
                        self.beginCapture(modelPaths: paths)
                    }
                } catch {
                    await MainActor.run {
                        self.isPreparing = false
                        self.modelStatus = "模型准备失败"
                        NSLog("CustomChat ASR model error: %@", error.localizedDescription)
                        onDenied()
                    }
                }
            }
        }
    }

    private func prepareLocalModel() async throws -> [String: String] {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
        var paths: [String: String] = [:]

        for (index, item) in Self.modelFiles.enumerated() {
            let destination = Self.modelDirectory.appendingPathComponent(item.name)
            let existingSize = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0

            if existingSize >= item.minimumBytes {
                paths[item.name] = destination.path
                continue
            }

            await MainActor.run {
                self.modelStatus = "首次下载中文模型 · \(index + 1)/4"
            }

            await MainActor.run {
                self.downloadingFileName = item.name
                self.downloadProgress = 0
            }
            let temporaryURL = Self.modelDirectory.appendingPathComponent(".\(item.name).download")
            if fm.fileExists(atPath: temporaryURL.path) { try fm.removeItem(at: temporaryURL) }
            guard fm.createFile(atPath: temporaryURL.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: temporaryURL) else {
                throw NSError(domain: "CustomChatASR", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "无法创建模型文件：\(item.name)"
                ])
            }
            defer { try? output.close() }
            let (bytes, response) = try await URLSession.shared.bytes(from: item.url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw NSError(domain: "CustomChatASR", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "下载模型文件失败：\(item.name)"
                ])
            }
            let expectedBytes = max(response.expectedContentLength, Int64(item.minimumBytes))
            var receivedBytes: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                receivedBytes += 1
                if buffer.count >= 64 * 1024 {
                    try output.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    let progress = min(1, Double(receivedBytes) / Double(expectedBytes))
                    await MainActor.run {
                        self.downloadProgress = progress
                        self.modelStatus = "正在下载 \(item.name)"
                    }
                }
            }
            if !buffer.isEmpty { try output.write(contentsOf: buffer) }
            try output.synchronize()
            await MainActor.run { self.downloadProgress = 1 }

            let downloadedSize = (try? fm.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard downloadedSize >= item.minimumBytes else {
                try? fm.removeItem(at: temporaryURL)
                throw NSError(domain: "CustomChatASR", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "模型文件不完整：\(item.name)"
                ])
            }

            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporaryURL, to: destination)
            paths[item.name] = destination.path
        }

        return paths
    }

    private func beginCapture(modelPaths: [String: String]) {
        do {
            let encoder = modelPaths["encoder.int8.onnx"]!
            let decoder = modelPaths["decoder.onnx"]!
            let joiner = modelPaths["joiner.int8.onnx"]!
            let tokens = modelPaths["tokens.txt"]!

            // Build the sherpa-onnx recognizer away from the real-time audio callback.
            inferenceQueue.sync {
                var modelConfig = sherpaOnnxOnlineModelConfig(
                    tokens: tokens,
                    transducer: sherpaOnnxOnlineTransducerModelConfig(
                        encoder: encoder,
                        decoder: decoder,
                        joiner: joiner
                    ),
                    numThreads: 2,
                    modelType: "zipformer2"
                )
                var config = sherpaOnnxOnlineRecognizerConfig(
                    featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                    modelConfig: modelConfig,
                    enableEndpoint: true,
                    rule1MinTrailingSilence: 2.0,
                    rule2MinTrailingSilence: 0.7,
                    rule3MinUtteranceLength: 20,
                    decodingMethod: "greedy_search",
                    maxActivePaths: 4
                )
                self.recognizer = SherpaOnnxRecognizer(config: &config)
                self.recognizer?.reset()
                self.finalizedSentences = []
                self.currentPartial = ""
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0,
                  let pcm16k = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                  ),
                  let audioConverter = AVAudioConverter(from: inputFormat, to: pcm16k) else {
                throw NSError(domain: "CustomChatASR", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "无法初始化麦克风音频格式"
                ])
            }

            converter = audioConverter
            outputFormat = pcm16k
            captured = []
            lastDuration = 0
            lastWaveform = []
            hasCapture = false
            transcript = ""
            smoothedLevel = 0.075
            samples = Array(repeating: 0.075, count: waveformSampleCount)

            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, let converter = self.converter, let outputFormat = self.outputFormat else { return }

                let ratio = outputFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 8
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

                var suppliedInput = false
                let inputBlock: AVAudioConverterInputBlock = { _, status in
                    if suppliedInput {
                        status.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    status.pointee = .haveData
                    return buffer
                }

                var conversionError: NSError?
                let conversionStatus = converter.convert(
                    to: converted,
                    error: &conversionError,
                    withInputFrom: inputBlock
                )
                guard conversionStatus != .error,
                      let channel = converted.floatChannelData?[0],
                      converted.frameLength > 0 else { return }

                let frameCount = Int(converted.frameLength)
                let audio = Array(UnsafeBufferPointer(start: channel, count: frameCount))
                var sum: Float = 0
                var peak: Float = 0
                for sample in audio {
                    let value = abs(sample)
                    sum += sample * sample
                    peak = max(peak, value)
                }

                let rms = Double(sqrt(sum / Float(frameCount)))
                let amplified = pow(max(rms, Double(peak) * 0.20), 0.62) * 3.6
                let level = min(1, max(0.075, amplified))

                // Drive the live waveform directly from the audio tap, not from
                // the slower ASR decoder queue. 1024-frame buffers keep it responsive.
                DispatchQueue.main.async {
                    guard self.isRecording || self.isPreparing else { return }
                    let smoothing = level > self.smoothedLevel ? 0.78 : 0.38
                    self.smoothedLevel += (level - self.smoothedLevel) * smoothing
                    self.samples.append(self.smoothedLevel)
                    if self.samples.count > waveformSampleCount {
                        self.samples.removeFirst(self.samples.count - waveformSampleCount)
                    }
                    self.captured.append(self.smoothedLevel)
                }

                self.inferenceQueue.async {
                    guard let recognizer = self.recognizer else { return }
                    recognizer.acceptWaveform(samples: audio, sampleRate: 16_000)
                    while recognizer.isReady() {
                        recognizer.decode()
                    }

                    let text = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if recognizer.isEndpoint() {
                        if !text.isEmpty { self.finalizedSentences.append(text) }
                        self.currentPartial = ""
                        recognizer.reset()
                    } else {
                        self.currentPartial = text
                    }

                    let currentText = (self.finalizedSentences + [self.currentPartial])
                        .filter { !$0.isEmpty }
                        .joined()
                    DispatchQueue.main.async {
                        guard self.isRecording else { return }
                        self.transcript = currentText
                    }
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            startedAt = Date()
            isPreparing = false
            isRecording = true
            modelStatus = "中文离线模型已就绪"
        } catch {
            cleanup()
            modelStatus = "语音引擎启动失败"
            NSLog("CustomChat ASR start error: %@", error.localizedDescription)
            onFailure?()
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard isRecording else { return false }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isRecording = false
        isFinalizing = true

        let duration = max(1, Date().timeIntervalSince(startedAt ?? Date()))
        let source = captured.isEmpty ? Array(repeating: 0.075, count: waveformSampleCount) : captured
        let waveform = (0..<waveformSampleCount).map { index -> Double in
            let lower = index * source.count / waveformSampleCount
            let upper = max(lower + 1, (index + 1) * source.count / waveformSampleCount)
            return source[lower..<min(upper, source.count)].max() ?? 0.075
        }

        // This sync runs after queued audio chunks so the final partial sentence is retained.
        let finalText = inferenceQueue.sync { () -> String in
            let partial = recognizer?.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !partial.isEmpty && partial != currentPartial {
                currentPartial = partial
            }
            return (finalizedSentences + [currentPartial])
                .filter { !$0.isEmpty }
                .joined()
        }

        startedAt = nil
        lastDuration = duration
        lastWaveform = waveform
        transcript = finalText
        isFinalizing = false
        hasCapture = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }

    func consumeCapture() -> (duration: Double, waveform: [Double], transcript: String)? {
        guard hasCapture, !isFinalizing else { return nil }
        let value = (lastDuration, lastWaveform, transcript)
        hasCapture = false
        lastDuration = 0
        lastWaveform = []
        return value
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isPreparing = false
        isRecording = false
        isFinalizing = false
    }
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var text: String
    var role: ChatRole
    var time: Date
    var imageData: Data?
    var kind: ChatMessageKind
    var amount: Double?
    var note: String
    var isWithdrawn: Bool
    var isReceived: Bool
    var senderName: String?
    var senderAvatarData: Data?
    var senderAccountID: UUID?
    var voiceDuration: Double
    var waveform: [Double]
    var voiceTranscript: String?

    init(text: String = "", role: ChatRole, time: Date = .now, imageData: Data? = nil,
         kind: ChatMessageKind? = nil, amount: Double? = nil, note: String = "", isWithdrawn: Bool = false, isReceived: Bool = false, senderName: String? = nil, senderAvatarData: Data? = nil, senderAccountID: UUID? = nil, voiceDuration: Double = 0, waveform: [Double] = [], voiceTranscript: String? = nil) {
        id = UUID(); self.text = text; self.role = role; self.time = time; self.imageData = imageData
        self.kind = kind ?? (imageData == nil ? .text : .image)
        self.amount = amount; self.note = note; self.isWithdrawn = isWithdrawn; self.isReceived = isReceived; self.senderName = senderName; self.senderAvatarData = senderAvatarData; self.senderAccountID = senderAccountID
        self.voiceDuration = voiceDuration; self.waveform = waveform; self.voiceTranscript = voiceTranscript
    }

    enum CodingKeys: String, CodingKey { case id, text, role, time, imageData, kind, amount, note, isWithdrawn, isReceived, senderName, senderAvatarData, senderAccountID, voiceDuration, waveform, voiceTranscript }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        role = try values.decode(ChatRole.self, forKey: .role)
        time = try values.decode(Date.self, forKey: .time)
        imageData = try values.decodeIfPresent(Data.self, forKey: .imageData)
        kind = try values.decodeIfPresent(ChatMessageKind.self, forKey: .kind) ?? (imageData == nil ? .text : .image)
        amount = try values.decodeIfPresent(Double.self, forKey: .amount)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        isWithdrawn = try values.decodeIfPresent(Bool.self, forKey: .isWithdrawn) ?? false
        isReceived = try values.decodeIfPresent(Bool.self, forKey: .isReceived) ?? false
        senderName = try values.decodeIfPresent(String.self, forKey: .senderName)
        senderAvatarData = try values.decodeIfPresent(Data.self, forKey: .senderAvatarData)
        senderAccountID = try values.decodeIfPresent(UUID.self, forKey: .senderAccountID)
        voiceDuration = try values.decodeIfPresent(Double.self, forKey: .voiceDuration) ?? 0
        waveform = try values.decodeIfPresent([Double].self, forKey: .waveform) ?? []
        voiceTranscript = try values.decodeIfPresent(String.self, forKey: .voiceTranscript)
    }
}

struct PersonaAppearance: Codable {
    var appBackgroundHex: UInt = 0xF5F7FB
    var chatBackgroundHex: UInt = 0xF5F7FB
    var outgoingBubbleHex: UInt = 0xD8EAFF
    var incomingBubbleHex: UInt = 0xFFFFFF
    var textHex: UInt = 0x202A3A
    var accentHex: UInt = 0x8FC7FF
    var backgroundOption: String = "雾蓝白"
    var themeOption: String = "浅蓝"
    var fontOption: String = "标准"
    var soundOption: String = "轻柔"
    var chatBackgroundImageData: Data?
}

struct ChatIdentity: Codable {
    var me = "我"
    var other = "对方"
    var meAvatarData: Data?
    var otherAvatarData: Data?
    var appearance: PersonaAppearance?
}

struct CallRecord: Identifiable, Codable {
    var id: UUID
    var isVideo: Bool
    var date: Date
    var duration: Int

    init(isVideo: Bool, duration: Int) {
        id = UUID()
        self.isVideo = isVideo
        date = .now
        self.duration = duration
    }
}

struct MomentComment: Identifiable, Codable {
    var id: UUID
    var author: String
    var text: String
    var date: Date
    var replyToAuthor: String?
    var mediaData: Data?
    var mediaType: String?

    init(author: String, text: String, replyToAuthor: String? = nil, mediaData: Data? = nil, mediaType: String? = nil) {
        id = UUID()
        self.author = author
        self.text = text
        self.date = .now
        self.replyToAuthor = replyToAuthor
        self.mediaData = mediaData
        self.mediaType = mediaType
    }
}

struct MomentPost: Identifiable, Codable {
    var id: UUID
    var text: String
    var date: Date
    var mediaData: Data?
    var mediaType: String?
    var isLiked: Bool?
    var comments: [MomentComment]?
    var shareCount: Int?

    init(text: String, date: Date = .now, mediaData: Data? = nil, mediaType: String? = nil) {
        id = UUID()
        self.text = text
        self.date = date
        self.mediaData = mediaData
        self.mediaType = mediaType
        isLiked = false
        comments = []
        shareCount = 0
    }
}

struct ChatContact: Identifiable, Codable {
    var id: UUID
    var name: String
    var avatarData: Data?
    var bio: String
    var notes: String
    var moments: [MomentPost]
    var isGroup: Bool?
    var memberIDs: [UUID]?
    var walletBalance: Double?
    var appearance: PersonaAppearance?
    var accountNumber: String?
    var ownerAccountID: UUID?

    init(id: UUID = UUID(), name: String, avatarData: Data? = nil,
         bio: String = "分享生活，记录日常。", notes: String = "", moments: [MomentPost] = [], isGroup: Bool = false, memberIDs: [UUID] = [], walletBalance: Double? = 1000, appearance: PersonaAppearance? = PersonaAppearance(), accountNumber: String? = nil, ownerAccountID: UUID? = nil) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.bio = bio
        self.notes = notes
        self.moments = moments
        self.isGroup = isGroup
        self.memberIDs = memberIDs
        self.walletBalance = walletBalance
        self.appearance = appearance
        self.accountNumber = accountNumber
        self.ownerAccountID = ownerAccountID
    }
}

@MainActor
private final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet { persistCurrentThread() }
    }
    @Published var activeRole: ChatRole = .me
    @Published var activeGroupSenderID: UUID?
    @Published var identity = ChatIdentity() { didSet { persistIdentity() } }
    @Published var calls: [CallRecord] = [] { didSet { saveCalls() } }
    @Published var contacts: [ChatContact] = [] { didSet { persistContacts() } }
    @Published var selectedContactID: UUID?
    @Published var activePersonaID: UUID? {
        didSet { UserDefaults.standard.set(activePersonaID?.uuidString, forKey: "customchat.activePersona.v1") }
    }
    @Published private var friendIDsByAccount: [String: Set<String>] = [:] { didSet { persistFriendships() } }
    @Published private var hiddenChatIDsByAccount: [String: Set<String>] = [:] { didSet { persistHiddenChats() } }
    @Published var myMoments: [MomentPost] = [] { didSet { persistMyMoments() } }
    @Published var walletBalance: Double = 1000 {
        didSet { UserDefaults.standard.set(walletBalance, forKey: walletKey) }
    }
    private let messagesKey = "customchat.messages.v1"
    private let threadsKey = "customchat.threads.v1"
    private let threadsBackupKey = "customchat.threads.preSharedBackup.v1"
    private let identityKey = "customchat.identity.v1"
    private let callsKey = "customchat.calls.v1"
    private let contactsKey = "customchat.contacts.v1"
    private let friendshipsKey = "customchat.friendships.v1"
    private let hiddenChatsKey = "customchat.hiddenChats.v1"
    private let callsByAccountKey = "customchat.calls.byAccount.v1"
    private let myMomentsKey = "customchat.myMoments.v1"
    private let walletKey = "customchat.wallet.balance.v1"
    private let otherWalletKey = "customchat.wallet.other.balance.v1"
    private let mainAccountIDKey = "customchat.mainAccount.id.v1"
    private let mainAccountNumberKey = "customchat.mainAccount.number.v1"
    private(set) var mainAccountID: UUID = UUID()
    private(set) var mainAccountNumber: String = ""
    private var callsByAccount: [String: [CallRecord]] = [:]
    private var threadMessages: [String: [ChatMessage]] = [:]
    private var isSwitchingThread = false

    init() {
        if let fileURL = Self.identityFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = value
            UserDefaults.standard.set(data, forKey: identityKey)
        } else if let data = UserDefaults.standard.data(forKey: identityKey),
                  let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = value
        }

        let defaults = UserDefaults.standard
        if let storedID = defaults.string(forKey: mainAccountIDKey), let value = UUID(uuidString: storedID) {
            mainAccountID = value
        } else {
            mainAccountID = UUID()
            defaults.set(mainAccountID.uuidString, forKey: mainAccountIDKey)
        }
        mainAccountNumber = defaults.string(forKey: mainAccountNumberKey) ?? String(Int.random(in: 10_000_000...99_999_999))

        let legacyOtherBalance = defaults.object(forKey: otherWalletKey) as? Double
        if let data = defaults.data(forKey: contactsKey),
           let value = try? JSONDecoder().decode([ChatContact].self, from: data),
           !value.isEmpty {
            var restoredContacts = value
            if let firstUnmigrated = restoredContacts.firstIndex(where: { $0.walletBalance == nil }),
               let legacyOtherBalance {
                restoredContacts[firstUnmigrated].walletBalance = max(0, legacyOtherBalance)
            }
            for index in restoredContacts.indices where restoredContacts[index].walletBalance == nil {
                restoredContacts[index].walletBalance = 1000
            }
            contacts = restoredContacts
        } else {
            contacts = [ChatContact(name: identity.other, avatarData: identity.otherAvatarData, walletBalance: max(0, legacyOtherBalance ?? 1000))]
        }

        if let storedPersona = defaults.string(forKey: "customchat.activePersona.v1"),
           let personaID = UUID(uuidString: storedPersona),
           contacts.contains(where: { $0.id == personaID && $0.isGroup != true }) {
            activePersonaID = personaID
        }

        var normalizedContacts = contacts
        var usedNumbers = Set(normalizedContacts.compactMap { $0.accountNumber })
        if usedNumbers.contains(mainAccountNumber) {
            mainAccountNumber = Self.generateAccountNumber(avoiding: usedNumbers)
        }
        for index in normalizedContacts.indices {
            if normalizedContacts[index].isGroup == true {
                if normalizedContacts[index].ownerAccountID == nil {
                    normalizedContacts[index].ownerAccountID = mainAccountID
                }
            } else if normalizedContacts[index].accountNumber == nil {
                let number = Self.generateAccountNumber(avoiding: usedNumbers.union([mainAccountNumber]))
                normalizedContacts[index].accountNumber = number
                usedNumbers.insert(number)
            }
        }
        contacts = normalizedContacts
        defaults.set(mainAccountNumber, forKey: mainAccountNumberKey)

        if let data = defaults.data(forKey: friendshipsKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            friendIDsByAccount = saved.mapValues { Set($0) }
        } else {
            // Migrate the old global list to the original account only.
            // Each virtual account starts with the original account, not every other contact.
            var migrated: [String: Set<String>] = [:]
            let people = contacts.filter { $0.isGroup != true }
            migrated[mainAccountID.uuidString] = Set(people.map { $0.id.uuidString })
            for person in people {
                migrated[person.id.uuidString, default: []].insert(mainAccountID.uuidString)
            }
            friendIDsByAccount = migrated
        }
        if let data = defaults.data(forKey: hiddenChatsKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            hiddenChatIDsByAccount = saved.mapValues { Set($0) }
        }
        selectedContactID = friendContacts.first?.id

        if let data = UserDefaults.standard.data(forKey: threadsKey),
           let value = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data) {
            threadMessages = value
        }
        // Import the original single-thread store even when a newer thread dictionary
        // already exists. Older releases could have written messagesKey independently.
        if let legacyData = UserDefaults.standard.data(forKey: messagesKey),
           let legacyMessages = try? JSONDecoder().decode([ChatMessage].self, from: legacyData),
           let firstContactID = contacts.first?.id {
            let legacyKey = firstContactID.uuidString
            if threadMessages[legacyKey] == nil, !legacyMessages.isEmpty {
                threadMessages[legacyKey] = legacyMessages
            }
        }

        isSwitchingThread = true
        messages = selectedContactID.map { loadThread(for: $0, personaID: activePersonaID) } ?? []
        isSwitchingThread = false

        if let data = defaults.data(forKey: callsByAccountKey),
           let value = try? JSONDecoder().decode([String: [CallRecord]].self, from: data) {
            callsByAccount = value
            calls = callsByAccount[activeAccountID.uuidString] ?? []
        } else if let data = defaults.data(forKey: callsKey),
                  let value = try? JSONDecoder().decode([CallRecord].self, from: data) {
            callsByAccount[mainAccountID.uuidString] = value
            calls = activePersonaID == nil ? value : []
        }
        if let data = UserDefaults.standard.data(forKey: myMomentsKey),
           let value = try? JSONDecoder().decode([MomentPost].self, from: data) {
            myMoments = value
        }
        if let storedBalance = UserDefaults.standard.object(forKey: walletKey) as? Double {
            walletBalance = max(0, storedBalance)
        }
        persistContacts()
        persistFriendships()
        persistHiddenChats()
        saveCalls()
        persistCurrentThread()
    }

    var activeAccountID: UUID { activePersonaID ?? mainAccountID }

    var mainIdentityContact: ChatContact {
        ChatContact(id: mainAccountID,
                    name: identity.me.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我" : identity.me,
                    avatarData: identity.meAvatarData,
                    bio: "这是我的主账号。",
                    accountNumber: mainAccountNumber)
    }

    var activeAccountContact: ChatContact {
        activePersonaContact ?? mainIdentityContact
    }

    var activeAccountNumber: String {
        activeAccountContact.accountNumber ?? mainAccountNumber
    }

    var accountDirectory: [ChatContact] {
        [mainIdentityContact] + contacts.filter { $0.isGroup != true }
    }

    var friendAccountIDs: Set<UUID> {
        Set((friendIDsByAccount[activeAccountID.uuidString] ?? []).compactMap { UUID(uuidString: $0) })
    }

    var friendContacts: [ChatContact] {
        let ids = friendIDsByAccount[activeAccountID.uuidString] ?? []
        var result = contacts.filter { contact in
            if contact.isGroup == true {
                let participants = Set((contact.memberIDs ?? []).map(\.uuidString) + [(contact.ownerAccountID ?? UUID()).uuidString])
                return participants.contains(activeAccountID.uuidString)
            }
            return ids.contains(contact.id.uuidString)
        }
        if ids.contains(mainAccountID.uuidString) { result.append(mainIdentityContact) }
        return result
    }

    var visibleChatContacts: [ChatContact] {
        let hidden = hiddenChatIDsByAccount[activeAccountID.uuidString] ?? []
        return friendContacts.filter { !hidden.contains($0.id.uuidString) }
    }

    private func accountContact(with id: UUID) -> ChatContact? {
        if id == mainAccountID { return mainIdentityContact }
        return contacts.first(where: { $0.id == id && $0.isGroup != true })
    }

    var currentContact: ChatContact? {
        guard let selectedContactID else { return nil }
        if let group = contacts.first(where: { $0.id == selectedContactID && $0.isGroup == true }) {
            let participants = Set((group.memberIDs ?? []).map(\.uuidString) + [(group.ownerAccountID ?? UUID()).uuidString])
            if participants.contains(activeAccountID.uuidString) { return group }
        }
        guard friendAccountIDs.contains(selectedContactID),
              let contact = accountContact(with: selectedContactID) else { return nil }
        return contact
    }

    var activePersonaContact: ChatContact? {
        guard let activePersonaID else { return nil }
        return contacts.first(where: { $0.id == activePersonaID && $0.isGroup != true })
    }

    var activePersonaName: String {
        if let activePersonaContact { return activePersonaContact.name }
        let value = identity.me.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "我" : value
    }

    var activePersonaAvatar: Data? {
        activePersonaContact?.avatarData ?? (activePersonaID == nil ? identity.meAvatarData : nil)
    }

    var activePersonaAppearance: PersonaAppearance {
        activePersonaContact?.appearance ?? identity.appearance ?? PersonaAppearance()
    }

    var activePersonaMoments: [MomentPost] {
        activePersonaContact?.moments ?? myMoments
    }

    func switchPersona(_ id: UUID?) {
        guard id == nil || contacts.contains(where: { $0.id == id && $0.isGroup != true }) else { return }
        guard activePersonaID != id else { return }
        persistCurrentThread()
        saveCalls()
        withAnimation(ChatMotion.layout) {
            activePersonaID = id
            selectedContactID = friendContacts.first?.id
            activeRole = .me
            activeGroupSenderID = nil
            isSwitchingThread = true
            messages = selectedContactID.map { loadThread(for: $0, personaID: id) } ?? []
            calls = callsByAccount[id?.uuidString ?? mainAccountID.uuidString] ?? []
            isSwitchingThread = false
        }
    }

    private func threadKey(for contactID: UUID, personaID: UUID? = nil) -> String {
        let ownerID = personaID ?? mainAccountID
        if contacts.contains(where: { $0.id == contactID && $0.isGroup == true }) {
            return "group::\(contactID.uuidString)"
        }
        let ownerFriends = friendIDsByAccount[ownerID.uuidString] ?? []
        let contactFriends = friendIDsByAccount[contactID.uuidString] ?? []
        if ownerFriends.contains(contactID.uuidString), contactFriends.contains(ownerID.uuidString) {
            let pair = [ownerID.uuidString, contactID.uuidString].sorted()
            return "pair::\(pair[0])::\(pair[1])"
        }
        return "\(personaID?.uuidString ?? "self")::\(contactID.uuidString)"
    }

    private func loadThread(for contactID: UUID, personaID: UUID?) -> [ChatMessage] {
        let ownerID = personaID ?? mainAccountID
        let key = threadKey(for: contactID, personaID: personaID)
        let isGroupThread = contacts.contains(where: { $0.id == contactID && $0.isGroup == true })
        let group = isGroupThread ? contacts.first(where: { $0.id == contactID && $0.isGroup == true }) : nil

        // Keep an untouched device-local copy before migrating any legacy histories.
        if UserDefaults.standard.data(forKey: threadsBackupKey) == nil,
           !threadMessages.isEmpty,
           let backup = try? JSONEncoder().encode(threadMessages) {
            UserDefaults.standard.set(backup, forKey: threadsBackupKey)
        }

        // Old releases stored a separate thread for each account. Prefer the
        // untouched snapshot for legacy keys, then fill any keys missing from it
        // with the current store. The shared key is handled separately below.
        var legacyThreads: [String: [ChatMessage]] = [:]
        if let backupData = UserDefaults.standard.data(forKey: threadsBackupKey),
           let backupThreads = try? JSONDecoder().decode([String: [ChatMessage]].self, from: backupData) {
            legacyThreads = backupThreads
        }
        for (legacyKey, history) in threadMessages where legacyThreads[legacyKey] == nil {
            legacyThreads[legacyKey] = history
        }

        var sources: [([ChatMessage], UUID, UUID)] = []
        if isGroupThread {
            let suffix = "::\(contactID.uuidString)"
            for (legacyKey, history) in legacyThreads
            where legacyKey != key && legacyKey.hasSuffix(suffix) {
                let ownerPart = String(legacyKey.dropLast(suffix.count))
                let sourceOwnerID = ownerPart == "self"
                    ? mainAccountID
                    : (UUID(uuidString: ownerPart) ?? group?.ownerAccountID ?? ownerID)
                sources.append((history, sourceOwnerID, contactID))
            }
        } else {
            let ownLegacyKey = "\(personaID?.uuidString ?? "self")::\(contactID.uuidString)"
            if ownLegacyKey != key, let ownHistory = legacyThreads[ownLegacyKey] {
                sources.append((ownHistory, ownerID, contactID))
            }
            // Some pre-account builds stored the first conversation directly under
            // the contact UUID. Import it too instead of treating it as a new chat.
            if personaID == nil, contactID.uuidString != key,
               let bareHistory = legacyThreads[contactID.uuidString] {
                sources.append((bareHistory, ownerID, contactID))
            }

            let ownerFriends = friendIDsByAccount[ownerID.uuidString] ?? []
            let contactFriends = friendIDsByAccount[contactID.uuidString] ?? []
            let isMutualFriend = ownerFriends.contains(contactID.uuidString)
                && contactFriends.contains(ownerID.uuidString)
            if isMutualFriend {
                let reverseLegacyKey = "\(contactID.uuidString)::\(ownerID.uuidString)"
                if reverseLegacyKey != key, let reverseHistory = legacyThreads[reverseLegacyKey] {
                    sources.append((reverseHistory, contactID, ownerID))
                }
            }
        }

        // Rebuild sender attribution from the original perspective of each legacy
        // thread. In direct chats, .me belongs to the source owner and .other to
        // the source contact. Build #139/#140 accidentally assigned both roles to
        // sourceOwnerID, which made the whole history appear to come from one side.
        var legacyMessages: [UUID: ChatMessage] = [:]
        var recoveredSenderIDs: [UUID: UUID] = [:]
        var legacyOwnerIDsForOtherMessages: [UUID: Set<UUID>] = [:]
        let groupMembersList = group.map { groupMembers($0) } ?? []
        let groupMemberIDs = Set(groupMembersList.map(\.id))

        for (history, sourceOwnerID, sourceContactID) in sources {
            for original in history {
                var message = original
                let resolvedSenderID: UUID?
                if isGroupThread {
                    if let existingID = message.senderAccountID, groupMemberIDs.contains(existingID) {
                        resolvedSenderID = existingID
                    } else if let senderName = message.senderName,
                              let matched = groupMembersList.first(where: { $0.name == senderName }) {
                        resolvedSenderID = matched.id
                    } else if message.role == .me {
                        resolvedSenderID = sourceOwnerID
                    } else {
                        resolvedSenderID = groupMembersList.first(where: { $0.id != sourceOwnerID })?.id
                    }
                } else {
                    resolvedSenderID = message.senderAccountID
                        ?? (message.role == .me ? sourceOwnerID : sourceContactID)
                    if message.role == .other {
                        legacyOwnerIDsForOtherMessages[message.id, default: []].insert(sourceOwnerID)
                    }
                }

                if let resolvedSenderID {
                    if recoveredSenderIDs[message.id] == nil {
                        recoveredSenderIDs[message.id] = resolvedSenderID
                    }
                    message.senderAccountID = resolvedSenderID
                }
                if legacyMessages[message.id] == nil {
                    legacyMessages[message.id] = message
                }
            }
        }

        // Start from recovered legacy messages, then overlay the latest shared
        // payload so edits, withdrawals, payment state, images and voice data win.
        var merged = legacyMessages
        for original in threadMessages[key] ?? [] {
            var message = original
            if let recoveredSenderID = recoveredSenderIDs[message.id] {
                let knownBadOwners = legacyOwnerIDsForOtherMessages[message.id] ?? []
                if message.senderAccountID == nil || knownBadOwners.contains(message.senderAccountID!) {
                    message.senderAccountID = recoveredSenderID
                }
            } else if message.senderAccountID == nil {
                if isGroupThread, let senderName = message.senderName,
                   let matched = groupMembersList.first(where: { $0.name == senderName }) {
                    message.senderAccountID = matched.id
                } else {
                    message.senderAccountID = message.role == .me ? ownerID : contactID
                }
            }
            merged[message.id] = message
        }

        var normalized = Array(merged.values).sorted {
            if $0.time == $1.time { return $0.id.uuidString < $1.id.uuidString }
            return $0.time < $1.time
        }
        for index in normalized.indices {
            if normalized[index].senderAccountID == nil {
                normalized[index].senderAccountID = normalized[index].role == .me ? ownerID : contactID
            }
            normalized[index].role = normalized[index].senderAccountID == ownerID ? .me : .other
        }

        threadMessages[key] = normalized
        persistAllThreads()
        return normalized
    }

    private func messageSenderAccountID(for role: ChatRole) -> UUID? {
        if currentContact?.isGroup == true { return activeGroupSenderID ?? activeAccountID }
        return role == .me ? activeAccountID : selectedContactID
    }

    func isMessageFromActiveSender(_ message: ChatMessage) -> Bool {
        if currentContact?.isGroup == true {
            return message.senderAccountID == (activeGroupSenderID ?? activeAccountID)
        }
        return message.role == activeRole
    }

    func isFriend(_ accountID: UUID) -> Bool {
        friendIDsByAccount[activeAccountID.uuidString]?.contains(accountID.uuidString) == true
    }

    func updateActivePersonaAppearance(_ appearance: PersonaAppearance) {
        if let id = activePersonaID,
           let index = contacts.firstIndex(where: { $0.id == id }) {
            contacts[index].appearance = appearance
        } else {
            var updated = identity
            updated.appearance = appearance
            identity = updated
        }
    }

    func updateActivePersonaName(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = activePersonaID,
           let index = contacts.firstIndex(where: { $0.id == id }) {
            contacts[index].name = cleaned
        } else {
            var updated = identity
            updated.me = cleaned
            identity = updated
        }
    }

    func updateActivePersonaAvatar(_ data: Data) {
        if let id = activePersonaID,
           let index = contacts.firstIndex(where: { $0.id == id }) {
            contacts[index].avatarData = data
        } else {
            var updated = identity
            updated.meAvatarData = data
            identity = updated
        }
    }

    func activePersonaWalletBalance() -> Double {
        activePersonaContact?.walletBalance ?? walletBalance
    }

    func setActivePersonaWalletBalance(_ value: Double) {
        if let id = activePersonaID {
            updateWalletBalance(value, contactID: id)
        } else {
            walletBalance = max(0, value)
        }
    }

    func updateActivePersonaMoments(_ moments: [MomentPost]) {
        if let id = activePersonaID,
           let index = contacts.firstIndex(where: { $0.id == id }) {
            contacts[index].moments = moments
        } else {
            myMoments = moments
        }
    }


    // In a one-to-one chat the selected friend owns the recipient wallet.
    // In a group chat the selected simulated sender owns that member's wallet.
    var walletContactForCurrentChat: ChatContact? {
        guard let contact = currentContact else { return nil }
        if contact.isGroup == true {
            let members = groupMembers(contact)
            return activeGroupSenderID.flatMap { id in members.first(where: { $0.id == id }) } ?? members.first
        }
        return contact
    }

    func walletBalance(for contact: ChatContact?) -> Double {
        guard let contact else { return 1000 }
        if contact.id == mainAccountID { return walletBalance }
        return contact.walletBalance ?? 1000
    }

    func updateWalletBalance(_ value: Double, contactID: UUID?) {
        guard let contactID else { return }
        if contactID == mainAccountID {
            walletBalance = max(0, value)
            return
        }
        guard let index = contacts.firstIndex(where: { $0.id == contactID }) else { return }
        contacts[index].walletBalance = max(0, value)
    }

    func selectContact(_ id: UUID) {
        guard friendContacts.contains(where: { $0.id == id }), selectedContactID != id else { return }
        persistCurrentThread()
        selectedContactID = id
        isSwitchingThread = true
        messages = loadThread(for: id, personaID: activePersonaID)
        isSwitchingThread = false
    }

    func hideChat(for contactID: UUID) {
        var hidden = hiddenChatIDsByAccount[activeAccountID.uuidString] ?? []
        hidden.insert(contactID.uuidString)
        hiddenChatIDsByAccount[activeAccountID.uuidString] = hidden
    }

    func clearChatHistory(for contactID: UUID) {
        threadMessages.removeValue(forKey: threadKey(for: contactID, personaID: activePersonaID))
        if activePersonaID == nil { threadMessages.removeValue(forKey: contactID.uuidString) }
        if selectedContactID == contactID {
            isSwitchingThread = true
            messages = []
            isSwitchingThread = false
        }
        persistAllThreads()
    }

    private func revealCurrentChat() {
        guard let selectedContactID else { return }
        var hidden = hiddenChatIDsByAccount[activeAccountID.uuidString] ?? []
        guard hidden.remove(selectedContactID.uuidString) != nil else { return }
        hiddenChatIDsByAccount[activeAccountID.uuidString] = hidden
    }

    @discardableResult
    func addFriend(accountID: UUID) -> Bool {
        guard accountID != activeAccountID, accountContact(with: accountID) != nil else { return false }
        let activeKey = activeAccountID.uuidString
        let targetKey = accountID.uuidString
        var updated = friendIDsByAccount
        var activeFriends = updated[activeKey] ?? []
        let wasAlreadyAdded = activeFriends.contains(targetKey)
        activeFriends.insert(targetKey)
        updated[activeKey] = activeFriends
        var targetFriends = updated[targetKey] ?? []
        let reciprocalWasMissing = !targetFriends.contains(activeKey)
        targetFriends.insert(activeKey)
        updated[targetKey] = targetFriends
        if !wasAlreadyAdded || reciprocalWasMissing {
            friendIDsByAccount = updated
        }
        return !wasAlreadyAdded
    }

    @discardableResult
    func addContact(name: String, bio: String, avatarData: Data?) -> UUID {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = ChatContact(
            name: cleanedName.isEmpty ? "新好友" : cleanedName,
            avatarData: avatarData,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "分享生活，记录日常。" : bio,
            accountNumber: Self.generateAccountNumber(avoiding: Set(contacts.compactMap { $0.accountNumber }).union([mainAccountNumber]))
        )
        contacts.append(contact)
        _ = addFriend(accountID: contact.id)
        selectContact(contact.id)
        return contact.id
    }

    func addGroup(name: String, memberIDs: [UUID]) -> UUID {
        let members = friendContacts.filter { memberIDs.contains($0.id) && $0.isGroup != true }
        let group = ChatContact(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "群聊" : name,
            bio: "\(members.count) 位好友的群聊",
            isGroup: true,
            memberIDs: members.map(\.id),
            ownerAccountID: activeAccountID
        )
        contacts.insert(group, at: 0)
        selectContact(group.id)
        return group.id
    }

    func groupMembers(_ contact: ChatContact) -> [ChatContact] {
        var ids = contact.memberIDs ?? []
        if let ownerID = contact.ownerAccountID, !ids.contains(ownerID) { ids.insert(ownerID, at: 0) }
        return ids.compactMap { id in accountContact(with: id) }
    }

    func selectGroupSender(_ memberID: UUID?) {
        activeGroupSenderID = memberID
        activeRole = memberID == nil ? .me : .other
    }

    private var outgoingSenderName: String? {
        guard currentContact?.isGroup == true else { return nil }
        return accountContact(with: activeGroupSenderID ?? activeAccountID)?.name
    }

    private var outgoingSenderAvatar: Data? {
        guard currentContact?.isGroup == true else { return nil }
        return accountContact(with: activeGroupSenderID ?? activeAccountID)?.avatarData
    }

    func updateContact(_ updated: ChatContact) {
        if updated.id == mainAccountID {
            var changed = identity
            changed.me = updated.name
            changed.meAvatarData = updated.avatarData
            identity = changed
            return
        }
        guard let index = contacts.firstIndex(where: { $0.id == updated.id }) else { return }
        contacts[index] = updated
    }

    func removeFriend(_ contact: ChatContact) {
        guard contact.isGroup != true, contact.id != activeAccountID else { return }
        var ids = friendIDsByAccount[activeAccountID.uuidString] ?? []
        ids.remove(contact.id.uuidString)
        friendIDsByAccount[activeAccountID.uuidString] = ids
        // Intentionally retain all conversation data and attachments. Removing a
        // friend relationship must not erase a shared thread or affect other accounts.
        if selectedContactID == contact.id {
            persistCurrentThread()
        }
    }

    func deleteContact(_ contact: ChatContact) {
        if contact.isGroup == true {
            guard contact.ownerAccountID == activeAccountID else { return }
            contacts.removeAll { $0.id == contact.id }
        } else {
            removeFriend(contact)
        }
        if contact.isGroup == true {
            threadMessages.removeValue(forKey: threadKey(for: contact.id, personaID: activePersonaID))
            if selectedContactID == contact.id {
                selectedContactID = friendContacts.first?.id
                isSwitchingThread = true
                messages = selectedContactID.map { loadThread(for: $0, personaID: activePersonaID) } ?? []
                isSwitchingThread = false
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(threadMessages), forKey: threadsKey)
        }
    }

    func preview(for contact: ChatContact) -> String {
        let last = threadMessages[threadKey(for: contact.id, personaID: activePersonaID)]?.last ?? (activePersonaID == nil ? threadMessages[contact.id.uuidString]?.last : nil)
        guard let last else { return "开始你们的第一段对话" }
        if last.isWithdrawn { return "撤回了一条消息" }
        switch last.kind {
        case .image: return "发来了一张图片"
        case .redPacket: return "发送了一个红包"
        case .transfer: return "发送了一笔转账"
        case .paymentReceipt: return "已收款"
        case .call: return last.note
        case .voice: return "语音消息"
        case .text: return last.text
        }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        revealCurrentChat()
        messages.append(ChatMessage(text: value, role: activeRole, senderName: outgoingSenderName, senderAvatarData: outgoingSenderAvatar, senderAccountID: messageSenderAccountID(for: activeRole)))
    }

    func sendVoice(duration: Double, waveform: [Double], text: String = "", recognizedText: String = "") {
        revealCurrentChat()
        messages.append(ChatMessage(text: text, role: activeRole, kind: .voice, senderName: outgoingSenderName, senderAvatarData: outgoingSenderAvatar, senderAccountID: messageSenderAccountID(for: activeRole), voiceDuration: duration, waveform: waveform, voiceTranscript: recognizedText))
    }

    func sendImage(_ data: Data) {
        revealCurrentChat()
        messages.append(ChatMessage(role: activeRole, imageData: data, kind: .image, senderName: outgoingSenderName, senderAvatarData: outgoingSenderAvatar, senderAccountID: messageSenderAccountID(for: activeRole)))
    }

    @discardableResult
    func sendPayment(kind: ChatMessageKind, amount: Double, note: String) -> Bool {
        guard (kind == .redPacket || kind == .transfer), amount > 0 else { return false }
        if activeRole == .me {
            let balance = activePersonaWalletBalance()
            guard balance >= amount else { return false }
            setActivePersonaWalletBalance(balance - amount)
        } else {
            guard let walletContact = walletContactForCurrentChat else { return false }
            let balance = walletBalance(for: walletContact)
            guard balance >= amount else { return false }
            updateWalletBalance(balance - amount, contactID: walletContact.id)
        }
        revealCurrentChat()
        messages.append(ChatMessage(role: activeRole, kind: kind, amount: amount, note: note, senderName: outgoingSenderName, senderAvatarData: outgoingSenderAvatar, senderAccountID: messageSenderAccountID(for: activeRole)))
        return true
    }

    @discardableResult
    func receivePayment(_ message: ChatMessage) -> Bool {
        guard message.kind == .redPacket || message.kind == .transfer,
              message.role != activeRole,
              let amount = message.amount, amount.isFinite, amount > 0,
              let index = messages.firstIndex(where: { $0.id == message.id }),
              !messages[index].isReceived else { return false }

        // Match the old, working two-identity behavior: a payment sent by
        // "对方" credits my wallet; a payment sent by "我" credits this chat's friend.
        if message.role == .other {
            setActivePersonaWalletBalance(activePersonaWalletBalance() + amount)
        } else {
            let walletContact: ChatContact?
            if currentContact?.isGroup == true,
               let senderName = message.senderName {
                walletContact = currentContact.flatMap { group in
                    groupMembers(group).first(where: { $0.name == senderName })
                } ?? walletContactForCurrentChat
            } else {
                walletContact = walletContactForCurrentChat
            }
            guard let walletContact else { return false }
            updateWalletBalance(walletBalance(for: walletContact) + amount, contactID: walletContact.id)
        }

        var updatedMessages = messages
        updatedMessages[index].isReceived = true
        updatedMessages.append(
            ChatMessage(
                role: activeRole,
                kind: .paymentReceipt,
                amount: amount,
                note: message.kind == .transfer ? "转账" : "红包",
                senderName: outgoingSenderName,
                senderAvatarData: outgoingSenderAvatar,
                senderAccountID: messageSenderAccountID(for: activeRole)
            )
        )
        messages = updatedMessages
        return true
    }

    func addCallMessage(isVideo: Bool, duration: Int) {
        revealCurrentChat()
        let label = isVideo ? "视频通话" : "语音通话"
        let time = String(format: "%02d:%02d", duration / 60, duration % 60)
        messages.append(ChatMessage(role: .me, kind: .call, note: "\(label) · \(time)", senderAccountID: messageSenderAccountID(for: .me)))
    }

    func update(_ message: ChatMessage, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        // A voice message keeps its original waveform and duration. The text
        // field stores the transcript entered by the user.
        messages[index].text = message.kind == .voice
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : text
    }

    func changeRole(_ message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].role = messages[index].role == .me ? .other : .me
        messages[index].senderAccountID = messageSenderAccountID(for: messages[index].role)
    }

    func updateTime(_ message: ChatMessage, time: Date) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].time = time
        messages.sort { $0.time < $1.time }
    }

    func withdraw(_ message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isWithdrawn = true
        messages[index].text = ""
        messages[index].imageData = nil
        messages[index].amount = nil
        messages[index].note = ""
    }

    func delete(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }

    func addCall(isVideo: Bool, duration: Int) {
        calls.insert(CallRecord(isVideo: isVideo, duration: duration), at: 0)
        if calls.count > 100 { calls = Array(calls.prefix(100)) }
    }

    func updateAvatar(for role: ChatRole, data: Data) {
        if role == .me {
            updateActivePersonaAvatar(data)
        } else if var contact = currentContact {
            contact.avatarData = data
            updateContact(contact)
        }
    }

    func name(for role: ChatRole) -> String {
        let value = role == .me ? activePersonaName : (currentContact?.name ?? identity.other)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? role.rawValue : value
    }

    func avatar(for role: ChatRole) -> Data? {
        role == .me ? activePersonaAvatar : currentContact?.avatarData
    }

    private static func identityFileURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return supportDirectory
            .appendingPathComponent("CustomChat", isDirectory: true)
            .appendingPathComponent("identity-v1.json", isDirectory: false)
    }

    func persistIdentity() {
        guard let fileURL = Self.identityFileURL(),
              let data = try? JSONEncoder().encode(identity) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(data, forKey: identityKey)
        } catch {
            NSLog("CustomChat: failed to persist identity: %@", error.localizedDescription)
        }
    }

    private func persistContacts() {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: contactsKey)
    }

    private func persistFriendships() {
        let stored = friendIDsByAccount.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: friendshipsKey)
    }

    private func persistHiddenChats() {
        let stored = hiddenChatIDsByAccount.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: hiddenChatsKey)
    }

    private func persistAllThreads() {
        if let data = try? JSONEncoder().encode(threadMessages) {
            UserDefaults.standard.set(data, forKey: threadsKey)
        }
    }

    private func persistCurrentThread() {
        guard !isSwitchingThread, let selectedContactID else { return }
        var sharedMessages = messages
        for index in sharedMessages.indices where sharedMessages[index].senderAccountID == nil {
            sharedMessages[index].senderAccountID = messageSenderAccountID(for: sharedMessages[index].role)
        }
        threadMessages[threadKey(for: selectedContactID, personaID: activePersonaID)] = sharedMessages
        if let data = try? JSONEncoder().encode(threadMessages) {
            UserDefaults.standard.set(data, forKey: threadsKey)
        }
        // Keep the legacy key current for backwards compatibility with older builds.
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: messagesKey)
        }
    }

    private func saveCalls() {
        callsByAccount[activeAccountID.uuidString] = calls
        if let data = try? JSONEncoder().encode(callsByAccount) {
            UserDefaults.standard.set(data, forKey: callsByAccountKey)
        }
        if activePersonaID == nil, let legacyData = try? JSONEncoder().encode(calls) {
            UserDefaults.standard.set(legacyData, forKey: callsKey)
        }
    }

    private static func generateAccountNumber(avoiding used: Set<String>) -> String {
        var candidate = String(Int.random(in: 10_000_000...99_999_999))
        while used.contains(candidate) {
            candidate = String(Int.random(in: 10_000_000...99_999_999))
        }
        return candidate
    }

    private func persistMyMoments() {
        if let data = try? JSONEncoder().encode(myMoments) {
            UserDefaults.standard.set(data, forKey: myMomentsKey)
        }
    }

    private func save() {
        persistIdentity()
        persistContacts()
        persistCurrentThread()
        saveCalls()
        persistMyMoments()
    }
}

private enum AppTab: String, CaseIterable {
    case chats = "聊天"
    case contacts = "通讯录"
    case calls = "通话"
    case album = "朋友圈"
    case profile = "我的"

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .contacts: return "person.2"
        case .calls: return "phone"
        case .album: return "text.bubble"
        case .profile: return "person"
        }
    }
}

private enum Macaron {
    static let background = Color(hex: 0xF5F7FB)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x202A3A)
    static let secondary = Color(hex: 0x788397)
    static let blue = Color(hex: 0xD8EAFF)
    static let blueStrong = Color(hex: 0x8FC7FF)
    static let pink = Color(hex: 0xF9DDEB)
    static let mint = Color(hex: 0xDDF2E8)
    static let lavender = Color(hex: 0xE9E2FA)
    static let line = Color(hex: 0xE9EDF3)
}

@MainActor
private final class SimulatedCall: ObservableObject, Identifiable {
    let id = UUID()
    let isVideo: Bool

    @Published var isConnected = false
    @Published var isMuted = false
    @Published var isSpeakerOn = true
    @Published var isCameraOn = true
    @Published var connectedAt: Date?
    @Published var didEnd = false
    @Published var selectedMedia: PhotosPickerItem?
    @Published var selectedImage: UIImage?
    @Published var pendingCropImage: UIImage?
    @Published var selectedVideoURL: URL?
    @Published var videoPlayer: AVPlayer?
    @Published var showMediaImportError = false

    init(isVideo: Bool) {
        self.isVideo = isVideo
    }
}

private struct SelectedPhoto: Identifiable {
    let id = UUID()
    let data: Data
    let gallery: [Data]
    let index: Int

    init(data: Data, gallery: [Data]? = nil, index: Int = 0) {
        self.data = data
        self.gallery = gallery ?? [data]
        self.index = min(max(0, index), max(0, (gallery ?? [data]).count - 1))
    }
}

private enum ImageCropShape: Equatable {
    case circle
    case roundedSquare
}

private struct ImageCropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
    let shape: ImageCropShape
    let onCrop: (UIImage) -> Void
}

private struct ImageCropCanvas: UIViewRepresentable {
    let image: UIImage
    let onReady: (ImageCropScrollView) -> Void

    func makeUIView(context: Context) -> ImageCropScrollView {
        let view = ImageCropScrollView(image: image)
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    func updateUIView(_ uiView: ImageCropScrollView, context: Context) {}
}

private final class ImageCropScrollView: UIScrollView, UIScrollViewDelegate {
    private let sourceImage: UIImage
    private let imageView: UIImageView
    private var hasInitialZoom = false

    init(image: UIImage) {
        let maxDimension = max(image.size.width, image.size.height)
        let ratio = maxDimension > 0 ? min(1, 2200 / maxDimension) : 1
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        sourceImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        imageView = UIImageView()
        super.init(frame: .zero)
        imageView.image = sourceImage
        imageView.frame = CGRect(origin: .zero, size: size)
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        contentSize = size
        delegate = self
        backgroundColor = .clear
        clipsToBounds = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        bouncesZoom = false
        contentInsetAdjustmentBehavior = .never
        maximumZoomScale = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !hasInitialZoom, bounds.width > 0, bounds.height > 0 else { return }
        let fit = max(bounds.width / sourceImage.size.width, bounds.height / sourceImage.size.height)
        minimumZoomScale = fit
        maximumZoomScale = fit * 5
        setZoomScale(fit, animated: false)
        contentOffset = CGPoint(
            x: max(0, (sourceImage.size.width * fit - bounds.width) / 2),
            y: max(0, (sourceImage.size.height * fit - bounds.height) / 2)
        )
        hasInitialZoom = true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func croppedImage() -> UIImage? {
        let scale = max(zoomScale, 0.0001)
        let visible = CGRect(
            x: contentOffset.x / scale,
            y: contentOffset.y / scale,
            width: bounds.width / scale,
            height: bounds.height / scale
        )
        let crop = visible.intersection(CGRect(origin: .zero, size: sourceImage.size))
        guard !crop.isNull, crop.width > 1, crop.height > 1 else { return nil }
        return UIGraphicsImageRenderer(size: crop.size).image { _ in
            sourceImage.draw(in: CGRect(
                x: -crop.minX, y: -crop.minY,
                width: sourceImage.size.width, height: sourceImage.size.height
            ))
        }
    }
}

private struct ImageCropperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var canvas: ImageCropScrollView?
    let image: UIImage
    let shape: ImageCropShape
    let onCancel: () -> Void
    let onCrop: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(shape == .circle ? "移动和缩放图片，让头像位于圆形范围内。" : "移动和缩放图片，调整圆角正方形画面。")
                    .font(.system(size: 13))
                    .foregroundStyle(Macaron.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                GeometryReader { geometry in
                    let side = min(geometry.size.width - 28, geometry.size.height - 12, 340)
                    ImageCropCanvas(image: image) { canvas = $0 }
                        .frame(width: side, height: side)
                        .clipShape(shape == .circle
                                   ? AnyShape(Circle())
                                   : AnyShape(RoundedRectangle(cornerRadius: 38, style: .continuous)))
                        .overlay {
                            if shape == .circle {
                                Circle().stroke(.white, lineWidth: 2)
                            } else {
                                RoundedRectangle(cornerRadius: 38, style: .continuous)
                                    .stroke(.white, lineWidth: 2)
                            }
                        }
                        .shadow(color: .black.opacity(0.13), radius: 18, y: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Label("单指拖动 · 双指缩放", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.bottom, 18)
            }
            .background(Macaron.background)
            .navigationTitle("调整裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用图片") {
                        guard let result = canvas?.croppedImage() else { return }
                        onCrop(result)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(canvas == nil)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private func cropPreviewData(_ image: UIImage) -> Data? {
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return nil }
    let scale = min(1, 1600 / longest)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format)
        .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        .jpegData(compressionQuality: 0.84)
}

private struct PickedCallVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("customchat-call-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedCallVideo(url: destination)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .chats
    @State private var showConversation = false
    @State private var showMyProfileEditor = false
    @State private var showPersonaSwitcher = false
    @State private var isProfileSettingsExpanded = false
    @State private var walletTargetContactID: UUID?
    @State private var chatBackgroundImageSelection: PhotosPickerItem?
    @State private var contactPendingDeletion: ChatContact?
    @State private var chatHistoryPendingDeletion: ChatContact?
    @State private var showAccountManagement = false
    @State private var showAddContact = false
    @State private var showCreateGroup = false
    @StateObject private var voiceCapture = VoiceCaptureManager()
    @State private var isVoiceComposer = false
    @State private var showMicrophoneAlert = false
    @State private var showFriendProfile = false
    @State private var selectedGroupMember: ChatContact?
    @State private var showChatSettings = false
    @State private var showVirtualScanner = false
    @State private var showMyQRCode = false
    @FocusState private var messageFocused: Bool
    @State private var showBalanceEditor = false
    @State private var showInsufficientBalance = false
    @State private var walletBalanceDraft = ""
    @State private var editingWalletRole: ChatRole = .me
    @State private var editingWalletContactID: UUID?
    @State private var imageCropRequest: ImageCropRequest?
    @State private var showMyMomentEditor = false
    @State private var myMomentDraft = ""
    @State private var editingMyMomentID: UUID?
    @State private var searchText = ""
    @State private var draft = ""
    @State private var isComposerVisible = true
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showAddMenu = false
    @State private var showRedPacketInput = false
    @State private var showTransferInput = false
    @State private var paymentAmountDraft = ""
    @State private var paymentNoteDraft = ""
    @State private var timeEditingMessage: ChatMessage?
    @State private var editedMessageTime = Date()
    @State private var myAvatarSelection: PhotosPickerItem?
    @State private var otherAvatarSelection: PhotosPickerItem?
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var activeCall: SimulatedCall?
    @State private var isCallMinimized = false
    @State private var minimizedCallPosition: CGPoint?
    @State private var minimizedCallDragOrigin: CGPoint?
    @State private var isVoiceTextMode = false
    @State private var previewPhoto: SelectedPhoto?
    @State private var showClearConfirmation = false
    @State private var showAllMyMoments = false
    @State private var showBackgroundPicker = false
    @State private var showThemePicker = false
    @State private var showFontPicker = false
    @State private var showSoundPicker = false

    private var activeAppearance: PersonaAppearance { model.activePersonaAppearance }
    private var appBackgroundColor: Color { Color(hex: activeAppearance.appBackgroundHex) }
    private var accentColor: Color { Color(hex: activeAppearance.accentHex) }
    private var incomingBubbleColor: Color { Color(hex: activeAppearance.incomingBubbleHex) }
    private var messageTextColor: Color { Color(hex: activeAppearance.textHex) }

    private var backgroundOption: String { activeAppearance.backgroundOption }
    private var themeOption: String { activeAppearance.themeOption }
    private var fontOption: String { activeAppearance.fontOption }
    private var soundOption: String { activeAppearance.soundOption }

    private var backgroundOptionBinding: Binding<String> {
        Binding(get: { backgroundOption }, set: { setBackgroundOption($0) })
    }
    private var themeOptionBinding: Binding<String> {
        Binding(get: { themeOption }, set: { setThemeOption($0) })
    }
    private var fontOptionBinding: Binding<String> {
        Binding(get: { fontOption }, set: { setFontOption($0) })
    }
    private var soundOptionBinding: Binding<String> {
        Binding(get: { soundOption }, set: { setSoundOption($0) })
    }

    private func setBackgroundOption(_ option: String) {
        var value = model.activePersonaAppearance
        value.backgroundOption = option
        switch option {
        case "奶油白": value.chatBackgroundHex = 0xFBF8F1
        case "淡粉": value.chatBackgroundHex = 0xFCF1F6
        case "薄荷绿": value.chatBackgroundHex = 0xF0F8F3
        default: value.chatBackgroundHex = 0xF5F7FB
        }
        model.updateActivePersonaAppearance(value)
    }

    private func setThemeOption(_ option: String) {
        var value = model.activePersonaAppearance
        value.themeOption = option
        switch option {
        case "樱花粉": value.accentHex = 0xF0B8D2
        case "薄荷绿": value.accentHex = 0xA9DCC5
        case "薰衣草紫": value.accentHex = 0xC9B9ED
        default: value.accentHex = 0x8FC7FF
        }
        model.updateActivePersonaAppearance(value)
    }

    private func setFontOption(_ option: String) {
        var value = model.activePersonaAppearance
        value.fontOption = option
        model.updateActivePersonaAppearance(value)
    }

    private func setSoundOption(_ option: String) {
        var value = model.activePersonaAppearance
        value.soundOption = option
        model.updateActivePersonaAppearance(value)
    }

    private var walletTargetContact: ChatContact? {
        if let walletTargetContactID,
           let contact = model.friendContacts.first(where: { $0.id == walletTargetContactID && $0.isGroup != true }) {
            return contact
        }
        if let current = model.walletContactForCurrentChat, current.isGroup != true, current.id != model.activePersonaID { return current }
        return model.friendContacts.first(where: { $0.isGroup != true && $0.id != model.activePersonaID })
    }

    private var messageFontSize: CGFloat {
        switch fontOption {
        case "偏小": return 14
        case "偏大": return 18
        default: return 16
        }
    }

    private var conversationBackground: Color {
        Color(hex: activeAppearance.chatBackgroundHex)
    }

    private func appearanceColorBinding(_ keyPath: WritableKeyPath<PersonaAppearance, UInt>) -> Binding<Color> {
        Binding(
            get: { Color(hex: model.activePersonaAppearance[keyPath: keyPath]) },
            set: { newColor in
                var appearance = model.activePersonaAppearance
                appearance[keyPath: keyPath] = Self.hexValue(from: newColor)
                model.updateActivePersonaAppearance(appearance)
            }
        )
    }

    private static func hexValue(from color: Color) -> UInt {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (UInt(red * 255) << 16) | (UInt(green * 255) << 8) | UInt(blue * 255)
    }

    private var pageContent: some View {
        ZStack {
            appBackgroundColor.ignoresSafeArea()
            if showConversation {
                conversationView
                    .transition(.chatCinematic)
            } else {
                mainTabView
                    .transition(.chatCinematic)
            }
        }
        .overlay { minimizedCallOverlay }
        .sheet(item: Binding(
            get: { activeMomentForComments.map { MomentCommentTarget(id: $0) } },
            set: { activeMomentForComments = $0?.id }
        )) { target in
            MomentCommentsSheet(
                comments: momentsFeedItems.first(where: { $0.id == target.id })?.post.comments ?? [],
                authorOptions: ([model.activePersonaName] + model.friendContacts.filter { $0.isGroup != true }.map { $0.name }).reduce(into: [String]()) { result, name in
                    if !result.contains(name) { result.append(name) }
                },
                onSend: { comment in
                    updateMoment(target.id) {
                        var list = $0.comments ?? []
                        list.append(comment)
                        $0.comments = list
                    }
                },
                onUpdate: { comment in
                    updateMoment(target.id) {
                        var list = $0.comments ?? []
                        if let index = list.firstIndex(where: { $0.id == comment.id }) { list[index] = comment }
                        $0.comments = list
                    }
                },
                onDelete: { commentID in
                    updateMoment(target.id) {
                        $0.comments = ($0.comments ?? []).filter { $0.id != commentID }
                    }
                }
            )
        }
    }

    @ViewBuilder private var minimizedCallOverlay: some View {
        if let call = activeCall, isCallMinimized {
            MinimizedCallPill(call: call, position: $minimizedCallPosition) {
                withAnimation(ChatMotion.layout) { isCallMinimized = false }
            }
            .transition(.chatCinematic)
            .zIndex(50)
        }
    }
    var body: some View {
        preferenceDialogs
    }

    // Keep the modifier groups small so Swift's type checker does not have to
    // infer one enormous SwiftUI expression for the entire screen.
    private var basePresentation: some View {
        pageContent
            .buttonStyle(FluidPressButtonStyle())
            .animation(ChatMotion.layout, value: themeOption)
            .animation(ChatMotion.layout, value: backgroundOption)
            .animation(ChatMotion.layout, value: fontOption)
            .preferredColorScheme(.light)
            .onAppear {
                voiceCapture.onFailure = { showMicrophoneAlert = true }
            }
            .alert("需要麦克风权限或模型下载", isPresented: $showMicrophoneAlert) {
                Button("知道了", role: .cancel) { }
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } message: {
                Text("请允许 CustomChat 使用麦克风。首次使用还需要联网下载中文离线模型；下载完成后，识别将在本机运行，不会上传或保存录音。")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .inactive || phase == .background {
                    model.persistIdentity()
                    if voiceCapture.isRecording {
                        _ = voiceCapture.stop()
                        isVoiceComposer = false
                    }
                }
            }
            .sheet(isPresented: $showMyProfileEditor) { myProfileEditor }
            .sheet(isPresented: $showPersonaSwitcher) {
                PersonaSwitcherSheet(
                    currentPersonaID: model.activePersonaID,
                    ownName: model.identity.me,
                    ownAvatar: model.identity.meAvatarData,
                    ownAccountNumber: model.mainAccountNumber,
                    contacts: model.accountDirectory.filter { $0.id != model.mainAccountID }
                ) { selectedID in
                    model.switchPersona(selectedID)
                    walletTargetContactID = nil
                }
            }
            .sheet(isPresented: $showVirtualScanner) {
                VirtualScannerSheet(
                    accounts: model.accountDirectory,
                    currentAccountID: model.activeAccountID,
                    friendIDs: model.friendAccountIDs,
                    onAdd: { model.addFriend(accountID: $0) }
                )
            }
            .sheet(isPresented: $showMyQRCode) {
                AccountQRCodeSheet(account: model.activeAccountContact)
            }
            .sheet(isPresented: $showChatSettings) { chatSettingsSheet }
            .sheet(isPresented: $showAccountManagement) {
                AccountManagementView(
                    accounts: model.accountDirectory,
                    currentAccountID: model.activeAccountID,
                    onSelect: { id in model.switchPersona(id == model.mainAccountID ? nil : id) }
                )
            }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupSheet(contacts: model.friendContacts.filter { $0.isGroup != true }) { name, ids in
                    let id = model.addGroup(name: name, memberIDs: ids)
                    model.selectContact(id)
                    showConversation = true
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet { name, bio, avatarData in
                    model.addContact(name: name, bio: bio, avatarData: avatarData)
                    showAddContact = false
                    showConversation = true
                }
            }
            .sheet(isPresented: $showFriendProfile) {
                if let contact = model.currentContact, contact.isGroup != true {
                    FriendProfileSheet(contact: contact) { updated in
                        model.updateContact(updated)
                    }
                }
            }
            .sheet(item: $selectedGroupMember) { member in
                GroupMemberProfileSheet(member: member, isFriend: model.isFriend(member.id)) {
                    _ = model.addFriend(accountID: member.id)
                }
            }
            .sheet(item: $imageCropRequest) { request in
                ImageCropperSheet(image: request.image, shape: request.shape, onCancel: {
                    imageCropRequest = nil
                }) { cropped in
                    request.onCrop(cropped)
                    imageCropRequest = nil
                }
            }
            .sheet(item: $previewPhoto) { photo in
                PhotoPreviewView(images: photo.gallery, initialIndex: photo.index)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .confirmationDialog(
                "删除“\(contactPendingDeletion?.name ?? "好友")”？",
                isPresented: Binding(
                    get: { contactPendingDeletion != nil },
                    set: { if !$0 { contactPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("从当前账号移除好友", role: .destructive) {
                    if let contact = contactPendingDeletion {
                        model.removeFriend(contact)
                    }
                    contactPendingDeletion = nil
                }
                Button("取消", role: .cancel) { contactPendingDeletion = nil }
            } message: {
                Text("只移除当前账号的好友关系，不会删除聊天记录、图片或语音，也不会影响其他账号。")
            }
            .confirmationDialog(
                "删除与“\(chatHistoryPendingDeletion?.name ?? "好友")”的所有聊天记录？",
                isPresented: Binding(
                    get: { chatHistoryPendingDeletion != nil },
                    set: { if !$0 { chatHistoryPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除全部聊天记录", role: .destructive) {
                    if let contact = chatHistoryPendingDeletion { model.clearChatHistory(for: contact.id) }
                    chatHistoryPendingDeletion = nil
                }
                Button("取消", role: .cancel) { chatHistoryPendingDeletion = nil }
            } message: {
                Text("只删除本账号与该好友的聊天消息、图片和附件，不会删除好友关系。")
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
            .overlay {
                if showAddMenu {
                    AddContentMenu(
                        onDismiss: { showAddMenu = false },
                        onPhoto: {
                            showAddMenu = false
                            showPhotoPicker = true
                        },
                        onRedPacket: {
                            showAddMenu = false
                            paymentAmountDraft = ""
                            paymentNoteDraft = "恭喜发财"
                            showRedPacketInput = true
                        },
                        onTransfer: {
                            showAddMenu = false
                            paymentAmountDraft = ""
                            paymentNoteDraft = "转账"
                            showTransferInput = true
                        }
                    )
                    .transition(.chatCinematic)
                    .zIndex(20)
                }
            }
            .animation(ChatMotion.layout, value: showAddMenu)
    }

    private var paymentPresentation: some View {
        basePresentation
            .alert("发红包", isPresented: $showRedPacketInput) {
                TextField("金额，例如 8.88", text: $paymentAmountDraft).keyboardType(.decimalPad)
                TextField("红包标题", text: $paymentNoteDraft)
                Button("取消", role: .cancel) {}
                Button("发送") { sendPaymentMessage(kind: .redPacket) }
            } message: {
                Text("红包仅在本机记录，不涉及真实支付。")
            }
            .alert("发起转账", isPresented: $showTransferInput) {
                TextField("金额，例如 66.00", text: $paymentAmountDraft).keyboardType(.decimalPad)
                TextField("转账说明", text: $paymentNoteDraft)
                Button("取消", role: .cancel) {}
                Button("发送") { sendPaymentMessage(kind: .transfer) }
            } message: {
                Text("使用本地钱包记录，不涉及真实资金交易。")
            }
            .sheet(isPresented: Binding(
                get: { timeEditingMessage != nil },
                set: { if !$0 { timeEditingMessage = nil } }
            )) {
                NavigationStack {
                    Form {
                        DatePicker("发送时间", selection: $editedMessageTime, displayedComponents: [.date, .hourAndMinute])
                    }
                    .navigationTitle("修改消息时间")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { timeEditingMessage = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if let message = timeEditingMessage {
                                    model.updateTime(message, time: editedMessageTime)
                                }
                                timeEditingMessage = nil
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: Binding(
                get: { activeCall != nil && !isCallMinimized },
                set: { presented in
                    if !presented && activeCall != nil { isCallMinimized = true }
                }
            )) {
                if let call = activeCall {
                    SimulatedCallView(
                        name: model.name(for: .other),
                        meName: model.name(for: .me),
                        avatarData: model.avatar(for: .other),
                        meAvatarData: model.avatar(for: .me),
                        call: call,
                        onMinimize: {
                            call.videoPlayer?.pause()
                            isCallMinimized = true
                        }
                    ) { duration in
                        model.addCall(isVideo: call.isVideo, duration: duration)
                        model.addCallMessage(isVideo: call.isVideo, duration: duration)
                        activeCall = nil
                        isCallMinimized = false
                    }
                }
            }
    }

    private var selectedPhotoPresentation: some View {
        paymentPresentation
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        imageCropRequest = ImageCropRequest(image: image, shape: .roundedSquare) { cropped in
                            if let compact = compactImageData(cropped) {
                                model.sendImage(compact)
                                playMessageSound()
                            }
                        }
                    }
                    selectedPhoto = nil
                }
            }
    }

    private var myAvatarPresentation: some View {
        selectedPhotoPresentation
            .onChange(of: myAvatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        imageCropRequest = ImageCropRequest(image: image, shape: .circle) { cropped in
                            if let compact = compactImageData(cropped) { model.updateAvatar(for: .me, data: compact) }
                        }
                    }
                    myAvatarSelection = nil
                }
            }
    }

    private var otherAvatarPresentation: some View {
        myAvatarPresentation
            .onChange(of: otherAvatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        imageCropRequest = ImageCropRequest(image: image, shape: .circle) { cropped in
                            if let compact = compactImageData(cropped) { model.updateAvatar(for: .other, data: compact) }
                        }
                    }
                    otherAvatarSelection = nil
                }
            }
    }

    private var photoHandlingPresentation: some View {
        otherAvatarPresentation
            .onChange(of: chatBackgroundImageSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let compact = compactImageData(data) {
                        var appearance = model.activePersonaAppearance
                        appearance.chatBackgroundImageData = compact
                        model.updateActivePersonaAppearance(appearance)
                    }
                    chatBackgroundImageSelection = nil
                }
            }
    }

    private var preferenceDialogs: some View { editMessageAlert }

    private var backgroundOptionDialog: some View {
        photoHandlingPresentation
            .confirmationDialog("聊天背景", isPresented: $showBackgroundPicker, titleVisibility: .visible) {
                ForEach(["雾蓝白", "奶油白", "淡粉", "薄荷绿"], id: \.self) { option in
                    Button(option) { setBackgroundOption(option) }
                }
            }
    }

    private var themeOptionDialog: some View {
        backgroundOptionDialog
            .confirmationDialog("主题颜色", isPresented: $showThemePicker, titleVisibility: .visible) {
                ForEach(["浅蓝", "樱花粉", "薄荷绿", "薰衣草紫"], id: \.self) { option in
                    Button(option) { setThemeOption(option) }
                }
            }
    }

    private var fontOptionDialog: some View {
        themeOptionDialog
            .confirmationDialog("字体大小", isPresented: $showFontPicker, titleVisibility: .visible) {
                ForEach(["偏小", "标准", "偏大"], id: \.self) { option in
                    Button(option) { setFontOption(option) }
                }
            }
    }

    private var soundOptionDialog: some View {
        fontOptionDialog
            .confirmationDialog("消息提示音", isPresented: $showSoundPicker, titleVisibility: .visible) {
                ForEach(["轻柔", "清脆", "关闭"], id: \.self) { option in
                    Button(option) {
                        setSoundOption(option)
                        if option != "关闭" { playPreviewSound() }
                    }
                }
            }
    }

    private var insufficientBalanceAlert: some View {
        soundOptionDialog
            .alert("余额不足", isPresented: $showInsufficientBalance) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(model.activeRole == .me
                     ? "当前账号余额不足，请先在“我的”页面调整余额。"
                     : "对方账户余额不足，请先为对方身份补充余额。")
            }
    }

    private var clearHistoryAlert: some View {
        insufficientBalanceAlert
            .alert("清空聊天记录？", isPresented: $showClearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    withAnimation(ChatMotion.layout) { model.messages.removeAll() }
                }
            } message: {
                Text("此操作会删除本机保存的全部消息和图片，无法撤销。")
            }
    }

    private var editMessageAlert: some View {
        clearHistoryAlert
            .alert(editing?.kind == .voice ? "自定义语音文字" : "编辑消息", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField(editing?.kind == .voice ? "输入要显示的自定义文字" : "消息内容", text: $editText)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") {
                    if let editing { withAnimation(ChatMotion.layout) { model.update(editing, text: editText) } }
                    editing = nil
                }
            }
    }

    private var mainTabView: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .chats: chatListView
                case .contacts: contactsView
                case .calls: callsView
                case .album: momentsFeedView
                case .profile: profileView
                }
            }
            .animation(ChatMotion.layout, value: selectedTab)
            tabBar
        }
    }

    private var chatListView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("CustomChat")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(messageTextColor)
                Spacer()
                Menu {
                    Button("扫一扫添加好友", systemImage: "qrcode.viewfinder") { showVirtualScanner = true }
                    Button("手动添加好友", systemImage: "person.badge.plus") { showAddContact = true }
                    Button("创建群聊", systemImage: "person.3") { showCreateGroup = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(hex: 0x438FDC))
                        .frame(width: 42, height: 42)
                        .background(Macaron.blue, in: Circle())
                }
                .accessibilityLabel("添加好友")
            }
            .padding(.horizontal, 19)
            .padding(.top, 10)
            .padding(.bottom, 13)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                TextField("搜索聊天", text: $searchText)
                    .font(.system(size: 15))
                    .foregroundStyle(messageTextColor)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 45)
            .background(Color(hex: 0xEEF1F6), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 15)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("最近聊天")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 5)

                    let filteredContacts = model.visibleChatContacts.filter {
                        $0.isGroup == true || $0.id != model.activeAccountID
                    }.filter {
                        searchText.isEmpty ||
                        $0.name.localizedCaseInsensitiveContains(searchText) ||
                        ($0.accountNumber ?? "").localizedCaseInsensitiveContains(searchText)
                    }
                    if filteredContacts.isEmpty {
                        EmptyHint(
                            symbol: "person.crop.circle.badge.plus",
                            title: model.friendContacts.isEmpty ? "当前账号还没有好友" : "没有找到好友",
                            subtitle: model.friendContacts.isEmpty ? "点击右上角加号，扫一扫添加第一个好友。" : "试试昵称或账号编号。"
                        )
                        .padding(.top, 50)
                    } else {
                        ForEach(filteredContacts) { contact in
                            SwipeRevealRow(
                                content: {
                                    Button {
                                        model.selectContact(contact.id)
                                        withAnimation(ChatMotion.layout) { showConversation = true }
                                    } label: {
                                        ChatListRow(
                                            name: contact.name,
                                            preview: model.preview(for: contact),
                                            time: " ",
                                            avatarData: contact.avatarData,
                                            tint: Macaron.pink,
                                            isOnline: true,
                                            accentColor: accentColor
                                        )
                                    }
                                    .buttonStyle(FluidPressButtonStyle())
                                },
                                actions: {
                                    HStack(spacing: 8) {
                                        Button {
                                            chatHistoryPendingDeletion = contact
                                        } label: {
                                            VStack(spacing: 5) {
                                                Image(systemName: "trash")
                                                Text("删除记录").font(.system(size: 10, weight: .semibold))
                                            }
                                            .foregroundStyle(.white)
                                            .frame(width: 68, height: 66)
                                            .background(Color(hex: 0xE58A9D), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        }
                                        Button {
                                            withAnimation(ChatMotion.layout) { model.hideChat(for: contact.id) }
                                        } label: {
                                            VStack(spacing: 5) {
                                                Image(systemName: "eye.slash")
                                                Text("隐藏").font(.system(size: 10, weight: .semibold))
                                            }
                                            .foregroundStyle(Macaron.ink)
                                            .frame(width: 68, height: 66)
                                            .background(Macaron.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        }
                                    }
                                }
                            )
                            .transition(.chatCinematic)
                            .contextMenu {
                                Button {
                                    model.selectContact(contact.id)
                                    showFriendProfile = true
                                } label: {
                                    Label("编辑好友", systemImage: "pencil")
                                }
                            }
                        }
                        .animation(ChatMotion.layout, value: filteredContacts.map { $0.id })
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            Spacer(minLength: 0)
        }
    }

    private var contactsView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("通讯录")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(messageTextColor)
                    Text("当前账号 · \(model.friendContacts.filter { $0.isGroup != true && $0.id != model.activeAccountID }.count) 位好友")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                }
                Spacer()
                Menu {
                    Button("扫一扫添加好友", systemImage: "qrcode.viewfinder") { showVirtualScanner = true }
                    Button("手动添加好友", systemImage: "person.badge.plus") { showAddContact = true }
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x438FDC))
                        .frame(width: 42, height: 42)
                        .background(Macaron.blue, in: Circle())
                }
            }
            .padding(.horizontal, 19)
            .padding(.top, 18)
            .padding(.bottom, 13)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Macaron.secondary)
                TextField("搜索通讯录", text: $searchText)
                    .font(.system(size: 15))
                    .foregroundStyle(messageTextColor)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(hex: 0xEEF1F6), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    let friends = model.friendContacts.filter { $0.isGroup != true && $0.id != model.activeAccountID }.filter {
                        searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || ($0.accountNumber ?? "").localizedCaseInsensitiveContains(searchText)
                    }
                    if friends.isEmpty {
                        EmptyHint(symbol: "person.2", title: "通讯录还是空的", subtitle: "添加好友后，他们会一直保留在通讯录中。")
                            .padding(.top, 48)
                    } else {
                        ForEach(friends) { contact in
                            Button {
                                model.selectContact(contact.id)
                                withAnimation(ChatMotion.layout) { showConversation = true }
                            } label: {
                                HStack(spacing: 12) {
                                    IdentityAvatar(data: contact.avatarData, name: contact.name, size: 48, tint: Macaron.pink)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(contact.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(messageTextColor)
                                        Text("账号编号  \(contact.accountNumber ?? "未分配")")
                                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Macaron.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Macaron.secondary)
                                }
                                .padding(12)
                                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(FluidPressButtonStyle())
                            .contextMenu {
                                Button {
                                    model.selectContact(contact.id)
                                    showFriendProfile = true
                                } label: {
                                    Label("编辑备注", systemImage: "square.and.pencil")
                                }
                                Button(role: .destructive) {
                                    contactPendingDeletion = contact
                                } label: {
                                    Label("删除好友", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            Spacer(minLength: 0)
        }
    }

    private var conversationView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    messageFocused = false
                    withAnimation(ChatMotion.layout) { showConversation = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(messageTextColor)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zIndex(2)
                Button {
                    if model.currentContact?.isGroup == true { showCreateGroup = true } else { showFriendProfile = true }
                } label: {
                    IdentityAvatar(data: model.avatar(for: .other), name: model.name(for: .other), size: 42, tint: Macaron.pink)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .zIndex(1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.currentContact?.name ?? model.name(for: .other))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(messageTextColor)
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0x58C994)).frame(width: 7, height: 7)
                        Text(model.currentContact?.isGroup == true ? "群聊 · \(model.groupMembers(model.currentContact!).count) 位好友 · 本地聊天" : "本地聊天")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Spacer()
                Button { beginCall(video: false) } label: {
                    Image(systemName: "phone").font(.system(size: 19)).foregroundStyle(messageTextColor).frame(width: 34, height: 40)
                }
                .accessibilityLabel("语音通话")
                Button { beginCall(video: true) } label: {
                    Image(systemName: "video").font(.system(size: 20)).foregroundStyle(messageTextColor).frame(width: 34, height: 40)
                }
                .accessibilityLabel("视频通话")
                Button { showChatSettings = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).foregroundStyle(messageTextColor).frame(width: 30, height: 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 7)
            .padding(.bottom, 7)
            .background(Macaron.card)

            Rectangle().fill(Macaron.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 15) {
                        Text("今天")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(hex: 0xEEF1F6), in: Capsule())
                            .padding(.top, 12)

                        if model.messages.isEmpty {
                            EmptyHint(symbol: "bubble.left", title: "从这里开始聊天", subtitle: "切换发送身份，发送文字或图片。")
                                .padding(.top, 100)
                        } else {
                            ForEach(model.messages) { message in
                                MessageRow(
                                    message: message,
                                    name: message.senderName ?? model.name(for: message.role),
                                    avatarData: message.senderAvatarData ?? model.avatar(for: message.role),
                                    // The selected identity is always the outgoing/right-hand side.
                                    // Switching between "我" and "小羊" mirrors the whole conversation
                                    // without mutating the stored sender role.
                                    isMe: model.isMessageFromActiveSender(message),
                                    fontSize: messageFontSize,
                                    outgoingColor: Color(hex: activeAppearance.outgoingBubbleHex),
                                    incomingColor: Color(hex: activeAppearance.incomingBubbleHex),
                                    textColor: messageTextColor,
                                    onEdit: { editing = message; editText = message.text },
                                    onVoiceTranscript: {
                                        let recognized = message.voiceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? message.text
                                        guard !recognized.isEmpty else { return }
                                        withAnimation(ChatMotion.layout) { model.update(message, text: recognized) }
                                    },
                                    onVoiceCustom: { editing = message; editText = message.text },
                                    onDelete: { withAnimation(ChatMotion.layout) { model.delete(message) } },
                                    onChangeRole: { withAnimation(ChatMotion.layout) { model.changeRole(message) } },
                                    onChangeTime: { editedMessageTime = message.time; timeEditingMessage = message },
                                    onWithdraw: { withAnimation(ChatMotion.layout) { model.withdraw(message) } },
                                    onImageTap: { data in
                                        let gallery = model.messages.compactMap { $0.imageData }
                                        let index = gallery.firstIndex(of: data) ?? 0
                                        previewPhoto = SelectedPhoto(data: data, gallery: gallery, index: index)
                                    },
                                    onReceiveTransfer: {
                                        let received = withAnimation(ChatMotion.layout) { model.receivePayment(message) }
                                        if received {
                                            NotificationCenter.default.post(name: .customChatScrollToBottom, object: nil)
                                        }
                                    }
                                )
                                .id(message.id)
                                .transition(.chatCinematic)
                                // Individual message fields below drive their own lightweight transitions.
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
                    .animation(ChatMotion.layout, value: model.messages.map { $0.id })
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom-anchor")
                }
                // Keep the composer anchored above the keyboard. The message list
                // owns the remaining height and must not dismiss the keyboard
                // or hide the composer as a side effect of a drag gesture.
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    // Scroll to a dedicated bottom anchor after SwiftUI has
                    // completed the first layout pass. A second pass corrects
                    // late image/text measurements that can shift the stack.
                    guard !model.messages.isEmpty else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )) { _ in
                    guard !model.messages.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        withAnimation(.easeOut(duration: 0.20)) {
                            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.messages.count) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .customChatScrollToBottom)) { _ in
                    guard let last = model.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background {
                if let data = activeAppearance.chatBackgroundImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    conversationBackground
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)

            composer
                .transition(.chatCinematic)
        }
        .background(appBackgroundColor)
        .padding(.bottom, messageFocused ? 8 : 0)
    }

    private func senderIdentityChip(name: String, selected: Bool, tint: Color) -> some View {
        Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(messageTextColor)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(selected ? tint.opacity(0.78) : Color(hex: 0xF0F1F5), in: Capsule())
    }

    private var composer: some View {
        VStack(spacing: 11) {
            HStack(spacing: 7) {
                Text("发送身份")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                    .fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if model.currentContact?.isGroup == true {
                            Button {
                                withAnimation(ChatMotion.layout) { model.selectGroupSender(nil) }
                            } label: {
                                senderIdentityChip(name: model.activePersonaName, selected: model.activeGroupSenderID == nil, tint: accentColor)
                            }
                            .buttonStyle(FluidPressButtonStyle())
                            ForEach(model.currentContact.map { model.groupMembers($0).filter { $0.id != model.activeAccountID } } ?? []) { member in
                                Button {
                                    if model.isFriend(member.id) {
                                        withAnimation(ChatMotion.layout) { model.selectGroupSender(member.id) }
                                    } else {
                                        selectedGroupMember = member
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        senderIdentityChip(name: member.name, selected: model.activeGroupSenderID == member.id, tint: Macaron.pink)
                                        if !model.isFriend(member.id) {
                                            Text("非好友")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(Color(hex: 0xD18A55))
                                        }
                                    }
                                }
                                .buttonStyle(FluidPressButtonStyle())
                            }
                        } else {
                            ForEach(ChatRole.allCases, id: \.self) { role in
                                Button {
                                    withAnimation(ChatMotion.layout) { model.activeRole = role }
                                } label: {
                                    senderIdentityChip(name: model.name(for: role), selected: model.activeRole == role, tint: role == .me ? accentColor : Macaron.pink)
                                }
                                .buttonStyle(FluidPressButtonStyle())
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity)
                .clipped()
                Button { messageFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0xF0F1F5), in: Circle())
                }
                .accessibilityLabel("收起键盘")
                Button {
                    NotificationCenter.default.post(name: .customChatScrollToBottom, object: nil)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0xF0F1F5), in: Circle())
                }
                .accessibilityLabel("滚动到聊天底部")
            }

            HStack(spacing: 11) {
                if !isVoiceComposer {
                    Button {
                        messageFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showAddMenu = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(Color(hex: 0x5799D9))
                            .frame(width: 46, height: 46)
                            .background(accentColor.opacity(0.68), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    }
                    .buttonStyle(FluidPressButtonStyle())
                    .accessibilityLabel("添加聊天内容")
                }

                Group {
                    if isVoiceComposer {
                        VoiceComposerPanel(
                            capture: voiceCapture,
                            isTextMode: $isVoiceTextMode,
                            onWaveformTap: {
                                if voiceCapture.isRecording {
                                    _ = voiceCapture.stop()
                                    withAnimation(ChatMotion.layout) { isVoiceTextMode = true }
                                } else if voiceCapture.hasCapture {
                                    withAnimation(ChatMotion.layout) { isVoiceTextMode = true }
                                } else if !voiceCapture.isPreparing && !voiceCapture.isFinalizing {
                                    voiceCapture.start { showMicrophoneAlert = true }
                                }
                            },
                            onSendWaveform: sendVoiceMessage,
                            onSendText: sendVoiceTranscriptAsText,
                            onCancel: cancelVoiceComposer
                        )
                    } else {
                        HStack(spacing: 8) {
                            TextField("输入消息...", text: $draft, axis: .vertical)
                                .font(.system(size: fontOption == "偏大" ? 16 : 15))
                                .foregroundStyle(messageTextColor)
                                .lineLimit(1...4)
                                .padding(.vertical, 12)
                                .focused($messageFocused)
                                .onSubmit(sendText)
                            Button {
                                messageFocused = false
                                withAnimation(ChatMotion.layout) { isVoiceComposer = true }
                                voiceCapture.start { showMicrophoneAlert = true }
                            } label: {
                                Image(systemName: "waveform")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color(hex: 0x5799D9))
                                    .frame(width: 34, height: 34)
                                    .background(Macaron.blue, in: Circle())
                            }
                            .buttonStyle(FluidPressButtonStyle())
                            .accessibilityLabel("开始语音输入")
                            Button(action: sendText) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(accentColor.opacity(0.9), in: Circle())
                            }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.38 : 1)
                        }
                        .padding(.leading, 17)
                        .padding(.trailing, 8)
                        .frame(minHeight: 48)
                        .background(Macaron.card, in: Capsule())
                        .overlay(Capsule().stroke(Color(hex: 0xE5E8EF), lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(ChatMotion.layout, value: isVoiceComposer)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Macaron.card)
        .onDisappear {
            if voiceCapture.isRecording { voiceCapture.stop() }
        }
    }

    private var profileView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                profileHeader
                profileIdentityCard
                accountQRCodeCard
                profileWalletCard
                profileSettingsCard
                myMomentsProfileSection
                Text("CustomChat · 本地社交")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.bottom, 18)
            }
        }
    }

    private var profileHeader: some View {
        HStack {
            Text("我的")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(messageTextColor)
            Spacer()
            Button { showMyProfileEditor = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
                    .frame(width: 40, height: 40)
                    .background(Macaron.blue, in: Circle())
            }
            .accessibilityLabel("编辑我的资料")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    private var profileIdentityCard: some View {
        Button { showPersonaSwitcher = true } label: {
            HStack(spacing: 14) {
                IdentityAvatar(data: model.activePersonaAvatar, name: model.activePersonaName, size: 66, tint: Macaron.blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.activePersonaName)
                        .contentTransition(.interpolate)
                        .animation(ChatMotion.text, value: model.activePersonaName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(messageTextColor)
                    Text(model.activePersonaID == nil ? "主账号 · 点击切换身份" : "独立账号 · 点击切换身份")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(17)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        }
        .buttonStyle(FluidPressButtonStyle())
        .padding(.horizontal, 18)
    }

    private var accountQRCodeCard: some View {
        Button { showMyQRCode = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color(hex: 0x4F91D2))
                    .frame(width: 48, height: 48)
                    .background(Macaron.blue, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的专属二维码")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(messageTextColor)
                    Text("账号编号  \(model.activeAccountNumber)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Macaron.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(15)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(FluidPressButtonStyle())
        .padding(.horizontal, 18)
    }

    private var profileWalletCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("我的钱包", systemImage: "wallet.pass.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(messageTextColor)
                Spacer()
                Button("修改余额") {
                    editingWalletRole = .me
                    walletBalanceDraft = String(format: "%.2f", model.activePersonaWalletBalance())
                    showBalanceEditor = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x4F91D2))
            }
            Text("当前账号余额")
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
            Text("¥\(model.activePersonaWalletBalance(), specifier: "%.2f")")
                .contentTransition(.numericText())
                .animation(ChatMotion.text, value: model.activePersonaWalletBalance())
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(messageTextColor)
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.friendContacts.filter { $0.isGroup != true && $0.id != model.activeAccountID }) { contact in
                        Button {
                            withAnimation(ChatMotion.layout) { walletTargetContactID = contact.id }
                        } label: {
                            if walletTargetContact?.id == contact.id {
                                Label(contact.name, systemImage: "checkmark")
                            } else {
                                Text(contact.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("\(walletTargetContact?.name ?? "选择好友")的账户余额")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0x4F91D2))
                }
                Spacer()
                Text("¥\(model.walletBalance(for: walletTargetContact), specifier: "%.2f")")
                    .contentTransition(.numericText())
                    .animation(ChatMotion.text, value: model.walletBalance(for: walletTargetContact))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(messageTextColor)
                Button("修改") {
                    editingWalletRole = .other
                    editingWalletContactID = walletTargetContact?.id
                    walletBalanceDraft = String(format: "%.2f", model.walletBalance(for: walletTargetContact))
                    showBalanceEditor = true
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0x4F91D2))
                .disabled(walletTargetContact == nil)
            }
            .padding(.top, 2)
            Text("红包和转账会从发送身份的余额扣除，领取后计入接收身份余额。仅保存在本机，不涉及真实资金。")
                .font(.system(size: 11))
                .foregroundStyle(Macaron.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xE8F3FF), Color(hex: 0xF2EDFC)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.horizontal, 18)
        .alert("修改钱包余额", isPresented: $showBalanceEditor) {
            TextField("输入余额", text: $walletBalanceDraft)
                .keyboardType(.decimalPad)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let value = Double(walletBalanceDraft), value >= 0 {
                    if editingWalletRole == .me {
                        model.setActivePersonaWalletBalance(value)
                    } else {
                        model.updateWalletBalance(value, contactID: editingWalletContactID)
                    }
                }
            }
        } message: {
            Text(editingWalletRole == .me ? "修改当前账号的独立本地余额。" : "修改已选择好友的本地余额，不影响其他账号。")
        }
    }

    private var profileSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            profileSettingsHeader
            if isProfileSettingsExpanded {
                profileSettingsRows
            }
        }
        .padding(.vertical, 4)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 18)
    }

    private var profileSettingsHeader: some View {
        Button {
            withAnimation(ChatMotion.layout) { isProfileSettingsExpanded.toggle() }
        } label: {
            HStack {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(messageTextColor)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
                    .rotationEffect(.degrees(isProfileSettingsExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 15)
            .padding(.top, 12)
            .padding(.bottom, isProfileSettingsExpanded ? 0 : 12)
        }
        .buttonStyle(FluidPressButtonStyle())
    }

    private var profileSettingsRows: some View {
        VStack(spacing: 0) {
            SettingsRow(symbol: "person.2.crop.square.stack", title: "账号管理", value: "\(model.accountDirectory.count) 个账号", tint: Color(hex: 0x83B9EF)) {
                showAccountManagement = true
            }
            settingsDivider
            voiceModelSettingRow
            settingsDivider
            clearChatSettingRow
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 8)
        .transition(.chatCinematic)
    }

    private var settingsDivider: some View {
        Divider().overlay(Macaron.line).padding(.leading, 54)
    }

    private var chatBackgroundSettingRow: some View {
        SettingsRow(symbol: "photo", title: "聊天背景", value: backgroundOption, tint: Color(hex: 0x83B9EF)) {
            showBackgroundPicker = true
        }
    }

    private var themeSettingRow: some View {
        SettingsRow(symbol: "paintpalette", title: "主题色", value: themeOption, tint: Color(hex: 0xC18AD8)) {
            showThemePicker = true
        }
    }

    private var fontSettingRow: some View {
        SettingsRow(symbol: "textformat.size", title: "字体大小", value: fontOption, tint: Color(hex: 0x83B9EF)) {
            showFontPicker = true
        }
    }

    private var soundSettingRow: some View {
        SettingsRow(symbol: "bell", title: "消息提示音", value: soundOption, tint: Color(hex: 0xE6A5C7)) {
            showSoundPicker = true
        }
    }

    private var voiceModelSettingRow: some View {
        SettingsRow(symbol: "waveform.badge.mic", title: "语音模型下载", value: voiceCapture.isModelInstalled ? "已就绪" : "未下载", tint: Color(hex: 0x83B9EF)) {
            voiceCapture.refreshModelStatus()
            showChatSettings = true
        }
    }

    private var clearChatSettingRow: some View {
        Button { showClearConfirmation = true } label: {
            SettingsLine(symbol: "trash", title: "清空当前好友聊天记录", tint: Color(hex: 0xD9829F))
        }
    }

    private var myMomentsProfileSection: some View {
        VStack(spacing: 12) {
            myMomentsHeader
            if model.activePersonaMoments.isEmpty {
                EmptyHint(symbol: "text.bubble", title: "还没有朋友圈", subtitle: "记录生活，发布第一条动态吧。")
                    .padding(.vertical, 20)
            } else {
                myMomentsPreviewRows
            }
        }
        .sheet(isPresented: $showAllMyMoments) { myMomentsAllSheet }
        .sheet(isPresented: $showMyMomentEditor) { myMomentEditorSheet }
    }

    private var myMomentsHeader: some View {
        HStack {
            Text("我的朋友圈")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(messageTextColor)
            Spacer()
            if !model.activePersonaMoments.isEmpty {
                Button("查看全部") { showAllMyMoments = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
            }
            Button {
                editingMyMomentID = nil
                myMomentDraft = ""
                showMyMomentEditor = true
            } label: {
                Label("发布", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
            }
        }
        .padding(.horizontal, 20)
    }

    private var myMomentsPreviewRows: some View {
        ForEach(Array(model.activePersonaMoments.prefix(3))) { post in
            profileMomentCard(post: post, inAllList: false)
                .padding(.horizontal, 18)
                .transition(.chatCinematic)
        }
        .animation(ChatMotion.layout, value: model.activePersonaMoments.map { $0.id })
    }

    private var myMomentsAllSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(model.activePersonaMoments) { post in
                        profileMomentCard(post: post, inAllList: true)
                    }
                }
                .padding(18)
                .animation(ChatMotion.layout, value: model.activePersonaMoments.map { $0.id })
            }
            .background(appBackgroundColor)
            .navigationTitle("我的朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingMyMomentID = nil
                        myMomentDraft = ""
                        showAllMyMoments = false
                        showMyMomentEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func profileMomentCard(post: MomentPost, inAllList: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.system(size: 14))
                    .foregroundStyle(messageTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let mediaData = post.mediaData {
                MomentMediaView(data: mediaData, mediaType: post.mediaType)
            }
            Text(post.date, format: .dateTime.year().month().day().hour().minute())
                .font(.system(size: 10))
                .foregroundStyle(Macaron.secondary)
        }
        .padding(15)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.chatCinematic)
        .contextMenu {
            Button("编辑动态", systemImage: "pencil") {
                editingMyMomentID = post.id
                myMomentDraft = post.text
                if inAllList { showAllMyMoments = false }
                showMyMomentEditor = true
            }
            Button("删除动态", systemImage: "trash", role: .destructive) {
                withAnimation(ChatMotion.layout) {
                    model.updateActivePersonaMoments(model.activePersonaMoments.filter { $0.id != post.id })
                }
            }
        }
    }

    private var myMomentEditorSheet: some View {
        MomentEditorSheet(
            title: editingMyMomentID == nil ? "发布朋友圈" : "编辑朋友圈",
            initialText: myMomentDraft,
            initialMediaData: editingMyMomentID.flatMap { id in model.activePersonaMoments.first(where: { $0.id == id })?.mediaData },
            initialMediaType: editingMyMomentID.flatMap { id in model.activePersonaMoments.first(where: { $0.id == id })?.mediaType }
        ) { text, mediaData, mediaType in
            var posts = model.activePersonaMoments
            if let id = editingMyMomentID, let index = posts.firstIndex(where: { $0.id == id }) {
                posts[index].text = text
                posts[index].mediaData = mediaData
                posts[index].mediaType = mediaType
            } else {
                posts.insert(MomentPost(text: text, mediaData: mediaData, mediaType: mediaType), at: 0)
            }
            model.updateActivePersonaMoments(posts)
        }
    }

    private var callsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                callScreenTitle
                callStarterCard
                recentCallsHeader
                recentCallsList
                Spacer(minLength: 20)
            }
        }
    }

    private var callScreenTitle: some View {
        Text("通话")
            .font(.system(size: 23, weight: .bold))
            .foregroundStyle(messageTextColor)
            .padding(.top, 22)
    }

    private var callStarterCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(hex: 0x5D9FE2))
                .frame(width: 72, height: 72)
                .background(Macaron.blue, in: Circle())
            Text("通话")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(messageTextColor)
            Text("查看和管理最近的语音通话与视频通话。")
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { beginCall(video: false) } label: {
                    Label("语音", systemImage: "phone")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Macaron.blue, in: Capsule())
                }
                Button { beginCall(video: true) } label: {
                    Label("视频", systemImage: "video")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Macaron.pink, in: Capsule())
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(messageTextColor)
        }
        .padding(18)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 18)
    }

    private var recentCallsHeader: some View {
        HStack {
            Text("最近通话")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(messageTextColor)
            Spacer()
            Text("仅本机保存")
                .font(.system(size: 11))
                .foregroundStyle(Macaron.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 5)
    }

    @ViewBuilder private var recentCallsList: some View {
        if model.calls.isEmpty {
            EmptyHint(symbol: "clock", title: "还没有通话记录", subtitle: "完成通话后，会显示在这里。")
                .padding(.top, 18)
        } else {
            VStack(spacing: 0) {
                ForEach(model.calls) { call in
                    CallHistoryRow(record: call, name: model.name(for: .other)) {
                        withAnimation(ChatMotion.layout) {
                            model.calls.removeAll { $0.id == call.id }
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .chatCinematic,
                        removal: .scale(scale: 0.94, anchor: .trailing)
                            .combined(with: .opacity)
                            .combined(with: .move(edge: .trailing))
                    ))
                    if call.id != model.calls.last?.id {
                        Divider().overlay(Macaron.line).padding(.leading, 70)
                    }
                }
            }
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .animation(ChatMotion.layout, value: model.calls.map { $0.id })
            .padding(.horizontal, 18)
        }
    }

    @State private var activeMomentForComments: UUID?

    private func updateMoment(_ id: UUID, mutate: (inout MomentPost) -> Void) {
        withAnimation(ChatMotion.layout) {
            if let index = model.myMoments.firstIndex(where: { $0.id == id }) {
                mutate(&model.myMoments[index])
                return
            }
            for index in model.contacts.indices {
                if let postIndex = model.contacts[index].moments.firstIndex(where: { $0.id == id }) {
                    mutate(&model.contacts[index].moments[postIndex])
                    return
                }
            }
        }
    }

    private var momentsFeedItems: [MomentFeedItem] {
        var items = model.activePersonaMoments.map {
            MomentFeedItem(author: model.activePersonaName, avatarData: model.activePersonaAvatar, post: $0)
        }
        for contact in model.friendContacts where contact.isGroup != true && contact.id != model.activeAccountID {
            if contact.id == model.mainAccountID {
                items.append(contentsOf: model.myMoments.map {
                    MomentFeedItem(author: model.identity.me, avatarData: model.identity.meAvatarData, post: $0)
                })
            } else {
                items.append(contentsOf: contact.moments.map {
                    MomentFeedItem(author: contact.name, avatarData: contact.avatarData, post: $0)
                })
            }
        }
        return items.sorted { $0.post.date > $1.post.date }
    }

    private var momentsFeedView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                momentsFeedHeader
                if momentsFeedItems.isEmpty {
                    EmptyHint(symbol: "text.bubble", title: "朋友圈还很安静", subtitle: "发布自己的动态，或到好友主页查看他们的分享。")
                        .padding(.top, 80)
                } else {
                    ForEach(momentsFeedItems) { item in
                        momentFeedCard(item)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var momentsFeedHeader: some View {
        HStack {
            Text("朋友圈")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(messageTextColor)
            Spacer()
            Button {
                selectedTab = .profile
                editingMyMomentID = nil
                myMomentDraft = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { showMyMomentEditor = true }
            } label: {
                Label("发布", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func momentFeedCard(_ item: MomentFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                IdentityAvatar(data: item.avatarData, name: item.author, size: 42, tint: Macaron.blue)
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.author)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                    if !item.post.text.isEmpty {
                        Text(item.post.text)
                            .font(.system(size: 14))
                            .foregroundStyle(messageTextColor)
                    }
                    if let data = item.post.mediaData {
                        MomentMediaView(data: data, mediaType: item.post.mediaType)
                    }
                    HStack(spacing: 8) {
                        Text(item.post.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: 10))
                            .foregroundStyle(Macaron.secondary)
                        if (item.post.shareCount ?? 0) > 0 {
                            Text("转发 \(item.post.shareCount ?? 0) 次")
                                .font(.system(size: 10))
                                .foregroundStyle(Macaron.secondary)
                        }
                    }
                }
            }
            momentInteractionBar(item)
            momentCommentsPreview(item)
        }
        .padding(15)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .transition(.chatCinematic)
    }

    private func momentInteractionBar(_ item: MomentFeedItem) -> some View {
        HStack(spacing: 0) {
            Button {
                updateMoment(item.id) { $0.isLiked = !($0.isLiked ?? false) }
            } label: {
                Label(item.post.isLiked == true ? "已赞" : "赞", systemImage: item.post.isLiked == true ? "heart.fill" : "heart")
                    .foregroundStyle(item.post.isLiked == true ? Color(hex: 0xE77D9B) : Macaron.secondary)
                    .scaleEffect(item.post.isLiked == true ? 1.05 : 1)
            }
            Spacer()
            Button { activeMomentForComments = item.id } label: {
                Label("评论 \(item.post.comments?.count ?? 0)", systemImage: "bubble.right")
                    .foregroundStyle(Macaron.secondary)
            }
            Spacer()
            ShareLink(item: "\(item.author) 的朋友圈：\(item.post.text)") {
                Label("转发", systemImage: "arrowshape.turn.up.right")
                    .foregroundStyle(Macaron.secondary)
            }
            .simultaneousGesture(TapGesture().onEnded {
                updateMoment(item.id) { $0.shareCount = ($0.shareCount ?? 0) + 1 }
            })
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.top, 7)
    }

    @ViewBuilder private func momentCommentsPreview(_ item: MomentFeedItem) -> some View {
        if let comments = item.post.comments, !comments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    HStack(alignment: .top, spacing: 4) {
                        Text(comment.author + "：")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(hex: 0x4F91D2))
                        Text(comment.text)
                            .foregroundStyle(messageTextColor)
                        if let data = comment.mediaData {
                            MomentMediaView(data: data, mediaType: comment.mediaType)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appBackgroundColor, in: RoundedRectangle(cornerRadius: 10))
            .transition(.chatCinematic)
        }
    }

    private var albumView: some View {
        VStack(spacing: 0) {
            Text("相册")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(messageTextColor)
                .padding(.top, 22)
                .padding(.bottom, 18)

            let imageMessages = model.messages.filter { $0.imageData != nil }
            if imageMessages.isEmpty {
                EmptyHint(symbol: "photo", title: "还没有图片", subtitle: "在聊天中发送的图片会自动收录到这里。")
                    .padding(.top, 100)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                        ForEach(imageMessages) { message in
                            if let data = message.imageData, let image = UIImage(data: data) {
                                Button {
                                    let gallery = imageMessages.compactMap { $0.imageData }
                                    let index = gallery.firstIndex(of: data) ?? 0
                                    previewPhoto = SelectedPhoto(data: data, gallery: gallery, index: index)
                                } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 112)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(FluidPressButtonStyle())
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { withAnimation(ChatMotion.layout) { selectedTab = tab } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 21, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? Color(hex: 0x4F9DE8) : Macaron.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(accentColor.opacity(0.38))
                                .padding(.horizontal, 5)
                        }
                    }
                }
                .buttonStyle(FluidPressButtonStyle())
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
        .background(Macaron.card)
        .overlay(alignment: .top) { Rectangle().fill(Macaron.line).frame(height: 1) }
    }

    private var chatSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("聊天外观") {
                    Picker("聊天背景", selection: backgroundOptionBinding) {
                        ForEach(["雾蓝白", "奶油白", "淡粉", "薄荷绿"], id: \.self) { Text($0) }
                    }
                    Picker("主题颜色", selection: themeOptionBinding) {
                        ForEach(["浅蓝", "樱花粉", "薄荷绿", "薰衣草紫"], id: \.self) { Text($0) }
                    }
                    Picker("文字大小", selection: fontOptionBinding) {
                        ForEach(["偏小", "标准", "偏大"], id: \.self) { Text($0) }
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.badge.mic")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x5799D9))
                                .frame(width: 38, height: 38)
                                .background(Macaron.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("中文离线语音模型")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(messageTextColor)
                                Text(voiceCapture.isModelInstalled ? "已下载 · 可离线使用" : "约 168 MB · 首次下载需要网络")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Macaron.secondary)
                            }
                            Spacer()
                            if voiceCapture.isModelInstalled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color(hex: 0x69B99A))
                                    .font(.system(size: 20))
                            }
                        }
                        Text("用于聊天输入框的语音转文字。模型下载并保存在本机，识别过程在设备端完成。")
                            .font(.system(size: 12))
                            .foregroundStyle(Macaron.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if voiceCapture.isDownloadingModel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(voiceCapture.modelStatus)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Macaron.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(Int(voiceCapture.downloadProgress * 100))%")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Color(hex: 0x4F91D2))
                                }
                                ProgressView(value: voiceCapture.downloadProgress)
                                    .tint(Color(hex: 0x5799D9))
                                HStack {
                                    Text("文件 \(voiceCapture.downloadingFileName)")
                                    Spacer()
                                    Text("正在下载 · 请保持网络连接")
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(Macaron.secondary)
                            }
                        } else {
                            Button { Task { await voiceCapture.downloadModel() } } label: {
                                HStack {
                                    Image(systemName: voiceCapture.isModelInstalled ? "arrow.down.circle" : "arrow.down.to.line")
                                    Text(voiceCapture.isModelInstalled ? "检查 / 重新下载模型" : "下载中文语音模型")
                                    Spacer()
                                    Text(voiceCapture.isModelInstalled ? "已就绪" : "约 168 MB")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Macaron.secondary)
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x4F91D2))
                            }
                            .disabled(voiceCapture.isRecording || voiceCapture.isPreparing)
                        }
                        if let error = voiceCapture.modelDownloadError {
                            Text("下载失败：\(error)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0xC65C58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("语音输入模型")
                } footer: {
                    Text("模型文件会保存在本机 App 数据目录。首次使用语音转文字前，请先完成下载。")
                }
                .onAppear { voiceCapture.refreshModelStatus() }

                Section("消息提醒") {
                    Picker("消息提醒", selection: soundOptionBinding) {
                        ForEach(["轻柔", "清脆", "关闭"], id: \.self) { Text($0) }
                    }
                }
                Section("聊天记录") {
                    Button(role: .destructive) {
                        showChatSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showClearConfirmation = true }
                    } label: {
                        Label("清空当前好友聊天记录", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showChatSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var myProfileEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityEditor(
                        title: "当前账号资料",
                        name: activePersonaNameBinding,
                        avatarData: model.activePersonaAvatar,
                        selection: $myAvatarSelection,
                        tint: Macaron.blue
                    )
                    personaAppearanceEditor
                    Text("昵称、头像、颜色和聊天背景只保存在当前账号下。切换账号不会覆盖其他角色的设置。")
                        .font(.system(size: 11))
                        .foregroundStyle(Macaron.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(appBackgroundColor)
            .navigationTitle("编辑账号 · \(model.activePersonaName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showMyProfileEditor = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var activePersonaNameBinding: Binding<String> {
        Binding(
            get: { model.activePersonaName },
            set: { model.updateActivePersonaName($0) }
        )
    }

    private var personaAppearanceEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("界面外观")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(messageTextColor)
            appearanceColorRow("整体背景", keyPath: \.appBackgroundHex)
            appearanceColorRow("聊天背景", keyPath: \.chatBackgroundHex)
            appearanceColorRow("我方聊天气泡", keyPath: \.outgoingBubbleHex)
            appearanceColorRow("好友聊天气泡", keyPath: \.incomingBubbleHex)
            appearanceColorRow("文字颜色", keyPath: \.textHex)
            appearanceColorRow("主题强调色", keyPath: \.accentHex)
            PhotosPicker(selection: $chatBackgroundImageSelection, matching: .images) {
                Label(activeAppearance.chatBackgroundImageData == nil ? "选择聊天背景图片" : "更换聊天背景图片", systemImage: "photo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(Color(hex: 0xE8F3FF), in: RoundedRectangle(cornerRadius: 14))
            }
            if activeAppearance.chatBackgroundImageData != nil {
                Button(role: .destructive) {
                    var appearance = activeAppearance
                    appearance.chatBackgroundImageData = nil
                    model.updateActivePersonaAppearance(appearance)
                } label: {
                    Label("移除背景图片", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            Text("每个账号独立保存颜色设置。背景图片只影响当前账号的聊天界面。")
                .font(.system(size: 11))
                .foregroundStyle(Macaron.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func appearanceColorRow(_ title: String, keyPath: WritableKeyPath<PersonaAppearance, UInt>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(messageTextColor)
            Spacer()
            ColorPicker(title, selection: appearanceColorBinding(keyPath), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func identityEditor(
        title: String,
        name: Binding<String>,
        avatarData: Data?,
        selection: Binding<PhotosPickerItem?>,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            PhotosPicker(selection: selection, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    IdentityAvatar(data: avatarData, name: name.wrappedValue, size: 64, tint: tint)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(hex: 0x83B9EF), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            .buttonStyle(FluidPressButtonStyle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
                TextField("输入昵称", text: name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(messageTextColor)
                    .padding(12)
                    .background(appBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(15)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func beginCall(video: Bool) {
        activeCall = SimulatedCall(isVideo: video)
    }

    private func sendVoiceMessage() {
        if voiceCapture.isRecording { _ = voiceCapture.stop() }
        guard let captured = voiceCapture.consumeCapture() else { return }
        model.sendVoice(duration: captured.duration, waveform: captured.waveform, text: "", recognizedText: captured.transcript)
        voiceCapture.transcript = ""
        isVoiceTextMode = false
        withAnimation(ChatMotion.layout) { isVoiceComposer = false }
        playMessageSound()
    }

    private func sendVoiceTranscriptAsText() {
        let value = voiceCapture.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.send(value)
        _ = voiceCapture.consumeCapture()
        voiceCapture.transcript = ""
        isVoiceTextMode = false
        withAnimation(ChatMotion.layout) { isVoiceComposer = false }
        playMessageSound()
    }

    private func cancelVoiceComposer() {
        if voiceCapture.isRecording { _ = voiceCapture.stop() }
        if voiceCapture.hasCapture { _ = voiceCapture.consumeCapture() }
        voiceCapture.transcript = ""
        isVoiceTextMode = false
        withAnimation(ChatMotion.layout) { isVoiceComposer = false }
    }

    private func sendText() {
        let previousCount = model.messages.count
        model.send(draft)
        draft = ""
        if model.messages.count > previousCount { playMessageSound() }
    }

    private func sendPaymentMessage(kind: ChatMessageKind) {
        guard let amount = Double(paymentAmountDraft), amount > 0 else { return }
        let sent = model.sendPayment(
            kind: kind,
            amount: amount,
            note: paymentNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        paymentAmountDraft = ""; paymentNoteDraft = ""
        if sent {
            playMessageSound()
        } else {
            showInsufficientBalance = true
        }
    }

    private func playMessageSound() {
        // Replace the loud system alert tone with a subtle, low-intensity haptic.
        guard soundOption != "关闭" else { return }
        let feedback = UIImpactFeedbackGenerator(style: .soft)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.22)
    }

    private func playPreviewSound() {
        guard soundOption != "关闭" else { return }
        let feedback = UIImpactFeedbackGenerator(style: .soft)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.22)
    }

    private func compactImageData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return compactImageData(image)
    }

    private func compactImageData(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1500 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.78)
    }
}

private struct ChatListRow: View {
    let name: String
    let preview: String
    let time: String
    let avatarData: Data?
    let tint: Color
    var isOnline = false
    let accentColor: Color

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                IdentityAvatar(data: avatarData, name: name, size: 54, tint: tint)
                if isOnline {
                    Circle()
                        .fill(Color(hex: 0x55C987))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .contentTransition(.interpolate)
                    .animation(ChatMotion.text, value: name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Macaron.ink)
                Text(preview.isEmpty ? " " : preview)
                    .contentTransition(.interpolate)
                    .animation(ChatMotion.text, value: preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Macaron.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Text(time)
                    .font(.system(size: 12))
                    .foregroundStyle(Macaron.secondary)
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(isOnline ? 1 : 0)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct ProfileIdentityCard: View {
    let title: String
    let name: String
    let avatarData: Data?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IdentityAvatar(data: avatarData, name: name, size: 66, tint: tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Macaron.secondary)
                    Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Macaron.ink)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(17)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(FluidPressButtonStyle())
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Macaron.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(FluidPressButtonStyle())
    }
}

private struct SettingsLine: View {
    let symbol: String
    let title: String
    var tint: Color = Color(hex: 0x83B9EF)

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28)
            Text(title).foregroundStyle(Macaron.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Macaron.secondary)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

private struct CallHistoryRow: View {
    let record: CallRecord
    let name: String
    let onDelete: () -> Void
    @State private var revealAmount: CGFloat = 0
    @State private var dragStart: CGFloat = 0

    private let deleteWidth: CGFloat = 82

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: onDelete) {
                VStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                    Text("删除")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0xF29AA8), Color(hex: 0xE9788C)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(revealAmount < -12 ? 1 : 0)
            .scaleEffect(revealAmount < -12 ? 1 : 0.88, anchor: .trailing)
            .allowsHitTesting(revealAmount < -12)

            HStack(spacing: 13) {
                Image(systemName: record.isVideo ? "video" : "phone")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(record.isVideo ? Color(hex: 0xD99ABF) : Color(hex: 0x74AEE3))
                    .frame(width: 42, height: 42)
                    .background(record.isVideo ? Macaron.pink : Macaron.blue, in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Text("\(record.isVideo ? "视频通话" : "语音通话") · \(durationText(record.duration))")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
                Spacer()
                Text(record.date, format: .dateTime.month(.twoDigits).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Macaron.card)
            .contentShape(Rectangle())
            .offset(x: revealAmount)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        guard abs(horizontal) > abs(value.translation.height) else { return }
                        let proposed = dragStart + horizontal
                        revealAmount = min(0, max(-deleteWidth, proposed))
                    }
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard abs(horizontal) > abs(value.translation.height) else {
                            withAnimation(ChatMotion.press) { revealAmount = 0 }
                            return
                        }
                        let shouldReveal = revealAmount < -deleteWidth * 0.42 || horizontal < -deleteWidth * 0.55
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            revealAmount = shouldReveal ? -deleteWidth : 0
                        }
                        dragStart = shouldReveal ? -deleteWidth : 0
                    }
            )
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: revealAmount)
        }
        .clipped()
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct EmptyHint: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(Color(hex: 0x91B8DE))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Macaron.ink)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .transition(.chatCinematic)
    }
}

private struct IdentityAvatar: View {
    let data: Data?
    let name: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint)
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.39, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x55718E))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let name: String
    let avatarData: Data?
    let isMe: Bool
    let fontSize: CGFloat
    let outgoingColor: Color
    let incomingColor: Color
    let textColor: Color
    let onEdit: () -> Void
    let onVoiceTranscript: () -> Void
    let onVoiceCustom: () -> Void
    let onDelete: () -> Void
    let onChangeRole: () -> Void
    let onChangeTime: () -> Void
    let onWithdraw: () -> Void
    let onImageTap: (Data) -> Void
    let onReceiveTransfer: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if isMe { Spacer(minLength: 58) }
            else { IdentityAvatar(data: avatarData, name: name, size: 33, tint: Macaron.pink) }

            messageBubble
                .contextMenu {
                    if !message.isWithdrawn && message.kind == .text {
                        Button("编辑文本", systemImage: "pencil", action: onEdit)
                    }
                    if !message.isWithdrawn && message.kind == .voice {
                        Menu("转换为文字", systemImage: "text.alignleft") {
                            Button("转换成刚才说的话", systemImage: "waveform") { onVoiceTranscript() }
                                .disabled((message.voiceTranscript ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("自定义文字", systemImage: "pencil") { onVoiceCustom() }
                        }
                    }
                    if !message.isWithdrawn {
                        Button(isMe ? "显示为对方发送" : "显示为我发送", systemImage: "arrow.left.arrow.right", action: onChangeRole)
                        Button("修改发送时间", systemImage: "clock", action: onChangeTime)
                        Button("撤回消息", systemImage: "arrow.uturn.backward", role: .destructive, action: onWithdraw)
                    }
                    Button("删除消息", systemImage: "trash", role: .destructive, action: onDelete)
                }

            if isMe { IdentityAvatar(data: avatarData, name: name, size: 33, tint: Macaron.blue) }
            else { Spacer(minLength: 58) }
        }
        .frame(maxWidth: .infinity)
        .animation(ChatMotion.layout, value: isMe)
        .animation(ChatMotion.layout, value: message.isWithdrawn)
        .animation(ChatMotion.layout, value: message.isReceived)
    }

    @ViewBuilder private var messageBubble: some View {
        if message.isWithdrawn {
            Text("你撤回了一条消息")
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Color.white.opacity(0.72), in: Capsule())
        } else if message.kind == .voice {
            VoiceMessageBubble(message: message, isMe: isMe, outgoingColor: outgoingColor, incomingColor: incomingColor, textColor: textColor)
        } else if message.kind == .call {
            HStack(spacing: 11) {
                Image(systemName: message.note.contains("视频") ? "video.fill" : "phone.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color(hex: 0x8AB7E8), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.note.contains("视频") ? "视频通话" : "语音通话")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message.note.replacingOccurrences(of: "视频通话 · ", with: "").replacingOccurrences(of: "语音通话 · ", with: ""))
                        .font(.system(size: 12))
                        .opacity(0.75)
                }
                .foregroundStyle(Macaron.ink)
            }
            .padding(12)
            .frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xE7F0FC), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if message.kind == .paymentReceipt {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(hex: 0xE7A65B))
                        .frame(width: 45, height: 45)
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("已收款")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Text("¥\(message.amount ?? 0, specifier: "%.2f")")
                        .contentTransition(.numericText())
                        .animation(ChatMotion.text, value: message.amount ?? 0)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Macaron.ink)
                    Text(message.note.isEmpty ? "转账" : message.note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xFFF1D9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white, lineWidth: 1))
        } else if message.kind == .redPacket {
            HStack(spacing: 11) {
                Image(systemName: "gift.fill").font(.system(size: 25)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(Color(hex: 0xE97868), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("红包").font(.system(size: 15, weight: .semibold))
                    Text(message.note.isEmpty ? "恭喜发财" : message.note).font(.system(size: 12)).opacity(0.8)
                    Text("¥\(message.amount ?? 0, specifier: "%.2f")").font(.system(size: 13, weight: .bold))
                    if !isMe && !message.isReceived {
                        Button(action: onReceiveTransfer) {
                            Text("一键领取")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xB94E42))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.72), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(FluidPressButtonStyle())
                        .accessibilityLabel("一键领取红包")
                        .padding(.top, 2)
                    } else if message.isReceived {
                        Text(isMe ? "对方已收款 · ¥\(message.amount ?? 0, specifier: "%.2f")" : "已被接收 · ¥\(message.amount ?? 0, specifier: "%.2f")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x2C8A5A))
                    }
                }.foregroundStyle(Macaron.ink)
            }
            .padding(12).frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xFCE7E2), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white, lineWidth: 1))
        } else if message.kind == .transfer {
            HStack(spacing: 11) {
                Image(systemName: "yensign.circle.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(Color(hex: 0xE7A65B), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("转账").font(.system(size: 15, weight: .semibold))
                    Text(message.note.isEmpty ? "转账" : message.note).font(.system(size: 12)).opacity(0.8)
                    Text("¥\(message.amount ?? 0, specifier: "%.2f")").font(.system(size: 13, weight: .bold))
                    if !isMe && !message.isReceived {
                        Button("确认收款") { onReceiveTransfer() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x2C8A5A))
                            .padding(.top, 3)
                    } else if message.isReceived {
                        Text(isMe ? "对方已收款 · ¥\(message.amount ?? 0, specifier: "%.2f")" : "已被接收 · ¥\(message.amount ?? 0, specifier: "%.2f")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0x2C8A5A))
                    }
                }.foregroundStyle(Macaron.ink)
            }
            .padding(12).frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xFFF1D9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white, lineWidth: 1))
        } else if let data = message.imageData, let image = UIImage(data: data) {
            Button { onImageTap(data) } label: {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 285, maxHeight: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous)).padding(7)
                    .background(isMe ? outgoingColor : incomingColor, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.white.opacity(0.95), lineWidth: 1.4))
            }.buttonStyle(FluidPressButtonStyle())
        } else {
            Text(message.text).font(.system(size: fontSize)).foregroundStyle(textColor)
                .contentTransition(.interpolate)
                .animation(ChatMotion.text, value: message.text)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 15).padding(.vertical, 11)
                .background(isMe ? outgoingColor : incomingColor, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
        }
    }
}


private struct AddContentMenu: View {
    let onDismiss: () -> Void
    let onPhoto: () -> Void
    let onRedPacket: () -> Void
    let onTransfer: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Capsule()
                    .fill(Color(hex: 0xD9DEE8))
                    .frame(width: 34, height: 4)
                    .padding(.top, 10)

                HStack {
                    Text("添加内容")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Spacer()
                    Button("取消", action: onDismiss)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                }

                HStack(spacing: 12) {
                    AddContentMenuItem(symbol: "photo", title: "照片", tint: Color(hex: 0xDCEBFA), action: onPhoto)
                    AddContentMenuItem(symbol: "gift", title: "红包", tint: Color(hex: 0xF9E2DF), action: onRedPacket)
                    AddContentMenuItem(symbol: "yensign.circle", title: "转账", tint: Color(hex: 0xFBEBD2), action: onTransfer)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(Color(hex: 0xE9EDF3), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
    }
}

private struct AddContentMenuItem: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                    .frame(width: 54, height: 54)
                    .background(tint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Macaron.ink)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(FluidPressButtonStyle())
    }
}

private struct PhotoPreviewView: View {
    let images: [Data]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var zoomScale: CGFloat = 1
    @State private var zoomStartScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var dragTranslation: CGFloat = 0

    init(images: [Data], initialIndex: Int) {
        self.images = images
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: min(max(0, initialIndex), max(0, images.count - 1)))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Macaron.background.ignoresSafeArea()
                GeometryReader { geometry in
                    if images.indices.contains(currentIndex), let image = UIImage(data: images[currentIndex]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .scaleEffect(zoomScale)
                            .offset(
                                x: zoomScale > 1.02 ? imageOffset.width : dragTranslation,
                                y: zoomScale > 1.02 ? imageOffset.height : 0
                            )
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        zoomScale = min(max(zoomStartScale * value, 1), 5)
                                        if zoomScale <= 1.02 {
                                            imageOffset = .zero
                                            dragStartOffset = .zero
                                        }
                                    }
                                    .onEnded { _ in
                                        zoomStartScale = zoomScale
                                        if zoomScale <= 1.02 {
                                            withAnimation(ChatMotion.layout) {
                                                imageOffset = .zero
                                                dragStartOffset = .zero
                                            }
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        if zoomScale > 1.02 {
                                            imageOffset = CGSize(
                                                width: dragStartOffset.width + value.translation.width,
                                                height: dragStartOffset.height + value.translation.height
                                            )
                                        } else {
                                            dragTranslation = value.translation.width
                                        }
                                    }
                                    .onEnded { value in
                                        if zoomScale > 1.02 {
                                            dragStartOffset = imageOffset
                                        } else if value.translation.width < -65 {
                                            changeImage(by: 1)
                                        } else if value.translation.width > 65 {
                                            changeImage(by: -1)
                                        } else {
                                            withAnimation(ChatMotion.layout) { dragTranslation = 0 }
                                        }
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(ChatMotion.layout) {
                                    if zoomScale > 1.02 {
                                        zoomScale = 1
                                        zoomStartScale = 1
                                        imageOffset = .zero
                                        dragStartOffset = .zero
                                    } else {
                                        zoomScale = 2.4
                                        zoomStartScale = 2.4
                                    }
                                }
                            }
                            .frame(width: geometry.size.width - 32, height: geometry.size.height - 32)
                            // Clip after scaling/offset so the preview keeps fixed rounded corners.
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .padding(16)
                    } else {
                        ContentUnavailableView("无法显示图片", systemImage: "photo")
                    }
                }
            }
            .navigationTitle(images.count > 1 ? "\(currentIndex + 1) / \(images.count)" : "图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func changeImage(by delta: Int) {
        let next = currentIndex + delta
        guard images.indices.contains(next) else {
            withAnimation(ChatMotion.layout) { dragTranslation = 0 }
            return
        }
        withAnimation(ChatMotion.layout) {
            currentIndex = next
            zoomScale = 1
            imageOffset = .zero
            dragStartOffset = .zero
            dragTranslation = 0
        }
    }
}
private struct MinimizedCallPill: View {
    @ObservedObject var call: SimulatedCall
    @Binding var position: CGPoint?
    let onRestore: () -> Void
    @State private var dragOrigin: CGPoint?
    @State private var didDrag = false

    var body: some View {
        GeometryReader { geometry in
            let current = position ?? CGPoint(x: geometry.size.width - 104, y: 76)
            Button {
                if !didDrag { onRestore() }
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(Color(hex: 0xE5F1FD)).frame(width: 34, height: 34)
                        Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x4F91D2))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.isVideo ? "视频通话中" : "语音通话中")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Text("轻点返回 · 可拖动")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(width: 184, height: 56)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
                .shadow(color: Color(hex: 0x607FA5).opacity(0.17), radius: 14, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            .position(current)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = current
                            didDrag = false
                        }
                        didDrag = true
                        let origin = dragOrigin ?? current
                        let x = min(max(94, origin.x + value.translation.width), max(94, geometry.size.width - 94))
                        let y = min(max(36, origin.y + value.translation.height), max(36, geometry.size.height - 36))
                        position = CGPoint(x: x, y: y)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { didDrag = false }
                    }
            )
        }
    }
}

private struct SimulatedCallView: View {
    let name: String
    let meName: String
    let avatarData: Data?
    let meAvatarData: Data?
    @ObservedObject var call: SimulatedCall
    let onMinimize: () -> Void
    let onEnd: (Int) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xF4F7FC), Color(hex: 0xE8F1FB), Color(hex: 0xF9EFF5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.8), in: Circle())
                    }
                    .accessibilityLabel("返回聊天")
                    Text(call.isVideo ? "视频通话" : "语音通话")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                    Spacer()
                    Text("通话中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.75), in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                Spacer()

                if call.isVideo {
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .fill(Color(hex: 0xDDEAF7))
                            if call.isCameraOn {
                                if let videoPlayer = call.videoPlayer {
                                    VideoPlayer(player: videoPlayer)
                                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                } else if let selectedImage = call.selectedImage {
                                    Image(uiImage: selectedImage)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                } else {
                                    VStack(spacing: 14) {
                                        IdentityAvatar(data: avatarData, name: name, size: 118, tint: Macaron.pink)
                                        Text(name)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(Macaron.ink)
                                        Text("视频画面")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Macaron.secondary)
                                    }
                                }
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "video.slash")
                                        .font(.system(size: 34, weight: .light))
                                    Text("摄像头画面已关闭")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(Macaron.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    }
                    .padding(.horizontal, 18)
                } else {
                    VStack(spacing: 18) {
                        IdentityAvatar(data: avatarData, name: name, size: 126, tint: Macaron.pink)
                            .shadow(color: Color(hex: 0xA8C8E8).opacity(0.35), radius: 22, y: 8)
                        Text(name)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        Text(call.isConnected ? callDurationText(at: context.date) : "正在呼叫…")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Macaron.ink)
                        Text(call.isConnected ? "通话已接通" : "等待接通")
                            .font(.system(size: 12))
                            .foregroundStyle(Macaron.secondary)
                    }
                }
                .padding(.top, 26)

                Spacer()

                HStack(spacing: 24) {
                    CallControlButton(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", title: "静音", isActive: call.isMuted) {
                        call.isMuted.toggle()
                    }
                    CallControlButton(symbol: call.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", title: "扬声器", isActive: call.isSpeakerOn) {
                        call.isSpeakerOn.toggle()
                    }
                    if call.isVideo {
                        CallControlButton(symbol: call.isCameraOn ? "video.fill" : "video.slash.fill", title: "摄像头", isActive: call.isCameraOn) {
                            call.isCameraOn.toggle()
                        }
                    }
                }
                .padding(.bottom, 28)

                if call.isVideo {
                    HStack(spacing: 24) {
                        VStack(spacing: 6) {
                            IdentityAvatar(data: meAvatarData, name: meName, size: 46, tint: Macaron.blue)
                            Text("我")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Macaron.ink)
                        }
                        .frame(width: 76, height: 88)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white, lineWidth: 1))
                        .shadow(color: Color(hex: 0x9EB5CE).opacity(0.10), radius: 8, x: 0, y: 3)

                        Button(action: endCall) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Color(hex: 0xE8788D), in: Circle())
                        }
                        .accessibilityLabel("结束通话")

                        PhotosPicker(selection: $call.selectedMedia, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 66, height: 66)
                                .background(Color(hex: 0x8793A2), in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                        }
                        .accessibilityLabel("添加图片或视频")
                    }
                    .padding(.bottom, 35)
                } else {
                    Button(action: endCall) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(Color(hex: 0xE8788D), in: Circle())
                    }
                    .accessibilityLabel("结束通话")
                    .padding(.bottom, 35)
                }
            }
        }
        .onChange(of: call.selectedMedia) { _, item in
            guard let item else { return }
            Task {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let imported = try? await item.loadTransferable(type: PickedCallVideo.self) else {
                        call.showMediaImportError = true
                        call.selectedMedia = nil
                        return
                    }
                    if let oldURL = call.selectedVideoURL { try? FileManager.default.removeItem(at: oldURL) }
                    call.videoPlayer?.pause()
                    call.selectedImage = nil
                    call.selectedVideoURL = imported.url
                    let player = AVPlayer(url: imported.url)
                    call.videoPlayer = player
                    player.play()
                } else {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        call.showMediaImportError = true
                        call.selectedMedia = nil
                        return
                    }
                    if let oldURL = call.selectedVideoURL { try? FileManager.default.removeItem(at: oldURL) }
                    call.videoPlayer?.pause()
                    call.videoPlayer = nil
                    call.selectedVideoURL = nil
                    call.pendingCropImage = image
                }
                call.selectedMedia = nil
            }
        }
        .task {
            guard !call.didEnd, !call.isConnected else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !call.didEnd, !call.isConnected else { return }
            call.connectedAt = .now
            withAnimation(.easeInOut(duration: 0.25)) { call.isConnected = true }
        }
        .alert("无法载入媒体", isPresented: $call.showMediaImportError) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("这张图片或视频暂时无法读取，请换一个文件再试。")
        }
        .sheet(isPresented: Binding(
            get: { call.pendingCropImage != nil },
            set: { if !$0 { call.pendingCropImage = nil } }
        )) {
            if let image = call.pendingCropImage {
                ImageCropperSheet(image: image, shape: .roundedSquare, onCancel: {
                    call.pendingCropImage = nil
                }) { cropped in
                    call.selectedImage = cropped
                    call.pendingCropImage = nil
                }
            }
        }
        .onAppear {
            call.videoPlayer?.play()
        }
        .onDisappear {
            call.videoPlayer?.pause()
        }
    }

    private func callDurationText(at date: Date) -> String {
        guard let connectedAt = call.connectedAt else { return "00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(connectedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func endCall() {
        guard !call.didEnd else { return }
        call.didEnd = true
        let duration = call.connectedAt.map { max(0, Int(Date.now.timeIntervalSince($0))) } ?? 0
        call.videoPlayer?.pause()
        if let url = call.selectedVideoURL { try? FileManager.default.removeItem(at: url) }
        onEnd(duration)
    }
}


private struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var avatarSelection: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var pendingCropImage: UIImage?
    let onAdd: (String, String, Data?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("好友资料") {
                    HStack(spacing: 14) {
                        IdentityAvatar(data: avatarData, name: name.isEmpty ? "新" : name, size: 62, tint: Macaron.pink)
                        PhotosPicker(selection: $avatarSelection, matching: .images) {
                            Label("选择头像", systemImage: "photo")
                        }
                    }
                    TextField("好友昵称", text: $name)
                    TextField("个性签名（可选）", text: $bio)
                }
                Section {
                    Text("新账号会获得独立编号和二维码，并只加入当前账号的好友关系；其他账号不会自动成为好友。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Macaron.background)
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(name, bio, avatarData)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pendingCropImage = image
                    }
                    avatarSelection = nil
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingCropImage != nil },
                set: { if !$0 { pendingCropImage = nil } }
            )) {
                if let image = pendingCropImage {
                    ImageCropperSheet(image: image, shape: .circle, onCancel: {
                        pendingCropImage = nil
                    }) { cropped in
                        avatarData = cropPreviewData(cropped)
                        pendingCropImage = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct GroupMemberProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let member: ChatContact
    let isFriend: Bool
    let onAddFriend: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                IdentityAvatar(data: member.avatarData, name: member.name, size: 86, tint: Macaron.pink)
                Text(member.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Macaron.ink)
                Text(member.bio.isEmpty ? "这个群成员还没有填写个性签名。" : member.bio)
                    .font(.system(size: 13)).foregroundStyle(Macaron.secondary).multilineTextAlignment(.center)
                Text(isFriend ? "已是你的好友" : "对方当前不是你的好友")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isFriend ? Color(hex: 0x65B99A) : Color(hex: 0xD18A55))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(hex: 0xF4F6F9), in: Capsule())
                if !isFriend {
                    Button {
                        onAddFriend()
                        dismiss()
                    } label: {
                        Label("添加好友", systemImage: "person.badge.plus")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Color(hex: 0x78B7F2), in: Capsule())
                    }
                    .buttonStyle(FluidPressButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Macaron.background)
            .navigationTitle("群成员资料").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible).presentationCornerRadius(28)
    }
}

private struct FriendProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contact: ChatContact
    @State private var avatarSelection: PhotosPickerItem?
    @State private var pendingCropImage: UIImage?
    @State private var showMomentEditor = false
    @State private var momentDraft = ""
    @State private var editingMomentID: UUID?
    let onUpdate: (ChatContact) -> Void

    init(contact: ChatContact, onUpdate: @escaping (ChatContact) -> Void) {
        _contact = State(initialValue: contact)
        self.onUpdate = onUpdate
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $avatarSelection, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                IdentityAvatar(data: contact.avatarData, name: contact.name, size: 82, tint: Macaron.pink)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 25, height: 25)
                                    .background(Color(hex: 0x83B9EF), in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                        .buttonStyle(FluidPressButtonStyle())
                        TextField("好友昵称", text: $contact.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Macaron.ink)
                            .multilineTextAlignment(.center)
                        TextField("好友个性签名", text: $contact.bio, axis: .vertical)
                            .font(.system(size: 13))
                            .foregroundStyle(Macaron.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("好友笔记")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        TextEditor(text: $contact.notes)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(8)
                            .background(Macaron.background, in: RoundedRectangle(cornerRadius: 14))
                        Text("这里只是本机保存的好友备注和记录。")
                            .font(.system(size: 10))
                            .foregroundStyle(Macaron.secondary)
                    }
                    .padding(15)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))

                    VStack(spacing: 12) {
                        HStack {
                            Text("他的朋友圈")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Macaron.ink)
                            Spacer()
                            Button {
                                editingMomentID = nil
                                momentDraft = ""
                                showMomentEditor = true
                            } label: {
                                Label("发布动态", systemImage: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x4F91D2))
                            }
                        }
                        .padding(.horizontal, 4)

                        if contact.moments.isEmpty {
                            EmptyHint(symbol: "text.bubble", title: "暂时没有动态", subtitle: "可以在这里记录这位好友的朋友圈内容。")
                                .padding(.vertical, 20)
                        } else {
                            ForEach(contact.moments) { post in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(post.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Macaron.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let mediaData = post.mediaData {
                                        MomentMediaView(data: mediaData, mediaType: post.mediaType)
                                    }
                                    Text(post.date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.system(size: 10))
                                        .foregroundStyle(Macaron.secondary)
                                }
                                .padding(15)
                                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .transition(.chatCinematic)
                                .contextMenu {
                                    Button("编辑动态", systemImage: "pencil") {
                                        editingMomentID = post.id
                                        momentDraft = post.text
                                        showMomentEditor = true
                                    }
                                    Button("删除动态", systemImage: "trash", role: .destructive) {
                                        contact.moments.removeAll { $0.id == post.id }
                                    }
                                }
                            }
                            .animation(ChatMotion.layout, value: contact.moments.map { $0.id })
                        }
                    }
                }
                .padding(16)
            }
            .background(Macaron.background)
            .navigationTitle("好友主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onUpdate(contact)
                        dismiss()
                    }
                }
            }
            .onChange(of: contact.name) { _, _ in onUpdate(contact) }
            .onChange(of: contact.bio) { _, _ in onUpdate(contact) }
            .onChange(of: contact.notes) { _, _ in onUpdate(contact) }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pendingCropImage = image
                    }
                    avatarSelection = nil
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingCropImage != nil },
                set: { if !$0 { pendingCropImage = nil } }
            )) {
                if let image = pendingCropImage {
                    ImageCropperSheet(image: image, shape: .circle, onCancel: {
                        pendingCropImage = nil
                    }) { cropped in
                        contact.avatarData = cropPreviewData(cropped)
                        onUpdate(contact)
                        pendingCropImage = nil
                    }
                }
            }
            .sheet(isPresented: $showMomentEditor) {
                MomentEditorSheet(
                    title: editingMomentID == nil ? "发布好友动态" : "编辑好友动态",
                    initialText: momentDraft,
                    initialMediaData: editingMomentID.flatMap { id in contact.moments.first(where: { $0.id == id })?.mediaData },
                    initialMediaType: editingMomentID.flatMap { id in contact.moments.first(where: { $0.id == id })?.mediaType }
                ) { text, mediaData, mediaType in
                    if let id = editingMomentID,
                       let index = contact.moments.firstIndex(where: { $0.id == id }) {
                        contact.moments[index].text = text
                        contact.moments[index].date = .now
                        contact.moments[index].mediaData = mediaData
                        contact.moments[index].mediaType = mediaType
                    } else {
                        contact.moments.insert(MomentPost(text: text, mediaData: mediaData, mediaType: mediaType), at: 0)
                    }
                    onUpdate(contact)
                }
            }
            .onChange(of: contact.moments.count) { _, _ in onUpdate(contact) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct MomentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var mediaSelection: PhotosPickerItem?
    @State private var pendingCropImage: UIImage?
    @State private var mediaData: Data?
    @State private var mediaType: String?
    let title: String
    let onSave: (String, Data?, String?) -> Void

    init(title: String, initialText: String, initialMediaData: Data? = nil, initialMediaType: String? = nil,
         onSave: @escaping (String, Data?, String?) -> Void) {
        self.title = title
        _text = State(initialValue: initialText)
        _mediaData = State(initialValue: initialMediaData)
        _mediaType = State(initialValue: initialMediaType)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                PhotosPicker(selection: $mediaSelection, matching: .any(of: [.images, .videos])) {
                    Label(mediaData == nil ? "添加照片或视频" : "更换照片或视频", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                        .padding(12)
                        .background(Macaron.blue, in: Capsule())
                }
                if let mediaData {
                    MomentMediaView(data: mediaData, mediaType: mediaType)
                        .frame(maxHeight: 170)
                    Button("移除媒体", role: .destructive) {
                        self.mediaData = nil
                        mediaType = nil
                    }
                    .font(.system(size: 12))
                }
                Text("动态只保存在本机，可以随时再次编辑或删除。")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Macaron.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty || mediaData != nil else { return }
                        onSave(value, mediaData, mediaType)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mediaData == nil)
                }
            }
            .onChange(of: mediaSelection) { _, item in
                guard let item else { return }
                Task {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            mediaData = data
                            mediaType = "video"
                        }
                    } else if let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) {
                        pendingCropImage = image
                    }
                    mediaSelection = nil
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingCropImage != nil },
                set: { if !$0 { pendingCropImage = nil } }
            )) {
                if let image = pendingCropImage {
                    ImageCropperSheet(image: image, shape: .roundedSquare, onCancel: {
                        pendingCropImage = nil
                    }) { cropped in
                        mediaData = cropPreviewData(cropped)
                        mediaType = "image"
                        pendingCropImage = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct MomentMediaView: View {
    let data: Data
    let mediaType: String?
    @State private var isPreviewPresented = false

    var body: some View {
        Button {
            isPreviewPresented = true
        } label: {
            MomentCommentThumbnail(data: data, mediaType: mediaType)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.36), in: Circle())
                        .padding(5)
                }
        }
        .buttonStyle(FluidPressButtonStyle())
        .accessibilityLabel(mediaType == "video" ? "放大预览朋友圈视频" : "放大预览朋友圈图片")
        .sheet(isPresented: $isPreviewPresented) {
            MomentMediaPreviewSheet(data: data, mediaType: mediaType)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }
}


private struct MomentCommentTarget: Identifiable { let id: UUID }

private struct MomentMediaPreviewItem: Identifiable {
    let id = UUID()
    let data: Data
    let mediaType: String?
}

private struct MomentCommentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var comments: [MomentComment]
    @State private var selectedAuthor: String
    @State private var replyingTo: MomentComment?
    @State private var editingCommentID: UUID?
    @State private var draftMediaData: Data?
    @State private var draftMediaType: String?
    @State private var mediaSelection: PhotosPickerItem?
    @State private var previewMedia: MomentMediaPreviewItem?
    let authorOptions: [String]
    let onSend: (MomentComment) -> Void
    let onUpdate: (MomentComment) -> Void
    let onDelete: (UUID) -> Void

    init(
        comments: [MomentComment],
        authorOptions: [String],
        onSend: @escaping (MomentComment) -> Void,
        onUpdate: @escaping (MomentComment) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        _comments = State(initialValue: comments)
        self.authorOptions = authorOptions.isEmpty ? ["我"] : authorOptions
        _selectedAuthor = State(initialValue: authorOptions.first ?? "我")
        self.onSend = onSend
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                commentsList
                composer
            }
            .background(Macaron.background)
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(item: $previewMedia) { item in
            MomentMediaPreviewSheet(data: item.data, mediaType: item.mediaType)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .onChange(of: mediaSelection) { _, item in
            guard let item else { return }
            Task {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        draftMediaData = data
                        draftMediaType = isVideo ? "video" : "image"
                    }
                }
                await MainActor.run { mediaSelection = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if comments.isEmpty {
                    EmptyHint(symbol: "bubble.left", title: "还没有评论", subtitle: "来发表第一条评论吧。")
                        .padding(.top, 55)
                } else {
                    ForEach(comments) { comment in
                        commentRow(comment)
                    }
                }
            }
            .padding(16)
        }
    }

    private func commentRow(_ comment: MomentComment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(comment.author)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4F91D2))
                if let target = comment.replyToAuthor, !target.isEmpty {
                    Text("回复").font(.system(size: 10)).foregroundStyle(Macaron.secondary)
                    Text(target).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x4F91D2))
                }
                Spacer()
                Button {
                    withAnimation(ChatMotion.layout) {
                        replyingTo = comment
                        editingCommentID = nil
                        draft = ""
                        draftMediaData = nil
                        draftMediaType = nil
                    }
                } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                }
            }
            if !comment.text.isEmpty {
                Text(comment.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Macaron.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let data = comment.mediaData {
                Button {
                    previewMedia = MomentMediaPreviewItem(data: data, mediaType: comment.mediaType)
                } label: {
                    MomentCommentThumbnail(data: data, mediaType: comment.mediaType)
                }
                .buttonStyle(FluidPressButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if comment.author == selectedAuthor {
                Button("编辑评论", systemImage: "pencil") {
                    beginEditing(comment)
                }
                Button("删除评论", systemImage: "trash", role: .destructive) {
                    withAnimation(ChatMotion.layout) { comments.removeAll { $0.id == comment.id } }
                    onDelete(comment.id)
                }
            }
            Button("回复评论", systemImage: "arrowshape.turn.up.left") {
                replyingTo = comment
                editingCommentID = nil
                draft = ""
                draftMediaData = nil
                draftMediaType = nil
            }
        }
        .transition(.chatCinematic)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if let target = replyingTo {
                HStack(spacing: 6) {
                    Text("正在回复").foregroundStyle(Macaron.secondary)
                    Text(target.author).fontWeight(.semibold).foregroundStyle(Color(hex: 0x4F91D2))
                    Spacer()
                    Button {
                        withAnimation(ChatMotion.layout) { replyingTo = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Macaron.secondary)
                    }
                }
                .font(.system(size: 11))
            } else if editingCommentID != nil {
                HStack {
                    Text("正在编辑评论")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                    Spacer()
                    Button("取消编辑") { cancelEditing() }
                        .font(.system(size: 11))
                        .foregroundStyle(Macaron.secondary)
                }
            }

            HStack {
                Text("评论身份")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                Menu {
                    ForEach(authorOptions, id: \.self) { name in
                        Button {
                            withAnimation(ChatMotion.layout) { selectedAuthor = name }
                        } label: {
                            if selectedAuthor == name { Label(name, systemImage: "checkmark") }
                            else { Text(name) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedAuthor).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0x4F91D2))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: 0xE8F3FF), in: Capsule())
                }
                Spacer()
            }

            if let data = draftMediaData {
                HStack(spacing: 9) {
                    MomentCommentThumbnail(data: data, mediaType: draftMediaType)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draftMediaType == "video" ? "已添加视频" : "已添加图片")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Button("移除附件") {
                            draftMediaData = nil
                            draftMediaType = nil
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xC86E82))
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                TextField(editingCommentID == nil ? (replyingTo.map { "回复 \($0.author)…" } ?? "写下你的评论…") : "编辑评论内容…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(11)
                    .background(Macaron.card, in: Capsule())

                PhotosPicker(selection: $mediaSelection, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: 0xE8F3FF), in: Circle())
                }
                .accessibilityLabel("添加图片或视频")

                Button(action: submitComment) {
                    Image(systemName: editingCommentID == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 29))
                        .foregroundStyle(Color(hex: 0x5D9FE2))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftMediaData == nil)
            }
        }
        .padding(12)
        .background(Macaron.background)
    }

    private func beginEditing(_ comment: MomentComment) {
        withAnimation(ChatMotion.layout) {
            editingCommentID = comment.id
            replyingTo = nil
            selectedAuthor = comment.author
            draft = comment.text
            draftMediaData = comment.mediaData
            draftMediaType = comment.mediaType
        }
    }

    private func cancelEditing() {
        withAnimation(ChatMotion.layout) {
            editingCommentID = nil
            replyingTo = nil
            draft = ""
            draftMediaData = nil
            draftMediaType = nil
        }
    }

    private func submitComment() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || draftMediaData != nil else { return }

        if let editingCommentID, let index = comments.firstIndex(where: { $0.id == editingCommentID }) {
            var updated = comments[index]
            updated.text = value
            updated.mediaData = draftMediaData
            updated.mediaType = draftMediaType
            withAnimation(ChatMotion.layout) { comments[index] = updated }
            onUpdate(updated)
        } else {
            let comment = MomentComment(
                author: selectedAuthor,
                text: value,
                replyToAuthor: replyingTo?.author,
                mediaData: draftMediaData,
                mediaType: draftMediaType
            )
            withAnimation(ChatMotion.layout) { comments.append(comment) }
            onSend(comment)
        }
        cancelEditing()
    }
}

private struct MomentCommentThumbnail: View {
    let data: Data
    let mediaType: String?

    var body: some View {
        Group {
            if mediaType == "video" {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(hex: 0xDCEAF7))
                    Image(systemName: "video.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                    Text("视频")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                        .offset(y: 21)
                }
            } else if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Macaron.blue)
            }
        }
        .frame(width: 88, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white, lineWidth: 1))
    }
}

private struct MomentMediaPreviewSheet: View {
    let data: Data
    let mediaType: String?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Macaron.background.ignoresSafeArea()
                Group {
                    if mediaType == "video" {
                        if let player {
                            VideoPlayer(player: player)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        } else {
                            ProgressView().tint(Color(hex: 0x5799D9))
                        }
                    } else if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(16)
            }
            .navigationTitle(mediaType == "video" ? "视频预览" : "图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                guard mediaType == "video" else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("comment-preview-\(UUID().uuidString).mov")
                do {
                    try data.write(to: url, options: .atomic)
                    let next = AVPlayer(url: url)
                    next.play()
                    player = next
                } catch {
                    NSLog("CustomChat comment video preview error: %@", error.localizedDescription)
                }
            }
            .onDisappear { player?.pause(); player = nil }
        }
    }
}

private struct MomentFeedItem: Identifiable {
    let author: String
    let avatarData: Data?
    let post: MomentPost
    var id: UUID { post.id }
}

private struct AccountQRCodeView: View {
    let accountID: UUID
    let accountNumber: String

    private var generatedImage: UIImage? {
        let payload = "customchat://account/\(accountID.uuidString)?number=\(accountNumber)"
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        Group {
            if let generatedImage {
                Image(uiImage: generatedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
    }
}

private struct AccountQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: ChatContact

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                IdentityAvatar(data: account.avatarData, name: account.name, size: 76, tint: Macaron.blue)
                Text(account.name)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Macaron.ink)
                VStack(spacing: 6) {
                    Text("CustomChat 账号编号")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                    Text(account.accountNumber ?? "未分配")
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Macaron.ink)
                }
                AccountQRCodeView(accountID: account.id, accountNumber: account.accountNumber ?? "")
                    .frame(width: 230, height: 230)
                Text("这是当前账号的专属二维码。其他账号不会共用此身份。")
                    .font(.system(size: 12))
                    .foregroundStyle(Macaron.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(Macaron.background)
            .navigationTitle("我的二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

private struct VirtualScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [ChatContact]
    let currentAccountID: UUID
    let friendIDs: Set<UUID>
    let onAdd: (UUID) -> Bool
    @State private var selectedAccountID: UUID?
    @State private var searchText = ""
    @State private var scanProgress: CGFloat = -1
    @State private var didAdd = false
    @State private var addedAccountIDs: Set<UUID> = []

    private func isAlreadyFriend(_ accountID: UUID) -> Bool {
        friendIDs.contains(accountID) || addedAccountIDs.contains(accountID)
    }

    private var visibleAccounts: [ChatContact] {
        accounts.filter { $0.id != currentAccountID }.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.accountNumber ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedAccount: ChatContact? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: 0xEAF3FC))
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 78, weight: .ultraLight))
                                .foregroundStyle(Color(hex: 0x76AEE4).opacity(0.55))
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color(hex: 0x69A8E4), lineWidth: 2)
                                .padding(18)
                            VStack {
                                Rectangle()
                                    .fill(Color(hex: 0x5D9FE0))
                                    .frame(height: 2)
                                    .shadow(color: Color(hex: 0x5D9FE0).opacity(0.55), radius: 5)
                                    .offset(y: scanProgress * 72)
                                Spacer(minLength: 0)
                            }
                            .padding(30)
                        }
                        .frame(width: 222, height: 174)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .onAppear {
                            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: true)) {
                                scanProgress = 1
                            }
                        }
                        Text("虚拟扫一扫")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Text("选择一个已创建的账号，模拟识别它的二维码")
                            .font(.system(size: 12))
                            .foregroundStyle(Macaron.secondary)
                        Label("本地模拟 · 不调用相机 · 无需相机权限", systemImage: "iphone")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(hex: 0x5799D9))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Color(hex: 0xEAF3FC), in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Macaron.secondary)
                        TextField("搜索昵称或账号编号", text: $searchText)
                            .font(.system(size: 14))
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color(hex: 0xEEF1F6), in: Capsule())

                    VStack(alignment: .leading, spacing: 10) {
                        Text("可识别的虚拟账号")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        if visibleAccounts.isEmpty {
                            EmptyHint(symbol: "person.crop.circle.badge.questionmark", title: "没有找到账号", subtitle: "请检查昵称或账号编号。")
                                .padding(.vertical, 14)
                        } else {
                            ForEach(visibleAccounts) { account in
                                Button {
                                    withAnimation(ChatMotion.layout) {
                                        selectedAccountID = account.id
                                        didAdd = false
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        IdentityAvatar(data: account.avatarData, name: account.name, size: 46, tint: Macaron.blue)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(account.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(Macaron.ink)
                                            Text("账号编号  \(account.accountNumber ?? "未分配")")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Macaron.secondary)
                                        }
                                        Spacer()
                                        AccountQRCodeView(accountID: account.id, accountNumber: account.accountNumber ?? "")
                                            .frame(width: 48, height: 48)
                                        Image(systemName: selectedAccountID == account.id ? "checkmark.circle.fill" : "chevron.right")
                                            .foregroundStyle(selectedAccountID == account.id ? Color(hex: 0x65B99A) : Macaron.secondary)
                                    }
                                    .padding(11)
                                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(selectedAccountID == account.id ? Color(hex: 0x91C8F2) : .clear, lineWidth: 1.5))
                                }
                                .buttonStyle(FluidPressButtonStyle())
                            }
                        }
                    }

                    if let account = selectedAccount {
                        VStack(spacing: 13) {
                            Text("已识别账号")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x5799D9))
                            IdentityAvatar(data: account.avatarData, name: account.name, size: 60, tint: Macaron.blue)
                            Text(account.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Macaron.ink)
                            Text("账号编号  \(account.accountNumber ?? "未分配")")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Macaron.secondary)
                            AccountQRCodeView(accountID: account.id, accountNumber: account.accountNumber ?? "")
                                .frame(width: 150, height: 150)
                            Button {
                                if onAdd(account.id) {
                                    addedAccountIDs.insert(account.id)
                                    didAdd = true
                                }
                            } label: {
                                Label(
                                    didAdd ? "已添加好友" : (isAlreadyFriend(account.id) ? "已添加" : "添加到通讯录"),
                                    systemImage: didAdd || isAlreadyFriend(account.id) ? "checkmark" : "person.badge.plus"
                                )
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(hex: 0x72B9A0), in: Capsule())
                            }
                            .disabled(didAdd || isAlreadyFriend(account.id))
                            .opacity(didAdd || isAlreadyFriend(account.id) ? 0.65 : 1)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .transition(.chatCinematic)
                    }
                }
                .padding(18)
                .padding(.bottom, 20)
            }
            .background(Macaron.background)
            .navigationTitle("扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

private struct AccountManagementView: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [ChatContact]
    let currentAccountID: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("每个账号拥有独立的资料、好友关系、聊天列表和钱包。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 3)
                    ForEach(accounts) { account in
                        Button {
                            onSelect(account.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                IdentityAvatar(data: account.avatarData, name: account.name, size: 50, tint: Macaron.blue)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(account.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Macaron.ink)
                                    Text("账号编号  \(account.accountNumber ?? "未分配")")
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Macaron.secondary)
                                }
                                Spacer()
                                if account.id == currentAccountID {
                                    Label("当前使用", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x65B99A))
                                } else {
                                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Macaron.secondary)
                                }
                            }
                            .padding(13)
                            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(FluidPressButtonStyle())
                    }
                }
                .padding(18)
            }
            .background(Macaron.background)
            .navigationTitle("账号管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

private struct SwipeRevealRow<Content: View, Actions: View>: View {
    let content: Content
    let actions: Actions
    let revealOnLeft: Bool
    @State private var revealWidth: CGFloat = 0

    init(
        revealOnLeft: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.revealOnLeft = revealOnLeft
        self.content = content()
        self.actions = actions()
    }

    private var actionWidth: CGFloat { revealOnLeft ? 92 : 160 }

    var body: some View {
        ZStack(alignment: revealOnLeft ? .trailing : .leading) {
            actions
                .frame(maxWidth: .infinity, alignment: revealOnLeft ? .trailing : .leading)
                .opacity(revealWidth > 0 ? 1 : 0)
            content
                .offset(x: revealOnLeft ? -revealWidth : revealWidth)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            let horizontal = value.translation.width
                            withAnimation(ChatMotion.layout) {
                                if revealOnLeft {
                                    if horizontal < -42 { revealWidth = actionWidth }
                                    else if horizontal > 35 || revealWidth > 0 { revealWidth = 0 }
                                } else {
                                    if horizontal > 42 { revealWidth = actionWidth }
                                    else if horizontal < -35 || revealWidth > 0 { revealWidth = 0 }
                                }
                            }
                        }
                )
        }
        .clipped()
        .animation(ChatMotion.layout, value: revealWidth)
    }
}

private struct PersonaSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentPersonaID: UUID?
    let ownName: String
    let ownAvatar: Data?
    let ownAccountNumber: String
    let contacts: [ChatContact]
    let onSelect: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    personaRow(name: ownName, avatar: ownAvatar, subtitle: "主账号 · 账号编号 \(ownAccountNumber)", isSelected: currentPersonaID == nil) {
                        onSelect(nil)
                        dismiss()
                    }
                    ForEach(contacts) { contact in
                        personaRow(name: contact.name, avatar: contact.avatarData, subtitle: "账号编号 \(contact.accountNumber ?? "未分配") · 独立资料与好友列表", isSelected: currentPersonaID == contact.id) {
                            onSelect(contact.id)
                            dismiss()
                        }
                    }
                }
                .padding(16)
            }
            .background(Macaron.background)
            .navigationTitle("切换账号")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func personaRow(name: String, avatar: Data?, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IdentityAvatar(data: avatar, name: name, size: 48, tint: Macaron.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Macaron.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(hex: 0x65B99A))
                }
            }
            .padding(13)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(FluidPressButtonStyle())
    }
}

private struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var selectedIDs: Set<UUID> = []
    let contacts: [ChatContact]
    let onCreate: (String, [UUID]) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("群聊名称") {
                    TextField("例如：周末出游", text: $groupName)
                }
                Section("邀请好友（至少选择 1 位）") {
                    if contacts.isEmpty {
                        Text("请先添加好友，再创建群聊。")
                            .foregroundStyle(Macaron.secondary)
                    } else {
                        ForEach(contacts) { contact in
                            Button {
                                if selectedIDs.contains(contact.id) {
                                    selectedIDs.remove(contact.id)
                                } else {
                                    selectedIDs.insert(contact.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    IdentityAvatar(data: contact.avatarData, name: contact.name, size: 38, tint: Macaron.pink)
                                    Text(contact.name).foregroundStyle(Macaron.ink)
                                    Spacer()
                                    Image(systemName: selectedIDs.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(contact.id) ? Color(hex: 0x69B99A) : Macaron.secondary)
                                }
                            }
                            .listRowBackground(Macaron.card)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Macaron.background)
            .navigationTitle("创建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(groupName, Array(selectedIDs))
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct VoiceComposerPanel: View {
    @ObservedObject var capture: VoiceCaptureManager
    @Binding var isTextMode: Bool
    let onWaveformTap: () -> Void
    let onSendWaveform: () -> Void
    let onSendText: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isTextMode {
                textContent
                    .transition(.chatCinematic)
            } else {
                waveformContent
                    .transition(.chatCinematic)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: 0xE7EDF4), lineWidth: 1))
        .shadow(color: Color(hex: 0x9EB5CE).opacity(0.10), radius: 14, x: 0, y: 5)
        .animation(ChatMotion.layout, value: isTextMode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isTextMode ? "text.alignleft" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x4F91D2))
            Text(isTextMode ? "语音转文字" : "语音输入")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Macaron.ink)
            Spacer()
            Text(capture.isPreparing ? "正在准备模型" : capture.isRecording ? "正在聆听" : capture.isFinalizing ? "正在整理识别结果" : capture.hasCapture ? "录音完成" : "中文离线识别")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Macaron.secondary)
                .contentTransition(.interpolate)
        }
    }

    private var waveformContent: some View {
        VStack(spacing: 12) {
            Button(action: onWaveformTap) {
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(capture.samples.suffix(36).enumerated()), id: \.offset) { _, value in
                            Capsule()
                                .fill(capture.isRecording ? Color(hex: 0x5799D9) : Color(hex: 0xA9C8E8))
                                .frame(width: 3, height: max(5, CGFloat(value) * 54))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .clipped()
                    Text(capture.isRecording ? "点击声纹，将刚才说的话转换成文字" : capture.hasCapture ? "点击声纹查看识别文字" : "正在准备声纹输入…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0xF7F9FC), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: 0xE9EEF5), lineWidth: 1))
            }
            .buttonStyle(FluidPressButtonStyle())
            .disabled(capture.isPreparing || capture.isFinalizing)
            .animation(.linear(duration: 0.045), value: capture.samples)

            HStack {
                Button("取消", action: onCancel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                Spacer()
                Text("发送时默认只发送声纹")
                    .font(.system(size: 10))
                    .foregroundStyle(Macaron.secondary)
                Spacer()
                Button(action: onSendWaveform) {
                    Label("发送声纹", systemImage: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Color(hex: 0x5799D9), in: Capsule())
                }
                .buttonStyle(FluidPressButtonStyle())
                .disabled((!capture.isRecording && !capture.hasCapture) || capture.isPreparing || capture.isFinalizing)
                .opacity((capture.isRecording || capture.hasCapture) && !capture.isPreparing && !capture.isFinalizing ? 1 : 0.4)
            }
        }
    }

    private var textContent: some View {
        VStack(spacing: 10) {
            TextEditor(text: $capture.transcript)
                .font(.system(size: 14))
                .foregroundStyle(Macaron.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88, maxHeight: 132)
                .padding(10)
                .background(Color(hex: 0xF7F9FC), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color(hex: 0xE9EEF5), lineWidth: 1))
            HStack {
                Button("返回声纹") {
                    withAnimation(ChatMotion.layout) { isTextMode = false }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Macaron.secondary)
                Spacer()
                Button(action: onSendText) {
                    Label("发送文字", systemImage: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Color(hex: 0x5799D9), in: Capsule())
                }
                .buttonStyle(FluidPressButtonStyle())
                .disabled(capture.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(capture.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
    }
}

private struct VoiceMessageBubble: View {
    let message: ChatMessage
    let isMe: Bool
    let outgoingColor: Color
    let incomingColor: Color
    let textColor: Color
    @State private var isAnimating = false

    private var durationText: String { String(format: "%d″", Int(message.voiceDuration.rounded())) }

    var body: some View {
        Button {
            guard !isAnimating else { return }
            isAnimating = true
            // Silent visual playback only; no audio is stored or played.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, message.voiceDuration)) {
                isAnimating = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: isAnimating ? "waveform" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array((message.waveform.isEmpty ? Array(repeating: 0.12, count: 24) : message.waveform).enumerated()), id: \.offset) { _, value in
                            Capsule().fill(isMe ? Macaron.ink.opacity(0.78) : Color(hex: 0x5799D9))
                                .frame(width: 2.5, height: max(4, CGFloat(value) * 27))
                        }
                    }.frame(height: 30)
                    Text(durationText).font(.system(size: 12, weight: .medium))
                }
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("转换成功")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Macaron.secondary)
                        Text(message.text)
                            .contentTransition(.interpolate)
                            .animation(ChatMotion.text, value: message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Macaron.ink.opacity(0.10)).frame(height: 1)
                    }
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(width: 230, alignment: .leading)
            .background(isMe ? outgoingColor : incomingColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
        }
        .buttonStyle(FluidPressButtonStyle())
        .accessibilityLabel(message.text.isEmpty ? "语音消息，时长\(durationText)，点击播放静音动画" : "语音消息，已转换文字，时长\(durationText)")
    }
}

private struct CallControlButton: View {
    let symbol: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                    .frame(width: 58, height: 58)
                    .background(isActive ? Macaron.blue : Color.white.opacity(0.88), in: Circle())
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
            }
        }
        .buttonStyle(FluidPressButtonStyle())
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
