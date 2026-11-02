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
    weak var engine: LiveEngine?
    #if PROMO
    /// A take replays recorded levels instead of reading the engine.
    var promoPeak: ((Int) -> Float)?
    var promoSlots = 0
    #endif

    func register(_ view: StemMeterNSView, slot: Int) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view: view, slot: slot))
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick))
            #if PROMO
            // Film takes need every ProMotion frame, even on a busy Mac.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            #endif
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func unregister(_ view: StemMeterNSView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        if entries.isEmpty {
            link?.invalidate()
            link = nil
        }
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
        if let engine {
            for slot in 0..<slots {
                let peak = engine.meters[slot]
                engine.meters[slot] = 0
                levels[slot] = Self.ballistics(peak: peak, level: levels[slot])
            }
        }
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
    var gain: CGFloat = 1
    var audible = true { didSet { refreshColors() } }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { MeterHub.shared.unregister(self) }
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
