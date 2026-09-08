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
    window.URL.createObjectURL = function () { return "blob:stub"; };
    window.Blob = function () {};
    window.Worker = function () {};
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
    private func bootedContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext(), file: file, line: line)
        var failures: [String] = []
        context.exceptionHandler = { _, exception in
            failures.append(exception?.toString() ?? "unknown JavaScript exception")
        }

        let bridgeURL = try XCTUnwrap(EditorResources.bridgeScriptURL, "Bundle.module ships no bridge.js")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        context.evaluateScript(Self.pageGlobals)
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
}
