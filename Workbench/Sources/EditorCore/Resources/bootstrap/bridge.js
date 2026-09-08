// The editor-side half of the W4 bridge: one flat tagged JSON object per message, in both
// directions. The Swift spelling of this vocabulary is EditorCore's BridgeCodec.swift, and a
// test asserts every `type` string it emits appears in this file. Adding a message here that
// the codec does not know, or renaming one it does, is the drift that test exists to catch.
//
// A plain classic script, no build step and no module graph: it must load identically under
// every route S3 is still choosing between (custom scheme, blob URL, file URL), and a classic
// script is the one shape none of them can refuse.
//
// The live Monaco wiring sits below the dispatch, in `boot` and `makeAdapter`: index.html calls
// `boot` once the module entry has evaluated, and `attach` swaps the not-attached adapter for
// the real one and posts `ready`. The dispatch and the event shapes above it did not move for
// that, and should not move for anything a panel wants either.

(function (global) {
  "use strict";

  // --- editor to host -------------------------------------------------------------------

  function post(event) {
    global.webkit.messageHandlers.afleet.postMessage(event);
  }

  var events = {
    ready: function () {
      post({ type: "ready" });
    },
    dirty: function (path, isDirty) {
      post({ type: "dirty", path: path, isDirty: isDirty });
    },
    saveRequested: function (path, text) {
      post({ type: "saveRequested", path: path, text: text });
    },
    cursor: function (line, column) {
      post({ type: "cursor", line: line, column: column });
    },
    error: function (message) {
      post({ type: "error", message: String(message) });
    },
  };

  // --- the Monaco seam ------------------------------------------------------------------
  //
  // Replaced wholesale by `attach()`. Until then every command answers with an `error`, which
  // is the vocabulary's own way of saying "no editor yet" and is what the host would have to
  // handle anyway.

  function notAttached(what) {
    return function () {
      events.error("no editor is attached: " + what);
    };
  }

  var adapter = {
    open: notAttached("open"),
    setText: notAttached("setText"),
    gotoLine: notAttached("gotoLine"),
    setTheme: notAttached("setTheme"),
    showDiff: notAttached("showDiff"),
    // Answers { path, text } for the current buffer; `save` turns that into saveRequested.
    readBuffer: function () {
      events.error("no editor is attached: save");
      return null;
    },
  };

  function attach(monacoAdapter) {
    adapter = monacoAdapter;
    events.ready();
  }

  // --- the worker route -----------------------------------------------------------------
  //
  // One switchable seam, as spec Design §7 asks for. The host injects
  // `window.afleetEditorConfig = { workerRoute: "scheme" | "blob" | "file" }` at document
  // start; S3 changes that value and re-runs rather than rewriting anything here.
  //
  // The base URL is derived from document.baseURI and never passed in: it is then correct
  // under every route by construction, and cannot disagree with the URL the document was
  // actually loaded from.
  //
  // Every worker is a MODULE worker. The bundle is built with `bun build --splitting`, which
  // leaves each worker entry a shim that `import`s shared chunks — editor.worker.js is 156
  // bytes — so a classic worker would fail on its first import statement. It also means chunks
  // are fetched from inside the worker context, which the scheme handler serves like any other
  // request.

  var config = global.afleetEditorConfig || {};
  var workerRoute = config.workerRoute || "scheme";
  var monacoBase = new URL("../monaco/", document.baseURI).href;

  var workerFileByLabel = {
    json: "json.worker.js",
    css: "css.worker.js",
    scss: "css.worker.js",
    less: "css.worker.js",
    html: "html.worker.js",
    handlebars: "html.worker.js",
    razor: "html.worker.js",
    typescript: "ts.worker.js",
    javascript: "ts.worker.js",
  };

  function workerURL(label) {
    return monacoBase + (workerFileByLabel[label] || "editor.worker.js");
  }

  function createWorker(label) {
    var url = workerURL(label);
    var objectURL = null;
    if (workerRoute === "blob") {
      // A blob module worker has a `blob:` base URL, so its relative chunk imports do not
      // resolve back onto the scheme; the shim's own import is written absolute here, and
      // whether the chunks it pulls in behave is exactly what S3 measures.
      var source = "import " + JSON.stringify(url) + ";";
      objectURL = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
      url = objectURL;
    }
    var worker = new Worker(url, { type: "module", name: label });
    // The object URL has done its whole job by the time the constructor returns: `new Worker`
    // creates its request synchronously and that request keeps the blob URL entry it resolved,
    // so revoking now cannot strand the fetch. Not revoking leaks — the bundled json, css and
    // html worker managers stop an idle worker after two minutes and build a new one, so a
    // long-lived page strands one Blob per idle cycle until it navigates.
    if (objectURL) URL.revokeObjectURL(objectURL);
    return worker;
  }

  global.MonacoEnvironment = {
    getWorker: function (workerId, label) {
      return createWorker(label);
    },
  };

  // --- the Monaco adapter ---------------------------------------------------------------
  //
  // The six method bodies the seam above was left for. `boot` is called by index.html once
  // the module entry has evaluated and assigned globalThis.monaco.

  function boot(monaco, editorContainer, diffContainer) {
    try {
      var state = {
        monaco: monaco,
        editorContainer: editorContainer,
        diffContainer: diffContainer,
        editor: null,
        diffEditor: null,
        model: null,
        // The single `onDidChangeContent` registration on `state.model`, held so it can be
        // taken off before the host replaces the buffer and put back after.
        contentSubscription: null,
        diffModels: null,
        path: "",
        savedVersionId: 0,
        wasDirty: false,
        // Which surface is on screen. The diff editor is read-only and holds a pair of models
        // that are not the open buffer, so `save` cannot be answered from `state.model` while
        // it is up: the host would be handed a file it is not showing.
        mode: "editor",
      };

      state.editor = monaco.editor.create(editorContainer, {
        automaticLayout: true,
        theme: "vs",
        scrollBeyondLastLine: false,
      });
      state.editor.onDidChangeCursorPosition(function (change) {
        events.cursor(change.position.lineNumber, change.position.column);
      });

      attach(makeAdapter(state));
    } catch (failure) {
      events.error(failure && failure.message ? failure.message : String(failure));
    }
  }

  function makeAdapter(state) {
    var monaco = state.monaco;

    // The diff editor is persistent — it is created once and reused — but the pair of models it
    // is shown with is not: they are two whole file contents that belong to one `showDiff`.
    // Hiding the container leaves them attached and alive, so a panel that shows a diff and goes
    // back to the file holds both buffers until the next diff or a navigation.
    function releaseDiffModels() {
      if (!state.diffModels) return;
      if (state.diffEditor) state.diffEditor.setModel(null);
      state.diffModels.original.dispose();
      state.diffModels.modified.dispose();
      state.diffModels = null;
    }

    function showEditor() {
      releaseDiffModels();
      state.mode = "editor";
      state.diffContainer.style.display = "none";
      state.editorContainer.style.display = "block";
      state.editor.layout();
    }

    function showDiffPane() {
      state.mode = "diff";
      state.editorContainer.style.display = "none";
      state.diffContainer.style.display = "block";
      if (!state.diffEditor) {
        state.diffEditor = monaco.editor.createDiffEditor(state.diffContainer, {
          automaticLayout: true,
          readOnly: true,
          renderSideBySide: true,
          scrollBeyondLastLine: false,
        });
      }
      state.diffEditor.layout();
    }

    // A model URI has to be unique per path, and Monaco refuses a second model at a URI it
    // already holds. The scheme is this app's own, so it can never collide with a bundle
    // resource.
    function modelURI(path) {
      return monaco.Uri.parse("afleet-file:///" + encodeURI(path).replace(/^\/+/, ""));
    }

    function reportDirty() {
      var isDirty = state.model !== null
        && state.model.getAlternativeVersionId() !== state.savedVersionId;
      if (isDirty !== state.wasDirty) {
        state.wasDirty = isDirty;
        events.dirty(state.path, isDirty);
      }
    }

    function replaceModel(path, language, text) {
      var previous = state.model;
      // `dirty` is a transition and the host holds the last one it was told. The baseline below
      // is reset with the content listener detached, so a buffer that was dirty when the host
      // replaced it has to be reported clean explicitly, under the path it was dirty as —
      // otherwise the host keeps an unsaved marker on a file nobody is editing any more.
      var replacedDirtyPath = state.wasDirty ? state.path : null;
      var uri = modelURI(path);
      // Opening the path that is already on screen is a normal command, not a mistake: a file
      // watcher refreshing the buffer the agent just edited sends exactly this. Monaco would
      // refuse a second model at the URI, so the model already there is REUSED rather than
      // disposed and rebuilt — the URI is what language workers, markers, decorations and view
      // state are keyed to, and recreating the model throws all of those away for a change that
      // is only to the text.
      var existing = monaco.editor.getModel(uri);
      var model;
      // The content subscription goes first, so the value change below cannot be mistaken for
      // the user typing and report a file the host just replaced as dirty.
      if (state.contentSubscription) {
        state.contentSubscription.dispose();
        state.contentSubscription = null;
      }
      if (existing) {
        model = existing;
        if (language && model.getLanguageId() !== language) {
          monaco.editor.setModelLanguage(model, language);
        }
        model.setValue(text);
      } else {
        model = monaco.editor.createModel(text, language || undefined, uri);
      }
      state.model = model;
      state.path = path;
      state.savedVersionId = model.getAlternativeVersionId();
      state.wasDirty = false;
      state.editor.setModel(model);
      state.contentSubscription = model.onDidChangeContent(reportDirty);
      if (previous && previous !== model) previous.dispose();
      if (replacedDirtyPath !== null) events.dirty(replacedDirtyPath, false);
    }

    function reveal(line, column) {
      state.editor.setPosition({ lineNumber: line, column: column || 1 });
      state.editor.revealLineInCenter(line);
      state.editor.focus();
    }

    return {
      open: function (path, language, text, line) {
        showEditor();
        replaceModel(path, language, text);
        if (line) reveal(line, 1);
      },

      setText: function (text) {
        if (!state.model) {
          events.error("setText before open: there is no buffer");
          return;
        }
        showEditor();
        // Same reason as in replaceModel: a host-driven value change is not the user typing,
        // and must not be announced as a dirty buffer on its way to the clean baseline below.
        if (state.contentSubscription) {
          state.contentSubscription.dispose();
          state.contentSubscription = null;
        }
        state.model.setValue(text);
        // setValue is the host replacing the buffer, so it is the new clean baseline.
        state.savedVersionId = state.model.getAlternativeVersionId();
        state.wasDirty = false;
        state.contentSubscription = state.model.onDidChangeContent(reportDirty);
        events.dirty(state.path, false);
      },

      gotoLine: function (line, column) {
        if (!state.model) {
          events.error("gotoLine before open: there is no buffer");
          return;
        }
        showEditor();
        reveal(line, column);
      },

      setTheme: function (name) {
        // A Monaco built-in passes straight through: vs, vs-dark, hc-black, hc-light. Any UI
        // over the choice belongs to the panel, not here.
        monaco.editor.setTheme(name);
      },

      showDiff: function (path, original, modified, language) {
        showDiffPane();
        var previous = state.diffModels;
        state.diffModels = {
          original: monaco.editor.createModel(original, language || undefined),
          modified: monaco.editor.createModel(modified, language || undefined),
        };
        state.diffEditor.setModel(state.diffModels);
        // The replacement is built and attached before the models it replaces are disposed, so
        // the diff editor is never left holding a disposed pair.
        if (previous) {
          previous.original.dispose();
          previous.modified.dispose();
        }
      },

      readBuffer: function () {
        if (state.mode === "diff") {
          // W4's `error` is the whole vocabulary for a refusal, so the message carries the
          // reason and never the path: a file name in a host log is what §11 forbids.
          events.error("save while a diff is on screen: the diff is read-only");
          return null;
        }
        if (!state.model) {
          events.error("save before open: there is no buffer");
          return null;
        }
        // The buffer is reported as it stands; the dirty flag is NOT cleared here, because
        // only the host knows whether the write it is about to do succeeded. Clearing it is
        // the host's next `setText` or `open`.
        return { path: state.path, text: state.model.getValue() };
      },
    };
  }

  // --- host to editor -------------------------------------------------------------------

  function receive(command) {
    try {
      switch (command.type) {
        case "open":
          adapter.open(command.path, command.language, command.text, command.line);
          break;
        case "setText":
          adapter.setText(command.text);
          break;
        case "gotoLine":
          adapter.gotoLine(command.line, command.column);
          break;
        case "setTheme":
          adapter.setTheme(command.name);
          break;
        case "showDiff":
          adapter.showDiff(command.path, command.original, command.modified, command.language);
          break;
        case "save": {
          var buffer = adapter.readBuffer();
          if (buffer) {
            events.saveRequested(buffer.path, buffer.text);
          }
          break;
        }
        default:
          // An unknown command is reported, never dropped in silence — the same rule the
          // Swift decoder holds for an unknown event.
          events.error("unknown command type " + command.type);
      }
    } catch (failure) {
      events.error(failure && failure.message ? failure.message : failure);
    }
  }

  global.afleetBridge = {
    attach: attach,
    boot: boot,
    receive: receive,
    events: events,
  };
})(window);
