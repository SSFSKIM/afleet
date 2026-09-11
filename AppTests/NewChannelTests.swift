import Foundation
import XCTest
import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// §8.2's *New channel* and §14 item 3, on the app's side: the row a created channel gets before
/// any transcript exists, the moment the index replaces it, the sheet's one action, and the two
/// gates that keep a process out until the preconditions allow one.
///
/// Nothing here prints a title, a path or a session id: every clause about a fixture-derived or
/// message-bearing value is a boolean with a fixed message (§11).
@MainActor
final class NewChannelTests: XCTestCase {

    private static let configHome = FileManager.default.temporaryDirectory
        .appending(path: "afleet-new-channel-unwritten")

    /// Two invented project roots. Neither exists, which is what the grouping falls back to when the
    /// filesystem cannot answer — a directory with no `.git` is its own project section.
    private static let project = URL(fileURLWithPath: "/invented/new-channel-project", isDirectory: true)
    private static let otherProject = URL(fileURLWithPath: "/invented/other-project", isDirectory: true)

    private func browser(_ lifecycle: LifecycleDouble) -> FleetBrowserModel {
        FleetBrowserModel(lifecycle: lifecycle, configHome: Self.configHome)
    }

    private func key(_ nibble: String) -> ChannelKey {
        ChannelKey(configHome: Self.configHome, session: SidebarFixtures.session(nibble))
    }

    // MARK: - The pending row

    /// A created channel has a row, in the section its directory belongs to, before the index has
    /// heard of it.
    ///
    /// Without it the channel the user just made has nowhere to be seen: `ShellModel.select` moves
    /// the focus, `ChannelColumnView` resolves what it draws through `FleetBrowserModel.row(_:)`,
    /// and a selection with no row leaves the column on its pick-a-channel placeholder.
    func testACreatedChannelGetsARowInItsProjectSection() async throws {
        let model = browser(LifecycleDouble())
        let created = key("1")

        model.addPending(created, name: nil, cwd: Self.project)

        let row = try XCTUnwrap(model.row(created.session), "a created channel has no row")
        XCTAssertTrue(row.cwd == Self.project, "the pending row does not run where the request said")
        XCTAssertTrue(row.isRecent, "a channel created a moment ago is not recent")
        XCTAssertFalse(row.isArchived, "a created channel was filed under Archived")
        XCTAssertTrue(row.offersOwnedActions, "a created channel was listed read-only")
        XCTAssertTrue(row.title == FleetBrowserModel.newChannelTitle,
                      "an unnamed created channel does not carry the New channel placeholder")
        XCTAssertTrue(row.preview.isEmpty, "a channel with no transcript reported a preview")
        // `isProvisional` means *restored from the persisted snapshot*, which the sidebar italicises.
        // A created channel is the newest thing the fleet knows about, not a stale paint.
        XCTAssertFalse(row.isProvisional, "a created channel was drawn as a restored snapshot")
        XCTAssertTrue(model.sections.contains { $0.root == Self.project },
                      "the created channel produced no project section")
        XCTAssertTrue(model.archived.isEmpty, "the created channel landed in the archive")
    }

    /// The session name the user typed is the row's title until the engine has one of its own.
    func testANamedCreationCarriesTheNameAsItsTitle() async throws {
        let model = browser(LifecycleDouble())
        let created = key("2")

        model.addPending(created, name: "invented session name", cwd: Self.project)

        let row = try XCTUnwrap(model.row(created.session))
        XCTAssertTrue(row.title == "invented session name", "a named creation lost its name")
        XCTAssertTrue(row.titleSource == .customTitle, "a typed name was not reported as a custom title")
    }

    /// §8.2's worktree semantics through the grouping: a `-w` creation's row lands under the
    /// repository the CLI will make the checkout inside, from the first paint.
    ///
    /// `ChannelCreation.expectedCWD` is what makes that possible, and it is the engine's own path —
    /// `<repo>/.claude/worktrees/<name>` (spike S10) — rather than a guess, so the row does not move
    /// section when the engine finally reports the directory it created.
    func testAWorktreeCreationsRowLandsUnderItsRepository() async throws {
        let request = ChannelCreation(cwd: Self.project, worktree: .named("invented-worktree"))
        let expected = Self.project.appending(path: ".claude/worktrees/invented-worktree",
                                              directoryHint: .isDirectory)
        XCTAssertTrue(request.expectedCWD.standardizedFileURL == expected.standardizedFileURL,
                      "a worktree creation does not expect the CLI's own checkout path")

        let model = browser(LifecycleDouble())
        model.addPending(key("3"), name: nil, cwd: request.expectedCWD)

        // Neither directory exists, so `PathMemo` falls back to the path itself and the worktree is
        // its own section. What this holds is that the row is *placed* at all and placed at the
        // checkout — the repository join over a real worktree is `ProjectGroupingTests`'.
        let row = try XCTUnwrap(model.row(key("3").session), "a worktree creation has no row")
        XCTAssertTrue(row.cwd?.standardizedFileURL == expected.standardizedFileURL,
                      "the worktree creation's row does not run in the checkout")
        XCTAssertTrue(model.sections.contains { $0.allRows.contains { $0.id == row.id } },
                      "the worktree creation's row reached no section")
    }

    /// The moment the index lists the created channel, the indexed row replaces the pending one —
    /// one row throughout, and the AI title the engine minted becomes the row's.
    ///
    /// This is item 3's second clause: *the channel gains an AI title after the first turn*. Nothing
    /// here asks for a title; `TitlePrecedence` already resolved it and the row reports where it
    /// came from.
    func testTheIndexDeltaReplacesThePendingRowWithTheIndexedOne() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let created = key("4")
        model.addPending(created, name: nil, cwd: Self.project)
        XCTAssertEqual(model.allRows.count, 1, "the created channel drew \(model.allRows.count) rows")

