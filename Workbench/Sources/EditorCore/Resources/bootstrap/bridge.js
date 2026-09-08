// The editor-side half of the W4 bridge: one flat tagged JSON object per message, in both
// directions. The Swift spelling of this vocabulary is EditorCore's BridgeCodec.swift, and a
// test asserts every `type` string it emits appears in this file. Adding a message here that
// the codec does not know, or renaming one it does, is the drift that test exists to catch.
//
// A plain classic script, no build step and no module graph: it must load identically under
// every route S3 is still choosing between (custom scheme, blob URL, file URL), and a classic
// script is the one shape none of them can refuse.
//
// Wiring to a live Monaco instance is a later task, and it is filling in the bodies of the
// `adapter` methods below — this file's dispatch and event shapes do not move for it.

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
    receive: receive,
    events: events,
  };
})(window);
