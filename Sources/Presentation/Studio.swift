import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor final class Studio: ObservableObject {
    @Published var history: [Transcript] = []
    @Published var document: Transcript?
    @Published var source: URL?
    @Published var player: AVPlayer? {
        didSet {
            player?.volume = playbackVolume
            currentTime = 0; playbackDuration = 0; isPlaying = false
        }
    }
    @Published var isPlaying = false
    @Published var playbackDuration = 0.0
    @Published var playbackVolume: Float = 1 {
        didSet { player?.volume = playbackVolume }
    }
    @Published var busy = false
    @Published var stage = "" {
        didSet {
            if stage != oldValue { processingFraction = nil; processingDetail = "" }
        }
    }
    @Published var processingFraction: Double?
    @Published var processingDetail = ""
    @Published var error: String?
    @Published var count = 0 {
        didSet { persistPreferences() }
    }
    @Published var mode: TranscriptionMode = .accurate {
        didSet { persistPreferences() }
    }
    @Published var fastModel: RecognitionModel = .automatic {
        didSet { persistPreferences() }
    }
    @Published var accurateModel: RecognitionModel = .qwen {
        didSet { persistPreferences() }
    }
    @Published var voiceModel: VoiceModel = .automatic {
        didSet { persistPreferences() }
    }
    @Published var oneSpeakerPerSource = false {
        didSet { persistPreferences() }
    }
    @Published var vocabulary = "" {
        didSet { persistPreferences() }
    }
    @Published var cloudLanguage: CloudLanguage = .russian {
        didSet { persistPreferences() }
    }
    @Published private(set) var hasCloudKey = false
    @Published var modelInfo = ""
    var recognitionModel: RecognitionModel {
        get { mode == .fast ? fastModel : accurateModel }
        set {
            switch mode {
            case .fast: fastModel = newValue
            case .accurate: accurateModel = newValue
            case .cloud: break
            }
        }
    }
    @Published var quickExport = false
    @Published var quickFormat = "md"
    @Published var savedExportURL: URL?
    @Published var audioInfo = ""
    @Published var audioLayout = "automatic"
    @Published var sourceProgress = ""
    @Published var search = ""
    @Published var filter = "All"
    @Published var reviewOnly = false
    @Published var selected: UUID?
    @Published var currentTime = 0.0
    @Published var showExport = false
    @Published private(set) var speakerRemovalUndo: Transcript?
    private var transcriptionService: (any TranscriptionServicing)?
    private var task: Task<Void, Never>?
    private var ticker: Timer?
    private var isRestoringPreferences = true
    private let repository: any TranscriptRepository
    private let preferences: any PreferencesStoring
    private let credentials: (any CredentialStoring)?
    private let makeTranscriptionService: @MainActor () -> any TranscriptionServicing

    init(repository: any TranscriptRepository,
         preferences: any PreferencesStoring,
         credentials: (any CredentialStoring)? = nil,
         startTicker: Bool = true,
         makeTranscriptionService: @escaping @MainActor () -> any TranscriptionServicing) {
        self.repository = repository
        self.preferences = preferences
        self.credentials = credentials
        self.makeTranscriptionService = makeTranscriptionService
        let settings = preferences.load()
        mode = settings.mode
        fastModel = settings.fastModel
        accurateModel = settings.accurateModel
        voiceModel = settings.voiceModel
        vocabulary = settings.vocabulary
        oneSpeakerPerSource = settings.oneSpeakerPerSource
        count = settings.speakerCount
        cloudLanguage = settings.cloudLanguage
        hasCloudKey = credentials?.hasSecret ?? false
        isRestoringPreferences = false
        do { history = try repository.load() }
        catch { self.error = "Could not load the library: \(error.localizedDescription)" }
        guard startTicker else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rawTime = self.player?.currentTime().seconds ?? 0
                let time = rawTime.isFinite ? rawTime : 0
                if abs(self.currentTime - time) > 0.001 { self.currentTime = time }
                let playing = self.player?.timeControlStatus == .playing
                if self.isPlaying != playing { self.isPlaying = playing }
                let rawDuration = self.player?.currentItem?.duration.seconds ?? 0
                let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
                if self.playbackDuration != duration { self.playbackDuration = duration }
                self.refreshStage()
            }
        }
    }
    deinit { ticker?.invalidate() }

    func choose() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie, .audio]
        p.allowsMultipleSelection = false
        p.begin { [weak self] response in
            if response == .OK, let url = p.url { Task { @MainActor in self?.load(url) } }
        }
    }
    func load(_ url: URL) {
        guard !busy else { return }
        speakerRemovalUndo = nil
        source = url; player?.pause(); player = AVPlayer(url: url)
        document = nil; selected = nil; error = nil; search = ""; filter = "All"; reviewOnly = false
        savedExportURL = nil
        audioInfo = ""; audioLayout = "automatic"; modelInfo = ""
        if quickExport { transcribe(quickExport: true) }
    }
    func open(_ doc: Transcript) {
        guard !busy else { return }
        speakerRemovalUndo = nil
        savedExportURL = nil
        audioInfo = doc.audioLayout ?? ""; audioLayout = "automatic"
        modelInfo = doc.modelSummary ?? ""
        let sourceURL = URL(fileURLWithPath: doc.sourcePath)
        document = doc; source = sourceURL
        player?.pause(); player = AVPlayer(url: sourceURL); selected = nil; filter = "All"; search = ""
        reviewOnly = false
        if !FileManager.default.fileExists(atPath: doc.sourcePath) {
            error = "Source file is unavailable. You can edit and export the transcript. Restore the file to play it: \(doc.sourcePath)"
        } else { error = nil }
    }
    func newDocument() { guard !busy else { return }; player?.pause(); player = nil; source = nil; document = nil; error = nil; audioInfo = ""; audioLayout = "automatic"; modelInfo = "" }
    func save() {
        guard let doc = document else { return }
        if let index = history.firstIndex(where: { $0.id == doc.id }) { history[index] = doc }
        else { history.insert(doc, at: 0) }
        do {
            try repository.save(history)
        } catch { self.error = "Could not save changes: \(error.localizedDescription)" }
    }
    @discardableResult
    func clearLibrary() -> Bool {
        guard !busy, !history.isEmpty else { return false }
        do {
            // Persist first: a failed write must leave the library intact.
            try repository.save([])
        } catch {
            self.error = "Could not clear the library: \(error.localizedDescription)"
            return false
        }
        history = []
        newDocument()
        speakerRemovalUndo = nil
        savedExportURL = nil
        selected = nil
        search = ""; filter = "All"; reviewOnly = false
        currentTime = 0; stage = ""
        return true
    }
    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus != .paused {
            player.pause(); isPlaying = false
        } else {
            if playbackDuration > 0, currentTime >= playbackDuration - 0.1 {
                player.seek(to: .zero)
            }
            player.play(); isPlaying = true
        }
    }
    func seekPlayback(to time: Double) {
        guard time.isFinite else { return }
        let target = min(max(0, time), playbackDuration)
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func seek(_ segment: Utterance) {
        selected = segment.id
        player?.seek(to: CMTime(seconds: segment.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        isPlaying = true
    }
    func rename(_ speaker: String, _ name: String) { speakerRemovalUndo = nil; document?.names[speaker] = name; save() }
    func update(_ id: UUID, text: String? = nil, speaker: String? = nil, reviewed: Bool = false) {
        speakerRemovalUndo = nil
        document?.updateSegment(id, text: text, speaker: speaker, reviewed: reviewed)
        save()
    }
    var reviewCount: Int { document?.reviewCount ?? 0 }
    func confirmAllReviews() {
        speakerRemovalUndo = nil
        document?.confirmAllReviews()
        save()
    }
    func addSpeaker() {
        guard var doc = document else { return }
        speakerRemovalUndo = nil
        var n = 1
        while speakers.contains("Speaker \(n)") { n += 1 }
        doc.names["Speaker \(n)"] = "Speaker \(n)"; document = doc; save()
    }
    func removeSpeaker(_ speaker: String) {
        guard !busy, var doc = document, !Transcript.isUnknown(speaker) else { return }
        speakerRemovalUndo = doc
        doc.removeSpeaker(speaker)
        document = doc
        if filter == speaker { filter = doc.speakers.contains("Unknown") ? "Unknown" : "All" }
        save()
    }
    func undoSpeakerRemoval() {
        guard let previous = speakerRemovalUndo, previous.id == document?.id else { return }
        document = previous
        speakerRemovalUndo = nil
        filter = "All"
        save()
    }
    var speakers: [String] { Array(Set((document?.speakers ?? []) + Array(document?.names.keys ?? Dictionary<String,String>().keys))).sorted() }
    var visible: [Utterance] {
        (document?.segments ?? []).filter {
            (filter == "All" || $0.speaker == filter) && (!reviewOnly || $0.needsReview) &&
            (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || (document?.name($0.speaker) ?? "").localizedCaseInsensitiveContains(search))
        }
    }
    func color(_ speaker: String) -> Color { palette[(speakers.firstIndex(of: speaker) ?? 0) % palette.count] }
    private func persistPreferences() {
        guard !isRestoringPreferences else { return }
        preferences.save(TranscriptionPreferences(speakerCount: count, mode: mode,
            fastModel: fastModel, accurateModel: accurateModel, voiceModel: voiceModel,
            oneSpeakerPerSource: oneSpeakerPerSource, vocabulary: vocabulary, cloudLanguage: cloudLanguage))
    }

    /// Returns false and sets `error` when the key could not be stored.
    @discardableResult
    func saveCloudKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credentials, !trimmed.isEmpty else { return false }
        do { try credentials.save(trimmed); hasCloudKey = true; error = nil; return true }
        catch { self.error = "Could not save the Deepgram key: \(error.localizedDescription)"; return false }
    }

    func removeCloudKey() {
        guard let credentials else { return }
        do { try credentials.delete(); hasCloudKey = false }
        catch { self.error = "Could not remove the Deepgram key: \(error.localizedDescription)" }
    }

    func cancel() {
        task?.cancel()
        transcriptionService?.cancel()
        stage = "Stopping…"
    }

    func refreshStage() {
        guard busy, task?.isCancelled != true else { return }
        transcriptionService?.refreshProgress()
    }

    private func apply(_ progress: TranscriptionProgress) {
        stage = progress.stage
        processingFraction = progress.fraction
        processingDetail = progress.detail
        audioInfo = progress.audioInfo
        modelInfo = progress.modelInfo
        sourceProgress = progress.sourceProgress
    }

    func transcribe(quickExport: Bool = false) {
        guard let source, !busy else { return }
        speakerRemovalUndo = nil
        savedExportURL = nil
        let previous = document
        let request = TranscriptionRequest(source: source, speakerCount: count, mode: mode,
            model: recognitionModel, voiceModel: voiceModel, vocabulary: vocabulary,
            audioLayout: audioLayout, oneSpeakerPerSource: oneSpeakerPerSource, cloudLanguage: cloudLanguage)
        let outputFormat = quickFormat
        let service = makeTranscriptionService()
        service.onProgress = { [weak self] progress in self?.apply(progress) }
        transcriptionService = service
        busy = true
        error = nil
        stage = "Preparing audio…"
        processingFraction = nil
        processingDetail = ""
        player?.pause()
        task = Task {
            defer {
                service.onProgress = nil
                transcriptionService = nil
                busy = false
                sourceProgress = ""
                processingFraction = nil
                processingDetail = ""
            }
            do {
                let refined = try await service.transcribe(request, previous: previous)
                try Task.checkCancellation()
                document = refined
                selected = nil
                filter = "All"
                reviewOnly = false
                save()
                stage = refined.segments.isEmpty ? "No speech detected" : "Transcript ready"
                if quickExport {
                    stage = "Saving transcript…"
                    do {
                        savedExportURL = try refined.writeNextToSource(format: outputFormat)
                        stage = "Transcript saved"
                    } catch {
                        self.error = "Transcript ready, but it could not be saved next to the source file. Use Export to choose another folder. \(error.localizedDescription)"
                        stage = "Export failed"
                    }
                }
            } catch is CancellationError {
                stage = "Processing stopped"
            } catch {
                self.error = error.localizedDescription
                stage = "Could not process this file"
            }
        }
    }
    func export(_ format: String) {
        guard let doc = document else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(doc.title).\(format)"
        p.directoryURL = URL(fileURLWithPath: doc.sourcePath).deletingLastPathComponent()
        p.isExtensionHidden = false
        p.begin { [weak self] response in
            guard response == .OK, let url = p.url else { return }
            do { try doc.exported(format).write(to: url, atomically: true, encoding: .utf8) }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
}

