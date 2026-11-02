#if PROMO
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import StemSeparation
import SwiftUI

/// One filmed take: the real panel, enlarged so the film can zoom without softening, driven by a
/// timeline instead of a person, with its window captured frame by frame.
struct PromoSpec: Decodable {
    struct Action: Decodable {
        var t: Double
        var kind: String
        var id: String?
    }
    var scale: Double
    var title: String
    var artist: String
    var album: String
    var artwork: String
    var duration: Double
    var lead: Double
    var latency: Double
    /// Float32 peaks, `meterSlots` per frame in catalogue order, at `meterRate` frames a second of film time.
    var meters: String
    var meterRate: Double
    var meterSlots: Int
    var out: String
    var layoutOut: String
    var actions: [Action]
    var capture: Bool
}

/// Where each control ended up, for the film's cursor.
final class PromoLayout {
    static let shared = PromoLayout()
    var frames: [String: CGRect] = [:]
}

struct PromoAnchor: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.onAppear { PromoLayout.shared.frames[id] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in PromoLayout.shared.frames[id] = frame }
        })
    }
}

extension View {
    func promoAnchor(_ id: String) -> some View { modifier(PromoAnchor(id: id)) }
}

/// Stands in for the source menu on film: a real NSMenu is its own modal window, so it can't scale
/// with the panel or follow the timeline.
@Observable
final class PromoMenu {
    static let shared = PromoMenu()
    var isOpen = false
    var highlighted: Int?
    var origin = CGPoint.zero
}

struct PromoSourceMenu: View {
    private let menu = PromoMenu.shared
    private let apps = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music"), ("com.apple.Safari", "Safari"),
                        ("com.google.Chrome", "Chrome"), ("company.thebrowser.Browser", "Arc")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                row(index) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.0) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    }
                    Text(app.1)
                }
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            row(apps.count) {
                Image(systemName: "macbook").frame(width: 16, height: 16)
                Text("All Mac Audio")
            }
        }
        .padding(5)
        .frame(width: 172)
        .background(.black.opacity(0.42), in: .rect(cornerRadius: 12))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .opacity(menu.isOpen ? 1 : 0)
        .offset(x: menu.origin.x, y: menu.origin.y)
    }

    private func row(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                if menu.highlighted == index { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.accent) }
            }
            .promoAnchor("menu.\(index)")
    }
}

/// A borderless window that can still be key, so controls draw in their active colours.
final class PromoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Tints only show in the active app, and a take may run with another app (or nothing) in front.
final class PromoApplication: NSApplication {
    override var isActive: Bool { true }
}

final class PromoDirector: NSObject, NSApplicationDelegate {
    private let spec: PromoSpec
    private let model = AppDelegate.model
    private var window: NSWindow?
    private var hosting: NSView?
    private var link: CADisplayLink?
    private var filmStart: CFTimeInterval = 0
    private var meters: [Float] = []
    private var lastMeterFrame = 0
    private var capture: PromoCapture?
    private var finished = false

