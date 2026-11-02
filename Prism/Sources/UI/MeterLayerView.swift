import AppKit
import QuartzCore
import SwiftUI

/// Live stem levels, drawn by Core Animation off the SwiftUI graph (SwiftUI never re-renders for a meter).
///
/// One display link reads the engine's peak meters, applies ballistics and moves plain CALayers.
final class MeterHub {
    static let shared = MeterHub()

    private struct Entry {
        weak var view: StemMeterNSView?
        let slot: Int
    }

    private var entries: [Entry] = []
    private var levels: [Float] = []
    private var link: CADisplayLink?
    /// The meter the display link belongs to. A view's link only fires while that view is on screen, so
    /// it has to belong to a meter that's visible: closing the main window mustn't freeze the menu bar panel.
    private weak var linkOwner: StemMeterNSView?
    /// Ticks in a row where no level moved; past half a second the link drops to 10 Hz until one does.
    private var stillTicks = 0
    private var throttled = false
    weak var engine: LiveEngine?
    #if PROMO
    /// A take replays recorded levels instead of reading the engine.
    var promoPeak: ((Int) -> Float)?
    var promoSlots = 0
    #endif

    func register(_ view: StemMeterNSView, slot: Int) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view: view, slot: slot))
        refreshLink()
    }

    func unregister(_ view: StemMeterNSView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        refreshLink()
    }

    /// Keeps the display link on a meter that's on screen: when its window closes or hides, a meter in
    /// another visible window takes over, and with none on screen the link stops until one appears.
    func refreshLink() {
        entries.removeAll { $0.view == nil }
        func onScreen(_ view: StemMeterNSView?) -> Bool { view?.window?.occlusionState.contains(.visible) == true }
        if link != nil, let owner = linkOwner, onScreen(owner), entries.contains(where: { $0.view === owner }) { return }
        link?.invalidate()
        link = nil
        linkOwner = nil
        guard let view = entries.first(where: { onScreen($0.view) })?.view else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        #if PROMO
        // Film takes need every ProMotion frame, even on a busy Mac.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        linkOwner = view
        stillTicks = 0
        throttled = false
    }

    /// Instant attack, ~20 dB/s release, on a dB scale that reads like a mixer.
    private static func ballistics(peak: Float, level: Float) -> Float {
        let db = 20 * log10(max(peak, 1e-5))
        let target = max(0, min(1, (db + 54) / 54))
        return target > level ? target : max(target, level - 0.012)
    }

    @objc private func tick() {
        var slots = engine?.slotCount ?? 0
        #if PROMO
        if promoPeak != nil { slots = promoSlots }
        #endif
        if levels.count != slots { levels = [Float](repeating: 0, count: slots) }
        #if PROMO
        if let promoPeak {
            for slot in 0..<slots { levels[slot] = Self.ballistics(peak: promoPeak(slot), level: levels[slot]) }
        }
        #endif
        var changed = false
        #if PROMO
        changed = promoPeak != nil
        #endif
        if let engine {
            for slot in 0..<slots {
                let peak = engine.meters[slot]
                engine.meters[slot] = 0
                let level = Self.ballistics(peak: peak, level: levels[slot])
                if level != levels[slot] { changed = true }
                levels[slot] = level
            }
        }
        // A resting meter needs no 120 Hz redraws: skip the layer writes when nothing moved, and after
        // half a second of stillness (paused, silence, off) drop to 10 Hz until a level moves again.
        stillTicks = changed ? 0 : stillTicks + 1
        if changed && throttled {
            link?.preferredFrameRateRange = .default
            throttled = false
        }
        if stillTicks > 60 && !throttled {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 10, preferred: 10)
            throttled = true
        }
        if !changed && stillTicks > 1 { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries {
            guard let view = entry.view else { continue }
            view.update(level: entry.slot < levels.count ? CGFloat(levels[entry.slot]) : 0)
        }
        CATransaction.commit()
    }
}

final class StemMeterNSView: NSView {
    private let fill = CALayer()
    private let ghost = CALayer()
    var color: NSColor = .systemPink { didSet { refreshColors() } }
    /// 0…1 fader position; the bright meter is post-fader, the ghost shows what's there regardless.
    /// Redrawn here because the hub skips meters whose level hasn't moved.
    var gain: CGFloat = 1 { didSet { if gain != oldValue { update(level: level) } } }
    var audible = true { didSet { refreshColors(); update(level: level) } }
    private var level: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ghost)
        layer?.addSublayer(fill)
        for l in [ghost, fill] {
            l.anchorPoint = .zero
            l.cornerCurve = .continuous
        }
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { refreshColors() }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.backgroundColor = color.withAlphaComponent(audible ? 0.42 : 0).cgColor
            ghost.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    func update(level: CGFloat) {
        self.level = level
        let bounds = self.bounds
        ghost.frame = CGRect(x: 0, y: 0, width: bounds.width * level, height: bounds.height)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * level * (audible ? gain : 0), height: bounds.height)
        ghost.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
    }

    private var visibilityObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        guard let window else { return MeterHub.shared.unregister(self) }
        // The menu bar panel and the main window come and go; the hub moves its display link to follow.
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                    object: window, queue: .main) { _ in
            MainActor.assumeIsolated { MeterHub.shared.refreshLink() }
        }
        MeterHub.shared.refreshLink()
    }
}

struct StemMeter: NSViewRepresentable {
    let slot: Int
    let color: Color
    let gain: Double
    let audible: Bool

    func makeNSView(context: Context) -> StemMeterNSView {
        let view = StemMeterNSView()
        MeterHub.shared.register(view, slot: slot)
        return view
    }

    func updateNSView(_ view: StemMeterNSView, context: Context) {
        view.color = NSColor(color)
        view.gain = gain
        view.audible = audible
        if view.window != nil { MeterHub.shared.register(view, slot: slot) }
    }
}
