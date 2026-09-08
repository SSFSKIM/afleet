import Foundation
import JavaScriptCore
import XCTest

@testable import EditorCore

/// The shipped `bridge.js`, driven in JavaScriptCore against a stand-in Monaco.
///
/// Nothing here re-implements the bridge: the file loaded is the one `Bundle.module` ships and
/// `MonacoEditorView` navigates to. What is faked is Monaco, and only in the properties the
/// adapter actually depends on — above all the one that made a real defect invisible: Monaco
/// refuses a second model at a URI it already holds. A stand-in that quietly allowed the
/// duplicate would be a stand-in that cannot fail.
final class BridgeAdapterTests: XCTestCase {

    // MARK: - The stand-in

    /// The page globals `bridge.js` reads while its IIFE runs. `URL` is stubbed to the one
    /// resolution the bootstrap performs (`../monaco/` against the document), because
    /// JavaScriptCore has no URL of its own.
    private static let pageGlobals = """
    var posted = [];
    var window = globalThis;
    window.webkit = { messageHandlers: { afleet: { postMessage: function (m) { posted.push(m); } } } };
    window.document = { baseURI: "afleet-editor:///bootstrap/index.html" };
    window.URL = function (relative, base) { this.href = String(base).replace(/bootstrap\\/index.html$/, "") + "monaco/"; };
    // The object-URL registry, kept rather than stubbed: a leak is a URL that was handed out
    // and never given back, which is only visible if the two calls are recorded together.
    var objectURLs = { created: [], revoked: [], counter: 0 };
    window.URL.createObjectURL = function () {
      var url = "blob:afleet-editor://bundle/" + (++objectURLs.counter);
      objectURLs.created.push(url);
      return url;
    };
    window.URL.revokeObjectURL = function (url) { objectURLs.revoked.push(url); };
    window.Blob = function (parts) { this.parts = parts; };
    var workersBuilt = [];
    window.Worker = function (url, options) { workersBuilt.push({ url: url, options: options }); };
    function liveObjectURLs() {
      return objectURLs.created.filter(function (url) { return objectURLs.revoked.indexOf(url) < 0; });
    }
    """

    /// Monaco, reduced to what the adapter touches, with its model registry behaving the way
    /// the real one does: one model per URI, the URI freed only by `dispose`.
    private static let monacoStandIn = """
    var registry = {};
    var modelCounter = 0;

    function Uri(text) { this.text = text; }
    Uri.prototype.toString = function () { return this.text; };

    function Model(text, language, uri) {
      this.value = text;
      this.language = language;
      this.uri = uri;
      this.version = 1;
      this.disposed = false;
      this.listeners = [];
      this.id = "model-" + (++modelCounter);
    }
    Model.prototype.getValue = function () { return this.value; };
    Model.prototype.setValue = function (text) {
      if (this.disposed) { throw new Error("setValue on a disposed model"); }
      this.value = text;
      this.version += 1;
      this.listeners.slice().forEach(function (listener) { listener(); });
    };
    Model.prototype.getAlternativeVersionId = function () { return this.version; };
    Model.prototype.getLanguageId = function () { return this.language; };
    Model.prototype.onDidChangeContent = function (listener) {
      var self = this;
      self.listeners.push(listener);
      return { dispose: function () {
        var index = self.listeners.indexOf(listener);
        if (index >= 0) { self.listeners.splice(index, 1); }
      } };
    };
    Model.prototype.dispose = function () {
      this.disposed = true;
      if (registry[this.uri.toString()] === this) { delete registry[this.uri.toString()]; }
    };

    var editor = {
      model: null,
      revealed: [],
      positions: [],
      setModel: function (model) { this.model = model; },
      getModel: function () { return this.model; },
      layout: function () {},
      focus: function () {},
      setPosition: function (position) { this.positions.push(position); },
      revealLineInCenter: function (line) { this.revealed.push(line); },
      onDidChangeCursorPosition: function () { return { dispose: function () {} }; }
    };

    var monaco = {
      Uri: { parse: function (text) { return new Uri(text); } },
      editor: {
        create: function () { return editor; },
        createModel: function (text, language, uri) {
          // A model created without a URI — which is how the diff editor's two models arrive —
          // gets a generated one, as the real ModelService does.
          var target = uri || new Uri("inmemory://model/" + (modelCounter + 1));
          var key = target.toString();
          // The real refusal, and the reason this file exists: Monaco throws rather than
          // handing back the model already at that URI.
          // The message is Monaco 0.56's own, as the S3 run recorded it against the real editor.
          if (registry[key]) { throw new Error("ModelService: Cannot add model because it already exists!"); }
          var model = new Model(text, language, target);
          registry[key] = model;
          return model;
        },
        getModel: function (uri) { return registry[uri.toString()] || null; },
        setModelLanguage: function (model, language) { model.language = language; },
        createDiffEditor: function () {
          diffEditor = {
            model: null,
            setModel: function (models) { this.model = models; },
            layout: function () {}
          };
          return diffEditor;
        },
        setTheme: function () {}
      }
    };

    var diffEditor = null;
    var containers = { editor: { style: {} }, diff: { style: {} } };

    function bootBridge() {
      window.afleetBridge.boot(monaco, containers.editor, containers.diff);
      return posted.length;
    }

    function registrySize() { return Object.keys(registry).length; }
    """

