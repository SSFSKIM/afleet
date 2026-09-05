// FleetTimeline — the timeline data half of FleetKit (parent §17 C3, contract X4).
//
// This module turns Claude Code's own on-disk transcripts and its `transcript_mirror`
// frames into one ordered, keyed, losslessly re-encodable record stream. Nothing here
// re-implements the engine: every record is the engine's own JSON, decoded into a typed
// shape that keeps every key it did not model (`Lossless`), and every kind name is
// transcribed from the engine bundle's own tables rather than guessed.
//
// The vocabulary is:
//
// - `LogicalStream` — a transcript's identity (config home, session, stream name). Paths
//   under `<configHome>/projects/` are aliases of it; `TranscriptPath.resolve` is the only
//   place a path becomes a stream.
// - `TranscriptRecord` — one line of a transcript, or one mirror entry: a conversation
//   record, a session-state record, an agent-metadata sidecar, an unrecognised kind, or an
//   undecodable line. Never dropped, never lossy.
// - `RecordKey` — a record's identity within a stream: its `uuid`, or, for the kinds the
//   engine writes without one, the canonical-JSON hash plus an occurrence ordinal, because
//   the engine repeats byte-identical state records and never deduplicates them.
// - `RecordDecoder` — the two-stage decode (`JSONValue`, then the typed model from the same
//   bytes) that a file line and a mirrored entry both go through, so the two agree.
// - `SessionStateVocabulary` — the engine's own record-kind table. A kind outside it is
//   drift this module exists to notice.
