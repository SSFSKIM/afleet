import Foundation

/// The JavaScript half of the spike.
///
/// Every one of these runs through `callAsyncJavaScript` in the page world, so each is the body
/// of an async function and returns a JSON-shaped value. None of them is production code and
/// none of them is loaded from the bundle: the spike deliberately measures the *shipped*
/// bootstrap, so it adds its instrumentation from outside rather than editing `bridge.js`.
enum ProbeScripts {

    /// Installed once, immediately after `ready`.
    ///
    /// It wraps `window.afleetBridge.receive` — the function `MonacoEditorView.send` reaches
    /// through `evaluateJavaScript` — so a command's synchronous cost and the time to the frame
    /// that paints it are measured on the real host-to-editor path, JSON parse included, rather
    /// than on a re-implementation of it.
    static let installHooks = """
    window.__s3 = { last: null, errors: [] };
    window.addEventListener("error", function (event) {
      window.__s3.errors.push(String(event.message || event.type));
    });
    window.addEventListener("unhandledrejection", function (event) {
      window.__s3.errors.push("unhandledrejection: " + String(event.reason));
    });
    var original = window.afleetBridge.receive;
    window.afleetBridge.receive = function (command) {
      var t0 = performance.now();
      original(command);
      var t1 = performance.now();
      // Recorded synchronously and completed later. The frame half of the measurement depends on
      // the window being given frames at all, and a record that only ever appears once a frame
      // has been painted turns "no frames" into "the harness hangs" rather than into a finding.
      var record = { type: command.type, syncMs: t1 - t0, toRenderMs: null, toSecondFrameMs: null, complete: false };
      window.__s3.last = record;
      requestAnimationFrame(function () {
        record.toRenderMs = performance.now() - t0;
        requestAnimationFrame(function () {
          record.toSecondFrameMs = performance.now() - t0;
          record.complete = true;
        });
      });
    };
    return true;
    """

    /// Clears the recorder so the next `send` is the one being measured.
    static let arm = "window.__s3.last = null; return true;"

    /// Waits for the wrapped `receive` to have recorded a command of `type`.
    static let awaitRecorded = """
    var deadline = performance.now() + timeoutMs;
    while (performance.now() < deadline) {
      var record = window.__s3.last;
      if (record && record.type === type && record.complete) { return record; }
      await new Promise(function (r) { setTimeout(r, 8); });
    }
    var partial = window.__s3.last;
    if (partial && partial.type === type) {
      partial.timedOutWaitingForFrame = true;
      partial.errors = window.__s3.errors.slice(-4);
      return partial;
    }
    return { type: type, timedOut: true, errors: window.__s3.errors.slice(-4) };
    """

    /// Counts animation frames over a fixed wall-clock window.
    ///
    /// Not a measurement of Monaco: a measurement of whether this process is being given frames
    /// at all. An occluded window gets none, and every render and scroll number below would then
    /// be a report on AppKit's power management wearing Monaco's name.
    static let frameLivenessProbe = """
    var frames = 0;
    var started = performance.now();
    await new Promise(function (resolve) {
      function tick() {
        frames += 1;
        if (performance.now() - started >= windowMs) { resolve(); } else { requestAnimationFrame(tick); }
      }
      requestAnimationFrame(tick);
      setTimeout(resolve, windowMs + 500);
    });
    var elapsed = performance.now() - started;
    return { frames: frames, elapsedMs: elapsed, framesPerSecond: frames / (elapsed / 1000),
             hidden: document.hidden, visibilityState: document.visibilityState };
    """

