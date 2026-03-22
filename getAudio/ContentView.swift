import SwiftUI
import AppKit

private let accentRed = Color(red: 175/255, green: 48/255, blue: 41/255)
private let accentPurple = Color(red: 139/255, green: 126/255, blue: 200/255)

class WindowState {
    var collapsedHeight: CGFloat = 86
    weak var window: NSWindow?
}

struct ContentView: View {
    @StateObject private var manager = AudioCaptureManager()
    @State private var windowState = WindowState()
    enum PanelState { case collapsed, list, settings }
    @State private var panelState: PanelState = .collapsed
    @State private var lastPanel: PanelState = .list
    @State private var errorMessage: String?
    @State private var playingRecording: AudioCaptureManager.Recording?
    @State private var editingRecording: AudioCaptureManager.Recording?
    @State private var editingName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Recorder
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    RecordButton(isRecording: manager.isRecording, action: toggleRecording)

                    WaveformView(
                        levels: manager.isPlaying ? manager.playbackLevels : manager.audioLevels,
                        isRecording: manager.isRecording,
                        isPlaying: manager.isPlaying
                    )
                    .frame(height: 46)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(accentRed)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.18, green: 0.18, blue: 0.19))
            .fixedSize(horizontal: false, vertical: true)

            // Recordings list + settings overlay
            ZStack {
                Group {
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
                        .scrollIndicators(.hidden)
                        .padding(.top, -4)
                    }
                }
                .opacity(lastPanel == .list ? 1 : 0)

                SettingsView(manager: manager, onClose: { togglePanel(.settings) })
                    .opacity(lastPanel == .settings ? 1 : 0)
            }
            .clipped()
        }
        .frame(minWidth: 380, maxWidth: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Spacer()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ChevronButton(isExpanded: panelState == .list, action: { togglePanel(.list) })
                SettingsButton(isActive: panelState == .settings, action: { togglePanel(.settings) })
            }
        }
        .background(WindowAccessor(windowState: windowState))
    }

    private func toggleRecording() {
        Task {
            if manager.isRecording {
                await manager.stopRecording()
                if panelState == .collapsed {
                    togglePanel(.list)
                }
                // Delay to let the list expand before selecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let newest = manager.recordings.first {
                        editingRecording = newest
                        editingName = newest.name
                    }
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
        guard editingRecording != nil else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != recording.name && !trimmed.isEmpty {
            if !manager.renameRecording(recording, to: editingName) {
                errorMessage = "Couldn't rename — name may already exist"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { errorMessage = nil }
            }
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

    private func togglePanel(_ panel: PanelState) {
        let listHeight: CGFloat = 400
        let collapsed = windowState.collapsedHeight
        let expanded = collapsed + listHeight

        if panelState == panel {
            // Same panel tapped — collapse
            panelState = .collapsed
        } else if panelState == .collapsed {
            // Currently collapsed — expand to requested panel
            lastPanel = panel
            panelState = panel
        } else {
            // Switching panels — instant, no resize
            lastPanel = panel
            panelState = panel
            return
        }

        let expanding = panelState != .collapsed
        guard let window = windowState.window else { return }
        var frame = window.frame
        let topY = frame.origin.y + frame.size.height
        let targetHeight = expanding ? expanded : collapsed
        frame.size.height = targetHeight
        frame.origin.y = topY - targetHeight
        window.minSize.height = targetHeight
        window.maxSize.height = targetHeight
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
                    .font(.system(.body))
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: onStartEditing)
            }

            Spacer()

            Text(recording.formattedDuration)
                .font(.system(.body))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.trailing, 4)

            IconButton(icon: "folder", action: onReveal)
                .help("Show in Finder")
                .padding(.trailing, -2)

            IconButton(icon: "trash", action: onDelete)
                .help("Delete")
        }
        .padding(.vertical, 12)
        .listRowInsets(EdgeInsets(top: 0, leading: -6, bottom: 0, trailing: -6))
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { d in d[.trailing] }
    }
}

