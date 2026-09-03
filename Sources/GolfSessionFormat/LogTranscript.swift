import Foundation

/// The round's logs as plain text, for a clipboard or a file.
///
/// **In the package rather than in the view, because the selection is the part
/// that can be quietly wrong.** The round screen's timeline is *not* the list to
/// copy: it hides a log that an event already cites, on the argument that showing
/// the same sentence twice is clutter (the event quotes it underneath instead).
/// Copying that list would therefore drop exactly the sentences extraction
/// succeeded on — the transcript would look complete and be missing its best
/// material, with nothing on screen to say so. So this reads the logs directly and
/// applies only the hole filter.
public enum LogTranscript {

    /// The logs shown for one hole, with the screen's own rule about nil.
    ///
    /// **A log with no hole belongs to every hole, never to none.** `hole` is a
    /// proposal from `Course.nearestHole` and is nil whenever there was no fix,
    /// no course file, or the phone was more than 250 m from anything mapped —
    /// which is most test runs and a fair number of real ones. Excluding those
    /// rows would make a copied transcript silently shorter than the screen it was
    /// copied from.
    ///
    /// - Parameter hole: nil copies the whole round.
    public static func onHole(_ logs: [LogEntry], hole: Int?) -> [LogEntry] {
        guard let hole else { return logs }
        return logs.filter { $0.hole == hole || $0.hole == nil }
    }

    /// `0:12:04  steve made par` — one line per log, elapsed from the round's own
    /// start rather than a wall clock, which is the same number the row shows.
    ///
    /// **A row with no words prints its fields instead** *(2026-09-03)*. Since the
    /// `"<hole>: <shot>"` prefix was retired, a marker filed from the Action Button
    /// or from the legend's shot button carries an empty text — and a bare timestamp
    /// followed by nothing reads as a corrupted file rather than as a position
    /// somebody stamped. Parenthesised, so it cannot be mistaken for something that
    /// was said, and with raw ids in it, because this is the plain-text rendering:
    /// what the app actually copies is `RoundExport`, which is JSON and resolves
    /// names properly.
    public static func text(_ logs: [LogEntry], start: Millis) -> String {
        logs
            .sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
            .map { "\(elapsed($0.t, from: start))  \(body(of: $0))" }
            .joined(separator: "\n")
    }

    private static func body(of log: LogEntry) -> String {
        let said = log.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.isEmpty else { return said }
        var parts: [String] = [log.mark == true ? "mark" : "marker"]
        if let hole = log.hole { parts.append("hole \(hole)") }
        if let player = log.player { parts.append(player) }
        if let shot = log.shot { parts.append("shot \(shot)") }
        return "(" + parts.joined(separator: " · ") + ")"
    }

    /// `H:MM:SS` since the round began, floored at zero — a log can predate
    /// `meta.start` by a few milliseconds when the first phrase commits during
    /// startup, and a negative clock reads as corruption.
    public static func elapsed(_ t: Millis, from start: Millis) -> String {
        let s = max(0, Int(Double(t - start) / 1000))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