    /// The third load path: a dynamic-import chunk.
    ///
    /// Monaco registers ~85 basic languages behind `monaco.languages.onLanguage(id, loader)`,
    /// and the loader is a dynamic `import()`. Encountering the language is what fires it, so
    /// creating a model in `language` is what forces the chunk fetch. The proof that the chunk
    /// *arrived and evaluated* is tokenisation: before the Monarch grammar is installed Monaco
    /// returns one undifferentiated token per line, and afterwards it returns the grammar's own
    /// scopes. A route that served the document but not the chunk would highlight nothing, and
    /// this is the assertion that sees it.
    static let chunkProbe = """
    var uri = monaco.Uri.parse("afleet-file:///s3/chunk-probe." + fileExtension);
    var existing = monaco.editor.getModel(uri);
    if (existing) { existing.dispose(); }
    var model = monaco.editor.createModel(sample, language, uri);
    var deadline = performance.now() + timeoutMs;
    var started = performance.now();
    var tokens = [];
    var loaded = false;
    while (performance.now() < deadline) {
      var lines = monaco.editor.tokenize(sample, language);
      tokens = (lines && lines[0]) || [];
      loaded = tokens.some(function (token) {
        return typeof token.type === "string" && token.type.indexOf("." + language) >= 0;
      });
      if (loaded) { break; }
      await new Promise(function (r) { setTimeout(r, 16); });
    }
    var elapsed = performance.now() - started;
    model.dispose();
    var timing = performance.getEntriesByType("resource").map(function (entry) { return entry.name; })
      .filter(function (name) { return name.indexOf("/" + language + "-") >= 0; });
    return {
      language: language,
      loaded: loaded,
      elapsedMs: elapsed,
      tokenTypes: tokens.slice(0, 8).map(function (token) { return token.type; }),
      resourceTimingURLs: timing,
      documentBaseURI: document.baseURI,
      errors: window.__s3.errors.slice(-4)
    };
    """

    /// A scripted scroll over whatever is in the editor, timed frame by frame.
    ///
    /// `setScrollTop` on each `requestAnimationFrame` is what a fling looks like to Monaco: a
    /// new viewport every frame, so tokenisation, decoration and DOM recycling all run. The
    /// deltas between successive callbacks are the frame times; the histogram is what "no
    /// visible jank" gets replaced by, because a human's word cannot be a gate.
    ///
    /// The probe reports the frames it was asked for beside the frames it recorded, because the
    /// timeout below can return at any point: percentiles over a truncated sample describe a
    /// scroll that was never finished, and only the two counts together say which happened. On
    /// that timeout the frame chain is cancelled — a chain left scheduled keeps scrolling the
    /// editor underneath every probe that runs after this one.
    static let scrollHistogram = """
    var editor = monaco.editor.getEditors()[0];
    if (!editor) { return { error: "no editor" }; }
    editor.focus();
    var height = editor.getScrollHeight();
    var deltas = [];
    var timedOut = false;
    await new Promise(function (resolve) {
      var frame = 0;
      var last = performance.now();
      var top = 0;
      var pending = 0;
      var timer = 0;
      function step() {
        pending = 0;
        var now = performance.now();
        if (frame > 0) { deltas.push(now - last); }
        last = now;
        top += stepPixels;
        if (top > height - 400) { top = 0; }
        editor.setScrollTop(top);
        frame += 1;
        if (frame > frameCount) { clearTimeout(timer); resolve(); }
        else { pending = requestAnimationFrame(step); }
      }
      pending = requestAnimationFrame(step);
      // The escape hatch for a window that is getting no frames: without it this probe never
      // resolves, and a spike whose report never prints is worth less than a spike that prints
      // "no frames were available".
      timer = setTimeout(function () {
        timedOut = true;
        if (pending) { cancelAnimationFrame(pending); pending = 0; }
        resolve();
      }, budgetMs);
    });
    editor.setScrollTop(0);
    var sorted = deltas.slice().sort(function (a, b) { return a - b; });
    function at(q) { return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : 0; }
    var sum = sorted.reduce(function (a, b) { return a + b; }, 0);
    return {
      requestedFrames: frameCount,
      frames: sorted.length,
      timedOut: timedOut,
      p50Ms: at(0.5),
      p95Ms: at(0.95),
      worstMs: sorted.length ? sorted[sorted.length - 1] : 0,
      meanMs: sorted.length ? sum / sorted.length : 0,
      over16Ms: sorted.filter(function (d) { return d > 16.7; }).length,
      over33Ms: sorted.filter(function (d) { return d > 33.4; }).length
    };
    """

