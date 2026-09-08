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
/// Each row is a server's name and the summary of its transport — the command a stdio server would
/// run, the URL an http or sse server would reach — because a consent dialog that hides what it is
/// consenting to is not consent.
struct ConsentSheet: View {

    let servers: [ProjectMCPServer]
    let isAnswering: Bool
    let accept: () -> Void
    let decline: () -> Void

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
    static func preamble(_ count: Int) -> String {
        "This project declares \(count) MCP server(s) you have not decided about. "
      + "Accepting lets this session start them; declining records them as disabled for this project."
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