    /// A context with the page globals, the shipped bridge and the stand-in loaded, booted.
    private func bootedContext(
        route: WorkerLoadingRoute = .schemeForEverything,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> JSContext {
        let context = try XCTUnwrap(JSContext(), file: file, line: line)
        var failures: [String] = []
        context.exceptionHandler = { _, exception in
            failures.append(exception?.toString() ?? "unknown JavaScript exception")
        }

        let bridgeURL = try XCTUnwrap(EditorResources.bridgeScriptURL, "Bundle.module ships no bridge.js")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        context.evaluateScript(Self.pageGlobals)
        // The same injection `MonacoEditorView.configurationScript(for:)` performs at document
        // start, so the route under test is the one the host would have asked for.
        context.evaluateScript("window.afleetEditorConfig = { workerRoute: \"\(route.javaScriptName)\" };")
        context.evaluateScript(bridge, withSourceURL: bridgeURL)
        context.evaluateScript(Self.monacoStandIn)
        context.evaluateScript("bootBridge();")

        XCTAssertTrue(failures.isEmpty, "loading the bridge threw: \(failures)", file: file, line: line)
        XCTAssertEqual(posted(in: context).first?["type"] as? String, "ready",
                       "the bridge did not report ready", file: file, line: line)
        return context
    }

    private func posted(in context: JSContext) -> [[String: Any]] {
        (context.objectForKeyedSubscript("posted").toArray() as? [[String: Any]]) ?? []
    }

    private func send(_ command: [String: Any], in context: JSContext) {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        context.evaluateScript("window.afleetBridge.receive(\(json));")
    }

    // MARK: - Reopening the path already on screen

    /// C7.5's normal path, not an edge case: root spec §9.1 has a file watcher refresh the open
    /// file when the agent edits it, and a refresh is a second `open` at the same path.
    func testSecondOpenOfTheSamePathReplacesTheBufferAndRevealsTheLine() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        let firstModelID = context.evaluateScript("editor.getModel().id;").toString()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "two\n", "line": 7],
             in: context)

        let errors = posted(in: context).filter { $0["type"] as? String == "error" }
        XCTAssertEqual(errors.count, 0, "reopening the same path reported an error: \(errors)")
        XCTAssertEqual(context.evaluateScript("editor.getModel().getValue();").toString(), "two\n",
                       "the reopened file still shows its old contents")
        XCTAssertEqual(context.evaluateScript("editor.revealed;").toArray() as? [Int], [7],
                       "the requested line was never revealed")
        XCTAssertEqual(context.evaluateScript("editor.getModel().disposed;").toBool(), false,
                       "the model the editor is showing has been disposed")
        XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 1,
                       "the reopen left a second model behind at the same path")
        XCTAssertEqual(context.evaluateScript("editor.getModel().id;").toString(), firstModelID,
                       "the model at the URI was replaced; markers and decorations keyed to it are lost")
    }

    /// The reopen is a clean baseline, exactly as the first open is: the host replaced the
    /// buffer, so nothing may report the file dirty on the strength of that replacement.
    func testReopeningTheSamePathDoesNotReportTheFileDirty() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "two\n"], in: context)

        let dirty = posted(in: context).filter { $0["type"] as? String == "dirty" }
        XCTAssertEqual(dirty.count, 0, "the reopen posted a dirty event: \(dirty)")
        XCTAssertEqual(context.evaluateScript("editor.getModel().listeners.length;").toInt32(), 1,
                       "the reopen left a second content listener on the model")

        // A real edit after the reopen still reports dirty, so the assertion above is not
        // passing because the bridge stopped watching.
        context.evaluateScript("editor.getModel().setValue('edited\\n');")
        let afterEdit = posted(in: context).filter { $0["type"] as? String == "dirty" }
        XCTAssertEqual(afterEdit.count, 1, "an edit after the reopen reported no dirty event")
        XCTAssertEqual(afterEdit.first?["isDirty"] as? Bool, true)
    }

    /// A language change on reopen — the same path served as a different language — lands on the
    /// model the editor is showing.
    func testReopeningWithADifferentLanguageRetagsTheModel() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "notes/file", "language": "plaintext", "text": "one\n"], in: context)
        send(["type": "open", "path": "notes/file", "language": "markdown", "text": "# two\n"], in: context)

        XCTAssertEqual(context.evaluateScript("editor.getModel().getLanguageId();").toString(), "markdown")
    }

    /// `setText` is the same host-replaces-the-buffer move as `open`, and says so once. Found
    /// beside the reopen defect: the content listener saw setValue and announced the buffer
    /// dirty, so the host was told `true` and then immediately `false` for a write it had just
    /// performed itself — a panel driving a save indicator from those events would flicker.
    func testSetTextReportsOneCleanBaselineAndNothingElse() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        send(["type": "setText", "text": "two\n"], in: context)

        let dirty = posted(in: context).filter { $0["type"] as? String == "dirty" }
        XCTAssertEqual(dirty.count, 1, "setText posted more than the clean baseline: \(dirty)")
        XCTAssertEqual(dirty.first?["isDirty"] as? Bool, false)
        XCTAssertEqual(context.evaluateScript("editor.getModel().listeners.length;").toInt32(), 1,
                       "setText left a second content listener on the model")
    }

    // MARK: - Saving while the diff is the visible surface

    /// The diff editor is read-only and shows a pair of models that are not the open buffer.
    /// Without a visible mode the bridge answers `save` from whatever `open` left behind, so a
    /// host that sent `showDiff` and then `save` would be handed — and would write — a file it
    /// is not showing. C7.7 puts a diff on screen in the same view C7.5 saves from, so this is
    /// the ordinary sequence between two panels, not a contrived one.
    func testSaveIsRefusedWhileTheDiffIsTheVisibleSurface() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        send(["type": "showDiff", "path": "src/main.swift", "language": "swift",
              "original": "one\n", "modified": "two\n"], in: context)
        send(["type": "save"], in: context)

        XCTAssertEqual(posted(in: context).filter { $0["type"] as? String == "saveRequested" }.count, 0,
                       "the bridge answered save with the buffer hidden behind the diff")
        let errors = posted(in: context).filter { $0["type"] as? String == "error" }
        XCTAssertEqual(errors.count, 1, "the refusal was silent: \(errors)")

        // The guard is about the visible surface, not about save: bringing the editor back
        // restores it, so a test that passed by refusing everything would fail here.
        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        send(["type": "save"], in: context)

        let saves = posted(in: context).filter { $0["type"] as? String == "saveRequested" }
        XCTAssertEqual(saves.count, 1, "save stayed refused after the editor came back")
        XCTAssertEqual(saves.first?["path"] as? String, "src/main.swift")
        XCTAssertEqual(saves.first?["text"] as? String, "one\n")
    }

    // MARK: - The dirty flag of the buffer being replaced

    /// `dirty` is a transition, and the host holds the last one it was told. Replacing a dirty
    /// buffer resets the bridge's own baseline with the content listener detached, so without an
    /// explicit transition the host is left believing a file it no longer shows is unsaved.
    func testOpeningAnotherFileReportsTheDirtyBufferItReplacedClean() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "a.swift", "language": "swift", "text": "one\n"], in: context)
        context.evaluateScript("editor.getModel().setValue('edited\\n');")
        XCTAssertEqual(posted(in: context).filter { $0["type"] as? String == "dirty" }.count, 1,
                       "the edit did not report the buffer dirty")

        send(["type": "open", "path": "b.swift", "language": "swift", "text": "two\n"], in: context)

        let dirty = posted(in: context).filter { $0["type"] as? String == "dirty" }
        XCTAssertEqual(dirty.count, 2, "the replaced buffer was never reported clean: \(dirty)")
        XCTAssertEqual(dirty.last?["isDirty"] as? Bool, false)
        XCTAssertEqual(dirty.last?["path"] as? String, "a.swift",
                       "the clean transition named the wrong file")
    }

    /// The same transition when the replacement is a refresh of the file already on screen —
    /// root spec §9.1's file watcher, arriving while the user has unsaved edits.
    func testReopeningTheSamePathReportsItsDirtyBufferClean() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "a.swift", "language": "swift", "text": "one\n"], in: context)
        context.evaluateScript("editor.getModel().setValue('edited\\n');")
        send(["type": "open", "path": "a.swift", "language": "swift", "text": "refreshed\n"], in: context)

        let dirty = posted(in: context).filter { $0["type"] as? String == "dirty" }
        XCTAssertEqual(dirty.count, 2, "the refresh left the host holding a stale dirty flag: \(dirty)")
        XCTAssertEqual(dirty.last?["isDirty"] as? Bool, false)
        XCTAssertEqual(dirty.last?["path"] as? String, "a.swift")
    }

    /// Opening a *different* path still disposes the model left behind, which is what keeps a
    /// long session from accumulating one model per file ever opened.
    func testOpeningADifferentPathDisposesThePreviousModel() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "a.swift", "language": "swift", "text": "one\n"], in: context)
        let firstID = context.evaluateScript("editor.getModel().id;").toString()
        send(["type": "open", "path": "b.swift", "language": "swift", "text": "two\n"], in: context)

        XCTAssertNotEqual(context.evaluateScript("editor.getModel().id;").toString(), firstID)
        XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 1,
                       "the model for the closed file was not disposed")
        XCTAssertEqual(context.evaluateScript("editor.getModel().getValue();").toString(), "two\n")
    }

    // MARK: - Leaving the diff behind

    /// The diff editor is persistent and holds a pair of models that are not the open buffer.
    /// Coming back to the editor only hid its container, so both diff buffers stayed alive —
    /// two whole file contents per diff, held until another `showDiff` or a navigation. C7.7
    /// puts a diff on screen in the same view C7.5 opens files in, so this is the ordinary
    /// sequence between two panels.
    func testReturningToTheEditorDisposesTheDiffModels() throws {
        let context = try bootedContext()

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
        send(["type": "showDiff", "path": "src/main.swift", "language": "swift",
              "original": "one\n", "modified": "two\n"], in: context)
        context.evaluateScript("var shown = diffEditor.model;")
        XCTAssertEqual(context.evaluateScript("shown.original.disposed;").toBool(), false)
        XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 3,
                       "the diff did not put its two models in the registry")

        send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "three\n"], in: context)

        XCTAssertEqual(context.evaluateScript("shown.original.disposed;").toBool(), true,
                       "the diff's original model outlived the diff")
        XCTAssertEqual(context.evaluateScript("shown.modified.disposed;").toBool(), true,
                       "the diff's modified model outlived the diff")
        XCTAssertEqual(context.evaluateScript("diffEditor.model;").isNull, true,
                       "the diff editor still holds the models it was shown with")
        XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 1,
                       "only the open buffer should be left")
    }

    /// `setText` and `gotoLine` reach the editor through the same door, so they release the diff
    /// too — otherwise the leak survives by whichever command the panel happens to send.
    func testSetTextAndGotoLineAlsoReleaseTheDiff() throws {
        for command in [["type": "setText", "text": "three\n"] as [String: Any],
                        ["type": "gotoLine", "line": 1] as [String: Any]] {
            let context = try bootedContext()
            send(["type": "open", "path": "src/main.swift", "language": "swift", "text": "one\n"], in: context)
            send(["type": "showDiff", "path": "src/main.swift", "language": "swift",
                  "original": "one\n", "modified": "two\n"], in: context)
            context.evaluateScript("var shown = diffEditor.model;")

            send(command, in: context)

            XCTAssertEqual(context.evaluateScript("shown.original.disposed;").toBool(), true,
                           "\(command["type"] as? String ?? "?") left the diff's models alive")
            XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 1,
                           "\(command["type"] as? String ?? "?") left diff models in the registry")
        }
    }

    /// A second diff still replaces the first, and the release above must not double-dispose or
    /// take the models the diff editor is about to be shown with.
    func testASecondDiffReplacesTheFirstAndKeepsItsOwnModels() throws {
        let context = try bootedContext()

        send(["type": "showDiff", "path": "a.swift", "language": "swift",
              "original": "one\n", "modified": "two\n"], in: context)
        context.evaluateScript("var first = diffEditor.model;")
        send(["type": "showDiff", "path": "b.swift", "language": "swift",
              "original": "three\n", "modified": "four\n"], in: context)

        XCTAssertEqual(context.evaluateScript("first.original.disposed;").toBool(), true)
        XCTAssertEqual(context.evaluateScript("diffEditor.model.original.disposed;").toBool(), false,
                       "the diff on screen was disposed under it")
        XCTAssertEqual(context.evaluateScript("diffEditor.model.original.getValue();").toString(), "three\n")
        XCTAssertEqual(context.evaluateScript("registrySize();").toInt32(), 2)
    }

    // MARK: - The Blob route's object URLs

    /// Route 2 builds each worker from an object URL. The bundled `json`, `css` and `html`
    /// worker managers stop an idle worker after two minutes and construct a new one, so the
    /// route creates object URLs for as long as the page lives; every one that is not revoked
    /// pins its Blob until navigation.
    ///
    /// Revoking immediately after the constructor returns is safe by HTML's own rule: `new
    /// Worker(url)` creates its request synchronously and the request keeps the blob URL entry
    /// it resolved, so a later revoke cannot strand the fetch.
    func testTheBlobRouteRevokesEveryObjectURLItCreates() throws {
        let context = try bootedContext(route: .blobWorkers)

        context.evaluateScript("""
        ["json", "css", "html", "typescript", "editorWorkerService"].forEach(function (label, index) {
          window.MonacoEnvironment.getWorker(index, label);
        });
        """)

        XCTAssertEqual(context.evaluateScript("objectURLs.created.length;").toInt32(), 5,
                       "the blob route did not build an object URL per worker")
        XCTAssertEqual(context.evaluateScript("workersBuilt.length;").toInt32(), 5)
        XCTAssertEqual(context.evaluateScript("workersBuilt[0].url;").toString(),
                       context.evaluateScript("objectURLs.created[0];").toString(),
                       "the worker was not built from the object URL")
        XCTAssertEqual(context.evaluateScript("workersBuilt[0].options.type;").toString(), "module",
                       "the shim must stay a module worker")
        XCTAssertEqual(context.evaluateScript("liveObjectURLs().length;").toInt32(), 0,
                       "object URLs were handed out and never revoked: \(context.evaluateScript("JSON.stringify(liveObjectURLs());").toString() ?? "")")
    }

    /// The scheme route builds no object URL at all, so the revoke above is not passing by
    /// revoking something the default route never creates.
    func testTheSchemeRouteBuildsNoObjectURL() throws {
        let context = try bootedContext()

        context.evaluateScript("window.MonacoEnvironment.getWorker(0, \"json\");")

        XCTAssertEqual(context.evaluateScript("objectURLs.created.length;").toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("workersBuilt[0].url;").toString(),
                       "afleet-editor:///monaco/json.worker.js")
    }
}

