import Foundation

/// What the browse grid is currently showing.
///
/// **A filter is a default, not a constraint.** Opened from a hole view it arrives
/// carrying that course and that hole, because that is what the golfer standing
/// there means; every field clears, because "that drive on 12 last month" is
/// reached from wherever they happen to be standing.
public struct SwingFilter: Equatable, Sendable {
    public var courseID: String?
    public var hole: Int?
    public var playerID: String?
    public var roundID: String?
    public var tags: [String]
    public var text: String
    /// Empty means every source. Named sources are how "only vipl's folder" is
    /// expressed.
    public var sourceIDs: Set<String>

    public init(courseID: String? = nil, hole: Int? = nil, playerID: String? = nil,
                roundID: String? = nil, tags: [String] = [], text: String = "",
                sourceIDs: Set<String> = []) {
        self.courseID = courseID
        self.hole = hole
        self.playerID = playerID
        self.roundID = roundID
        self.tags = tags
        self.text = text
        self.sourceIDs = sourceIDs
    }

    public static let none = SwingFilter()

    public var isEmpty: Bool {
        courseID == nil && hole == nil && playerID == nil && roundID == nil
            && tags.isEmpty && text.isEmpty && sourceIDs.isEmpty
    }

    /// Seeded from where the golfer opened the list.
    public static func from(_ context: SwingContext, includeHole: Bool) -> SwingFilter {
        SwingFilter(courseID: context.courseID, hole: includeHole ? context.hole : nil)
    }

    public func matches(_ swing: Swing) -> Bool {
        let c = swing.meta.context
        if !sourceIDs.isEmpty && !sourceIDs.contains(swing.sourceID) { return false }
        if let courseID, c.courseID != courseID { return false }
        if let hole, c.hole != hole { return false }
        if let playerID, c.playerID != playerID { return false }
        if let roundID, c.roundID != roundID { return false }
        if !tags.isEmpty {
            // vipl's rule, kept: a tag matches as a case-insensitive substring of
            // any tag on the swing, so "dri" finds "driver".
            let have = c.tags.map { $0.lowercased() }
            for tag in tags {
                let needle = tag.lowercased()
                guard have.contains(where: { $0.contains(needle) }) else { return false }
            }
        }
        if !text.isEmpty {
            let needle = text.lowercased()
            let haystack = [c.caption, swing.name, c.note ?? ""].joined(separator: " ").lowercased()
            guard haystack.contains(needle) else { return false }
        }
        return true
    }
}

public enum SwingSort: String, CaseIterable, Sendable {
    case newest, oldest, longest, name

    public func sorted(_ swings: [Swing]) -> [Swing] {
        switch self {
        case .newest: return swings.sorted { $0.sortDate > $1.sortDate }
        case .oldest: return swings.sorted { $0.sortDate < $1.sortDate }
        case .longest: return swings.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case .name: return swings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public var label: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .longest: return "Longest"
        case .name: return "Name"
        }
    }
}

extension Swing {
    /// **The file's creation date, falling back to its modification date.** A
    /// metadata edit preserves both (`SwingMetadata.replace`), so a swing does not
    /// jump to the top of the grid because somebody fixed a tag.
    public var sortDate: Date { created ?? modified }
}
