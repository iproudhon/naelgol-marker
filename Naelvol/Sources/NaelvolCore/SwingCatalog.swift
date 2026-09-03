import Foundation

/// What the host can offer a swing's fields, as plain values.
///
/// The edit sheet needs a list of courses, their holes and the round's players —
/// and naelvol must not learn what a `Course` is to get one. The host flattens
/// its own types into this; **an empty catalog is an ordinary state**, and the
/// sheet then takes free text.
public struct SwingCatalog: Sendable, Equatable {
    public struct Hole: Sendable, Equatable, Identifiable {
        public var id: Int { index }
        /// 1-based playing index — the scorecard's meaning.
        public var index: Int
        /// The course's own label, where it has one (`"황룡/3"`).
        public var ref: String?
        public init(index: Int, ref: String? = nil) {
            self.index = index
            self.ref = ref
        }
        public var label: String { ref ?? String(index) }
    }

    public struct Course: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var holes: [Hole]
        public init(id: String, name: String, holes: [Hole] = []) {
            self.id = id
            self.name = name
            self.holes = holes
        }
    }

    public struct Player: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var courses: [Course]
    public var players: [Player]
    public var roundID: String?

    public init(courses: [Course] = [], players: [Player] = [], roundID: String? = nil) {
        self.courses = courses
        self.players = players
        self.roundID = roundID
    }

    public static let empty = SwingCatalog()

    public func course(id: String?) -> Course? {
        guard let id else { return nil }
        return courses.first { $0.id == id }
    }

    public func player(id: String?) -> Player? {
        guard let id else { return nil }
        return players.first { $0.id == id }
    }

    /// Fill in the labels a context stores alongside its ids, so a swing carries
    /// a readable record even on a phone that has since deleted the course.
    public func resolve(_ context: SwingContext) -> SwingContext {
        var out = context
        if let course = course(id: context.courseID) {
            out.courseName = course.name
            if let hole = context.hole {
                out.holeRef = course.holes.first { $0.index == hole }?.ref
            }
        }
        if let player = player(id: context.playerID) { out.playerName = player.name }
        return out
    }
}