    /// Did the diff render, and did the editor worker compute it?
    ///
    /// `getLineChanges()` is null until the diff has been computed, and in 0.56 that computation
    /// happens on `editor.worker`. So a non-empty change list is two findings at once: the
    /// 2,000-line diff rendered, and the editor worker is alive and round-tripping. The DOM
    /// count is the separate, weaker claim that something is actually on screen.
    static let diffProbe = """
    var deadline = performance.now() + timeoutMs;
    var diffEditor = null;
    var changes = null;
    while (performance.now() < deadline) {
      diffEditor = monaco.editor.getDiffEditors()[0];
      if (diffEditor) { changes = diffEditor.getLineChanges(); }
      if (changes && changes.length) { break; }
      await new Promise(function (r) { setTimeout(r, 25); });
    }
    // The change list is computed before the decorations are painted, so the DOM is counted a
    // couple of frames later. Counted immediately it reads zero on a diff that renders perfectly
    // well, which is a measurement artefact and not a finding.
    await new Promise(function (resolve) {
      requestAnimationFrame(function () { requestAnimationFrame(function () { setTimeout(resolve, 300); }); });
      setTimeout(resolve, 3000);
    });
    var pane = document.getElementById("diff");
    return {
      computed: !!(changes && changes.length),
      changeCount: changes ? changes.length : 0,
      originalLines: diffEditor && diffEditor.getModel() ? diffEditor.getModel().original.getLineCount() : 0,
      modifiedLines: diffEditor && diffEditor.getModel() ? diffEditor.getModel().modified.getLineCount() : 0,
      renderedInsertLines: pane ? pane.querySelectorAll("[class*=line-insert], [class*=char-insert]").length : 0,
      renderedDeleteLines: pane ? pane.querySelectorAll("[class*=line-delete], [class*=char-delete]").length : 0,
      renderedDiffDecorations: pane ? pane.querySelectorAll("[class*=insert], [class*=delete]").length : 0,
      viewLines: pane ? pane.querySelectorAll(".view-line").length : 0,
      diffPaneDisplayed: pane ? getComputedStyle(pane).display !== "none" : false,
      errors: window.__s3.errors.slice(-4)
    };
    """

    /// What the editor is showing right now: the buffer behind the visible editor, its URI, and
    /// where the caret was left.
    ///
    /// The reopen check reads this rather than trusting the command it just sent — the defect it
    /// exists for was a failed `open` that left the previous contents on screen and reported the
    /// failure only as an `error` event, which is exactly the shape a probe that asks the host
    /// what it sent cannot see.
    static let bufferProbe = """
    var editor = monaco.editor.getEditors()[0];
    if (!editor) { return { error: "no editor" }; }
    var model = editor.getModel();
    if (!model) { return { error: "no model" }; }
    var position = editor.getPosition();
    return {
      uri: String(model.uri),
      languageId: model.getLanguageId(),
      lineCount: model.getLineCount(),
      firstLine: model.getLineContent(1),
      lineAtCaret: position ? model.getLineContent(position.lineNumber) : null,
      caretLine: position ? position.lineNumber : 0,
      modelCount: monaco.editor.getModels().length,
      errors: window.__s3.errors.slice(-4)
    };
    """

    /// Instantiates each of the five worker entries exactly the way the bootstrap does, and
    /// watches for the load to fail.
    ///
    /// A module worker whose top-level script — or any module it `import`s — fails to load
    /// fires an `error` event on the `Worker` object. Since `bun build --splitting` left every
    /// worker entry a shim that imports shared chunks, that event is precisely the signal for
    /// "the chunk fetch from inside the worker context did not resolve", which is the failure
    /// the Blob route is suspected of. Silence for the timeout is the negative of that, and is
    /// reported as such rather than as proof of life; the functional probes below carry the
    /// positive claim.
    static let directWorkerProbe = """
    var base = new URL("../monaco/", document.baseURI).href;
    var results = [];
    for (var i = 0; i < files.length; i++) {
      var file = files[i];
      var target = base + file;
      var url = target;
      var blobURL = null;
      if (route === "blob") {
        blobURL = URL.createObjectURL(new Blob(["import " + JSON.stringify(target) + ";"], { type: "text/javascript" }));
        url = blobURL;
      }
      results.push(await new Promise(function (resolve) {
        var worker = null;
        var settled = false;
        function finish(outcome) {
          if (settled) { return; }
          settled = true;
          try { if (worker) { worker.terminate(); } } catch (ignored) {}
          if (blobURL) { URL.revokeObjectURL(blobURL); }
          outcome.file = file;
          outcome.url = url;
          resolve(outcome);
        }
        try {
          // `__s3untracked` keeps this population out of the worker instrumentation. These
          // are the harness's own workers, constructed and terminated here; counting their
          // traffic as Monaco's is the confusion the instrumentation exists to end.
          worker = new Worker(url, { type: "module", name: file, __s3untracked: true });
        } catch (failure) {
          finish({ started: false, error: "constructor threw: " + String(failure) });
          return;
        }
        worker.onerror = function (event) {
          finish({ started: false, error: String((event && (event.message || event.type)) || "error event"),
                   filename: (event && event.filename) || null, lineno: (event && event.lineno) || null });
        };
        worker.onmessageerror = function () { finish({ started: false, error: "messageerror" }); };
        setTimeout(function () { finish({ started: true, error: null }); }, settleMs);
        try { worker.postMessage({ s3: "ping" }); } catch (ignored) {}
      }));
    }
    return results;
    """

