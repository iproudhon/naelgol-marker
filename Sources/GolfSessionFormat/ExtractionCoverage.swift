import Foundation

/// Which logs extraction has already read.
///
/// **A log that produced nothing is still a log that was read, and nothing else
/// records that.** Events cite the logs they rest on, so "has anything cited this
/// log?" looks like a coverage check and is not one: a log that yields **no
/// proposal at all** — "we're on the ninth", "players are A, B, C, D", anything
/// the model shrugs at — is never cited by anything, so it stays unread forever.
/// Every trigger re-reads it, and every pass that hallucinates something appends
/// another event. Observed on device 2026-08-27: repeated Apple Intelligence calls
/// producing garbage over one typed sentence.
///
/// Exactly the same shape as ``TranscriptCoverage``, and for the same reason
/// written there: a silent audio segment produces no utterances, so "does any
/// utterance fall in this window" marks a quiet stretch undone and re-transcribes
/// it forever. This is that trap one level up.
///
/// **Keyed on the row id, not the chain root.** Editing a log writes a superseding
/// row with a *new* id, which is deliberately absent from coverage — a corrected
/// sentence must be read again, since correcting it is the whole reason the user
/// bothered. Keying on the root would silently make every edit a no-op.
///
/// Ground truth? **No** — it is a record of what the machine did, not of what
/// happened in the round, and it is the same kind of bookkeeping as
/// `TranscriptCoverage`. It never enters a prompt because nothing would want it.
public struct ExtractionCoverage: Codable, Sendable, Equatable {

    /// `LogEntry.id` of every log a completed extraction pass has been shown.
    public var logs: Set<String>

    /// Which extractor produced it — the on-device draft pass or the cloud one.
    ///
    /// A cache that could not tell them apart would serve the weaker path's
    /// coverage for the stronger one's run, which is the mistake
    /// `TranscriptCoverage` records the transcriber to avoid.
    public var extractor: String

    public init(logs: Set<String> = [], extractor: String = "") {
        self.logs = logs
        self.extractor = extractor
    }

    /// The logs in `candidates` that still need reading.
    ///
    /// - Parameter cited: log ids already referenced by an event. Kept as a second
    ///   source so a round extracted *before* this file existed is not re-read
    ///   from scratch — its events are the only record of what was covered.
    public func unread(_ candidates: [LogEntry], cited: Set<String> = []) -> [LogEntry] {
        candidates.filter { !logs.contains($0.id) && !cited.contains($0.id) }
    }

    public mutating func mark(_ entries: [LogEntry], extractor: String) {
        logs.formUnion(entries.map(\.id))
        self.extractor = extractor
    }
}
