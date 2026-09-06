import SwiftUI
import AfleetCore
import FleetKit

/// Cmd+K (spec §4, §6). A query field over `QuickSwitcherModel`, whose results span projects,
/// channels and jobs and are drawn from the whole listed index rather than from what the sidebar
/// happens to be showing.
///
/// The view ranks nothing, filters nothing and holds no highlight of its own: it renders
/// `model.results` and forwards three gestures — type, move, open.
struct QuickSwitcherView: View {

    @Bindable var model: QuickSwitcherModel
    @Bindable var shell: ShellModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search projects, channels and background jobs", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit(open)
                .onKeyPress(.upArrow) { model.moveHighlight(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveHighlight(by: 1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider()

            let results = model.results
            if results.isEmpty {
                Text("Nothing matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(results, selection: $model.highlighted) { result in
                    SwitcherRowView(result: result)
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.highlighted = result.id; open() }
                }
                .listStyle(.plain)
                .frame(height: 320)
            }
        }
        .frame(width: 560)
        .onDisappear { model.reset() }
    }

    private func open() {
        guard let result = model.highlightedResult else { return }
        switch result.kind {
        case .channel:
            if let session = result.session { shell.select(session) }
        case .project:
            // A project is a place, not a channel: opening one goes to its most recent channel,
            // which is the row the sidebar draws first under that heading.
            if let session = result.session { shell.select(session) }
        case .job:
            if let session = result.session { shell.select(session) }
        }
        dismiss()
    }
}

private struct SwitcherRowView: View {

    let result: SwitcherResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).lineLimit(1)
                Text(result.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.kind.rawValue)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