    /// The positive half of the worker finding: does each language service actually answer?
    ///
    /// Each of these round-trips through the worker it names — TypeScript through the worker
    /// proxy itself, JSON and CSS through validation markers that only a worker produces, HTML
    /// through the formatter, which is the only thing `monaco-html` puts on the worker that has
    /// an observable effect from the standalone API. Where the answer is inconclusive it says
    /// so; a probe that cannot fail is worth nothing.
    static let languageWorkerProbe = """
    var out = {};

    async function markers(language, extension, source, timeoutMs) {
      var uri = monaco.Uri.parse("afleet-file:///s3/marker-probe." + extension);
      var stale = monaco.editor.getModel(uri);
      if (stale) { stale.dispose(); }
      var model = monaco.editor.createModel(source, language, uri);
      var deadline = performance.now() + timeoutMs;
      var found = [];
      while (performance.now() < deadline) {
        found = monaco.editor.getModelMarkers({ resource: uri });
        if (found.length) { break; }
        await new Promise(function (r) { setTimeout(r, 25); });
      }
      model.dispose();
      return { answered: found.length > 0, markerCount: found.length,
               owners: found.slice(0, 3).map(function (m) { return m.owner; }) };
    }

    try {
      out.json = await markers("json", "json", '{ "a": , "b": 1 }', timeoutMs);
    } catch (failure) { out.json = { answered: false, error: String(failure) }; }

    try {
      out.css = await markers("css", "css", "a { color: ; }\\n@bogus;\\n", timeoutMs);
    } catch (failure) { out.css = { answered: false, error: String(failure) }; }

    try {
      var tsURI = monaco.Uri.parse("afleet-file:///s3/marker-probe.ts");
      var stale = monaco.editor.getModel(tsURI);
      if (stale) { stale.dispose(); }
      // The model comes first and the API is waited for, because `monaco.languages.typescript`
      // does not exist until the TypeScript contribution has loaded — and that contribution is
      // itself one of the split build's lazy chunks, fetched when a TypeScript model is first
      // encountered. Reading the namespace before creating the model finds `undefined`, which
      // is a finding about load order and not about the worker.
      var tsModel = monaco.editor.createModel("const value: number = 'not a number';\\n", "typescript", tsURI);
      // `monaco.typescript`, not `monaco.languages.typescript`. In 0.56.0's ESM build the
      // language-service namespaces sit at the top of the `monaco` object — `typescript`,
      // `json`, `html`, `css`, `lsp` beside `editor` and `languages` — and the AMD-era nesting
      // the documentation still shows does not exist. Both spellings are tried so the probe
      // survives a bump that puts it back.
      var tsDeadline = performance.now() + timeoutMs;
      function typescriptNamespace() {
        var namespace = monaco.typescript || (monaco.languages && monaco.languages.typescript);
        return (namespace && namespace.getTypeScriptWorker) ? namespace : null;
      }
      while (performance.now() < tsDeadline && !typescriptNamespace()) {
        await new Promise(function (r) { setTimeout(r, 25); });
      }
      var namespace = typescriptNamespace();
      if (!namespace) { throw new Error("no typescript namespace on monaco after " + timeoutMs + " ms"); }
      var getWorker = await namespace.getTypeScriptWorker();
      var client = await getWorker(tsURI);
      var diagnostics = await client.getSemanticDiagnostics(tsURI.toString());
      out.typescript = { answered: Array.isArray(diagnostics) && diagnostics.length > 0,
                         diagnosticCount: Array.isArray(diagnostics) ? diagnostics.length : -1 };
      tsModel.dispose();
    } catch (failure) { out.typescript = { answered: false, error: String(failure) }; }

    try {
      var editor = monaco.editor.getEditors()[0];
      var previous = editor.getModel();
      var htmlURI = monaco.Uri.parse("afleet-file:///s3/marker-probe.html");
      var staleHTML = monaco.editor.getModel(htmlURI);
      if (staleHTML) { staleHTML.dispose(); }
      var htmlModel = monaco.editor.createModel("<div><p>one</p><p>two</p></div>", "html", htmlURI);
      editor.setModel(htmlModel);
      await new Promise(function (r) { setTimeout(r, 400); });
      var before = htmlModel.getValue();
      var action = editor.getAction("editor.action.formatDocument");
      if (!action) {
        out.html = { answered: false, error: "no formatDocument action" };
      } else {
        await action.run();
        var after = htmlModel.getValue();
        out.html = { answered: after !== before, formattedBytes: after.length, originalBytes: before.length };
      }
      editor.setModel(previous);
      htmlModel.dispose();
    } catch (failure) { out.html = { answered: false, error: String(failure) }; }

    out.errors = window.__s3.errors.slice(-6);
    return out;
    """

