import SwiftUI

enum Palette {
    /// Prism's one accent.
    static let accent = Color(hex: 0x7B6CFF)
}

struct PrismPanel: View {
    @Bindable var model: PrismModel

    var body: some View {
        VStack(spacing: 14) {
            if model.showsSetup {
                SetupView(model: model)
                    .transition(.opacity)
            } else {
                NowPlayingHeader(model: model)
                if case .failed(let message) = model.status {
                    Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: message)
                } else if model.permissionProblem {
                    PermissionNotice()
                } else if model.nowPlaying.automationDenied {
                    AutomationNotice(app: model.source.name)
                }
                PresetStrip(model: model)
                VStack(spacing: 6) {
                    ForEach($model.stems) { $stem in
                        StemRow(model: model, stem: $stem)
                    }
                }
            }
            Footer(model: model)
        }
        .animation(.smooth(duration: 0.45), value: model.showsSetup)
        .padding(16)
        .frame(width: 360)
        .onAppear {
            MeterHub.shared.engine = model.engine
            model.refreshSources()
        }
        .onChange(of: model.engine === nil) { MeterHub.shared.engine = model.engine }
    }
}

// MARK: - Header

private struct NowPlayingHeader: View {
    let model: PrismModel

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: model.nowPlaying.track?.artwork, hasTrack: model.nowPlaying.track != nil, fallback: model.source.icon)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SourceMenu(model: model)
            }
            Spacer(minLength: 8)
            // A failed start shows as off, so turning it on is the retry.
            Toggle("Prism", isOn: Binding(get: { model.isOn && !model.isFailed }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.accent)
                .help(model.isOn ? "Turn off and hand the audio back" : "Split \(model.source.name) live")
        }
    }

    private var title: String {
        if let track = model.nowPlaying.track, !track.title.isEmpty { return track.title }
        return model.source.name
    }

    private var subtitle: String {
        if let track = model.nowPlaying.track, !track.artist.isEmpty { return track.artist }
        if model.source.target == .system { return "Everything this Mac plays" }
        // Only Spotify and Music say what they're playing; for other apps Prism can't tell.
        return model.nowPlaying.supportsTransport ? "Nothing playing" : "Everything \(model.source.name) plays"
    }
}

private struct Artwork: View {
    let url: URL?
    /// False once the source changes: then the old cover goes, instead of waiting for a new one.
    let hasTrack: Bool
    let fallback: NSImage?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: image)
        // The last cover stays up until the next one has loaded, then cross-fades: no flash of the app
        // icon on every track change.
        .task(id: "\(url?.absoluteString ?? "")|\(hasTrack)") {
            guard let url else {
                if !hasTrack { image = nil }
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url), let loaded = NSImage(data: data) else { return }
            image = loaded
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    @ViewBuilder private var placeholder: some View {
        if let fallback {
            Image(nsImage: fallback).resizable().padding(8)
        } else {
            Image(systemName: "hifispeaker.2").font(.title2).foregroundStyle(.secondary)
        }
    }
}

private struct SourceMenu: View {
    let model: PrismModel

    var body: some View {
        Menu {
            // Toggles, so the menu ticks the source Prism is listening to.
            ForEach(model.sources) { source in
                Toggle(isOn: Binding(get: { model.source == source }, set: { _ in model.select(source) })) {
                    if let icon = source.icon {
                        Label { Text(source.name) } icon: { Image(nsImage: icon.resized(to: 16)) }
                    } else {
                        Text(source.name)
                    }
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { model.source == .system }, set: { _ in model.select(.system) })) {
                Label("All Mac Audio", systemImage: "macbook")
            }
        } label: {
            HStack(spacing: 3) {
                Text("from \(model.source.name)")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .promoAnchor("source")
    }
}

// MARK: - Presets

private struct PresetStrip: View {
    let model: PrismModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Preset.allCases) { preset in
                    let selected = model.activePreset == preset
                    Button {
                        model.apply(preset)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text(preset.title)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        // A solid fill: a tinted glass loses its colour when the window isn't in front.
                        .background(selected ? Palette.accent : .clear, in: .rect(cornerRadius: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .glassEffect(selected ? .regular.tint(Palette.accent).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 12))
                    .promoAnchor("preset.\(preset.rawValue)")
                }
            }
        }
    }
}

// MARK: - Stems

private struct StemRow: View {
    let model: PrismModel
    @Binding var stem: Stem
    @State private var dragStart: Double?
    /// Set once a drag has really moved, so returning to the start point doesn't count as a click.
    @State private var dragged = false

    private var slot: Int { model.engine?.stemNames.firstIndex(of: stem.id) ?? Stem.catalogue.firstIndex { $0.id == stem.id } ?? 0 }
    private var audible: Bool { model.isAudible(stem) }

    var body: some View {
        HStack(spacing: 8) {
            fader
            RowButton(symbol: stem.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", active: stem.muted,
                      tint: .secondary, help: stem.muted ? "Unmute \(stem.title)" : "Mute \(stem.title)") { model.toggleMute(stem.id) }
                .promoAnchor("mute.\(stem.id)")
            RowButton(symbol: "headphones", active: stem.soloed, tint: Palette.accent,
                      help: stem.soloed ? "Stop Soloing \(stem.title)" : "Solo \(stem.title)") { model.toggleSolo(stem.id) }
                .promoAnchor("solo.\(stem.id)")
        }
    }

