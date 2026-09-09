// C7.7 spec Design §8: the check rollup, and the bucket table it is a function of.
import Foundation
import SourceControlCore

/// One check's bucket, as this panel names it.
///
/// `gh` categorises every check's `state` into a bucket of its own — `pass`, `fail`, `pending`,
/// `skipping`, `cancel` — and this leaf reads that bucket rather than re-deriving it from `state`
/// (C7.3's `CheckRun`). The table below is the whole of what those five mean here, in one place, so
/// that the rollup is a function of a named vocabulary rather than of string comparisons scattered
/// through a view.
///
/// `unrecognised` is the sixth case and the honest one: `gh` may grow a bucket, and a panel that
/// mapped an unknown string onto its nearest neighbour would report a state it has never seen as
/// one it understands.
public enum CheckBucket: String, Hashable, Sendable, CaseIterable {
    case passing
    case failing
    case pending
    /// A check that did not run — a path filter, a conditional job. It did not fail, and `gh`'s own
    /// exit code treats it as not failing, so it neither fails a rollup nor holds one back.
    case skipped
    case unrecognised

    public init(bucket: String) {
        switch bucket {
        case "pass": self = .passing
        // `cancel` is a failure and not a pending: a cancelled check is finished, and nothing
        // further will arrive to change it.
        case "fail", "cancel": self = .failing
        case "pending": self = .pending
        case "skipping": self = .skipped
        default: self = .unrecognised
        }
    }

    /// What a row for one check says. Never the bucket string `gh` printed: this panel renders its
    /// own vocabulary (§6.3).
    public var label: String {
        switch self {
        case .passing: "Passed"
        case .failing: "Failed"
        case .pending: "Running"
        case .skipped: "Skipped"
        case .unrecognised: "In a state this panel does not name"
        }
    }
}

/// What every check on one pull request adds up to.
///
/// **Five-valued deliberately, and `none` is the reason.** A rollup that answered `passing` for a
/// pull request with no checks at all would pass every happy-path test ever written against it and
/// tell the user their untested branch is green. "No checks" is a different statement from "the
/// checks passed", and this type is where that distinction is kept.
public enum CheckRollup: Hashable, Sendable, CaseIterable {
    /// The checks were read and there are none. Not `passing`.
    case none
    case pending
    case failing
    case passing
    /// At least one bucket `gh` reported that `CheckBucket` does not name.
    case unknown

    /// The rollup of a pull request's checks.
    ///
    /// The precedence is stated once, here, and each step is a claim about what the user needs to
    /// know first:
    ///
    /// 1. no checks at all is `none`, before anything else can be said;
    /// 2. a failure outranks everything — a run still in flight does not make a failed one pending,
    ///    and a bucket this panel cannot name does not make a failed one unknowable;
    /// 3. a bucket that is not named **outranks a pending**, because "still running" is a claim
    ///    about what will happen next and this panel has no basis to make it for a state it has
    ///    never seen. `[pending, unrecognised]` is therefore `unknown` and not `pending`; that
    ///    mixture is the one case where this ordering is observable, and the table test has a row
    ///    for it. T4.2's plan wrote the two the other way round and the plan is what was loose;
    ///    ruled at the fix wave, 2026-09-09;
    /// 4. anything still pending is `pending`;
    /// 5. otherwise every check passed or was skipped, which is `passing` — **including a list
    ///    that is entirely `skipping`**. A skipped check did not fail and nothing further will
    ///    arrive to change it, which is the same judgement `gh`'s own exit code makes; and `none`
    ///    is already the case for "nothing ran at all", so folding all-skipped into it would erase
    ///    the difference between a pull request whose jobs were filtered out and one that has no
    ///    workflow at all. Ruled at the fix wave, 2026-09-09, with its own row in the table.
    public static func of(_ checks: [CheckRun]) -> CheckRollup {
        of(checks.map { CheckBucket(bucket: $0.bucket) })
    }

    static func of(_ buckets: [CheckBucket]) -> CheckRollup {
        if buckets.isEmpty { return .none }
        if buckets.contains(.failing) { return .failing }
        if buckets.contains(.unrecognised) { return .unknown }
        if buckets.contains(.pending) { return .pending }
        return .passing
    }

    /// The badge's text. Written here rather than in the view so a test asserting on a readout is
    /// asserting on the words the user reads (§17.7).
    public var label: String {
        switch self {
        case .none: "No checks"
        case .pending: "Checks running"
        case .failing: "Checks failing"
        case .passing: "Checks passing"
        case .unknown: "Checks in a state this panel does not name"
        }
    }
}
