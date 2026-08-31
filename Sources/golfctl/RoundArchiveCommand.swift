import Foundation
import GolfSessionFormat
import GolfCourse
import GolfExchange

/// `golfctl round export|import|show` — a whole round out to one pasteable
/// document, and back again.
///
/// **This is the only place the archive path is exercised by hand.** Scripted taps
/// do not exist in this environment, so the app's Export and Import buttons can be
/// screenshotted and not driven; every rule the format has — the two wire forms,
/// the course collision, the ground-truth nesting — is verified here and by test.
func cmdRound(_ args: Args) {
    switch args.positionals.first ?? "" {
    case "export": cmdRoundExport(args)
    case "import": cmdRoundImport(args)
    case "show":   cmdRoundShow(args)
    default:
        fail("round: unknown action — try export, import or show")
    }
}

/// `golfctl round export <session> [--out FILE] [--courses DIR] [--no-terrain] [--plain|--compressed]`
///
/// Writes to stdout by default, so it pipes: `golfctl round export S | pbcopy`.
private func cmdRoundExport(_ args: Args) {
    guard args.positionals.count > 1 else {
        fail("""
            usage: golfctl round export <session> [--out FILE] [--courses DIR]
                                                  [--no-terrain]
                                                  [--plain | --compressed]

              --courses  where to look for the round's course file and its .dem
                         (default: Courses). The course is found by the name in
                         the round's own meta.json, which is what the app matches
                         on too.
              --no-terrain  leave the course's elevation grid out. It is most of
                         the bytes, and the receiving side can fetch it again from
                         USGS for itself. The export records that it was left out,
                         so an import can say so rather than look like a course
                         that never had any.
              --plain    force readable JSON, however big it gets
              --compressed  force the compact form, however small
            """)
    }
    let folder = SessionFolder(url: URL(fileURLWithPath: args.positionals[1]))
    guard let meta = try? folder.readMeta() else {
        fail("no meta.json in \(folder.url.path) — is that a session folder?")
    }

    // The course is resolved **by name**, not by id, because that is what a round
    // records and what the app matches on. An id would be a second scheme.
    let store = CourseStore(directory:
        URL(fileURLWithPath: args.string("courses", default: "Courses")!))
    var course: Course?
    var dem: Elevation?
    if let name = meta.course, !name.isEmpty {
        course = store.loadAll().first { $0.name == name || $0.aliases.contains(name) }
        if let course { dem = store.loadElevation(id: course.id) }
    }

    let includeTerrain = !args.bool("no-terrain")
    let bundle: RoundBundle
    let unreadable: [RoundArchive.Unreadable]
    do {
        (bundle, unreadable) = try RoundArchive.bundle(from: folder, course: course,
                                                       elevation: dem,
                                                       includeTerrain: includeTerrain,
                                                       generator: "golfctl")
    } catch { fail("could not read the round: \(error)") }

    var forced: Bool?
    if args.bool("plain") { forced = false }
    if args.bool("compressed") { forced = true }

    let text: String
    do { text = try BundleText.encode(bundle, compressed: forced) }
    catch { fail("could not encode: \(error)") }

    // Everything about what was and was not included goes to **stderr**, so the
    // document on stdout stays pipeable into a clipboard.
    warn("round      \(folder.url.lastPathComponent)")
    warn("           \(bundle.summary)")
    if let name = meta.course, !name.isEmpty, course == nil {
        warn("course     \"\(name)\" — NO FILE FOUND in \(store.directory.path); "
           + "the round is exported without its map")
    }
    if let dem {
        if includeTerrain {
            // **What it costs, measured rather than described.** The saving is not
            // guessable from the grid's own size: relief is entropy, so a flat
            // course's terrain nearly vanishes under zlib and a hilly one barely
            // moves. Encoding the other form once is the only honest answer, and
            // it is what turns --no-terrain from a flag into a decision.
            let without = (try? BundleText.encode(
                RoundArchive.bundle(from: folder, course: course, elevation: dem,
                                    includeTerrain: false, generator: "golfctl").bundle,
                compressed: forced))?.count
            warn("terrain    \(dem.width)x\(dem.height) grid included"
               + (without.map { ", \(text.count - $0) characters of this export — "
                              + "--no-terrain leaves it out" } ?? ""))
        } else {
            warn("terrain    LEFT OUT (--no-terrain); the export says so, so an import "
               + "can tell it apart from a course that never had any")
        }
    }
    if !bundle.round.audio.segments.isEmpty {
        warn("audio      \(bundle.round.audio.segments.count) segment(s) indexed — "
           + "the .m4a recordings are never included")
    }
    if !bundle.round.groundTruth.isEmpty {
        warn("           includes GROUND TRUTH (journal, scorecard, marks, corrections) "
           + "— do not paste this into a model")
    }
    for u in unreadable {
        warn("WARNING    \(u.lost) of \(u.onDisk) row(s) in \(u.file) could not be read and "
           + "are NOT in this export")
    }
    let form = text.hasPrefix(BundleText.marker) ? "compressed" : "plain JSON"
    warn("form       \(form), \(text.count) characters")

    if let out = args.string("out") {
        do { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        catch { fail("could not write \(out): \(error)") }
        warn("wrote      \(out)")
    } else {
        print(text)
    }
}

/// `golfctl round import <file|-> [--out DIR] [--courses DIR] [--dry-run]`
private func cmdRoundImport(_ args: Args) {
    guard args.positionals.count > 1 else {
        fail("""
            usage: golfctl round import <file|-> [--out Sessions] [--courses Courses]
                                                 [--dry-run] [--no-courses]

              -             read the export from stdin: pbpaste | golfctl round import -
              --dry-run     say what would happen and write nothing
              --no-courses  import the round only, leaving the carried course alone

            Nothing is ever overwritten: the round lands in a new folder, and a
            course already on disk is kept.
            """)
    }
    let source = args.positionals[1]
    let text: String
    if source == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(decoding: data, as: UTF8.self)
    } else {
        guard let s = try? String(contentsOfFile: source, encoding: .utf8) else {
            fail("could not read \(source)")
        }
        text = s
    }

    let bundle: RoundBundle
    do { bundle = try BundleText.decode(text) }
    catch let e as BundleText.Failure { fail(e.description) }
    catch { fail("could not read the export: \(error)") }

    print("export     \(bundle.summary)")
    if let g = bundle.generator { print("           written by \(g)") }
    if !bundle.round.groundTruth.isEmpty {
        print("           carries ground truth: \(bundle.round.groundTruth.journal.count) journal, "
            + "\(bundle.round.groundTruth.marks.count) marks")
    }
    if args.bool("dry-run") {
        print("           --dry-run: nothing written")
        return
    }

    let root = URL(fileURLWithPath: args.string("out", default: "Sessions")!)
    let store = args.bool("no-courses") ? nil
        : CourseStore(directory: URL(fileURLWithPath: args.string("courses", default: "Courses")!))
    do {
        let report = try RoundArchive.restore(bundle, into: root, courses: store)
        for line in report.lines { print(line) }
    } catch { fail("import failed: \(error)") }
}

/// `golfctl round show <file|->` — the archive as readable JSON, whichever form it
/// arrived in. The compact form is bytes, and a format nobody can look inside is a
/// format nobody can debug.
private func cmdRoundShow(_ args: Args) {
    guard args.positionals.count > 1 else {
        fail("usage: golfctl round show <file|-> [--model-visible]")
    }
    let source = args.positionals[1]
    let text: String
    if source == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        guard let s = try? String(contentsOfFile: source, encoding: .utf8) else {
            fail("could not read \(source)")
        }
        text = s
    }
    do {
        // `--model-visible` is the archive with its answer key removed — what may
        // legitimately go to a model. Offered here so the firewall is something a
        // person can *see* rather than take on trust.
        if args.bool("model-visible") {
            let stripped = try BundleText.decode(text).modelVisible
            print(try BundleText.encode(stripped, compressed: false))
        } else {
            print(try BundleText.json(text))
        }
    }
    catch let e as BundleText.Failure { fail(e.description) }
    catch { fail("could not read the export: \(error)") }
}

private func warn(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
