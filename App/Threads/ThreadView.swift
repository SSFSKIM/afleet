import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The Thread tab, drawn. With no thread open it says so; §7.5's five kinds and their reply
/// behaviours land on top of this (spec §7.5, acceptance G2).
struct ThreadView: View {

    let model: ThreadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No thread open.").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
