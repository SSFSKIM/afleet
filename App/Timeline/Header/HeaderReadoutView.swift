import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The header's readback strip: branch, model, permission mode, effort and the context meter.
///
/// **Mounted by C6.2's header bar, in one line** (`HeaderReadoutView(model:)`). C6.1 owns the value
/// and the view; C6.2 owns `App/Header/` and the menus beside them, and neither leaf edits the
/// other's directory — the child spec's *Parent revision* is exactly this split.
///
/// It draws `model.readout` and derives nothing: every value on screen is the one a test asserts on.
/// The `.task` is what makes the strip's presence the thing that asks — the requests go out for a
/// channel whose header is on screen, once, and then after each `result` frame.
struct HeaderReadoutView: View {

    let model: ChannelTimelineModel

    var body: some View {
        HeaderReadoutBar(readout: model.readout)
            .task { model.startReadbacks() }
    }
}

/// The strip itself, over the value alone. Split out so the drawing can be exercised without a
/// model, and so the view that owns the request has no drawing in it.
struct HeaderReadoutBar: View {

    let readout: ChannelHeaderReadout

    var body: some View {
        // A channel with no branch that the engine has said nothing about has an empty strip, and an
        // empty strip is a band of padding under the title. It draws nothing instead.
        if readout.branch == nil, readout.isEngineSilent {
            EmptyView()
        } else {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: 12) {
            if let branch = readout.branch {
                chip("arrow.triangle.branch", branch, label: "branch")
            }
            if let model = readout.model {
                chip("cpu", model, label: "model")
            }
            if let mode = readout.mode {
                chip("lock.shield", mode.rawValue, label: "permission mode")
            }
            if let effort = readout.effort {
                chip("dial.medium", effort, label: "effort")
            }
            Spacer(minLength: 8)
            if let context = readout.context {
                ContextMeterView(usage: context)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ symbol: String, _ text: String, label: String) -> some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
        .accessibilityLabel("\(label): \(text)")
    }
}

/// The context meter: how much of the window is spent, and where auto-compaction sits in it.
struct ContextMeterView: View {

    let usage: ContextUsage

    /// The share of the window auto-compaction fires at, as a fraction of it. Nil when the engine
    /// reports no threshold or has the behaviour off — there is no mark to draw for a compaction
    /// that will not happen.
    private var threshold: Double? {
        guard usage.isAutoCompactEnabled, let at = usage.autoCompactThreshold, usage.maxTokens > 0 else { return nil }
        return min(1, Double(at) / Double(usage.maxTokens))
    }

    /// The answer's own per-category breakdown, in the order the engine reported it. The engine's
    /// category names, never anything read off this machine.
    private var breakdown: String {
        usage.categories.map { "\($0.name): \($0.tokens)" }.joined(separator: "\n")
    }

    private var spent: Double {
        guard usage.maxTokens > 0 else { return 0 }
        return min(1, Double(usage.totalTokens) / Double(usage.maxTokens))
    }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: geometry.size.width * spent)
                    if let threshold {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 1)
                            .offset(x: geometry.size.width * threshold)
                    }
                }
            }
            .frame(width: 64, height: 6)
            Text("\(usage.percentage)%")
        }
        .help(breakdown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("context used: \(usage.percentage) percent of \(usage.maxTokens) tokens")
    }
}