        var entry = SidebarFixtures.entry(created.session, configHome: Self.configHome,
                                          cwd: Self.project.path, mtime: Date(),
                                          title: "an invented AI title")
        entry.titleSource = .aiTitle
        await model.apply(IndexDelta(added: [created.session], updated: [], removed: [], durationMs: 0)) { _ in
            entry
        }

        XCTAssertEqual(model.allRows.count, 1,
                       "the indexed row and the pending row were both drawn (\(model.allRows.count) rows)")
        let row = try XCTUnwrap(model.row(created.session), "the created channel lost its row on the delta")
        XCTAssertTrue(row.titleSource == .aiTitle,
                      "the row kept the placeholder title after the engine's own arrived")
        XCTAssertFalse(row.title == FleetBrowserModel.newChannelTitle,
                       "the indexed row still reads as a New channel placeholder")
        XCTAssertFalse(row.decidingRule == FleetBrowserModel.creationRule,
                       "the indexed row is still attributed to the creation rather than to a listing rule")
    }

    /// A created channel's live half is kept across a fresh index build that does not name it.
    ///
    /// The join's snapshot path narrows everything it holds to what the snapshot listed. A created
    /// channel is by definition not listed, so narrowing on the index alone dropped its origin, its
    /// banner and the selection pointing at it the first time the index rebuilt under it — which on
    /// a warm launch is immediately.
    func testASnapshotThatCannotNameACreatedChannelKeepsItsRowAndItsLiveHalf() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let created = key("5")
        model.addPending(created, name: nil, cwd: Self.project)
        model.select(created.session)
        model.apply(SidebarFixtures.state(created, origin: .owned(.connecting)))

        model.apply(SidebarFixtures.snapshot(configHome: Self.configHome, entries: []))

        let row = try XCTUnwrap(model.row(created.session), "an index build dropped the created channel's row")
        XCTAssertTrue(row.origin == .owned(.connecting), "the created channel lost its live half")
        XCTAssertTrue(model.selected == created.session, "the created channel lost the selection")
    }

    /// A delta that **removes** a created channel's id does not take its live half, its banner or
    /// the selection with it.
    ///
    /// `paint` was made to ask this and the delta path was not, which left the two halves of one
    /// join disagreeing. The id really does arrive here: the first delta that lists a created
    /// channel names it `added`, and a transcript deleted a moment later names it `removed` while
    /// the channel is still there, with a process, being typed into.
    func testADeltaRemovingACreatedChannelsIDKeepsItsRowAndItsLiveHalf() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let created = key("6")
        model.addPending(created, name: nil, cwd: Self.project)
        model.select(created.session)
        model.apply(SidebarFixtures.state(created, origin: .owned(.ready)))

        await model.apply(IndexDelta(added: [], updated: [], removed: [created.session],
                                     durationMs: 0)) { _ in nil }

        let row = try XCTUnwrap(model.row(created.session), "a removal dropped the created channel's row")
        XCTAssertTrue(row.origin == .owned(.ready), "the created channel lost its live half to a removal")
        XCTAssertTrue(model.selected == created.session, "the created channel lost the selection to a removal")
    }

    /// The same for the arm where the listing policy stops listing an id the index still resolves.
    func testAnUnlistedVerdictOnACreatedChannelKeepsItsLiveHalf() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let created = key("7")
        model.addPending(created, name: nil, cwd: Self.project)
        model.apply(SidebarFixtures.state(created, origin: .owned(.connecting)))

        // A `continued-in` entry is what the listing policy stops listing, and it is the ordinary
        // way an id the index resolves loses its row.
        let entry = SidebarFixtures.entry(created.session, configHome: Self.configHome,
                                           cwd: Self.project.path, mtime: Date(),
                                           continuedIn: SidebarFixtures.session("8"))
        await model.apply(IndexDelta(added: [], updated: [created.session], removed: [],
                                     durationMs: 0)) { _ in entry }

        let row = try XCTUnwrap(model.row(created.session), "an unlisted verdict dropped the created row")
        XCTAssertTrue(row.origin == .owned(.connecting), "the created channel lost its live half")
    }

    /// A delta whose entry the index can no longer **resolve** lets the channel go completely.
    ///
    /// The third arm of the same join, and the asymmetry runs the other way here: the arm dropped
    /// the row and kept the live half, the banner and the selection, so the sidebar held an origin
    /// and a selection for a channel it could no longer draw. `TranscriptIndex.update` names a
    /// candidate in `updated` and then answers nil for it when the file went between the two, which
    /// is an ordinary watcher batch.
    func testADeltaWhoseEntryCannotBeResolvedLetsTheChannelGo() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let listed = SidebarFixtures.session("a")
        model.apply(SidebarFixtures.snapshot(configHome: Self.configHome, entries: [
            SidebarFixtures.entry(listed, configHome: Self.configHome, cwd: Self.project.path, mtime: Date())
        ]))
        model.select(listed)
        model.apply(SidebarFixtures.state(ChannelKey(configHome: Self.configHome, session: listed),
                                           origin: .owned(.ready)))
        XCTAssertNotNil(model.row(listed), "the snapshot drew no row, so this proves nothing")

        await model.apply(IndexDelta(added: [], updated: [listed], removed: [], durationMs: 0)) { _ in nil }

        XCTAssertNil(model.row(listed), "an unresolvable entry kept its row")
        XCTAssertNil(model.selected, "the selection still points at a channel the sidebar cannot draw")
    }

    /// And the same arm keeps a **created** channel's live half, which is what the guard is for.
    func testADeltaWhoseEntryCannotBeResolvedKeepsACreatedChannelsLiveHalf() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let created = key("b")
        model.addPending(created, name: nil, cwd: Self.project)
        model.select(created.session)
        model.apply(SidebarFixtures.state(created, origin: .owned(.ready)))

        await model.apply(IndexDelta(added: [], updated: [created.session], removed: [],
                                     durationMs: 0)) { _ in nil }

        let row = try XCTUnwrap(model.row(created.session),
                                "an unresolvable entry dropped the created channel's row")
        XCTAssertTrue(row.origin == .owned(.ready), "the created channel lost its live half")
        XCTAssertTrue(model.selected == created.session, "the created channel lost the selection")
    }

    // MARK: - The sheet's one action

    /// A ready verdict: create, select, and spawn — in that order, once each.
    func testConfirmCreatesSelectsAndOpensOnAReadyVerdict() async throws {
        let rig = try await SheetRig(verdict: .ready)
        rig.model.sessionName = "invented session name"

        let closed = await rig.model.confirm()

        XCTAssertTrue(closed, "a successful creation left the sheet up")
        let minted = await rig.creator.count
        XCTAssertEqual(minted, 1, "the sheet minted \(minted) channels, not one")
        let keys = await rig.creator.keys
        let created = try XCTUnwrap(keys.first)
        XCTAssertTrue(rig.shell.focus.session == created.session, "the window did not move to the new channel")
        let opens = await rig.lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(opens.count, 1, "a ready creation issued \(opens.count) open(s), not one")
        XCTAssertTrue(opens.first?.key == created, "the open named a channel other than the created one")
        let named = await rig.creator.requests.first?.name
        XCTAssertTrue(named == "invented session name", "the session name did not reach the request")
    }

    /// Item 47's first half: an untrusted root leaves the channel created, selected and
    /// **processless**, with the trust banner to come from `ChannelDecorations`.
    ///
    /// Directive 8's clause, and the reason creation and spawning are two calls: a sheet that
    /// spawned as it created would have a child running in an untrusted project before any banner
    /// could be drawn, and §6.11 says an untrusted workspace runs a silently reduced harness.
    func testConfirmOnAnUntrustedRootCreatesTheChannelAndSpawnsNothing() async throws {
        let rig = try await SheetRig(verdict: .untrusted(root: Self.project))
        let spawns = SpawnCounter()
        await rig.lifecycle.setSpawn(spawns.factory)

        let closed = await rig.model.confirm()

        XCTAssertTrue(closed, "the sheet stayed up over a channel it had already created")
        let minted = await rig.creator.count
        XCTAssertEqual(minted, 1, "the untrusted creation did not mint a channel")
        let keys = await rig.creator.keys
        let created = try XCTUnwrap(keys.first)
        XCTAssertTrue(rig.shell.focus.session == created.session,
                      "the untrusted channel was created and not shown")
        let acted = await rig.lifecycle.actions.count
        XCTAssertEqual(acted, 0, "an untrusted creation asked the lifecycle to act")
        XCTAssertEqual(spawns.count, 0, "an untrusted creation built a process")
        XCTAssertTrue(rig.browser.row(created.session) != nil,
                      "the untrusted channel has no row to draw the trust banner over")
    }

    /// The Developer setting is what the request carries, and it is read at the moment the sheet is
    /// opened rather than captured at launch: Settings writes it as the toggle moves, and it decides
    /// whether the channel's own launch line narrows its setting sources for the life of the session.
    func testTheIsolationSettingReachesTheRequest() async throws {
        for isolated in [true, false] {
            let rig = try await SheetRig(verdict: .ready, isolatedSettings: isolated)
            _ = await rig.model.confirm()
            let requests = await rig.creator.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertTrue(request.isolatedSettings == isolated,
                          "the isolated-settings toggle did not reach the request")
            XCTAssertTrue(rig.model.isolatedSettings == isolated,
                          "the sheet reported the wrong isolation state to the user")
        }
    }

    /// The worktree toggle needs a name before *Create* is offered, and the name reaches the request.
    func testTheWorktreeToggleGatesCreateUntilItHasAName() async throws {
        let rig = try await SheetRig(verdict: .ready)
        XCTAssertTrue(rig.model.canCreate, "a sheet over a section root could not create")

        rig.model.wantsWorktree = true
        XCTAssertFalse(rig.model.canCreate, "a worktree creation with no name was offered")
        rig.model.worktreeName = "invented-worktree"
        XCTAssertTrue(rig.model.canCreate, "a named worktree creation was still refused")

        _ = await rig.model.confirm()
        let requests = await rig.creator.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.worktree == .named("invented-worktree"),
                      "the worktree name did not reach the request")
    }

    /// The global entry has no root, so it offers a chooser and refuses to create until one is
    /// picked: a channel with no directory would be seeded in the config home, which every
    /// precondition then refuses.
    func testTheGlobalEntryRefusesToCreateUntilADirectoryIsChosen() async throws {
        let rig = try await SheetRig(verdict: .ready, root: nil)
        XCTAssertTrue(rig.model.offersDirectoryChooser, "the global entry offered no directory chooser")
        XCTAssertFalse(rig.model.canCreate, "the global entry created a channel with no directory")

        rig.model.chosenDirectory = Self.otherProject
        XCTAssertTrue(rig.model.canCreate, "a chosen directory did not enable the creation")
        _ = await rig.model.confirm()
        let chosen = await rig.creator.requests.first?.cwd
        XCTAssertTrue(chosen == Self.otherProject, "the chosen directory did not reach the request")
    }

    /// The section entry's directory is read-only, so a channel cannot be made in a project other
    /// than the one whose header was pressed.
    func testTheSectionEntryOffersNoChooser() async throws {
        let rig = try await SheetRig(verdict: .ready)
        XCTAssertFalse(rig.model.offersDirectoryChooser,
                       "a sheet opened over a section header offered to change its project")
        XCTAssertTrue(rig.model.cwd == Self.project, "the section's root did not pre-fill the sheet")
    }

    /// The permission modes the sheet offers are the composer's own list, `bypassPermissions`
    /// excluded: §8.6 puts that mode behind a disclaimer and a quiescent restart, and a launch flag
    /// chosen from a sheet would walk straight past the gate.
    func testTheSheetOffersTheComposersPermissionModes() async throws {
        let rig = try await SheetRig(verdict: .ready)
        XCTAssertEqual(rig.model.permissionModes, ComposerModel.cyclablePermissionModes,
                       "the sheet's mode list is not the composer's")
        XCTAssertFalse(rig.model.permissionModes.contains(.bypassPermissions),
                       "the sheet offered bypassPermissions at creation")
    }

    /// Blank fields are the CLI's own defaults and never empty tokens: `LaunchConfiguration` emits
    /// `--model`, `--agent`, `--effort` and `-n` exactly when their value is non-nil, so a blank
    /// field left as `""` would reach the engine as an option with a missing value.
    func testBlankFieldsBecomeNilRatherThanEmptyTokens() async throws {
        let rig = try await SheetRig(verdict: .ready)
        rig.model.model = "  "
        rig.model.agent = ""
        rig.model.effort = "\n"
        rig.model.sessionName = " "

        let request = try XCTUnwrap(rig.model.request, "a sheet over a root described no request")
        XCTAssertNil(request.model, "a blank model field became a token")
        XCTAssertNil(request.agent, "a blank agent field became a token")
        XCTAssertNil(request.effort, "a blank effort field became a token")
        XCTAssertNil(request.name, "a blank session name became a token")
    }

    // MARK: - The two guards the menu and the sheet carry

    /// The File menu's item is offered exactly when the sheet has somewhere to be presented.
    ///
    /// **The predicate and not the modifier.** `AfleetApp.shellCommands` is a `Commands` builder
    /// inside a `Scene`, and constructing the `App` value instantiates its `@State` model and its
    /// `NSApplicationDelegateAdaptor`; there is no way to evaluate it here, and `SidebarView.body`
    /// already showed what happens when a test tries to render a scene-level value. So what is
    /// asserted is the decision — `model.route.workspace == nil` — which is the whole of what the
    /// `.disabled` carries, and the attachment itself is read at review.
    ///
    /// It has to be the route and not `model.browser`: the coordinator is built inside the launch,
    /// so the browser exists while the route is still `.launching`, which is the window a user has
    /// the menu open in.
    func testTheMenuItemIsOfferedOnlyOnceTheRouteHasAWorkspace() async throws {
        let launching = AppModel(registry: RowRegistry())
        XCTAssertTrue(launching.route.isLaunching, "a fresh model is not launching, so this proves nothing")
        XCTAssertNil(launching.route.workspace, "a launching route offered the New Channel item")

        let rig = try await WorkspaceRig()
        XCTAssertNotNil(rig.app.route.workspace, "a launched route does not offer the New Channel item")
        // The browser exists on both, which is why it is the wrong predicate.
        XCTAssertNotNil(rig.app.browser, "the launched model has no browser")
    }

    /// The sheet always has a way out, including before its model exists.
    ///
    /// The model is built asynchronously and a launch that has not reached a workspace never answers
    /// one, so a sheet with only a progress view would be a window the user cannot close.
    func testTheSheetOffersCancelBeforeItsModelExists() throws {
        let sheet = NewChannelSheet(request: NewChannelRequest(id: 1, root: Self.project)) {}
        let cancel = ViewTree.button("Cancel", in: sheet.body)
        XCTAssertNotNil(cancel, "the sheet with no model yet offered no way out")
    }

    // MARK: - The production seams

    /// `FleetCoordinator.createChannel` is the pairing itself: one `Fleet.create`, and the row that
    /// makes the channel visible.
    ///
    /// Asserted through the coordinator and not through an equivalent closure, because the pairing
    /// is the thing: a `create` with no `addPending` hands the window a session the sidebar cannot
    /// draw and the column cannot mount, and every model-level clause in this file would stay green.
    func testTheCoordinatorPairsCreationWithTheRowThatShowsIt() async throws {
        let lifecycle = LifecycleDouble()
        let creator = CreatorDouble(configHome: Self.configHome)
        let registrar = RegistrarDouble()
        let model = browser(lifecycle)
        let coordinator = FleetCoordinator(configHome: Self.configHome, registrar: registrar,
                                           creator: creator,
                                           index: StubIndex(persisted: nil,
                                                            built: SidebarFixtures.snapshot(
                                                                configHome: Self.configHome, entries: [])),
                                           model: model)
        defer { coordinator.stop() }

        let made = await coordinator.createChannel(ChannelCreation(cwd: Self.project))
        let created = try XCTUnwrap(made, "the coordinator created nothing")

        let minted = await creator.count
        XCTAssertEqual(minted, 1, "the coordinator minted more than one channel")
        XCTAssertTrue(model.row(created.session) != nil, "the created channel got no row")
        // **And nothing was registered.** The creation already filed the seed; a `register` over it
        // would tell the fleet about a channel it had just made, with the request's cwd in place of
        // the one the engine will report.
        let registered = await registrar.count
        XCTAssertEqual(registered, 0, "the coordinator registered a channel it had just created")
    }

    /// A worktree creation's row runs at the checkout the CLI is about to make, which is
    /// `ChannelCreation.expectedCWD` and is the coordinator's choice to make.
    func testTheCoordinatorDrawsAWorktreeCreationAtItsCheckout() async throws {
        let lifecycle = LifecycleDouble()
        let creator = CreatorDouble(configHome: Self.configHome)
        let model = browser(lifecycle)
        let coordinator = FleetCoordinator(configHome: Self.configHome, registrar: RegistrarDouble(),
                                           creator: creator,
                                           index: StubIndex(persisted: nil,
                                                            built: SidebarFixtures.snapshot(
                                                                configHome: Self.configHome, entries: [])),
                                           model: model)
        defer { coordinator.stop() }

        let request = ChannelCreation(cwd: Self.project, worktree: .named("invented-worktree"))
        let madeWorktree = await coordinator.createChannel(request)
        let created = try XCTUnwrap(madeWorktree)

        let row = try XCTUnwrap(model.row(created.session))
        XCTAssertTrue(row.cwd?.standardizedFileURL == request.expectedCWD.standardizedFileURL,
                      "the worktree creation's row does not run at the checkout")
        XCTAssertFalse(row.cwd?.standardizedFileURL == Self.project.standardizedFileURL,
                       "the worktree creation's row runs in the repository, not the checkout")
    }

    /// `AppModel.makeNewChannelModel` reads the Developer setting **from the store, at the moment
    /// the sheet opens**.
    ///
    /// Settings writes that document as the toggle moves, so a value captured at launch would be
    /// the one the app started with — and this setting decides whether the channel's own launch line
    /// narrows its setting sources for the life of the session.
    func testTheSheetsModelReadsTheIsolationSettingFromTheStoreAtOpenTime() async throws {
        let rig = try await WorkspaceRig()
        var settings = AfleetSettings()
        settings.developer.isolatedSettingsForNewChannels = true
        try await AfleetSettingsStore.write(settings, to: rig.workspace.store)

        let built = await rig.app.makeNewChannelModel(root: Self.project)
        let on = try XCTUnwrap(built, "no workspace was bound, so the sheet has no model")
        XCTAssertTrue(on.isolatedSettings, "the sheet did not read the isolation setting the store holds")

        // Written again while the first sheet is still alive, as Settings would: the next sheet
        // reads the new value and the first keeps the one it was built with.
        settings.developer.isolatedSettingsForNewChannels = false
        try await AfleetSettingsStore.write(settings, to: rig.workspace.store)
        let rebuilt = await rig.app.makeNewChannelModel(root: Self.project)
        let off = try XCTUnwrap(rebuilt)
        XCTAssertFalse(off.isolatedSettings, "a second sheet did not re-read the setting")
        XCTAssertTrue(on.isolatedSettings, "the first sheet's request changed under it")
    }

    /// A replacing request rebuilds the sheet's model, so the second press's project is the one a
    /// channel is created in.
    ///
    /// `.sheet(item:)` keeps one view value across a replacing item — a section header's item and
    /// then Cmd+Shift+N over the open sheet is two requests for one presentation — and a `.task`
    /// that only ran while the model was nil left the second sheet holding the first request's root.
    ///
    /// **What is asserted here is the model and the request identity, not the `.task(id:)` itself.**
    /// SwiftUI owns `@State` and the task's lifetime through the render tree, and neither exists
    /// outside one; there is no way from here to observe that a replaced item re-ran the task. So
    /// this holds the two halves that *are* observable — two presses are two distinct request
    /// values, which is what makes the keying fire at all, and the factory answers per root — and
    /// the keying itself is read at review. Filed as tracker 454.
    func testAReplacingRequestRebuildsTheSheetsModel() async throws {
        let rig = try await WorkspaceRig()

        let firstBuilt = await rig.app.makeNewChannelModel(root: Self.project)
        let first = try XCTUnwrap(firstBuilt)
        XCTAssertTrue(first.cwd == Self.project, "the first request's root did not reach its model")
        let secondBuilt = await rig.app.makeNewChannelModel(root: Self.otherProject)
        let second = try XCTUnwrap(secondBuilt)
        XCTAssertTrue(second.cwd == Self.otherProject, "a second request's root did not reach a fresh model")

        // The view's own key is what makes the rebuild happen at all, and it is the request itself:
        // two presses are two `NewChannelRequest` values, so `.task(id: request)` re-runs.
        rig.shell.presentNewChannel(root: Self.project)
        let firstRequest = try XCTUnwrap(rig.shell.newChannelRequest)
        rig.shell.presentNewChannel(root: Self.otherProject)
        let secondRequest = try XCTUnwrap(rig.shell.newChannelRequest)
        XCTAssertNotEqual(firstRequest, secondRequest,
                          "two presses are one request value, so the sheet's task would not re-run")
    }

    // MARK: - The entry points

    /// Both entries write the same request, and each press is a new one: `.sheet(item:)` takes a
    /// superseded sheet down only when the item it is bound to is a different value.
    func testBothEntryPointsRaiseTheSheetAndEachPressIsItsOwn() async throws {
        let shell = ShellModel()
        XCTAssertNil(shell.newChannelRequest, "a fresh shell already had a New channel sheet up")

        shell.presentNewChannel(root: Self.project)
        let fromSection = try XCTUnwrap(shell.newChannelRequest, "the section header raised no sheet")
        XCTAssertTrue(fromSection.root == Self.project, "the section's root did not reach the sheet")

        shell.presentNewChannel(root: nil)
        let global = try XCTUnwrap(shell.newChannelRequest, "the global entry raised no sheet")
        XCTAssertNil(global.root, "the global entry pre-filled a directory")
        XCTAssertNotEqual(global.id, fromSection.id, "a second press was the same sheet item")

        shell.dismissNewChannel()
        XCTAssertNil(shell.newChannelRequest, "dismissing left the sheet up")
    }

    /// The sidebar's section header carries the item, and it names the section's own root.
    ///
    /// Walked through the view rather than asserted on the model, because the press is the only
    /// thing that connects the two and a button whose action wrote a different root would leave
    /// every model-level clause above green.
    func testTheSectionHeaderCarriesTheNewChannelItem() async throws {
        let lifecycle = LifecycleDouble()
        let model = browser(lifecycle)
        let shell = ShellModel()
        model.apply(SidebarFixtures.snapshot(configHome: Self.configHome, entries: [
            SidebarFixtures.entry(SidebarFixtures.session("7"), configHome: Self.configHome,
                                  cwd: Self.project.path, mtime: Date())
        ]))
        let section = try XCTUnwrap(model.sections.first, "the snapshot produced no section")

        // The header value the sidebar builds, not `SidebarView.body`: a `List(selection:)`
        // evaluated outside a window takes the test host down, which is why the header is a view of
        // its own and why `SidebarView` names it in exactly one place.
        let header = ProjectSectionHeader(section: section, shell: shell)
        // `labelledButton` rather than `button`: the item's label is a `Label` under `.iconOnly`, so
        // the header draws a plus and carries the name for VoiceOver and the help tag rather than
        // spelling the whole sentence out in a sidebar header.
        let button = try XCTUnwrap(ViewTree.labelledButton(ProjectSectionHeader.itemLabel(section),
                                                           in: header.body),
                                   "no project section header carried a New channel item")
        XCTAssertTrue(ViewTree.press(button), "the New channel item carried no action")
        XCTAssertTrue(shell.newChannelRequest?.root == section.root,
                      "the header's item raised a sheet for a different project")
    }

    // MARK: - The column on a channel with no transcript

    /// A created channel is told apart from a missing transcript by whether the fleet owns a
    /// supervisor for it, and it is **not** a failure.
    ///
    /// `Fleet.create` registers the channel, so `events(of:)` answers a stream for it; a row whose
    /// file has gone is a channel the fleet was never told about. Reporting "no transcript in the
    /// index" for the first would tell the user something is broken about a channel that is new.
    func testACreatedChannelAwaitsItsTranscriptRatherThanReportingAFailure() async throws {
        let rig = try await TimelineRig()

        let model = rig.registry.model(for: rig.created)
        await model.open(rig.row)

        XCTAssertTrue(model.awaitsTranscript, "a created channel is not waiting for its transcript")
        XCTAssertNil(model.failure, "a created channel reported a read failure")
        XCTAssertFalse(model.hasOpened, "a channel with no transcript reported an ingestion")

        // The column's own branch, which is the whole point of the flag: the placeholder has to say
        // the channel is new rather than that the app is reading a file that does not exist.
        let drawn = ChannelColumnPlaceholder.choose(failure: model.failure,
                                                    awaitsTranscript: model.awaitsTranscript,
                                                    isEmpty: model.rows.isEmpty,
                                                    hasOpened: model.hasOpened)
        XCTAssertTrue(drawn?.title == "This channel is new",
                      "the column drew no new-channel placeholder for a created channel")
    }

    /// The placeholder precedence, all four arms, so the branch above is a decision and not a
    /// coincidence: a failure outranks the wait, the wait outranks "nothing yet", and a channel with
    /// rows draws no placeholder at all.
    func testThePlaceholderPrecedenceIsFailureThenNewThenEmpty() async throws {
        let failed = ChannelColumnPlaceholder.choose(failure: "an invented shape", awaitsTranscript: true,
                                                     isEmpty: true, hasOpened: false)
        XCTAssertTrue(failed?.title == "This channel could not be read",
                      "a read failure did not outrank the new-channel wait")
        let waiting = ChannelColumnPlaceholder.choose(failure: nil, awaitsTranscript: true,
                                                      isEmpty: true, hasOpened: false)
        XCTAssertTrue(waiting?.title == "This channel is new",
                      "a created channel did not draw the new-channel placeholder")
        let opening = ChannelColumnPlaceholder.choose(failure: nil, awaitsTranscript: false,
                                                      isEmpty: true, hasOpened: false)
        XCTAssertTrue(opening?.title == "Opening…", "an unopened empty channel did not draw Opening…")
        let empty = ChannelColumnPlaceholder.choose(failure: nil, awaitsTranscript: false,
                                                    isEmpty: true, hasOpened: true)
        XCTAssertTrue(empty?.title == "Nothing in this transcript yet",
                      "an opened empty transcript did not say so")
        XCTAssertNil(ChannelColumnPlaceholder.choose(failure: nil, awaitsTranscript: false,
                                                     isEmpty: false, hasOpened: true),
                     "a channel with rows drew a placeholder over them")
    }

    /// A listed row whose transcript has gone still reports the failure: the negative half, without
    /// which the clause above would pass for both.
    ///
    /// The two cases cannot be told apart by asking the fleet — `events(of:)` answers a stream for
    /// **any** registered channel, and tracker 66's case is a registered channel whose file was
    /// deleted between listing and opening. What separates them is the row: a created channel's
    /// carries the creation rule because no `ListingPolicy` rule listed it. That is not a
    /// hypothetical: an earlier version of this branch asked the fleet, and
    /// `ChannelTimelineSeamTests.testAMissingIndexEntryIsRetried` caught it.
    func testAListedRowWhoseTranscriptIsGoneStillReportsTheMissingTranscript() async throws {
        let rig = try await TimelineRig()

        let model = rig.registry.model(for: rig.created)
        await model.open(rig.listedRow)

        XCTAssertFalse(model.awaitsTranscript, "a listed row was treated as a newly created channel")
        XCTAssertNotNil(model.failure, "a missing transcript reported no failure")
    }

    /// The index delta that first lists a created channel is what reopens it — **without a selection
    /// change**, which is the case *New channel* is always in: the column's `.task(id:)` is keyed by
    /// the channel and does not run again for a channel that stayed selected.
    func testTheIndexDeltaOpensTheCreatedChannelWithoutASelectionChange() async throws {
        let rig = try await TimelineRig()
        let model = rig.registry.model(for: rig.created)
        await model.open(rig.row)
        XCTAssertTrue(model.awaitsTranscript, "the created channel was not waiting")

        // The transcript appears, the index is rebuilt, and the coordinator forwards the entry's
        // path — which is the production path a delta takes (`FleetCoordinator.indexChanged`).
        let path = try rig.writeTranscript()
        _ = try await rig.index.build()
        await rig.registry.relocate(rig.created, to: path)

        XCTAssertFalse(model.awaitsTranscript, "the created channel is still waiting after its transcript arrived")
        XCTAssertTrue(model.hasOpened, "the created channel never ingested its transcript")
        XCTAssertNil(model.failure, "the reopened channel reported a failure")
        XCTAssertFalse(model.rows.isEmpty, "the reopened channel drew no timeline rows")
    }

    /// A relocate landing **inside** the first open's index lookup is not lost.
    ///
    /// `performOpen` suspends on `index.entry(...)`, and the delta that first lists a created
    /// channel can land in that window: `transcriptMoved` then finds `awaitsTranscript` still false
    /// and returns, and the channel waits for a second delta that on a quiet channel never comes.
    /// The wait's own entry re-reads the index once, which closes the window against the state
    /// published while the call was in flight rather than against a timer.
    func testARelocateLandingInsideTheFirstLookupIsNotLost() async throws {
        let rig = try await TimelineRig()
        let model = rig.registry.model(for: rig.created)

        // The transcript appears while the first open is suspended on its lookup: the index is
        // rebuilt and the relocation is delivered before `open` resumes.
        let path = try rig.writeTranscript()
        await rig.index.beforeEntry { [index = rig.index, registry = rig.registry, created = rig.created] in
            _ = try? await index.inner.build()
            await registry.relocate(created, to: path)
        }

        await model.open(rig.row)

        XCTAssertFalse(model.awaitsTranscript,
                       "the channel is still waiting for a transcript the index already holds")
        XCTAssertTrue(model.hasOpened, "a relocate inside the lookup left the channel unopened")
        XCTAssertNil(model.failure, "the recovered open reported a failure")
        XCTAssertFalse(model.rows.isEmpty, "the recovered open drew no timeline rows")
    }

    // **There is no test for the flag being re-read on every row change, and there is no re-read.**
    // `isCreatedChannel` is read in exactly one place — `performOpen`, once per model behind
    // `hasOpened` — and every `open` is handed the row the column has just resolved, so a re-read on
    // `adopt` changed nothing any test could observe. The field's own comment says so; a test that
    // passed with the mechanism removed would have said the opposite.

    // MARK: - Rigs

    /// `NewChannelModel` over a recording creator, a lifecycle double staged with one verdict, and
    /// the real browser and shell the app hands it.
    @MainActor
    private struct SheetRig {
        let creator: CreatorDouble
        let lifecycle: LifecycleDouble
        let browser: FleetBrowserModel
        let shell: ShellModel
        let model: NewChannelModel

        init(verdict: SpawnPrecondition, isolatedSettings: Bool = false,
             root: URL? = NewChannelTests.project) async throws {
            creator = CreatorDouble(configHome: NewChannelTests.configHome)
            lifecycle = LifecycleDouble()
            await lifecycle.stagePrecondition(verdict)
            await lifecycle.always(.success(SidebarFixtures.state(
                ChannelKey(configHome: NewChannelTests.configHome, session: SidebarFixtures.session("0")),
                origin: .owned(.connecting))))
            let browser = FleetBrowserModel(lifecycle: lifecycle, configHome: NewChannelTests.configHome)
            self.browser = browser
            let shell = ShellModel()
            self.shell = shell
            let creator = creator
            model = NewChannelModel(root: root, isolatedSettings: isolatedSettings, browser: browser,
                                    lifecycle: lifecycle, shell: shell,
                                    create: { request in
                                        let key = await creator.create(request)
                                        browser.addPending(key, name: request.name, cwd: request.expectedCWD)
                                        return key
                                    })
        }
    }

    /// An `AppModel` taken through a **real launch** with the sequence's seams stubbed, which is
    /// what `makeNewChannelModel` needs: the workspace route, a store to read the settings document
    /// out of, and the production `FleetCoordinator` the composition root builds.
    ///
    /// A launch rather than a test-only binder, because the route and the coordinator are what the
    /// sheet resolves through and a member that only a test could call is the wiring defect
    /// `check-app-wiring` exists to catch.
    @MainActor
    private struct WorkspaceRig {
        let temp: TempTree
        let app: AppModel
        let shell: ShellModel

        var workspace: Workspace { app.route.workspace! }

        init() async throws {
            let temp = try TempTree()
            self.temp = temp
            let configHome = try temp.directory("home")
            let storeRoot = temp.root.appending(path: "store", directoryHint: .isDirectory)
            let diagnosticsRoot = temp.root.appending(path: "logs", directoryHint: .isDirectory)
            let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: binary.path)
            let index = StubIndex(persisted: nil,
                                  built: LaunchFixtures.snapshot(configHome: configHome, ids: []),
                                  delta: IndexDelta(added: [], updated: [], removed: [], durationMs: 0))
            let fleet = StubFleet()
            let watcher = StubWatcher()
            let sequence = LaunchSequence(
                storeRoot: storeRoot,
                diagnosticsRoot: diagnosticsRoot,
                resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
                locateBinary: { _, _ in binary },
                checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
                makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
                makeDiagnostics: { DiagnosticsComposer(directory: $0) },
                makeIndex: { _, _, _ in index },
                fleetFactory: { _, _, _, _, _, _ in fleet },
                makeWatcher: { _ in watcher },
                readClaudeJSON: { _ in true })
            app = AppModel(registry: RowRegistry(), sequence: sequence)
            shell = app.shell
            await app.launch()
            guard app.route.workspace != nil else {
                throw Bail("the stubbed launch reached no workspace")
            }
        }
    }

    private struct Bail: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A workspace with a real `TranscriptIndex` over a scratch home holding **no** transcript for
    /// the created channel, which is exactly the state a creation leaves the index in.
    @MainActor
    private struct TimelineRig {
        let temp: TempTree
        let home: ScratchConfigHome
        let workspace: Workspace
        let lifecycle: LifecycleDouble
        let registry: ChannelTimelineRegistry
        let index: HookedIndex
        let created: ChannelKey
        let app: AppModel
        let shell: ShellModel

        /// The row `FleetBrowserModel` draws for a created channel: its `decidingRule` names the
        /// creation, because no listing rule listed it.
        var row: ChannelRow { row(rule: FleetBrowserModel.creationRule) }

        /// The row a *listed* channel gets, whose transcript has since gone.
        var listedRow: ChannelRow { row(rule: "invented-listing-rule") }

        private func row(rule: String) -> ChannelRow {
            ChannelRow(key: created, title: FleetBrowserModel.newChannelTitle, titleSource: .fallback,
                       preview: "", cwd: NewChannelTests.project, gitBranch: nil, agentName: nil,
                       mtime: Date(), isRecent: true, mode: .ownedCandidate,
                       decidingRule: rule, isProvisional: false)
        }

        init() async throws {
            temp = try TempTree()
            home = try ScratchConfigHome(tree: temp)
            let configHome = home.configHome
            index = HookedIndex(TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage()))
            _ = try await index.build()
            let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store",
                                                                             directoryHint: .isDirectory),
                                           configHomes: [home.root])
            lifecycle = LifecycleDouble()
            workspace = Workspace(configHome: configHome,
                                  environment: LaunchFixtures.environment(home: temp.root,
                                                                          configHome: home.root),
                                  binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                                  installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                                  store: store, index: index, fleet: StubFleet(),
                                  watcher: nil, changes: nil,
                                  diagnostics: DiagnosticsComposer(directory: temp.root
                                      .appending(path: "logs", directoryHint: .isDirectory)),
                                  rawCapture: nil)
            registry = ChannelTimelineRegistry()
            registry.attach(to: workspace, lifecycle: lifecycle)
            created = ChannelKey(configHome: configHome.root, session: SidebarFixtures.session("9"))
            app = AppModel(registry: RowRegistry())
            shell = app.shell
        }

        /// The transcript the engine's first record would produce, and the path the index then holds.
        /// Every byte invented (§11).
        func writeTranscript() throws -> URL {
            try LaunchFixtures.transcript(in: home.root, slug: "invented-new-channel",
                                          session: created.session)
        }
    }
}

