import Foundation

/// The S7 corpus: ten markdown documents, and the delta cadence of a real recording.
///
/// **Every character of the prose below is invented.** No engine byte is present, no recording was
/// read to write it, and nothing here was derived from a transcript. That is not a shortcut around
/// §11's publication rules — it satisfies them at their root, because the rule is about a byte's
/// origin and these bytes have none.
///
/// It exists because the corpus the gate names **does not exist in `Fixtures/`**. Surveyed across
/// all twenty committed fixtures: seventy-two assistant text blocks, the longest four hundred and
/// twenty-seven characters, containing zero fenced code blocks, zero table rows and zero nested
/// lists. Most are two to eight characters. So C6.1's G1 as the composite worded it — "recorded
/// assistant messages from `Fixtures/`, with tables, nested lists, fenced code" — was not
/// satisfiable, and the architect ruled the replacement: invented content at a recorded cadence.
///
/// What S7 measures is the renderer's frame time under a content **shape** and an event **rate**.
/// The shape is what the gate enumerates and is below; the rate is real and comes from
/// `nested-depth-2`, whose fifty-eight `content_block_delta` events are the richest streaming
/// recording the corpus holds. Provenance of the prose changes neither number. What it does cost is
/// that fidelity-to-the-terminal is argued from the parity map and from HighlightKit's own
/// differential fixtures rather than witnessed side by side, and that is written down as the thing
/// a human still has to look at.
enum MarkdownCorpus {

    /// Ten documents, covering every shape the gate names.
    static let documents: [String] = [
        // Document 1
        """
# One

A paragraph with `inline code`, a [link](https://invented.example/alpha), **strong** text and
*emphasised* text, so the inline runs are all exercised in one place.

## Two

### Three

#### Four

##### Five

###### Six

That is all six heading levels, which is what the gate names.
""",
        // Document 2
        """
## A table, and a wider one

| column | meaning | default |
|---|---|---|
| `mode` | the permission mode the channel runs under | `default` |
| `effort` | how hard the model is asked to think | unset |
| `model` | which model answered the turn | the account's |

A second table immediately after the first, because two in one document is the case a renderer
that caches per document rather than per block gets wrong.

| a | b |
|---|---|
| 1 | 2 |
""",
        // Document 3
        """
## Nested lists

- one
  - one point one
    - one point one point one
  - one point two
- two
  1. two point one
  2. two point two
     - a bullet under an ordinal
- three

1. first
2. second
   1. second point one
   2. second point two
      - and a bullet three deep
3. third
""",
        // Document 4
        """
## Fenced Swift

```swift
@MainActor
final class InventedController: NSObject {
    private var rows: [String] = []
    func append(_ line: String) {
        rows.append(line)
        guard rows.count > 100 else { return }
        rows.removeFirst(rows.count - 100)
    }
}
```

And a sentence after the fence so the block is closed and the paragraph that follows it is a
separate settled block.
""",
        // Document 5
        """
## Fenced Python and JSON

```python
def invented(rows, limit=100):
    kept = [r for r in rows if r]
    return kept[-limit:] if len(kept) > limit else kept
```

```json
{
  "invented": true,
  "rows": [1, 2, 3],
  "nested": {"a": null, "b": [{"c": "d"}]}
}
```
""",
        // Document 6
        """
## Fenced TypeScript, a shell session, and a language with no grammar

```typescript
export function invented<T>(rows: readonly T[], limit = 100): T[] {
  return rows.length > limit ? rows.slice(rows.length - limit) : [...rows];
}
```

```bash
$ afleet --invented
reading 4,261 transcripts
done in 2,105 ms
```

```zzunknownlang
this fence names a language no grammar covers, which is the fallback path §6 says is the
ordinary path rather than a rainy-day one
```
""",
        // Document 7
        """
## Quotes

> A block quote, which the terminal prefixes with a vertical bar and renders italic.
>
> A second paragraph inside the same quote.

> - a list inside a quote
> - which nests differently again

Ordinary text after the quote.
""",
        // Document 8
        """
## A long unbroken line

afleet renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expensive case renders one very long unbroken paragraph line without any newline in it so the layout engine has to wrap it itself which is the expe
""",
        // Document 9
        """
## A CJK paragraph

afleet 는 대화 기록을 원래 있었던 그대로 보여 준다. 모델이 쓴 문장과 사람이 쓴 문장이 같은 줄기 안에서 이어지고, 도구 호출은 접혀 있다가 필요할 때 펼쳐진다. 中文段落也在同一个渲染路径里：字形宽度不同，换行规则不同，行高也不同，所以它必须被真正地排版而不是被当作拉丁字母处理。日本語の段落も同じで、約物や禁則処理が入ると行の折り返しは単純な空白分割では決まらない。
""",
        // Document 10
        """
Considering the shape of the problem before answering. The row heights have to be cached per
item id or the table measures every row on every reload, and the measurement has to be invalidated
only for the ids a change names. If the whole cache is cleared on every publish the virtualisation
buys nothing, because measuring is most of the cost of a row that is not on screen.

There is a second question underneath: whether the streaming tail should be laid out as a settled
row at all. It should not — the last partial line jitters on every delta if it is, which is the
`wrap-stream` rule.
""",
    ]

    /// The index of the document that stands for a thinking block.
    static let thinkingDocumentIndex = 9

    /// The inter-arrival gaps of `nested-depth-2`'s `content_block_delta` events, in seconds, read
    /// from the committed fixture at test time rather than transcribed into this file — a
    /// transcribed cadence is a cadence that silently stops matching the recording it claims.
    static func cadence() throws -> [TimeInterval] {
        let url = FixtureRunner.directory("nested-depth-2").appending(path: "frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        var stamps: [Double] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frame = object["frame"] as? [String: Any],
                  frame["type"] as? String == "stream_event",
                  let event = frame["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let t = object["t"] as? Double else { continue }
            stamps.append(t / 1000)
        }
        guard stamps.count > 1 else { return [] }
        return zip(stamps.dropFirst(), stamps).map { max(0, $0 - $1) }
    }

    /// How many `content_block_delta` events the recording carries, counted the same way, so a test
    /// can compare the cadence against the recording rather than against a number written here.
    static func recordedDeltaCount() throws -> Int {
        let url = FixtureRunner.directory("nested-depth-2").appending(path: "frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frame = object["frame"] as? [String: Any],
                  frame["type"] as? String == "stream_event",
                  let event = frame["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta" else { continue }
            count += 1
        }
        return count
    }

    /// Every fenced block in the corpus, as the highlighter's warm-up wants them.
    static var fencedBlocks: [(code: String, language: String?)] {
        var out: [(code: String, language: String?)] = []
        for document in documents {
            var lines = document.split(separator: "\n", omittingEmptySubsequences: false)[...]
            while let openIndex = lines.firstIndex(where: { $0.hasPrefix("```") }) {
                let language = String(lines[openIndex].dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let rest = lines[lines.index(after: openIndex)...]
                guard let closeIndex = rest.firstIndex(where: { $0.hasPrefix("```") }) else { break }
                let code = rest[rest.startIndex..<closeIndex].joined(separator: "\n")
                out.append((code, language.isEmpty ? nil : language))
                lines = rest[rest.index(after: closeIndex)...]
            }
        }
        return out
    }
}
