import SwiftUI
import AppKit
import Observation
import ClaudeWire
import FleetKit

/// Spec §9's five sections as one readout, so what Settings shows is asserted without a window.
///
/// Every number here comes from something that already exists: the resolved environment, the
/// version gate's verdict, C3's index snapshot, the last `TimelineNotice.indexBuilt`, the store's
/// own schema statuses and the `afleet` namespace. Nothing is recomputed and nothing is a second
/// copy of a value another namespace owns.
@MainActor
@Observable
final class SettingsReadout {
    let workspace: Workspace
    private let counter: UnknownFrameCounter

    // Engine
    private(set) var lastCensus: CensusSummary?
    private(set) var unknownFrames = UnknownFrameTally()
    // ConfigHome
    private(set) var projectCount = 0
    private(set) var transcriptCount = 0
    private(set) var symlinkedProjectsSkipped = 0
    /// The sessions the sidebar would list, from the resolved config home and no other.
    private(set) var sessions: [IndexEntry] = []
    // Storage
    private(set) var schemaStatuses: [StoreNamespace: SchemaStatus] = [:]
    // Developer
    var settings = AfleetSettings()

    /// The app's one reservation set, for item 43's arming control alone (spec §15).
    ///
    /// Nil for a Settings window opened over a workspace with no app model behind it — a route that
    /// has no channels to answer a card on either — and the control is then absent rather than
    /// arming something nothing reads.
    @ObservationIgnored private let decisions: DecisionReservations?

    init(workspace: Workspace, decisions: DecisionReservations? = nil) {
        self.workspace = workspace
        self.decisions = decisions
        counter = UnknownFrameCounter(store: workspace.store)
    }

    // MARK: - Item 43's Developer action

    /// Whether the next permission answer will go out malformed.
    var malformedAnswerArmed: Bool { decisions?.malformedNextPermissionAnswer ?? false }

    /// Whether the control exists at all: a Settings window with no reservation set behind it can
    /// arm nothing.
    var offersMalformedAnswerAction: Bool { decisions != nil }

    /// Arms it. One-shot and unpersisted, so it dies with the process; `DecisionAnswering` spends it
    /// on the next permission answer from any surface.
    func armMalformedAnswer() { decisions?.malformedNextPermissionAnswer = true }

    // MARK: - Environment

    var shell: String { workspace.environment.shell }
    var captureMode: ResolvedEnvironment.CaptureMode { workspace.environment.mode }
    var pathEntryCount: Int { workspace.environment.path.count }
    var capturedAt: Date { workspace.environment.capturedAt }

    // MARK: - Engine

    var binary: URL { workspace.binary }
    var installedVersion: SemanticVersion { workspace.installed }
    var protocolBaseline: String { ProtocolBaseline.version }
    /// The launch reached a workspace, so the gate accepted; the route is the verdict.
    var gateVerdict: String { "accepted" }

    // MARK: - ConfigHome

    var configHomeRoot: URL { workspace.configHome.root }
    var configHomeSource: ConfigHome.Source { workspace.configHome.source }

    // MARK: - Reading

    func refresh() async {
        let snapshot = await workspace.index.currentSnapshot
        let listed = snapshot.entries.values.filter {
            if case .listed = ListingPolicy.include(ListingPolicy.IndexEntry($0)) { return true }
            return false
        }
        sessions = listed.sorted { $0.mtime > $1.mtime }
        transcriptCount = snapshot.entries.count
        projectCount = Set(snapshot.entries.values.map(\.slug)).count
        symlinkedProjectsSkipped = workspace.diagnostics.timeline.lastIndexBuild?.symlinkedProjectsSkipped ?? 0

        lastCensus = (try? await workspace.store.read(CensusSummary.self, namespace: .fleetKit,
                                                      key: FleetKitKeys.lastCensus)) ?? nil
        unknownFrames = await counter.snapshot()
        settings = await AfleetSettingsStore.read(from: workspace.store)

        if let file = workspace.store as? FileStateStore {
            var statuses: [StoreNamespace: SchemaStatus] = [:]
            for namespace in StoreNamespace.allCases {
                statuses[namespace] = await file.schemaStatus(of: namespace)
            }
            schemaStatuses = statuses
        }
    }

    // MARK: - Writing

    /// The Developer section's edits. The binary override is read by
    /// `BinaryLocator.locate(in:override:)` at launch, so it takes effect on the next launch and
    /// not live — which is what item 33 points at a `fake-claude`.
    func save() async {
        try? await AfleetSettingsStore.write(settings, to: workspace.store)
        // Raw frame capture is the one Developer setting that is live: the spawn path asks the switch at every
        // spawn, so the next channel opened captures. Channels already running keep what they were spawned with.
        workspace.rawCapture?.isOn = settings.developer.rawFrameCapture
    }