/// A real `TranscriptIndex` with one seam: a body that runs **inside** `entry(_:)`, before it
/// answers.
///
/// That suspension is the window `ChannelTimelineModel.performOpen` has, and the interleaving it
/// admits — an index delta landing while the first open is waiting for its own lookup — is not
/// something a test can arrange from outside. Everything else forwards, so what is under test is
/// the model's own recovery and not a stubbed index's idea of one.
actor HookedIndex: IndexAccess {
    let inner: TranscriptIndex
    private var hook: (@Sendable () async -> Void)?

    init(_ inner: TranscriptIndex) { self.inner = inner }

    func beforeEntry(_ body: @escaping @Sendable () async -> Void) { hook = body }

    /// **The hook runs after the inner lookup, not before it.** Before it, the lookup answers with
    /// the entry the hook had just created and `performOpen` takes its ordinary path — the awaiting
    /// branch is never entered and the recovery under test never runs. After it, the answer is the
    /// `nil` the real suspension would have returned while the delta landed behind it, which is the
    /// interleaving exactly.
    func entry(_ id: SessionID) async -> IndexEntry? {
        let body = hook
        hook = nil
        let answer = await inner.entry(id)
        await body?()
        return answer
    }

    func loadPersisted() async throws -> IndexSnapshot? { try await inner.loadPersisted() }
    @discardableResult func build() async throws -> IndexSnapshot { try await inner.build() }
    func update(changed: [URL]) async -> IndexDelta { await inner.update(changed: changed) }
    func persist() async throws { try await inner.persist() }
    var currentSnapshot: IndexSnapshot { get async { await inner.snapshot } }
}
