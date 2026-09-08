import SwiftUI

/// The queue chip, above the field (spec §8.5, C6.2 *The queue chip*).
///
/// Thin over `QueueChipModel`: one row per queued message, in the order the model holds them, each
/// with the one action the engine offers. It draws nothing when the queue is empty, which is the
/// arm that makes the chip mean something — a chip that is always on says nothing about whether a
/// message is waiting.
///
/// It writes no sentence about the queue's state and computes no row: `model.rows` **is** the
/// engine's `queued` list, read through the channel's one fold (contract X4).
struct QueueChipView: View {

    let model: QueueChipModel

    var body: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // A count, not the ids: what the user needs is how many are waiting (§11).
                Text("\(model.rows.count) message(s) queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.rows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        // The label is the timeline's own text for the message; a row the timeline
                        // has no item for yet is still drawn, unlabelled, because hiding it would
                        // hide a queued message from the person who queued it.
                        Text(row.label ?? "Queued")
                            .lineLimit(1)
                            .foregroundStyle(row.label == nil ? .secondary : .primary)
                        Spacer(minLength: 8)
                        Button("Cancel") { Task { await model.cancel(row.id) } }
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
                if let failure = model.cancelFailure {
                    // Only an X5 refusal reaches here. `{cancelled: false}` is not one: it means the
                    // message already started, and it shows nothing.
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
