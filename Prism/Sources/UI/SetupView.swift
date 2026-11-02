import SwiftUI

/// First run: the panel becomes a setup page while Prism fetches what it needs to split music,
/// with real progress, an honest time estimate, and the prism's rays filling in as it goes.
struct SetupView: View {
    let model: PrismModel

    var body: some View {
        VStack(spacing: 18) {
            SetupIcon(progress: lightProgress)
                .frame(width: 104, height: 104)
                .padding(.top, 14)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed = model.status {
                Button("Try Again") { model.turnOn() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 7) {
                    SetupBar(fraction: barFraction)
                    HStack {
                        Text(amount)
                        Spacer()
                        Text(timeLeft)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                }
                Button("Cancel") { model.turnOff() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .animation(.easeOut(duration: 0.3), value: model.status)
    }

    private var install: PrismModel.Install? {
        if case .installing(let install) = model.status { install } else { nil }
    }

    private var lightProgress: Double {
        switch model.status {
        case .installing(let install): install.step == .downloading ? install.fraction : 1
        case .loading: 1
        default: 0
        }
    }

    private var barFraction: Double? {
        guard let install, install.step == .downloading else { return nil }
        return install.fraction
    }

    private var title: String {
        if case .failed = model.status { return "The download didn’t finish" }
        if case .loading = model.status { return "Starting up" }
        switch install?.step {
        case .checking: return "Checking the download"
        case .preparing: return "Preparing"
        default: return "Downloading"
        }
    }

    private var message: String {
        if case .failed(let error) = model.status { return error }
        let size = ByteCountFormatter.string(fromByteCount: ModelLocation.downloadBytes, countStyle: .file)
        return "Prism needs a one-time \(size) download to split music on your Mac."
    }

    private var amount: String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        guard let install, install.step == .downloading else { return "\(size(ModelLocation.downloadBytes)) downloaded" }
        return "\(size(install.received)) of \(size(install.total))"
    }

    private var timeLeft: String {
        if case .loading = model.status { return "Almost done" }
        guard let install else { return "" }
        guard install.step == .downloading else { return "A few seconds" }
        guard let seconds = install.secondsLeft else { return "Estimating time…" }
        switch seconds {
        case ..<10: return "A few seconds left"
        case ..<50: return "Less than a minute left"
        case ..<90: return "About a minute left"
        case ..<5_400: return "About \(Int((seconds / 60).rounded())) minutes left"
        default: return "About \(Int((seconds / 3_600).rounded())) hours left"
        }
    }
}

/// Prism's violet whether or not the window is active (system bars go grey in an inactive window).
/// With no fraction, the bar fills and holds while the next step runs.
private struct SetupBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(Palette.accent.gradient)
                    .frame(width: max(6, geometry.size.width * (fraction ?? 1)))
                    .opacity(fraction == nil ? 0.55 : 1)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "Finishing")
    }
}

/// The app icon building up as Prism gets ready, from the same renders the launch film ends on:
/// the beam lights as the download starts, then each ray as another third arrives.
private struct SetupIcon: View {
    var progress: Double

    private static let layers = ["SetupBeam", "SetupRay1", "SetupRay2", "SetupRay3"]
    private static let starts = [0.0, 0.08, 0.40, 0.72]

    private func opacity(_ i: Int) -> Double {
        min(1, max(0, (progress - Self.starts[i]) / (i == 0 ? 0.06 : 0.22)))
    }

    var body: some View {
        ZStack {
            Image("SetupPrism").resizable()
            // Each render holds everything before it, so stacking them builds the icon without seams.
            ForEach(Self.layers.indices, id: \.self) { i in
                Image(Self.layers[i]).resizable().opacity(opacity(i))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.6), value: progress)
    }
}
