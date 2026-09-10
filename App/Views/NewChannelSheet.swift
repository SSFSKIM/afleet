import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// §8.2's *New channel* sheet: project, cwd or new worktree, model, permission mode, effort, agent
/// persona and name — then create, and spawn only when the preconditions allow it.
///
/// Every decision is `NewChannelModel`'s. This view reads it, and the one thing it owns is the
/// directory chooser, which is `fileImporter` and can only be a view modifier.
struct NewChannelSheet: View {

    let request: NewChannelRequest
    /// The composition root, for the settings the sheet reads and the fleet it creates through.
    /// Read from the environment because the sidebar that presents this sheet is handed the browser
    /// and the shell and not the whole model.
    @Environment(AppModel.self) private var app: AppModel?

    let dismiss: () -> Void

    /// Built once, from the store, on first appearance. Nil until then, which is what a sheet whose
    /// launch has not reached a workspace keeps.
    @State private var model: NewChannelModel?
    @State private var isChoosingDirectory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New channel").font(.headline).padding(.bottom, 8)
            if let model {
                form(model)
                Divider().padding(.vertical, 10)
                footer(model)
            } else {
                // **A modal always has a way out.** The model is built asynchronously and a launch
                // that has not reached a workspace never answers one, so a sheet with only a
                // progress view would be a window the user cannot close.
                VStack(spacing: 12) {
                    ProgressView()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .frame(width: 460)
        // **Keyed on the request, and the model is rebuilt when it changes.** `.sheet(item:)` keeps
        // one view value across a replacing item — pressing a section header's item and then
        // Cmd+Shift+N over the open sheet is two requests for the same presentation — and a `.task`
        // that only ran while `model == nil` would leave the second sheet holding the first
        // request's root, so a channel would be created in a project the user was no longer
        // looking at.
        .task(id: request) {
            model = await app?.makeNewChannelModel(root: request.root)
        }
    }

    // MARK: - The form

    @ViewBuilder
    private func form(_ model: NewChannelModel) -> some View {
        Form {
            directoryRow(model)
            Section {
                Toggle("New worktree named…", isOn: Binding(get: { model.wantsWorktree },
                                                            set: { model.wantsWorktree = $0 }))
                if model.wantsWorktree {
                    TextField("Worktree name", text: Binding(get: { model.worktreeName },
                                                             set: { model.worktreeName = $0 }))
                    // §8.2 and §7.4: the CLI makes the checkout itself from `-w <name>`, inside the
                    // repository, and the channel resumes in it afterwards. Said here because the
                    // directory the user is looking at is not the one the channel ends up in.
                    Text("Claude Code creates it under .claude/worktrees/ on branch worktree-<name>.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Permission mode", selection: Binding(get: { model.permissionMode },
                                                             set: { model.permissionMode = $0 })) {
                    ForEach(model.permissionModes, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                // Free text and not a picker, deliberately. The model, effort and agent pickers the
                // header draws are **engine readbacks** — their options come from the handshake's
                // `models[]` and the selected model's `supportedEffortLevels` — and a channel that
                // has not been created yet has no process to read back from. Inventing an option
                // set here would be a second, drifting answer to what the engine offers; a blank
                // field is the CLI's own default.
                TextField("Model", text: Binding(get: { model.model }, set: { model.model = $0 }))
                TextField("Effort", text: Binding(get: { model.effort }, set: { model.effort = $0 }))
                TextField("Agent", text: Binding(get: { model.agent }, set: { model.agent = $0 }))
                TextField("Session name", text: Binding(get: { model.sessionName },
                                                        set: { model.sessionName = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func directoryRow(_ model: NewChannelModel) -> some View {
        Section {
            if model.offersDirectoryChooser {
                HStack {
                    Text(model.cwd?.path ?? "Choose a directory…")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(model.cwd == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Button("Choose…") { isChoosingDirectory = true }
                }
                .fileImporter(isPresented: $isChoosingDirectory,
                              allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { model.chosenDirectory = url }
                }
            } else {
                LabeledContent("Directory", value: model.cwd?.path ?? "")
            }
            Text(model.isolatedSettings
                 ? "Isolated settings apply: this channel launches with --setting-sources \"\"."
                 : "Isolated settings do not apply: this channel launches with Claude Code's own settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The footer

    @ViewBuilder
    private func footer(_ model: NewChannelModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        if await model.confirm() { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
            }
        }
    }
}