    /// Installed at `didCommit`, before `bridge.js` can create a worker.
    ///
    /// Monaco's `MonacoEnvironment.getWorker` returns `new Worker(...)` from the bootstrap's own
    /// scope, so wrapping the page's `Worker` constructor catches every worker Monaco creates,
    /// whatever route built the URL, without editing `bridge.js` — the spike measures the
    /// shipped bootstrap, so it instruments from outside.
    ///
    /// The count that matters is *received*, added through `addEventListener` rather than
    /// `onmessage` so it is invisible to, and cannot be displaced by, whatever the consumer
    /// assigns. Without it the harness cannot tell a working worker from Monaco's silent
    /// main-thread fallback, which answers exactly the same and logs only a console warning.
    static let workerInstrumentation = """
    window.__s3workers = { records: [], warnings: [] };
    // Monaco announces the fallback with `console.warn`, not `console.error` — and in this
    // build the announcement sits behind a guard that is false in a browser, so it may never
    // be printed at all. The capture is kept because a warning that does arrive is worth
    // having, and is never relied on: the message counts below are the evidence.
    (function () {
      var originalWarn = console.warn;
      console.warn = function () {
        window.__s3workers.warnings.push(Array.prototype.map.call(arguments, String).join(" "));
        originalWarn.apply(console, arguments);
      };
    })();
    (function () {
      var Native = window.Worker;
      if (!Native || Native.__s3wrapped) { return; }
      class TrackedWorker extends Native {
        constructor(url, options) {
          super(url, options);
          if (options && options.__s3untracked) { return; }
          var record = { label: (options && options.name) || "", url: String(url),
                         sent: 0, received: 0, errors: [] };
          window.__s3workers.records.push(record);
          this.__s3record = record;
          this.addEventListener("message", function () { record.received += 1; });
          this.addEventListener("error", function (event) {
            record.errors.push(String((event && event.message) || "error"));
          });
        }
        postMessage(message, transfer) {
          if (this.__s3record) { this.__s3record.sent += 1; }
          return transfer === undefined ? super.postMessage(message) : super.postMessage(message, transfer);
        }
      }
      TrackedWorker.__s3wrapped = true;
      window.Worker = TrackedWorker;
    })();
    """

