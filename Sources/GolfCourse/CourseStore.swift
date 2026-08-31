import Foundation

/// Course files on disk: one JSON per course, in a folder of their own.
///
/// Deliberately **not** inside `Sessions/`. A session is per-round, gitignored and
/// full of other people's voices; a course is a one-time artifact with neither, and
/// is meant to be kept and shared.
public struct CourseStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// `Documents/Courses` on iOS. `UIFileSharingEnabled` is already on, so a
    /// course file can be dropped in over Finder or the Files app without a build.
    public static var documents: CourseStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return CourseStore(directory: docs.appendingPathComponent("Courses"))
    }

    public func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public func save(_ course: Course) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let tmp = directory.appendingPathComponent(".\(course.id).json.tmp")
        try encoder.encode(course).write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url(for: course.id), withItemAt: tmp)
    }

    // MARK: - Terrain

    /// The elevation sidecar. **A separate file, and deliberately not `.json`.**
    ///
    /// Separate because a grid is hundreds of kilobytes of base64 and a course
    /// file is meant to stay readable and diffable — a course's geometry is edited
    /// by hand and reviewed; its terrain never is. Not `.json` because `loadAll()`
    /// decodes every `.json` in the directory as a `Course`, and a sidecar sitting
    /// beside them would be a file that fails to parse on every scan.
    ///
    /// Missing is the ordinary case: every course file written before 2026-08-30
    /// has no terrain, and Korea has no source yet at all.
    public func elevationURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).dem")
    }

    public func save(_ elevation: Elevation, for id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let tmp = directory.appendingPathComponent(".\(id).dem.tmp")
        try encoder.encode(elevation).write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(elevationURL(for: id), withItemAt: tmp)
    }

    /// Whether a `.dem` is on disk, without decoding hundreds of kilobytes of it.
    ///
    /// The question "does this course have terrain?" is asked in places that do not
    /// want the grid — an export sheet deciding whether to offer a toggle, an
    /// import deciding what to say — and `loadElevation(id:) != nil` answers it by
    /// parsing the whole file. On the main actor that is the same hang the import
    /// sheet was already fixed for once.
    public func elevationExists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: elevationURL(for: id).path)
    }

    /// Nil when the course has no terrain, which is not an error — the plays-like
    /// number simply does not appear, the same way `rise` is nil for a hole with
    /// no elevation behind it.
    public func loadElevation(id: String) -> Elevation? {
        guard let data = try? Data(contentsOf: elevationURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Elevation.self, from: data)
    }

    public func load(id: String) throws -> Course {
        try JSONDecoder().decode(Course.self, from: Data(contentsOf: url(for: id)))
    }

    /// Every course file that parses. A corrupt one is skipped rather than fatal —
    /// the same tolerance the session reader has.
    public func loadAll() -> [Course] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? JSONDecoder().decode(Course.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }
}
