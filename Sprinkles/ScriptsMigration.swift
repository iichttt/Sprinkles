import Cocoa
import Defaults

/// Folds the old one-file-per-domain layout into `sprinkles.css` and `sprinkles.js`.
///
/// Nothing here is required for correctness — `ScriptCatalog` still reads the old per-domain
/// files — but combining them keeps the scripts directory tidy and puts every section in
/// Preferences › Sites.
enum ScriptsMigration {
  static let legacyDirectoryName = "sprinkles-legacy"

  /// Offers the migration once. Declining is safe: the old files keep working either way.
  static func offerIfNeeded(in directory: URL) {
    guard !Defaults[.hasMigratedToSingleFiles] else { return }

    let files = ScriptCatalog.legacyFiles(in: directory)
    guard !files.isEmpty else {
      Defaults[.hasMigratedToSingleFiles] = true
      return
    }

    let alert = NSAlert()
    alert.messageText = "Combine your Sprinkles files?"
    alert.informativeText = """
      Sprinkles now keeps everything in a single sprinkles.css and sprinkles.js, with each site \
      marked by a comment. Your \(files.count) existing file\(files.count == 1 ? "" : "s") can be \
      combined for you — the originals are moved to a “\(legacyDirectoryName)” folder, so nothing \
      is lost.

      Your styles and scripts keep working either way.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Combine")
    alert.addButton(withTitle: "Keep Separate Files")

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
      Defaults[.hasMigratedToSingleFiles] = true
      return
    }

    do {
      try combine(files, in: directory)
      Defaults[.hasMigratedToSingleFiles] = true
      NSWorkspace.shared.open(directory)
    } catch {
      let failure = NSAlert(error: error)
      failure.messageText = "Sprinkles couldn’t combine your files"
      failure.runModal()
    }
  }

  /// Appends each legacy file to the matching single file, then moves the originals aside.
  static func combine(_ files: [URL], in directory: URL) throws {
    let fileManager = FileManager.default
    var combined: [ScriptSection.Kind: String] = [:]

    // Read through the catalog's own reader rather than a second copy of it here: the migration
    // and the loader must agree about what `global.css` or `example.com.js` means, and that rule
    // is exactly what `testCombiningMovesLegacyFilesAsideAndKeepsTheirRules` pins down.
    for section in ScriptCatalog.legacySections(in: directory) {
      combined[section.kind, default: ""] += "\(marker(for: section))\n\n\(section.body)\n\n"
    }

    for (kind, addition) in combined {
      let url = directory.appendingPathComponent(kind.filename)
      let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let separator = existing.isEmpty ? "" : "\n\n"
      // Legacy sections go first, matching the order `ScriptCatalog.load` reads them in, so that
      // anything already in sprinkles.css keeps winning the cascade. Appending would silently
      // hand precedence to the old per-domain files and change how pages render.
      let merged = addition + separator + existing
      try hoistingImports(merged, kind: kind).write(to: url, atomically: true, encoding: .utf8)
    }

    let legacyDirectory = directory.appendingPathComponent(legacyDirectoryName)
    try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

    for url in files {
      let destination = legacyDirectory.appendingPathComponent(url.lastPathComponent)
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: url, to: destination)
    }
  }

  /// A stylesheet's `@import` rules are only honoured before any style rule, so prepending the
  /// legacy block would quietly disable one the user already has at the top of `sprinkles.css`.
  /// Lifts them back above everything else, keeping their relative order (`@charset` first).
  private static func hoistingImports(_ source: String, kind: ScriptSection.Kind) -> String {
    guard kind == .css else { return source }

    var hoisted: [String] = []
    var rest: [String] = []

    for line in source.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let isAtRule =
        (trimmed.hasPrefix("@import") || trimmed.hasPrefix("@charset")) && trimmed.hasSuffix(";")

      if isAtRule {
        if !hoisted.contains(trimmed) { hoisted.append(trimmed) }
      } else {
        rest.append(line)
      }
    }

    guard !hoisted.isEmpty else { return source }

    // Filtering rather than sorting: `sort` is not stable, and the order of the imports
    // themselves decides the cascade between them.
    let ordered =
      hoisted.filter { $0.hasPrefix("@charset") } + hoisted.filter { !$0.hasPrefix("@charset") }
    let body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    return ordered.joined(separator: "\n") + "\n\n" + body + "\n"
  }

  /// The marker that reproduces this section. `Kind` owns the comment syntax, so the writer here
  /// and the reader in `ScriptParser.markerDomains` can't drift apart.
  private static func marker(for section: ScriptSection) -> String {
    section.kind.marker(
      section.isGlobal ? "@global" : "@domain \(section.domains.joined(separator: ", "))")
  }
}