    private var fader: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                // Fader position: neutral, so colour only ever means sound.
                Capsule()
                    .fill(.primary.opacity(audible ? 0.07 : 0.035))
                    .frame(width: max(geometry.size.height, geometry.size.width * stem.level))
                    .opacity(stem.level > 0 ? 1 : 0)
                // Live level.
                StemMeter(slot: slot, color: stem.color, gain: stem.level, audible: audible)
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: stem.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(audible ? stem.color : .secondary)
                        .frame(width: 18)
                    Text(stem.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(audible ? .primary : .secondary)
                    Spacer()
                    Text(valueLabel)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? stem.level
                        dragStart = start
                        if abs(value.translation.width) > 2 { dragged = true }
                        guard dragged else { return }
                        stem.level = min(1, max(0, start + value.translation.width / geometry.size.width))
                    }
                    .onEnded { _ in
                        if !dragged { model.toggleMute(stem.id) }
                        dragStart = nil
                        dragged = false
                    }
            )
            .help("Drag to set the \(stem.title.lowercased()) level, click to mute")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stem.title)
            .accessibilityValue(valueLabel)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: stem.level = min(1, stem.level + 0.05)
                case .decrement: stem.level = max(0, stem.level - 0.05)
                @unknown default: break
                }
            }
            .accessibilityAction(named: stem.muted ? "Unmute" : "Mute") { model.toggleMute(stem.id) }
        }
        .frame(height: 32)
        .promoAnchor("fader.\(stem.id)")
    }

    private var valueLabel: String {
        if stem.soloed { return "Solo" }
        // While dragging a muted stem, show the level it will come back at.
        if !audible && dragStart == nil { return stem.muted ? "Muted" : "Off" }
        let gain = stem.level * stem.level
        if gain >= 0.999 { return "0 dB" }
        if gain < 0.001 { return "−∞" }
        let db = Int((20 * log10(gain)).rounded())
        return db == 0 ? "0 dB" : "−\(-db) dB"
    }
}

private struct RowButton: View {
    let symbol: String
    let active: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(Circle().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.6))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: active)
    }
}

// MARK: - Footer

private struct Footer: View {
    @Bindable var model: PrismModel
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            if model.nowPlaying.supportsTransport && !model.showsSetup {
                HStack(spacing: 2) {
                    TransportButton(symbol: "backward.fill", label: "Previous Track") { model.nowPlaying.send("previous track") }
                    TransportButton(symbol: model.nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                                    label: model.nowPlaying.isPlaying ? "Pause" : "Play", large: true) {
                        model.nowPlaying.send("playpause")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    TransportButton(symbol: "forward.fill", label: "Next Track") { model.nowPlaying.send("next track") }
                }
            }
            Spacer()
            if !model.showsSetup { StatusLabel(model: model) }   // the setup page says it all
            Menu {
                Picker("Latency", selection: $model.mode) {
                    ForEach(LatencyMode.allCases) { mode in
                        Text("\(mode.title) — \(mode.detail)").tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Performance…") {
                    openWindow(id: "performance")
                    NSApp.activate()
                }
                CheckForUpdatesButton()
                ReportProblemButton()
                Divider()
                Toggle("Open at Login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
                Toggle("Show in Menu Bar", isOn: $showsMenuBarIcon)
                Divider()
                Button("Quit Prism") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("More")
            .accessibilityLabel("More")
            .glassEffect(.regular.interactive(), in: .circle)
            .fixedSize()
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let label: String
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 15 : 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: large ? 34 : 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct StatusLabel: View {
    let model: PrismModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .help(helpText)
        .animation(.default, value: text)
    }

    private var dotColor: Color {
        switch model.status {
        case .live: model.stats?.playing == true ? .green : .secondary
        case .installing, .loading, .waiting: .orange
        case .failed: .red
        case .off: .secondary.opacity(0.5)
        }
    }

    private var text: String {
        switch model.status {
        case .off: return "Off"
        case .installing(let install):
            switch install.step {
            case .downloading: return "Downloading \(Int(install.fraction * 100))%"
            case .checking: return "Checking…"
            case .preparing: return "Preparing…"
            }
        case .loading: return "Loading model…"
        case .waiting(let message): return message
        case .failed: return "Couldn't start"
        case .live:
            guard let stats = model.stats else { return "Listening" }
            if model.nowPlaying.supportsTransport && !model.nowPlaying.isPlaying { return "Paused · \(model.mode.title)" }
            if !stats.playing { return stats.receivingAudio ? "Separating…" : "Listening" }
            return String(format: "%.1f s behind · %@", stats.latency, model.mode.title)
        }
    }

    private var helpText: String {
        guard let stats = model.stats else { return "" }
        return String(format: "Each %.1f s step takes %d ms to split (%.0f%% of real time). Playing through %@. Dropouts: %d.",
                      Double(stats.plan.step) / 44_100, stats.chunkMilliseconds, stats.load * 100,
                      model.engine?.outputDeviceName ?? "the speakers", stats.underruns)
    }
}

// MARK: - Notices

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

private struct PermissionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Notice(symbol: "lock.fill", tint: .orange,
                   text: "Prism can't hear the music yet. Allow it under Screen & System Audio Recording, then turn Prism off and on.")
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

private struct AutomationNotice: View {
    let app: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Notice(symbol: "hand.raised.fill", tint: .orange,
                   text: "Prism isn't allowed to control \(app), so play, pause and skip won't work. Allow it under Automation.")
            Button("Open Automation Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

#if !PROMO
extension View {
    @inline(__always) func promoAnchor(_ id: String) -> some View { self }
}
#endif

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        return image
    }
}
