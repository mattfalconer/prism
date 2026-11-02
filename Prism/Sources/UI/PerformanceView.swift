import Charts
import SwiftUI

/// Live view of how hard separation is working: where each chunk's time goes, how close each one
/// came to a dropout, and who else is using the GPU.
struct PerformanceView: View {
    let model: PrismModel
    private var perf: PerfRecorder { model.perf }

    /// The last few minutes, so the charts stay readable.
    private var window: (chunks: [PerfRecorder.Chunk], samples: [PerfRecorder.SystemSample]) {
        let chunks = Array(perf.chunks.suffix(90))
        let start = chunks.first?.time ?? Date().addingTimeInterval(-180)
        return (chunks, perf.samples.filter { $0.time >= start })
    }

    var body: some View {
        let window = self.window
        let analysis = PerfAnalysis(chunks: perf.chunks, samples: perf.samples, events: perf.events)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let analysis {
                    Metrics(analysis: analysis)
                    Section(title: "Chunk time", caption: "Each bar is one model step; it has to finish inside the step (dashed) to keep up.") {
                        ChunkChart(chunks: window.chunks)
                    }
                    Section(title: "Closest calls", caption: "Separated audio still queued when each chunk landed. At zero you hear a gap.") {
                        HeadroomChart(chunks: window.chunks)
                    }
                    Section(title: "GPU", caption: "The whole GPU's utilisation, and the part of it that is Prism.") {
                        GPUChart(samples: window.samples)
                    }
                    Section(title: "Findings", caption: nil) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(analysis.findings) { FindingRow(finding: $0) }
                        }
                    }
                } else {
                    ContentUnavailableView("No measurements yet", systemImage: "gauge.with.dots.needle.33percent",
                                           description: Text(model.isOn ? "Play something and Prism will start measuring." : "Turn Prism on and play something."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
                if let url = perf.fileURL {
                    HStack {
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                        Spacer()
                        Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 760)
    }
}

private struct Section<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

private struct Metrics: View {
    let analysis: PerfAnalysis

    var body: some View {
        let ms = { (x: Double) in "\(Int((x * 1000).rounded())) ms" }
        GlassEffectContainer {
            HStack(spacing: 10) {
                Metric(title: "Typical chunk", value: ms(analysis.p50), detail: "of \(ms(analysis.step))")
                Metric(title: "Slow chunks", value: ms(analysis.p95), detail: "95th percentile")
                Metric(title: "Closest call", value: String(format: "%.2f s", analysis.minHeadroom),
                       detail: analysis.underruns == 0 ? "no dropouts" : "\(analysis.underruns) dropout\(analysis.underruns == 1 ? "" : "s")",
                       warning: analysis.underruns > 0)
                Metric(title: "Delay", value: String(format: "%.1f s", analysis.latency), detail: "behind the source")
            }
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let detail: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

private struct ChunkChart: View {
    let chunks: [PerfRecorder.Chunk]

    private struct Slice: Identifiable {
        let id: String
        let chunk: Int
        let stage: String
        let seconds: Double
    }

    private var slices: [Slice] {
        chunks.enumerated().flatMap { index, chunk in
            [("GPU", chunk.gpu), ("Graph build", chunk.graph),
             ("Other", chunk.resampleIn + chunk.resampleOut + chunk.prepare + chunk.readback + chunk.assemble)]
                .map { Slice(id: "\(chunk.id)-\($0.0)", chunk: index, stage: $0.0, seconds: $0.1) }
        }
    }

    var body: some View {
        Chart {
            ForEach(slices) { slice in
                // Categorical x: bars on a numeric axis get no width.
                BarMark(x: .value("Chunk", String(slice.chunk)), y: .value("Seconds", slice.seconds), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Stage", slice.stage))
            }
            if let step = chunks.last?.step {
                RuleMark(y: .value("Step", step))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("step").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["GPU": Palette.accent, "Graph build": Palette.accent.opacity(0.45),
                                    "Other": Color.secondary.opacity(0.5)])
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let s = value.as(Double.self) { Text(String(format: "%.1f s", s)) } }
        } }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 170)
    }
}

private struct HeadroomChart: View {
    let chunks: [PerfRecorder.Chunk]

    var body: some View {
        Chart {
            ForEach(Array(chunks.enumerated()), id: \.element.id) { index, chunk in
                AreaMark(x: .value("Chunk", index), y: .value("Queued", chunk.headroom))
                    .foregroundStyle(Palette.accent.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Chunk", index), y: .value("Queued", chunk.headroom))
                    .foregroundStyle(Palette.accent)
                    .interpolationMethod(.monotone)
                if chunk.headroom < 0.01 && index > 0 && chunk.afterRestart != true {
                    PointMark(x: .value("Chunk", index), y: .value("Queued", 0))
                        .foregroundStyle(.orange)
                        .symbolSize(30)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let s = value.as(Double.self) { Text(String(format: "%.1f s", s)) } }
        } }
        .frame(height: 120)
    }
}

private struct GPUChart: View {
    let samples: [PerfRecorder.SystemSample]

    var body: some View {
        Chart {
            ForEach(samples, id: \.time) { sample in
                if let device = sample.gpuDevice {
                    AreaMark(x: .value("Time", sample.time), y: .value("GPU", device), series: .value("Who", "All apps"))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", sample.time), y: .value("GPU", sample.gpuPrism), series: .value("Who", "Prism"))
                    .foregroundStyle(Palette.accent)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis { AxisMarks(values: [0, 0.5, 1]) { value in
            AxisGridLine()
            AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v * 100))%") } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()) } }
        .frame(height: 120)
    }
}

private struct FindingRow: View {
    let finding: PerfAnalysis.Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.callout.weight(.semibold))
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch finding.severity {
        case .good: "checkmark.circle.fill"
        case .note: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .good: .green
        case .note: .secondary
        case .warning: .orange
        }
    }
}