    init(spec: PromoSpec) {
        self.spec = spec
        super.init()
        if let data = FileManager.default.contents(atPath: spec.meters) {
            meters = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.promoGoLive(title: spec.title, artist: spec.artist, album: spec.album,
                          artwork: URL(fileURLWithPath: spec.artwork), latency: spec.latency)
        model.bypass = true

        let panel = PrismPanel(model: model)
            .overlay(alignment: .topLeading) { PromoSourceMenu() }
            .environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .key)
        let measured = NSHostingView(rootView: panel).fittingSize
        let scale = CGFloat(spec.scale)
        let size = CGSize(width: measured.width * scale, height: measured.height * scale)
        let root = panel
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: 0.115))
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = PromoWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.minY + 10))
        }
        window.acceptsMouseMovedEvents = true
        // Only the timeline's clicks: the Mac may be in use while a take rolls.
        window.ignoresMouseEvents = true
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.hosting = hosting
        print("window \(window.windowNumber) \(Int(size.width))x\(Int(size.height)) pt")
        fflush(stdout)

        MeterHub.shared.promoPeak = { [weak self] slot in self?.peak(slot) ?? 0 }
        MeterHub.shared.promoSlots = spec.meterSlots

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let source = PromoLayout.shared.frames["source"] {
                PromoMenu.shared.origin = CGPoint(x: source.minX / scale, y: source.maxY / scale + 6)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self.writeLayout(measured: measured) }
        Task { @MainActor in
            await warmUp()
            if spec.capture {
                do {
                    print("starting capture"); fflush(stdout)
                    let capture = try await PromoCapture.start(windowNumber: window.windowNumber, out: URL(fileURLWithPath: spec.out))
                    self.capture = capture
                    print("capture started"); fflush(stdout)
                } catch {
                    print("capture failed: \(error)")
                    NSApp.terminate(nil)
                }
            }
            self.begin()
        }
    }

    /// Clicks through every state once before rolling, so each glass tint's first draw (and the
    /// shaders behind it) happens off camera instead of stalling a frame on the beat.
    private func warmUp() async {
        try? await Task.sleep(for: .seconds(1.2))
        PromoMenu.shared.isOpen = true
        try? await Task.sleep(for: .seconds(0.4))
        PromoMenu.shared.isOpen = false
        let ids = spec.actions.filter { $0.kind == "click" }.compactMap(\.id)
            + ["preset.karaoke", "solo.drums", "solo.drums", "preset.original"]
        for id in ids {
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                press(Press(t: 0, type: type, id: id))
                try? await Task.sleep(for: .milliseconds(type == .leftMouseUp ? 420 : 90))
            }
        }
        try? await Task.sleep(for: .seconds(0.8))
    }

    private func writeLayout(measured: CGSize) {
        var object: [String: [Double]] = [:]
        for (id, frame) in PromoLayout.shared.frames {
            object[id] = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
        }
        object["_window"] = [0, 0, Double(measured.width) * spec.scale, Double(measured.height) * spec.scale]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) {
            FileManager.default.createFile(atPath: spec.layoutOut, contents: data)
        }
    }

    private func begin() {
        guard let hosting else { return }
        let link = hosting.displayLink(target: self, selector: #selector(tick(_:)))
        // Ask for ProMotion's full rate: left to itself a busy Mac drops to 60 Hz, and a 60 Hz take
        // lands unevenly on the film's 60 fps grid (doubled and skipped frames).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var filmTime = -Double.infinity

    @objc private func tick(_ link: CADisplayLink) {
        // The clock starts on the first real frame: a display still waking up can't skew the take.
        if filmStart == 0 {
            filmStart = link.targetTimestamp + spec.lead
            capture?.filmStart = filmStart
        }
        filmTime = link.targetTimestamp - filmStart
        while nextPress < presses.count, presses[nextPress].t <= filmTime + 0.001 {
            press(presses[nextPress])
            nextPress += 1
        }
        while nextMenuBeat < menuBeats.count, menuBeats[nextMenuBeat].t <= filmTime + 0.001 {
            play(menuBeats[nextMenuBeat])
            nextMenuBeat += 1
        }
        if filmTime > spec.duration, !finished {
            finished = true
            link.invalidate()
            Task { @MainActor in
                await capture?.stop()
                NSApp.terminate(nil)
            }
        }
    }

    /// The loudest sample since the last read, for the meter ballistics.
    private var readThrough = [Int](repeating: 0, count: 8)
    private func peak(_ slot: Int) -> Float {
        let rate = spec.meterRate, slots = spec.meterSlots
        guard filmTime.isFinite, filmTime >= -spec.lead else { return 0 }
        let frame = min(Int((filmTime + spec.lead) * rate), meters.count / max(slots, 1) - 1)
        guard frame >= readThrough[slot] else { return 0 }
        var peak: Float = 0
        for f in readThrough[slot]...frame { peak = max(peak, meters[f * slots + slot]) }
        readThrough[slot] = frame + 1
        return peak
    }

    /// Every click goes through AppKit as a real mouse event, so hover and the Liquid Glass press
    /// are the real thing. The button lets go exactly on `t`; the press starts just before it.
    private struct Press {
        var t: Double
        var type: NSEvent.EventType
        var id: String
    }

    private lazy var presses: [Press] = spec.actions.filter { $0.kind == "click" }.flatMap { action -> [Press] in
        guard let id = action.id else { return [] }
        // The panel takes about 95 ms to redraw after a click at this size, so let go that much
        // early and the change lands on the beat.
        return [Press(t: action.t - 0.42, type: .mouseMoved, id: id),
                Press(t: action.t - 0.19, type: .leftMouseDown, id: id),
                Press(t: action.t - 0.095, type: .leftMouseUp, id: id)]
    }.sorted { $0.t < $1.t }
    private var nextPress = 0
    private var eventNumber = 0
    private lazy var menuBeats = spec.actions.filter { $0.kind != "click" }.sorted { $0.t < $1.t }
    private var nextMenuBeat = 0

    private func play(_ beat: PromoSpec.Action) {
        let menu = PromoMenu.shared
        switch beat.kind {
        case "menuOpen": withAnimation(.easeOut(duration: 0.12)) { menu.isOpen = true }
        case "menuHighlight": menu.highlighted = beat.id.flatMap(Int.init)
        case "menuClose": withAnimation(.easeOut(duration: 0.2)) { menu.isOpen = false }
        default: break
        }
    }

    private func press(_ press: Press) {
        guard let window, let frame = PromoLayout.shared.frames[press.id] else {
            print("no anchor for \(press.id)")
            return
        }
        eventNumber += 1
        let point = NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
        guard let event = NSEvent.mouseEvent(with: press.type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                             clickCount: press.type == .mouseMoved ? 0 : 1,
                                             pressure: press.type == .leftMouseDown ? 1 : 0) else { return }
        if press.type == .leftMouseUp {
            print(String(format: "%.3f click %@", filmTime, press.id))
            fflush(stdout)
        }
        NSApp.postEvent(event, atStart: false)
    }
}

/// Records one window with ScreenCaptureKit, stamping frames on the host clock.
nonisolated final class PromoCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var stream: SCStream!
    private let queue = DispatchQueue(label: "promo.capture", qos: .userInteractive)
    private let timesURL: URL
    private var times: [Double] = []
    private var started = false
    private var dropped = 0
    private var delivered = 0
    var filmStart: CFTimeInterval = 0

    static func start(windowNumber: Int, out: URL) async throws -> PromoCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else {
            throw NSError(domain: "promo", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not shareable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        let capture = try PromoCapture(filter: filter, config: config, out: out)
        try await capture.stream.startCapture()
        return capture
    }

    private init(filter: SCContentFilter, config: SCStreamConfiguration, out: URL) throws {
        try? FileManager.default.removeItem(at: out)
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        timesURL = out.deletingPathExtension().appendingPathExtension("times.json")
        super.init()
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("stream stopped: \(error)")
        fflush(stdout)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        delivered += 1
        if delivered == 1 { print("first frame"); fflush(stdout) }
        guard type == .screen, sample.isValid, let pixels = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sample.presentationTimeStamp
        if !started {
            started = writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        if adaptor.append(pixels, withPresentationTime: pts) { times.append(pts.seconds - filmStart) } else { dropped += 1 }
    }

    func stop() async {
        try? await stream.stopCapture()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                print("delivered \(self.delivered), started \(self.started)")
                guard self.started else { done.resume(); return }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    let data = try? JSONSerialization.data(withJSONObject: ["times": self.times, "dropped": self.dropped])
                    if let data { FileManager.default.createFile(atPath: self.timesURL.path, contents: data) }
                    print("frames \(self.times.count) dropped \(self.dropped) status \(self.writer.status.rawValue) \(self.writer.error?.localizedDescription ?? "")")
                    done.resume()
                }
            }
        }
    }
}

enum PromoTake {
    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--promo-take"), arguments.indices.contains(index + 1),
              let data = FileManager.default.contents(atPath: arguments[index + 1]),
              let spec = try? JSONDecoder().decode(PromoSpec.self, from: data) else {
            print("usage: --promo-take spec.json")
            return 1
        }
        MainActor.assumeIsolated {
            let app = PromoApplication.shared
            let director = PromoDirector(spec: spec)
            app.delegate = director
            withExtendedLifetime(director) { app.run() }
        }
        return 0
    }
}
#endif