    /// What the workers Monaco itself created actually carried, per service.
    ///
    /// `bridge.js` names each worker with the language label Monaco asked for, so the label is
    /// the attribution: a bucket per language service, and everything else — the editor worker
    /// is asked for under `editorWorkerService` — under `editor`. Read after the functional
    /// probes and after the diff, because those are what make Monaco create and use them.
    static let monacoWorkerProbe = """
    var records = (window.__s3workers && window.__s3workers.records) || [];
    var alias = { typescript: "typescript", javascript: "typescript", json: "json",
                  css: "css", scss: "css", less: "css",
                  html: "html", handlebars: "html", razor: "html" };
    var byService = {};
    records.forEach(function (record) {
      var service = alias[record.label] || "editor";
      var bucket = byService[service];
      if (!bucket) { bucket = byService[service] = { workers: 0, sent: 0, received: 0, labels: [], errors: [] }; }
      bucket.workers += 1;
      bucket.sent += record.sent;
      bucket.received += record.received;
      if (bucket.labels.indexOf(record.label) < 0) { bucket.labels.push(record.label); }
      bucket.errors = bucket.errors.concat(record.errors);
    });
    // "Could not create web worker(s). Falling back to loading web worker code in main thread"
    // is what Monaco says when it gives up, through `console.warn` and behind a guard that may
    // suppress it entirely in a browser. Corroboration, never proof: the counts above are what
    // separates a working worker from the fallback.
    var spoken = (window.__s3workers && window.__s3workers.warnings || [])
      .concat((window.__s3boot || []).map(function (entry) { return String(entry.message || ""); }));
    var fallbackWarnings = spoken.filter(function (message) {
      return message.toLowerCase().indexOf("web worker") >= 0;
    });
    return { byService: byService, workerCount: records.length, fallbackWarnings: fallbackWarnings,
             labels: records.map(function (record) { return record.label; }) };
    """

    /// Installed at `didCommit`, before the document's own scripts run.
    ///
    /// A route that never reaches `ready` reports nothing through the bridge, because the
    /// bridge is one of the things that did not load. This is the only place the reason for
    /// such a failure survives, so it is installed as early as WebKit allows.
    static let bootErrorCapture = """
    window.__s3boot = [];
    window.addEventListener("error", function (event) {
      window.__s3boot.push({ kind: "error", message: String(event.message || ""),
                             filename: String(event.filename || ""), lineno: event.lineno || 0,
                             target: event.target && event.target.src ? String(event.target.src) : null });
    }, true);
    window.addEventListener("unhandledrejection", function (event) {
      window.__s3boot.push({ kind: "rejection", message: String(event.reason) });
    });
    var originalConsoleError = console.error;
    console.error = function () {
      window.__s3boot.push({ kind: "console.error",
                             message: Array.prototype.map.call(arguments, String).join(" ") });
      originalConsoleError.apply(console, arguments);
    };
    """

    /// Run when `ready` never arrived: how far did the document get, and what said so.
    static let postMortem = """
    return {
      readyState: document.readyState,
      documentBaseURI: document.baseURI,
      documentURL: String(location.href),
      hasBridge: typeof window.afleetBridge !== "undefined",
      hasMonaco: typeof globalThis.monaco !== "undefined",
      stylesheetsLoaded: document.styleSheets.length,
      styleSheetRules: (function () {
        try { return document.styleSheets.length ? document.styleSheets[0].cssRules.length : -1; }
        catch (failure) { return "unreadable: " + String(failure); }
      })(),
      scripts: Array.prototype.map.call(document.querySelectorAll("script"), function (element) {
        return { src: element.src || "(inline module)", type: element.type || "classic" };
      }),
      captured: window.__s3boot || "the boot capture never ran"
    };
    """

    /// Everything the page can say about how it was loaded, for the record.
    static let environmentProbe = """
    var resources = performance.getEntriesByType("resource");
    var schemes = {};
    resources.forEach(function (entry) {
      var scheme = String(entry.name).split(":")[0];
      schemes[scheme] = (schemes[scheme] || 0) + 1;
    });
    return {
      documentBaseURI: document.baseURI,
      documentURL: String(location.href),
      origin: String(location.origin),
      resourceCount: resources.length,
      resourceSchemes: schemes,
      hasMonaco: typeof globalThis.monaco !== "undefined",
      stylesheetsLoaded: document.styleSheets.length,
      errors: window.__s3.errors.slice(0, 8)
    };
    """
}
