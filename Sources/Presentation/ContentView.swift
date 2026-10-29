import SwiftUI
import AppKit

private final class LibraryInteraction: ObservableObject {
    @Published var showingClearLibrary = false
    @Published var clearLibraryFailed = false
}

private final class PlaybackInteraction: ObservableObject {
    @Published var following = false
    @Published var request = UUID()
    var lastFollowedSegment: UUID?
}

private final class AudioSettingsInteraction: ObservableObject {
    @Published var expanded = false
}

private final class ExpansionInteraction: ObservableObject {
    @Published var expanded = false
}

private final class ModelMenuInteraction: ObservableObject {
    @Published var models = false
    @Published var voices = false
    @Published var cloud = false
    @Published var cloudKeyDraft = ""
}

private struct ExpandableSection<Content: View>: View {
    let title: String
    let content: Content
    @StateObject private var interaction = ExpansionInteraction()

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { interaction.expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(interaction.expanded ? 90 : 0))
                        .font(.system(size: 10, weight: .medium)).frame(width: 10)
                    Text(title).font(uiFont(12, weight: .medium))
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(muted)
                .accessibilityLabel(title)
                .accessibilityValue(interaction.expanded ? "Expanded" : "Collapsed")
            if interaction.expanded { content }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Observe user input rather than scroll offsets, which also change during scrollTo.
private struct ManualTranscriptScroll: NSViewRepresentable {
    var onScroll: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak view] event in
            guard let view, let scroll = view.enclosingScrollView, event.window === view.window else { return event }
            let point = scroll.convert(event.locationInWindow, from: nil)
            if event.type == .scrollWheel, scroll.bounds.contains(point), event.scrollingDeltaY != 0 {
                onScroll()
            } else if event.type == .leftMouseDown,
                      let scroller = scroll.verticalScroller, !scroller.isHidden,
                      scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) {
                onScroll()
            } else if event.type == .keyDown, [115, 119, 116, 121, 125, 126].contains(Int(event.keyCode)),
                      let focused = view.window?.firstResponder as? NSView,
                      focused === scroll || focused.isDescendant(of: scroll) {
                onScroll()
            }
            return event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        var monitor: Any?
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Studio
    @StateObject private var libraryInteraction = LibraryInteraction()
    @StateObject private var playbackInteraction = PlaybackInteraction()
    @StateObject private var audioSettingsInteraction = AudioSettingsInteraction()
    @StateObject private var modelMenu = ModelMenuInteraction()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Rectangle().fill(rule).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(rule).frame(height: 1)
                if let error = s.error {
                    HStack(alignment: .top, spacing: 12) {
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button { s.error = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss message")
                    }.font(uiFont(13)).foregroundStyle(accent).padding(20)
                    Rectangle().fill(rule).frame(height: 1)
                }
                if s.source == nil { welcome }
                else {
                    HStack(spacing: 0) {
                        mediaColumn.frame(width: 300)
                        Rectangle().fill(rule).frame(width: 1)
                        transcriptColumn
                    }
                }
            }
        }.background(ink).foregroundStyle(textColor).font(uiFont(14))
        .allowsHitTesting(!libraryInteraction.showingClearLibrary)
        .accessibilityHidden(libraryInteraction.showingClearLibrary)
        .overlay {
            if libraryInteraction.showingClearLibrary {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .contentShape(Rectangle()).onTapGesture { }
                    clearLibraryConfirmation
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: libraryInteraction.showingClearLibrary)
        .onChange(of: s.document?.id) { _, _ in
            playbackInteraction.following = false
            playbackInteraction.lastFollowedSegment = nil
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !s.busy, !libraryInteraction.showingClearLibrary, let provider = providers.first else { return false }
            FileDrop.read(provider) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): s.load(url)
                    case .failure(let error): s.error = error.localizedDescription
                    }
                }
            }
            return true
        }
    }

    func modelBadge(_ model: RecognitionModel) -> some View {
        let label: String
        let color: Color
        switch model {
        case .automatic:
            label = s.mode == .fast ? "Adaptive" : "Qwen 1.7B"
            color = Color(red: 0.53, green: 0.72, blue: 0.95)
        case .parakeet:
            label = "Fast"
            color = Color(red: 0.65, green: 0.83, blue: 0.61)
        case .qwenSmall:
            label = "Compact"
            color = Color(red: 0.49, green: 0.80, blue: 0.77)
        case .qwen:
            label = "Mixed languages"
            color = Color(red: 0.77, green: 0.67, blue: 0.94)
        case .moss:
            label = "Experimental"
            color = Color(red: 0.94, green: 0.75, blue: 0.47)
        }
        return Text(label).font(uiFont(9, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    var modelChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech model").font(uiFont(14, weight: .medium))
            Text(s.mode == .fast ? "Fast · Auto selects from audio analysis." : "Accurate · Auto uses Qwen3 1.7B.")
                .font(uiFont(11)).foregroundStyle(muted)
            ForEach(RecognitionModel.allCases) { model in
                Button {
                    s.recognitionModel = model
                    modelMenu.models = false
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(model.shortTitle).font(uiFont(12, weight: .medium))
                                modelBadge(model)
                            }
                            Text(model.menuSummary).font(uiFont(11)).foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accent).opacity(s.recognitionModel == model ? 1 : 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(s.recognitionModel == model ? soft : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(s.recognitionModel == model ? .isSelected : [])
            }
            Text("Runs locally · First use downloads weights")
                .font(uiFont(10)).foregroundStyle(muted)
        }.padding(18).frame(width: 350).background(ink).foregroundStyle(textColor)
    }

    var cloudSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Deepgram").font(uiFont(14, weight: .medium))
            HStack(spacing: 6) {
                Image(systemName: s.hasCloudKey ? "checkmark.seal" : "key").font(.system(size: 11))
                Text(s.hasCloudKey ? "API key saved in Keychain" : "No API key")
                    .font(uiFont(11))
            }.foregroundStyle(s.hasCloudKey ? accent : muted)
            SecureField(s.hasCloudKey ? "Replace API key" : "Paste API key", text: $modelMenu.cloudKeyDraft)
                .font(uiFont(12)).textFieldStyle(.roundedBorder)
                .onSubmit { if s.saveCloudKey(modelMenu.cloudKeyDraft) { modelMenu.cloudKeyDraft = "" } }
            HStack {
                Button("Save key") {
                    if s.saveCloudKey(modelMenu.cloudKeyDraft) { modelMenu.cloudKeyDraft = "" }
                }.disabled(modelMenu.cloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if s.hasCloudKey {
                    Button("Remove key", role: .destructive) { s.removeCloudKey() }
                }
            }.font(uiFont(12))
            Picker("Language", selection: $s.cloudLanguage) {
                ForEach(CloudLanguage.allCases) { Text($0.title).tag($0) }
            }.font(uiFont(12))
            Text("Nova-3 with speaker labels. Only extracted audio is uploaded. Usage is billed to your Deepgram account; vocabulary terms are sent as keyterms at extra cost.")
                .font(uiFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 330).background(ink).foregroundStyle(textColor)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("voicescribe").font(uiFont(20, weight: .medium))
                .padding(.top, 30).padding(.bottom, 24).padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 12) {
                Text("Transcription").font(uiFont(12)).foregroundStyle(muted)
                HStack(spacing: 0) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Button { s.mode = mode } label: {
                            Text(mode.title).font(uiFont(13, weight: .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(s.mode == mode ? ink : textColor)
                                .background(s.mode == mode ? accent : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(s.mode == mode ? .isSelected : [])
                    }
                }.background(soft).clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(s.busy).accessibilityElement(children: .contain)
                    .accessibilityLabel("Transcription mode")
                if s.mode == .cloud {
                Button { modelMenu.cloud.toggle() } label: {
                    HStack {
                        Text("Nova-3 · \(s.cloudLanguage.title)").font(uiFont(12, weight: .medium))
                        Spacer()
                        Image(systemName: s.hasCloudKey ? "chevron.down" : "exclamationmark.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(s.hasCloudKey ? textColor : accent)
                    }.padding(10).frame(maxWidth: .infinity)
                        .background(soft).clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(s.busy)
                    .accessibilityLabel(s.hasCloudKey ? "Deepgram settings" : "Deepgram settings, API key missing")
                    .popover(isPresented: $modelMenu.cloud, arrowEdge: .trailing) { cloudSettings }
                } else {
                Button { modelMenu.models.toggle() } label: {
                    HStack {
                        Text(s.recognitionModel.shortTitle).font(uiFont(12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    }.padding(10).frame(maxWidth: .infinity)
                        .background(soft).clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(s.busy)
                    .accessibilityLabel("Speech model, \(s.recognitionModel.shortTitle)")
                    .popover(isPresented: $modelMenu.models, arrowEdge: .trailing) {
                        modelChoices
                    }
                }
                Button { modelMenu.voices.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text("Voices and vocabulary").font(uiFont(12, weight: .medium))
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(muted).disabled(s.busy)
                    .popover(isPresented: $modelMenu.voices, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Voices and vocabulary").font(uiFont(14, weight: .medium))
                            Toggle("One speaker per audio track", isOn: $s.oneSpeakerPerSource)
                                .font(uiFont(12)).disabled(s.busy)
                            if s.oneSpeakerPerSource {
                                Text("Each original audio track keeps one speaker. Use only when each track contains one person's voice.")
                                    .font(uiFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("Voice detection", selection: $s.voiceModel) {
                                ForEach(VoiceModel.allCases) { model in Text(model.title).tag(model) }
                            }.font(uiFont(12)).disabled(s.busy || s.oneSpeakerPerSource || s.mode == .cloud)
                            Text(s.voiceModel.detail).font(uiFont(11)).foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Total speakers").font(uiFont(12)).foregroundStyle(muted)
                                Spacer()
                                Picker("Number of speakers", selection: $s.count) {
                                    Text("Auto").tag(0)
                                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                                }.labelsHidden().frame(width: 76).disabled(s.busy || s.oneSpeakerPerSource || s.mode == .cloud)
                                    .help("Used for mixed audio with Community. Separate audio keeps sources independent. For one person on each track, enable One speaker per audio track.")
                            }
                            if s.count > 0 && !s.oneSpeakerPerSource {
                                Text("Known count applies to mixed audio; separate sources detect voices independently")
                                    .font(uiFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                            TextField("Names or terms, comma-separated", text: $s.vocabulary)
                                .font(uiFont(12)).textFieldStyle(.roundedBorder).disabled(s.busy)
                                .help("Vocabulary hints for Qwen and MOSS. Parakeet does not use vocabulary hints. Audio is processed locally.")
                            Text(s.mode == .cloud ? "Deepgram detects voices itself; voice model and speaker count apply to local modes only." : "All inference runs on this Mac. First use downloads model weights.")
                                .font(uiFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(width: 330)
                            .background(ink).foregroundStyle(textColor)
                    }
            }.padding(.horizontal, 22).padding(.bottom, 22)
            Button { s.choose() } label: {
                Label("Open file", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(QuietButtonStyle()).disabled(s.busy).padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Quick export", isOn: $s.quickExport).toggleStyle(.checkbox).font(uiFont(13))
                    .disabled(s.busy)
                    .help("Automatically transcribe new files in the selected mode and save next to the source. No review or save dialog required.")
                if s.quickExport {
                    Picker("Format", selection: $s.quickFormat) {
                        Text("Markdown (.md)").tag("md")
                        Text("Plain text (.txt)").tag("txt")
                        Text("Subtitles (.srt)").tag("srt")
                        Text("WebVTT (.vtt)").tag("vtt")
                        Text("Project (.json)").tag("json")
                    }.font(uiFont(12)).disabled(s.busy)
                    Text("Saves next to the source file").font(uiFont(12)).foregroundStyle(muted)
                }
            }.padding(.horizontal, 22).padding(.top, 18)
            HStack {
                Text("Library").font(uiFont(12)).foregroundStyle(muted)
                Spacer()
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    libraryInteraction.clearLibraryFailed = false
                    libraryInteraction.showingClearLibrary = true
                } label: {
                    Text("Clear").font(uiFont(12)).padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(s.history.isEmpty || s.busy ? rule : muted)
                        .background(soft).overlay(Rectangle().stroke(rule, lineWidth: 1))
                }.buttonStyle(.plain).disabled(s.history.isEmpty || s.busy)
                    .help("Clear all saved transcripts from the library")
                    .accessibilityLabel("Clear library")
            }.padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(s.history) { doc in
                        Button { s.open(doc) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(doc.title).font(uiFont(13)).lineLimit(2)
                                    .multilineTextAlignment(.leading).foregroundStyle(textColor)
                                Text("\(stamp(doc.duration)) · \(doc.speakerCount) speakers")
                                    .font(uiFont(12)).foregroundStyle(s.document?.id == doc.id ? accent : muted)
                                Text(doc.created.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US"))))
                                    .font(uiFont(12)).foregroundStyle(muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.vertical, 16)
                                .background(s.document?.id == doc.id ? soft : .clear)
                                .contentShape(Rectangle())
                                .overlay(alignment: .leading) {
                                    if s.document?.id == doc.id { Rectangle().fill(accent).frame(width: 2).allowsHitTesting(false) }
                                }
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(rule).frame(height: 1).padding(.horizontal, 22).allowsHitTesting(false)
                                }
                        }.buttonStyle(.plain).disabled(s.busy).help(doc.title)
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(palette[1]).frame(width: 5, height: 5)
                Text("Processed on this Mac").font(uiFont(12)).foregroundStyle(muted)
            }.padding(22)
        }
    }

    var clearLibraryConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "trash").font(.system(size: 22, weight: .light)).foregroundStyle(accent)
            Text("Clear library?").font(uiFont(22, weight: .medium)).foregroundStyle(textColor)
            Text("This will permanently remove all \(s.history.count) saved \(s.history.count == 1 ? "transcript" : "transcripts"), including speaker names and review changes.")
                .font(uiFont(14)).foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
            Text("Your original recordings and exported files will stay on your Mac. This cannot be undone.")
                .font(uiFont(13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if libraryInteraction.clearLibraryFailed {
                Text(s.error ?? "Could not clear the library. Please try again.")
                    .font(uiFont(13)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(rule).frame(height: 1).padding(.top, 6)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { libraryInteraction.showingClearLibrary = false }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button {
                    if s.clearLibrary() { libraryInteraction.showingClearLibrary = false }
                    else { libraryInteraction.clearLibraryFailed = true }
                } label: {
                    Text("Clear library").font(uiFont(14)).foregroundStyle(ink)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(accent).overlay(Rectangle().stroke(accent, lineWidth: 1))
                }.buttonStyle(.plain).disabled(s.busy || s.history.isEmpty)
            }
        }.padding(30).frame(width: 420).background(ink)
            .overlay(Rectangle().stroke(rule, lineWidth: 1))
    }

    var header: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.document?.title ?? s.source?.lastPathComponent ?? "Transcription")
                    .font(uiFont(20, weight: .medium)).lineLimit(1)
                    .help(s.document?.title ?? s.source?.lastPathComponent ?? "Transcription")
                if let doc = s.document {
                    Text("\(stamp(doc.duration)) · \(doc.segments.count) segments · \(doc.speakerCount) speakers")
                        .font(uiFont(12)).foregroundStyle(muted)
                } else {
                    Text("Video and audio").font(uiFont(12)).foregroundStyle(muted)
                }
            }
            Spacer(minLength: 12)
            if let doc = s.document {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((try? doc.exported("txt")) ?? "", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(QuietButtonStyle()).help("Copy transcript")
                Menu {
                    Button("Plain text (.txt)") { s.export("txt") }
                    Button("Markdown (.md)") { s.export("md") }
                    Button("Subtitles (.srt)") { s.export("srt") }
                    Button("WebVTT (.vtt)") { s.export("vtt") }
                    Button("Project (.json)") { s.export("json") }
                } label: { Text("Export") }
                    .font(uiFont(13)).menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(soft).overlay(Rectangle().stroke(rule, lineWidth: 1))
            }
        }.padding(.horizontal, 28).padding(.vertical, 24)
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Open a recording").font(uiFont(24, weight: .medium))
            Text(s.quickExport ? "Drop a file to transcribe and export automatically." : "Drop a video or audio file here.")
                .font(uiFont(14)).foregroundStyle(muted)
            Button { s.choose() } label: {
                HStack { Text("Choose file"); Spacer(); Image(systemName: "arrow.up.right") }
                    .frame(width: 340)
            }.buttonStyle(QuietButtonStyle(primary: true)).padding(.top, 12)
            Text("MP4 · MOV · M4A · MP3 · WAV").font(uiFont(12)).foregroundStyle(muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var mediaColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RecordingPlayer()
                if !s.audioInfo.isEmpty || !s.modelInfo.isEmpty || (!s.busy && s.document?.processingTimeLabel != nil) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !s.busy, let elapsed = s.document?.processingTimeLabel {
                            Text(elapsed)
                        }
                        ExpandableSection("Processing details") {
                            VStack(alignment: .leading, spacing: 10) {
                                if !s.audioInfo.isEmpty {
                                    Text(s.audioInfo).fixedSize(horizontal: false, vertical: true)
                                }
                                if !s.modelInfo.isEmpty {
                                    Text(s.modelInfo).fixedSize(horizontal: false, vertical: true)
                                }
                                if let warnings = s.document?.coverageWarnings, !warnings.isEmpty {
                                    Text("Transcript warnings · \(warnings.count) spans")
                                        .foregroundStyle(accent)
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                                Text(warning).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 150)
                                }
                            }.textSelection(.enabled)
                        }
                    }.font(uiFont(12)).foregroundStyle(muted)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button { audioSettingsInteraction.expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: audioSettingsInteraction.expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .medium)).frame(width: 10)
                            Text("Audio settings")
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(uiFont(12)).foregroundStyle(muted)
                        .accessibilityValue(audioSettingsInteraction.expanded ? "Expanded" : "Collapsed")
                    if audioSettingsInteraction.expanded {
                        Menu {
                            Button("Auto") { s.audioLayout = "automatic" }
                            Button("Mixed audio") { s.audioLayout = "mixed" }
                            Button("Separate audio") { s.audioLayout = "separate" }
                        } label: {
                            HStack {
                                Text(s.audioLayout == "mixed" ? "Mixed audio" : (s.audioLayout == "separate" ? "Separate audio" : "Auto"))
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                            }.font(uiFont(13)).foregroundStyle(accent)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(accent.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(s.busy)
                            .accessibilityLabel("Audio layout")
                            .help("Auto checks tracks and channels. Choose a layout manually if detection does not match your recording. Voices are detected within every source, including sources with several people.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if s.document != nil && !s.quickExport {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Speakers").font(uiFont(13, weight: .medium)).padding(.bottom, 12)
                        ForEach(s.speakers, id: \.self) { speaker in
                            HStack(spacing: 10) {
                                Circle().fill(s.color(speaker)).frame(width: 6, height: 6)
                                if Transcript.isUnknown(speaker) {
                                    Text("Unknown speaker").font(uiFont(13)).foregroundStyle(muted)
                                    Spacer()
                                } else {
                                TextField(speaker, text: Binding(get: { s.document?.name(speaker) ?? speaker },
                                    set: { s.rename(speaker, $0) }))
                                    .textFieldStyle(.plain).font(uiFont(13))
                                    .help("Speaker name")
                                Button { s.removeSpeaker(speaker) } label: {
                                    Image(systemName: "trash").font(.system(size: 13)).padding(6)
                                }.buttonStyle(.plain).foregroundStyle(muted).disabled(s.busy)
                                    .accessibilityLabel("Remove \(s.document?.name(speaker) ?? speaker)")
                                    .help("Remove speaker. Their segments become Unknown speaker and need review.")
                                }
                            }.padding(.vertical, 12)
                            Rectangle().fill(rule).frame(height: 1)
                        }
                        Button("+ Add speaker") { s.addSpeaker() }
                            .buttonStyle(.plain).font(uiFont(12)).foregroundStyle(muted).padding(.top, 12)
                        if s.speakerRemovalUndo != nil {
                            HStack {
                                Text("Speaker removed").foregroundStyle(muted)
                                Spacer()
                                Button("Undo") { s.undoSpeakerRemoval() }.buttonStyle(.plain).foregroundStyle(accent)
                            }.font(uiFont(12)).padding(.top, 12)
                        }
                    }
                }
                if s.busy {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(s.stage).font(uiFont(13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: s.processingFraction)
                                .progressViewStyle(.linear).tint(accent)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(s.stage)
                            let detail = s.processingDetail.isEmpty ? s.sourceProgress : s.processingDetail
                            if !detail.isEmpty {
                                Text(detail).font(uiFont(12)).foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button("Stop") { s.cancel() }.buttonStyle(QuietButtonStyle()).frame(maxWidth: .infinity)
                    }
                } else {
                    Button { s.transcribe(quickExport: s.quickExport) } label: {
                        Text(s.quickExport ? "Transcribe & export" : (s.document == nil ? "Transcribe" : "Transcribe again"))
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(QuietButtonStyle(primary: true))
                        .help(s.quickExport ? "Transcribe in the selected mode and save next to the source file." : (s.document == nil ? "Transcribe audio and identify speakers" : "Create a new version and keep the current transcript and edits."))
                    if s.document == nil {
                        Button("Choose another file") { s.choose() }.buttonStyle(.plain).font(uiFont(12)).foregroundStyle(muted)
                    }
                }
            }.padding(24)
        }
    }

    var transcriptColumn: some View {
        VStack(spacing: 0) {
            if s.quickExport, let saved = s.savedExportURL {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Transcript saved", systemImage: "checkmark.circle").font(uiFont(24, weight: .medium))
                    Text(saved.lastPathComponent).font(uiFont(16)).textSelection(.enabled)
                    Text(saved.deletingLastPathComponent().path).font(uiFont(13)).foregroundStyle(muted)
                        .textSelection(.enabled)
                    HStack(spacing: 14) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                            .buttonStyle(QuietButtonStyle(primary: true))
                        Button("View transcript") { s.quickExport = false }.buttonStyle(QuietButtonStyle())
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let doc = s.document {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(muted)
                    TextField("Search transcript", text: $s.search).textFieldStyle(.plain).font(uiFont(13))
                    Picker("Speaker", selection: $s.filter) {
                        Text("All speakers").tag("All")
                        ForEach(s.speakers, id: \.self) { Text(doc.name($0)).tag($0) }
                    }.labelsHidden().font(uiFont(12)).frame(maxWidth: 170, alignment: .trailing)
                }.padding(14).background(Color(red: 12/255, green: 12/255, blue: 12/255))
                    .overlay(Rectangle().stroke(rule, lineWidth: 1)).padding(.horizontal, 28).padding(.vertical, 22)
                if !doc.segments.isEmpty {
                    HStack(spacing: 12) {
                        Button { s.reviewOnly.toggle() } label: {
                            HStack(spacing: 6) {
                                Text(s.reviewCount == 0 ? "All segments reviewed" : (s.reviewCount == 1 ? "1 segment needs review" : "\(s.reviewCount) segments need review"))
                                Image(systemName: s.reviewOnly ? "eye.fill" : "eye")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(s.reviewCount == 0 ? muted : accent)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help(s.reviewOnly ? "Show all segments" : "Show only segments that need review")
                            .accessibilityLabel("Needs review")
                            .accessibilityValue(s.reviewOnly ? "On" : "Off")
                        Spacer(minLength: 8)
                        Button {
                            playbackInteraction.following.toggle()
                            if playbackInteraction.following { playbackInteraction.request = UUID() }
                        } label: {
                            Label(playbackInteraction.following ? "Following" : "Follow playback", systemImage: "scope")
                                .foregroundStyle(playbackInteraction.following ? accent : muted)
                        }.buttonStyle(.plain)
                            .help("Jump to the current segment and follow playback. Scroll manually to stop. Active filters still apply.")
                            .accessibilityValue(playbackInteraction.following ? "On" : "Off")
                        Toggle("Confirm all", isOn: Binding(
                            get: { s.reviewCount == 0 },
                            set: { if $0 { s.confirmAllReviews() } }))
                            .toggleStyle(.checkbox).disabled(s.reviewCount == 0)
                            .help("Accept every speaker assignment in this transcript, including hidden segments.")
                    }.font(uiFont(13)).padding(.horizontal, 28).padding(.bottom, 16)
                }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(s.visible) { segment in
                            SegmentRow(segment: segment).id(segment.id)
                        }
                        if s.visible.isEmpty {
                            Text(doc.segments.isEmpty ? "No speech detected" : (s.reviewOnly && s.reviewCount == 0 ? "All segments reviewed. Turn off the review filter to see the transcript." : "No matching segments"))
                                .font(uiFont(14)).foregroundStyle(muted).padding(40)
                        }
                    }.background(ManualTranscriptScroll { playbackInteraction.following = false })
                        .padding(.horizontal, 28).padding(.bottom, 28)
                }
                .onChange(of: playbackInteraction.request) { _, _ in
                    followPlayback(proxy, force: true)
                }
                .onChange(of: s.currentTime) { _, time in
                    if let segment = doc.segments.first(where: { time >= $0.start && time < $0.end }), segment.id != s.selected {
                        s.selected = segment.id
                    }
                    followPlayback(proxy)
                }
                }
            } else {
                Text(s.busy ? "Processing recording…" : "Click Transcribe to create your transcript.")
                    .font(uiFont(14)).foregroundStyle(muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func followPlayback(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard playbackInteraction.following, let doc = s.document else { return }
        let segment = doc.segments.first(where: { s.currentTime >= $0.start && s.currentTime < $0.end })
            ?? doc.segments.last(where: { $0.start <= s.currentTime }) ?? doc.segments.first
        guard let segment, s.visible.contains(where: { $0.id == segment.id }) else { return }
        guard force || playbackInteraction.lastFollowedSegment != segment.id else { return }
        playbackInteraction.lastFollowedSegment = segment.id
        withAnimation(.easeInOut(duration: 0.55)) { proxy.scrollTo(segment.id, anchor: .center) }
    }
}

