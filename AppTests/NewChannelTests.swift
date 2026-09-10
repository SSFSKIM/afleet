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

    /// A workspace with a real `TranscriptIndex` over a scratch home holding **no** transcript for
    /// the created channel, which is exactly the state a creation leaves the index in.
    @MainActor
    private struct TimelineRig {
        let temp: TempTree
        let home: ScratchConfigHome
        let workspace: Workspace
        let lifecycle: LifecycleDouble
        let registry: ChannelTimelineRegistry
        let index: TranscriptIndex
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
            index = TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
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
