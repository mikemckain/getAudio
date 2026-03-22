import SwiftUI
import AVFoundation
import AppKit

private let accentRed = Color(red: 209/255, green: 77/255, blue: 65/255)
private let accentPurple = Color(red: 139/255, green: 126/255, blue: 200/255)

class WindowState {
    var collapsedHeight: CGFloat = 86
    weak var window: NSWindow?
}

struct ContentView: View {
    @StateObject private var manager = AudioCaptureManager()
    @State private var windowState = WindowState()
    @State private var isListExpanded = false
    @State private var errorMessage: String?
    @State private var playingRecording: AudioCaptureManager.Recording?
    @State private var editingRecording: AudioCaptureManager.Recording?
    @State private var editingName: String = ""
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: waveform + record
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    WaveformView(
                        levels: manager.isPlaying ? manager.playbackLevels : manager.audioLevels,
                        isRecording: manager.isRecording,
                        isPlaying: manager.isPlaying
                    )
                    .frame(height: 40)

                    RecordButton(isRecording: manager.isRecording, action: toggleRecording)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(accentRed)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)

            // Recordings list + settings overlay
            ZStack {
                if manager.recordings.isEmpty {
                    GeometryReader { geo in
                        List {
                            Text("No recordings yet")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: geo.size.height)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                        .scrollDisabled(true)
                    }
                } else {
                    List {
                        ForEach(manager.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                isPlaying: playingRecording == recording,
                                isEditing: editingRecording == recording,
                                editingName: $editingName,
                                onPlay: { togglePlayback(recording) },
                                onReveal: { manager.revealRecording(recording) },
                                onDelete: {
                                    if playingRecording == recording { stopPlayback() }
                                    manager.deleteRecording(recording)
                                },
                                onStartEditing: {
                                    editingRecording = recording
                                    editingName = recording.name
                                },
                                onCommitEditing: { commitRename(recording) },
                                onCancelEditing: { editingRecording = nil }
                            )
                        }
                    }
                }

                if showingSettings {
                    SettingsView(manager: manager, onClose: { showingSettings = false })
                }
            }
            .clipped()

            // Footer
            HStack {
                Text("v1.0")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
                Spacer()
                ChevronButton(isExpanded: isListExpanded, action: { toggleListExpanded() })
                Spacer()
                SettingsButton(action: {
                    if !isListExpanded {
                        toggleListExpanded()
                    }
                    showingSettings.toggle()
                })
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 380, maxWidth: .infinity, alignment: .top)
        .background(WindowAccessor(windowState: windowState))
    }

    private func toggleRecording() {
        Task {
            if manager.isRecording {
                await manager.stopRecording()
                if !isListExpanded {
                    toggleListExpanded()
                }
                if let newest = manager.recordings.first {
                    editingRecording = newest
                    editingName = newest.name
                }
            } else {
                do {
                    errorMessage = nil
                    try await manager.startRecording()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func commitRename(_ recording: AudioCaptureManager.Recording) {
        if !manager.renameRecording(recording, to: editingName) {
            errorMessage = "Couldn't rename — name may already exist"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { errorMessage = nil }
        }
        editingRecording = nil
    }

    private func togglePlayback(_ recording: AudioCaptureManager.Recording) {
        if playingRecording == recording {
            stopPlayback()
        } else {
            stopPlayback()
            if manager.startPlayback(recording) {
                playingRecording = recording
                // Watch for playback ending
                Task {
                    while manager.isPlaying {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    playingRecording = nil
                }
            } else {
                errorMessage = "Playback failed"
            }
        }
    }

    private func stopPlayback() {
        manager.stopPlayback()
        playingRecording = nil
    }

    private func toggleListExpanded() {
        let listHeight: CGFloat = 330
        let collapsed = windowState.collapsedHeight
        let expanded = collapsed + listHeight

        isListExpanded.toggle()

        guard let window = windowState.window else { return }
        var frame = window.frame
        let topY = frame.origin.y + frame.size.height
        let targetHeight = isListExpanded ? expanded : collapsed
        frame.size.height = targetHeight
        frame.origin.y = topY - targetHeight
        window.minSize.height = collapsed
        window.maxSize.height = expanded
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: AudioCaptureManager.Recording
    let isPlaying: Bool
    let isEditing: Bool
    @Binding var editingName: String
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void
    let onCancelEditing: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PlayButton(isPlaying: isPlaying, action: onPlay)

            if isEditing {
                SelectAllTextField(text: $editingName, onSubmit: onCommitEditing, onCancel: onCancelEditing)
            } else {
                Text(recording.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: onStartEditing)
            }

            Spacer()

            IconButton(icon: "folder", action: onReveal)
                .help("Show in Finder")

            IconButton(icon: "trash", action: onDelete)
                .help("Delete")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Record Button

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isRecording ? accentRed : accentRed.opacity(0.7))
                .frame(width: 14, height: 14)
                .frame(width: 40, height: 40)
                .background(isRecording ? accentRed.opacity(0.1) : isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Play Button

struct PlayButton: View {
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 14))
                .foregroundColor(accentPurple)
                .frame(width: 40, height: 40)
                .background(isHovered ? accentPurple.opacity(0.15) : accentPurple.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 40)
                .background(isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Settings Button

struct SettingsButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(isHovered ? 0.8 : 0.5))
                .offset(y: -1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Chevron Button

struct ChevronButton: View {
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(isHovered ? 0.8 : 0.5))
                .rotationEffect(.degrees(isExpanded ? -180 : 0))
                .animation(.easeInOut(duration: 0.25), value: isExpanded)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Window Accessor

class WindowObserverView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?
    private var didSetup = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, !didSetup {
            didSetup = true
            onWindowAvailable?(window)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let windowState: WindowState

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAvailable = { [windowState] window in
            windowState.window = window
            windowState.collapsedHeight = window.frame.size.height
            window.minSize = NSSize(width: 380, height: window.frame.size.height)
            window.maxSize = NSSize(width: .greatestFiniteMagnitude, height: window.frame.size.height)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}
}

// MARK: - Waveform

struct WaveformView: View {
    let levels: [Float]
    let isRecording: Bool
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let barWidth: CGFloat = 2
                let gap: CGFloat = 1.5
                let step = barWidth + gap
                let maxBars = Int(ceil(size.width / step))

                if isRecording {
                    // Live recording waveform
                    let visibleLevels = levels.suffix(maxBars)
                    let startX = size.width - CGFloat(visibleLevels.count) * step

                    for (i, level) in visibleLevels.enumerated() {
                        let x = startX + CGFloat(i) * step
                        let height = max(CGFloat(level) * size.height * 0.75, 1.5)
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(accentRed.opacity(Double(0.4 + level * 0.6)))
                        )
                    }
                } else if isPlaying {
                    // Playback waveform
                    let visibleLevels = levels.suffix(maxBars)
                    let startX = size.width - CGFloat(visibleLevels.count) * step

                    for (i, level) in visibleLevels.enumerated() {
                        let x = startX + CGFloat(i) * step
                        let height = max(CGFloat(level) * size.height * 0.75, 1.5)
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(accentPurple.opacity(Double(0.4 + level * 0.6)))
                        )
                    }
                } else {
                    // Idle breathing waveform
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for i in 0..<maxBars {
                        let x = CGFloat(i) * step
                        let wave1 = sin(Double(i) * 0.15 + time * 0.8) * 0.3
                        let wave2 = sin(Double(i) * 0.08 + time * 0.5) * 0.2
                        let wave3 = sin(Double(i) * 0.22 + time * 1.1) * 0.1
                        let combined = (wave1 + wave2 + wave3 + 0.6) * 0.25 + 0.05
                        let level = max(min(combined, 1.0), 0.03)
                        let height = CGFloat(level) * size.height
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(Color.primary.opacity(0.15))
                        )
                    }
                }
            }
        }
        .background(Color.black.opacity(0.15))
        .cornerRadius(8)
    }
}

// MARK: - Select-All TextField

struct SelectAllTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if !context.coordinator.didSelectAll {
            context.coordinator.didSelectAll = true
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                nsView.selectText(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SelectAllTextField
        var didSelectAll = false

        init(_ parent: SelectAllTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var manager: AudioCaptureManager
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Destination")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(shortenedPath(manager.recordingsDirectory))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(6)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)

                            Button("Choose") {
                                chooseFolder()
                            }
                            .buttonStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(6)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Format")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)

                            Picker("", selection: $manager.audioFormat) {
                                ForEach(AudioFormat.allCases, id: \.self) { fmt in
                                    Text(fmt.rawValue).tag(fmt)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sort by")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)

                            Picker("", selection: $manager.sortOrder) {
                                ForEach(SortOrder.allCases, id: \.self) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    IconButton(icon: "xmark", action: onClose)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func shortenedPath(_ url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count <= 3 {
            return url.path
        }
        return components.suffix(3).joined(separator: "/")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a folder for new recordings"

        if panel.runModal() == .OK, let url = panel.url {
            manager.recordingsDirectory = url
        }
    }
}