    /// Removes only known diagnostics files — the four logs and §11's capture tree — and leaves the four sinks
    /// writing. The renewal is the composer's, because deleting a file out from under an open handle turns
    /// logging off silently rather than clearing it.
    ///
    /// The capture's own handles are closed first, for that same reason turned around: a capture writing into a
    /// file that has just been unlinked goes on filling an inode nobody can reach or account for.
    func deleteDiagnostics() async {
        await workspace.rawCapture?.capture.prune(keeping: [])
        workspace.diagnostics.deleteLogs()
    }

    func revealDiagnostics() {
        NSWorkspace.shared.activateFileViewerSelecting([workspace.diagnostics.directory])
    }
}

/// Spec §9's five sections.
struct SettingsView: View {
    @Bindable var readout: SettingsReadout

    /// Item 43's control, worded as the acceptance item words it.
    static let malformedAnswerAction = "Send malformed answer to next permission"

    var body: some View {
        Form {
            Section("Environment") {
                LabeledContent("Shell", value: readout.shell)
                LabeledContent("Capture", value: readout.captureMode.rawValue)
                LabeledContent("PATH entries", value: "\(readout.pathEntryCount)")
                LabeledContent("Captured", value: readout.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Engine") {
                LabeledContent("Binary", value: readout.binary.path)
                LabeledContent("Installed version", value: readout.installedVersion.description)
                LabeledContent("Protocol baseline", value: readout.protocolBaseline)
                LabeledContent("Gate verdict", value: readout.gateVerdict)
                LabeledContent("Last census", value: censusSummary)
                LabeledContent("Unknown frame types seen", value: "\(readout.unknownFrames.total)")
            }

            Section("Config home") {
                LabeledContent("Root", value: readout.configHomeRoot.path)
                LabeledContent("Source", value: readout.configHomeSource.rawValue)
                LabeledContent("Projects", value: "\(readout.projectCount)")
                LabeledContent("Transcripts", value: "\(readout.transcriptCount)")
                LabeledContent("Symlinked project directories skipped",
                               value: "\(readout.symlinkedProjectsSkipped)")
            }

            Section("Storage") {
                ForEach(StoreNamespace.allCases, id: \.self) { namespace in
                    LabeledContent(namespace.rawValue, value: Self.describe(readout.schemaStatuses[namespace]))
                }
                Button("Delete diagnostics", role: .destructive) { Task { await readout.deleteDiagnostics() } }
            }

            Section("Developer") {
                TextField("Binary path override", text: Binding(
                    get: { readout.settings.developer.binaryPathOverride ?? "" },
                    set: { readout.settings.developer.binaryPathOverride = $0.isEmpty ? nil : $0 }))
                Text("Takes effect on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Capture raw frames", isOn: $readout.settings.developer.rawFrameCapture)
                Toggle("Leave the transcript watcher stopped",
                       isOn: $readout.settings.developer.transcriptWatcherStopped)
                Toggle("Isolated settings for new channels",
                       isOn: $readout.settings.developer.isolatedSettingsForNewChannels)
                // C7.6's G4. `isInspectable` alone puts *Inspect Element* in the Browser panel's
                // context menu, which is the whole of how the inspector is reached — no menu item
                // and no shortcut. Debug builds are inspectable regardless and never read this.
                Toggle("Web inspector in the Browser panel",
                       isOn: $readout.settings.developer.webInspector)
                Text("Takes effect on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if readout.offersMalformedAnswerAction {
                    Button(Self.malformedAnswerAction) { readout.armMalformedAnswer() }
                    Text(readout.malformedAnswerArmed
                         ? "The next permission answer will be sent in a shape the engine rejects."
                         : "Arms one answer. It is not saved and does not survive a relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Reveal the diagnostics log") { readout.revealDiagnostics() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .task { await readout.refresh() }
        .onChange(of: readout.settings) { _, _ in
            Task { await readout.save() }
        }
    }

    private var censusSummary: String {
        guard let census = readout.lastCensus else { return "none" }
        return "\(census.cliVersion), \(census.newInboundSubtypes.count) new inbound subtypes"
    }

    private static func describe(_ status: SchemaStatus?) -> String {
        switch status {
        case .current: "current"
        case .migrated(let from): "migrated from \(from)"
        case .newer(let found): "written by a newer build (schema \(found))"
        case .absent, nil: "absent"
        }
    }
}

/// The Settings scene, including routes that have not constructed a workspace.
struct AppSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
            if let readout = model.settingsReadout {
                SettingsView(readout: readout)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Workspace details become available after setup.")
                        .foregroundStyle(.secondary)
                    if model.canResetBinaryOverride {
                        Text("The saved binary override can be cleared without opening a workspace.")
                        Button("Reset binary override and check again") {
                            Task { await model.resetBinaryOverrideAndRetry() }
                        }
                    }
                    if let error = model.settingsRecoveryError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(40)
                .frame(width: 420)
            }
    }
}
