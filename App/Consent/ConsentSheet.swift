import SwiftUI
import AfleetCore
import FleetKit

/// The project-MCP-server consent sheet (root spec §6.12, acceptance G4).
///
/// The headless path promotes every pending `.mcp.json` server to approved and spawns its command
/// at startup, so consent has to be taken **before the child exists**: this sheet is up while the
/// channel has not spawned, and the only two things it can do are `acceptProjectServers` and
/// `declineProjectServers`. It runs no process and writes no file itself.
///
/// **Three answers, and only one of them writes anything.** *Accept* remembers the acceptance in
/// afleet's own store; *Decline* is the one Claude Code-owned file this app writes; *Not now*
/// dismisses the sheet and leaves the channel exactly as it was — unspawned, still asking, with the
/// banner that brings this sheet back. Closing the sheet is *Not now* and never a decline, because a
/// window dismissal is not a refusal and must not write one (tracker 170, ruled).
///
/// Each row is a server's name and the summary of its transport — the command a stdio server would
/// run, the URL an http or sse server would reach — because a consent dialog that hides what it is
/// consenting to is not consent.
struct ConsentSheet: View {

    let servers: [ProjectMCPServer]
    let isAnswering: Bool
    let accept: () -> Void
    let decline: () -> Void
    /// *Not now*: the third answer, which writes nothing anywhere (tracker 170, ruled).
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project MCP servers")
                .font(.headline)
            Text(Self.preamble(servers.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(servers, id: \.name) { server in
                    row(server)
                }
            }
            HStack(spacing: 10) {
                // Leftmost and away from the two that act, because it is the answer that does
                // nothing: the channel stays exactly as this sheet found it.
                Button("Not now") { notNow() }
                Spacer(minLength: 0)
                Button("Decline") { decline() }
                Button("Accept") { accept() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isAnswering)
        }
        .padding(16)
        .frame(minWidth: 380, alignment: .leading)
    }

    /// One server's row: its name and what it would do if it started. Not private, because
    /// `ForEach` stores its content closure rather than the views it makes, so this is the only
    /// handle a test has on the row the sheet actually draws (the convention `QuestionCardView`
    /// set).
    @ViewBuilder
    func row(_ server: ProjectMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.name).font(.callout.weight(.semibold))
            Text(ConsentSheet.summary(of: server.transport))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// A count, never a project name or a path (§6.3, §11).
    ///
    /// **It says how long an acceptance lasts, because the acceptance outlives the sheet.**
    /// `SpawnPreconditions.accept` records project root, server name and entry hash in afleet's own
    /// store, and `evaluate` reads those records on every later spawn — through a `FileStateStore`,
    /// so the grant survives quitting the app. Wording it as *this session* described a narrower
    /// permission than the one being taken, which is the one thing a consent dialog may not do. What
    /// bounds the grant is the configuration rather than the session: the hash is of the `.mcp.json`
    /// entry, so an edited server is a server the user has not decided about and is asked again.
    static func preamble(_ count: Int) -> String {
        "This project declares \(count) MCP server(s) you have not decided about. "
      + "Accepting lets this project's servers start as they are configured now — each server and "
      + "configuration remembered across sessions, until that configuration changes. "
      + "Declining records them as disabled for this project. "
      + "Not now leaves the decision open and starts nothing."
    }

    /// What each server would do if it started. `other` is still listed and still gated — an
    /// entry this build cannot type is exactly the one a user should be asked about.
    static func summary(of transport: ProjectMCPServer.Transport) -> String {
        switch transport {
        case .stdio(let command, let arguments):
            "stdio · " + ([command] + arguments).joined(separator: " ")
        case .http(let url):
            "http · \(url)"
        case .sse(let url):
            "sse · \(url)"
        case .other(let type):
            "\(type) · transport this build does not recognise"
        }
    }
}

/// What the column draws for a channel whose consent sheet the user answered with *Not now*
/// (tracker 170, ruled).
///
/// §6.12's decision is still outstanding: the channel has not spawned, nothing has been written and
/// nothing has been remembered. The banner is what keeps that visible and keeps the sheet reachable,
/// so dismissing the modal costs the decision nothing.
struct ConsentBanner: View {

    let isAnswering: Bool
    let review: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This project declares MCP servers you have not decided about.")
                    .font(.callout)
                Text("This channel starts nothing until you do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Review project servers") { review() }
                .disabled(isAnswering)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