// MARK: - Record Button

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            if isRecording {
                RoundedRectangle(cornerRadius: 5)
                    .fill(accentRed)
                    .frame(width: 17, height: 17)
                    .frame(width: 44, height: 44)
                    .background(accentRed.opacity(0.15))
                    .cornerRadius(12)
                    .frame(width: 46, height: 46)
            } else {
                Circle()
                    .fill(Color(red: 0.9, green: 0.2, blue: 0.15))
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(isHovered ? 0.7 : 0.65))
                    .cornerRadius(12)
                    .frame(width: 46, height: 46)
            }
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
                .font(.system(size: 16))
                .foregroundColor(accentPurple)
                .frame(width: 46, height: 46)
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
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(isHovered ? 0.8 : 0.5))
                .frame(width: 34, height: 34)
                .background(isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Settings Button

struct SettingsButton: View {
    var isActive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(isActive ? 1.0 : isHovered ? 0.8 : 0.5))
                .frame(width: 22, height: 22)
                .background(isActive ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.1) : Color.clear)
                .cornerRadius(6)
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
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(isExpanded ? 1.0 : isHovered ? 0.8 : 0.5))
                .frame(width: 22, height: 22)
                .background(isExpanded ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.1) : Color.clear)
                .cornerRadius(6)
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
            window.setFrameAutosaveName("")
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor.controlBackgroundColor

            // Snap to defaultSize height to clear any cached frame
            let targetHeight: CGFloat = 68
            var frame = window.frame
            let topY = frame.origin.y + frame.size.height
            frame.size.height = targetHeight
            frame.origin.y = topY - targetHeight
            window.setFrame(frame, display: false)

            windowState.collapsedHeight = targetHeight
            window.minSize = NSSize(width: 380, height: targetHeight)
            window.maxSize = NSSize(width: .greatestFiniteMagnitude, height: targetHeight)
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
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let intensity: Float = isRecording ? 1.0 : (isPlaying ? 0.5 : 0.0)

            Canvas { context, size in
                let barWidth: CGFloat = 2
                let gap: CGFloat = 1.5
                let step = barWidth + gap
                let maxBars = Int(ceil(size.width / step))

                if isRecording {
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
                    let t = time
                    // Global breathing pulses at different rates
                    let breath = sin(t * 0.7) * 0.5 + 0.5
                    let breathSlow = sin(t * 0.35) * 0.5 + 0.5
                    let morph = sin(t * 0.15) * 0.5 + 0.5

                    // Symmetry center drifts slowly left and right
                    let center = 0.5 + sin(t * 0.2) * 0.12 + sin(t * 0.13) * 0.06

                    for i in 0..<maxBars {
                        let x = CGFloat(i) * step
                        let pos = Double(i) / Double(maxBars)
                        let mirror = min(abs(pos - center) * 2.0, 1.0)

                        // Primary symmetric waves with morphing frequencies
                        let wave1 = sin(mirror * (6.0 + morph * 4.0) + t * 0.8) * 0.3
                        let wave2 = sin(mirror * 12.0 - t * 0.5 + sin(t * 0.3) * 2.0) * 0.2
                        let wave3 = cos(mirror * 18.0 + t * 1.2) * 0.12 * (0.5 + breath * 0.5)
                        let wave4 = sin(mirror * 4.0 + t * 0.4) * 0.18
                        let wave5 = cos(mirror * 25.0 - t * 0.9) * 0.08

                        // Organic break — slight pos-based wobble so it's not a perfect mirror
                        let organic = sin(pos * 7.0 + t * 0.25) * 0.04 * sin(t * 0.4)

                        // Ripple emanating from center
                        let ripple = sin(mirror * 22.0 - t * 1.8) * 0.06 * max(1.0 - mirror * 1.5, 0.0)

                        let base = 0.12 + breath * 0.1
                        let combined = base + (wave1 + wave2 + wave3 + wave4 + wave5 + organic + ripple) * (0.25 + breath * 0.18)
                        let level = max(min(combined, 0.85), 0.03)

                        let height = CGFloat(level) * size.height
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)

                        // Layered opacity — center-bright with flowing modulation
                        let centerFade = 1.0 - mirror * 0.5
                        let opacityWave = sin(mirror * 12.0 + t * 1.2) * 0.06
                        let opacityDrift = sin(pos * 6.0 + t * 0.3) * 0.02
                        let opacity = (0.16 + breath * 0.08 + opacityWave + opacityDrift) * centerFade

                        // Bright grey with subtle luminance variation
                        let lum = 0.82 + sin(mirror * 6.0 + t * 0.7) * 0.06 * breathSlow
                        let shimmer = 1.0 + cos(mirror * 16.0 - t * 1.1) * 0.03

                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(Color(red: lum * shimmer, green: lum * shimmer, blue: lum * shimmer + 0.02).opacity(opacity))
                        )
                    }
                }
            }
        }
        .background(Color.black.opacity(0.35))
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
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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

// MARK: - Tab Bar

struct TabBar<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var icon: ((T) -> String)? = nil
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let icon, !icon(option).isEmpty {
                            Image(systemName: icon(option))
                                .font(.system(size: 11))
                        }
                        Text(label(option))
                            .font(.system(.body))
                    }
                    .foregroundColor(selection == option ? .primary : .secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background {
                        if selection == option {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(accentPurple.opacity(0.15))
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var manager: AudioCaptureManager
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Destination")
                                .font(.system(.body))
                                .foregroundColor(.secondary)

                            HStack(spacing: 6) {
                                Text(manager.recordingsDirectory.path)
                                    .font(.system(.body))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(8)

                                Button("Choose") {
                                    chooseFolder()
                                }
                                .buttonStyle(.plain)
                                .font(.system(.body))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(Color.primary.opacity(0.08))
                                .cornerRadius(8)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Format")
                                .font(.system(.body))
                                .foregroundColor(.secondary)

                            TabBar(options: AudioFormat.allCases, selection: $manager.audioFormat, label: \.rawValue)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sort by")
                                .font(.system(.body))
                                .foregroundColor(.secondary)

                            TabBar(options: SortOrder.allCases, selection: $manager.sortOrder, label: \.rawValue)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Source")
                                .font(.system(.body))
                                .foregroundColor(.secondary)

                            TabBar(options: AudioSource.allCases, selection: $manager.audioSource, label: \.rawValue) { src in
                                src == .system ? "desktopcomputer" : "mic"
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .padding(.top, 4)
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
