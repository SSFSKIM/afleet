import Foundation
import AfleetCore
import FleetKit

/// Telling the fleet a channel exists.
///
/// A protocol of exactly one member, and deliberately **not** part of `LifecycleAPI`: registration
/// is `Fleet`'s own API, so a `LifecycleAPI` double has no way to record it and a test that wants
/// to prove "every listed entry was registered" needs a seam of its own. `AppFleet` refines it, so
/// `Workspace.fleet` is one without a cast.
protocol ChannelRegistering: Sendable {
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async
}

/// The listing join: C3's index on one side, C4's `ListingPolicy` in the middle, `Fleet.register`
/// on the other (spec §3, §4).
///
/// Everything here is a pure function over values. The rules are not re-implemented and not
/// re-ordered: `decide` walks `ListingPolicy.rules` in C4's own order and reports the name of the
/// first rule that fired, which is what lets the UI say *why* a transcript is missing instead of
/// leaving its absence mysterious. In particular `own-sdk-cli` fires before `sidechain`, so
/// afleet's own sessions are listed even when the transcript flags them — that ordering is C4's
/// deliberate choice and this file inherits it rather than restating it.
enum ChannelRegistrar {

    /// §7.4 and §8.2's split, in seconds. Not a new policy: the parent's, spelled once.
    static let recencyWindow: TimeInterval = 30 * 24 * 60 * 60

    /// The verdict for one entry together with the name of the rule that produced it.
    struct Decision: Sendable {
        let rule: String
        let verdict: ListingPolicy.Verdict

        var listedMode: ListingPolicy.Mode? {
            if case .listed(let mode) = verdict { return mode }
            return nil
        }

        var exclusionReason: ListingPolicy.Reason? {
            if case .excluded(let reason) = verdict { return reason }
            return nil
        }
    }

    /// What one snapshot listed, and why every entry in it landed where it did.
    struct Listing: Sendable {
        var configHome: URL
        /// The listed rows, newest first.
        var rows: [ChannelRow]
        /// Every entry of the snapshot, listed or not. An excluded entry is here and nowhere else,
        /// which is what makes "why is this transcript not in my sidebar" answerable.
        var decisions: [SessionID: Decision]

        func decision(for id: SessionID) -> Decision? { decisions[id] }
        var listedIDs: Set<SessionID> { Set(rows.map(\.id)) }
        var excludedIDs: Set<SessionID> {
            Set(decisions.filter { $0.value.exclusionReason != nil }.keys)
        }
    }

    /// What one registration pass did. Counts only: §11 forbids a path or an identifier from a real
    /// home in any report, and a count is what the diagnostics line needs anyway.
    struct RegistrationReport: Hashable, Sendable {
        var registered = 0
        var recent = 0
        /// Listed rows whose `IndexEntry` carried no `cwd`. These are **not** registered: a key with
        /// no seed runs in the config home and every precondition then refuses it (spec §3). They
        /// render archived instead.
        var skippedWithoutCWD = 0
    }

    // MARK: - The join

    /// The first `ListingPolicy` rule that fires, and its verdict.
    static func decide(_ entry: IndexEntry) -> Decision {
        let subject = ListingPolicy.IndexEntry(entry)
        for rule in ListingPolicy.rules {
            if let verdict = rule.decide(subject) { return Decision(rule: rule.name, verdict: verdict) }
        }
        // `ListingPolicy.rules` ends in a rule named `default` that always fires, so this line is
        // unreachable today. It matches `ListingPolicy.include`'s own total fallback rather than
        // trapping, because a rule set that stopped being total is C4's change to make, not a crash
        // in the sidebar.
        return Decision(rule: "default", verdict: .listed(.ownedCandidate))
    }

    /// Every entry of a snapshot run through the rules, with the listed ones turned into rows.
    ///
    /// `configHome` is the home every row's `ChannelKey` is built under, and it defaults to the
    /// snapshot's own. The composition root passes the *fleet's* home explicitly: `TranscriptIndex`
    /// records a symlink-resolved root in its snapshot while `Fleet` keys its supervisors by the
    /// root as resolved at launch, and two spellings of one directory here would register one key
    /// and then act on another.
    static func listed(_ snapshot: IndexSnapshot, configHome: URL? = nil, now: Date = Date()) -> Listing {
        let home = configHome ?? snapshot.configHome
        var decisions: [SessionID: Decision] = [:]
        var rows: [ChannelRow] = []
        decisions.reserveCapacity(snapshot.entries.count)
        rows.reserveCapacity(snapshot.entries.count)
        for (id, entry) in snapshot.entries {
            let decision = decide(entry)
            decisions[id] = decision
            if let mode = decision.listedMode {
                rows.append(row(for: entry, configHome: home, mode: mode,
                                rule: decision.rule, now: now))
            }
        }
        rows.sort { $0.mtime > $1.mtime }
        return Listing(configHome: home, rows: rows, decisions: decisions)
    }

    /// One entry as a row. The live half is left nil: it can only come from a `ChannelState`.
    static func row(for entry: IndexEntry, configHome: URL, mode: ListingPolicy.Mode,
                    rule: String, now: Date, isProvisional: Bool = false) -> ChannelRow {
        ChannelRow(key: ChannelKey(configHome: configHome, session: entry.sessionID),
                   title: entry.title,
                   titleSource: entry.titleSource,
                   preview: entry.preview,
                   cwd: entry.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
                   gitBranch: entry.gitBranch,
                   agentName: entry.agentName,
                   mtime: entry.mtime,
                   isRecent: isRecent(entry.mtime, now: now),
                   mode: mode,
                   decidingRule: rule,
                   isProvisional: isProvisional,
                   state: nil,
                   banner: nil)
    }

    /// §8.2's thirty-day rule. A future mtime is recent, which is the only sane reading of a clock
    /// that disagrees with a file.
    static func isRecent(_ mtime: Date, now: Date) -> Bool {
        now.timeIntervalSince(mtime) <= recencyWindow
    }

    // MARK: - Registration

    /// Seeds the fleet with every listed row that has a real working directory.
    ///
    /// The seed is the entry's **own** cwd and never the config home: C4 is explicit that a key with
    /// no seed runs in the config home, and every precondition then refuses it. A row with no cwd is
    /// therefore skipped and counted rather than registered against a directory it does not run in.
    @discardableResult
    static func register(_ listing: Listing, into fleet: any ChannelRegistering,
                         now: Date = Date()) async -> RegistrationReport {
        await register(listing.rows, into: fleet, now: now)
    }

    @discardableResult
    static func register(_ rows: [ChannelRow], into fleet: any ChannelRegistering,
                         now: Date = Date()) async -> RegistrationReport {
        var report = RegistrationReport()
        for row in rows {
            guard let cwd = row.cwd else {
                report.skippedWithoutCWD += 1
                continue
            }
            let recent = isRecent(row.mtime, now: now)
            await fleet.register(row.key, cwd: cwd, recent: recent)
            report.registered += 1
            if recent { report.recent += 1 }
        }
        return report
    }
}
