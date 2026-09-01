import Defaults
import Foundation

/// A chunk of a Sprinkles source file, delimited by an `@domain` marker comment.
///
/// Sprinkles keeps everything in two files — `sprinkles.css` and `sprinkles.js`. A marker
/// comment starts a new section and says which sites the lines below it apply to:
///
///     /* @domain example.com, *.wikipedia.org */
///     // @domain example.com
///
/// Anything before the first marker is global and applies everywhere, as does an explicit
/// `@global` marker.
struct ScriptSection {
  enum Kind: String, CaseIterable {
    case css
    case js

    var filename: String { "sprinkles.\(rawValue)" }
    var contentType: String { self == .css ? "text/css" : "text/javascript" }

    /// A marker comment in this file's comment syntax. The reading half lives in
    /// `ScriptParser.markerDomains`; keeping the writing half here stops the two drifting apart.
    func marker(_ body: String) -> String {
      self == .css ? "/* \(body) */" : "// \(body)"
    }
  }

  var kind: Kind
  /// Domain patterns this section applies to. Empty means "every site".
  var domains: [String]
  var body: String

  var isGlobal: Bool { domains.isEmpty }
}

enum ScriptParser {
  /// Keywords accepted in a marker comment. `global` takes no domain list.
  private static let domainKeywords: Set<String> = ["domain", "domains"]
  private static let globalKeywords: Set<String> = ["global"]

  /// The identifier used for the global section in the UI, in preferences and on the wire.
  static let globalIdentifier = "*"

  static func parse(_ source: String, kind: ScriptSection.Kind) -> [ScriptSection] {
    var sections: [ScriptSection] = []
    var domains: [String] = []
    var buffer: [String] = []

    func flush() {
      let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      buffer.removeAll()
      guard !body.isEmpty else { return }
      sections.append(ScriptSection(kind: kind, domains: domains, body: body))
    }

    for line in source.components(separatedBy: .newlines) {
      if let marker = markerDomains(in: line) {
        flush()
        domains = marker
      } else {
        buffer.append(line)
      }
    }
    flush()

    return sections
  }

  /// Returns the domain list if `line` is a marker comment, or `nil` if it is ordinary content.
  /// An empty list means the marker opens a global section.
  static func markerDomains(in line: String) -> [String]? {
    var text = line.trimmingCharacters(in: .whitespaces)

    if text.hasPrefix("/*") {
      text = String(text.dropFirst(2))
      if text.hasSuffix("*/") { text = String(text.dropLast(2)) }
    } else if text.hasPrefix("//") {
      text = String(text.dropFirst(2))
    } else {
      return nil
    }

    // `*` so a `/** @domain x */` banner still reads as a marker. `=-!` were there for banner
    // styles nobody writes, and every extra character widens what counts as a marker.
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t*"))
    guard text.hasPrefix("@") else { return nil }
    text = String(text.dropFirst())

    let keyword = text.prefix { !$0.isWhitespace && $0 != ":" }.lowercased()
    let rest = text.dropFirst(keyword.count).trimmingCharacters(
      in: CharacterSet(charactersIn: " \t:"))

    if globalKeywords.contains(keyword) { return [] }
    guard domainKeywords.contains(keyword) else { return nil }

    let domains =
      rest
      .components(separatedBy: CharacterSet(charactersIn: ", \t"))
      .map(normalize)
      .filter { !$0.isEmpty }

    // `@domain *` is just another way of spelling `@global`.
    return domains.contains(globalIdentifier) ? [] : domains
  }

  /// Tidies up a hand-written domain so that `https://Example.com/` and `example.com` agree.
  static func normalize(_ domain: String) -> String {
    var domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    for scheme in ["https://", "http://", "*://"] where domain.hasPrefix(scheme) {
      domain = String(domain.dropFirst(scheme.count))
    }
    if let slash = domain.firstIndex(of: "/") { domain = String(domain[domain.startIndex..<slash]) }
    while domain.hasSuffix(".") { domain = String(domain.dropLast()) }

    return domain
  }

  /// Whether a page served from `host` should get the rules written for `domain`.
  ///
  /// A bare `example.com` also covers `www.example.com`; `*.example.com` covers the apex plus
  /// every subdomain.
  static func domain(_ domain: String, matchesHost host: String) -> Bool {
    let host = normalize(host)

    if domain == globalIdentifier { return true }

    if domain.hasPrefix("*.") {
      let base = String(domain.dropFirst(2))
      return host == base || host.hasSuffix(".\(base)")
    }

    return host == domain || host == "www.\(domain)"
  }

  /// The WebExtension match patterns a browser needs in order to run this domain's section.
  static func matchPatterns(for domain: String) -> [String] {
    if domain == globalIdentifier { return ["*://*/*"] }
    if domain.hasPrefix("*.") { return ["*://\(domain)/*"] }
    return ["*://\(domain)/*", "*://www.\(domain)/*"]
  }
}

/// Everything Sprinkles knows about the user's two source files at a point in time.
struct ScriptCatalog {
  var sections: [ScriptSection] = []
  /// Domains the user has switched off in Preferences.
  var disabled: Set<String> = []
  /// Exactly the files `load` read, in the order it read them. `handleChecksumReq` hashes this
  /// rather than enumerating the directory again, so the two can't disagree about what the
  /// catalog is made of.
  var sourceFiles: [URL] = []

  /// Files left over from the per-domain layout, oldest naming scheme first (`global`).
  static func legacyFiles(in directory: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let reserved = ScriptSection.Kind.allCases.map(\.filename)

    return
      names
      .filter { $0.hasSuffix(".css") || $0.hasSuffix(".js") }
      .filter { !reserved.contains($0) }
      .sorted { lhs, rhs in
        let lhsGlobal = lhs.hasPrefix("global.")
        let rhsGlobal = rhs.hasPrefix("global.")
        if lhsGlobal != rhsGlobal { return lhsGlobal }
        return lhs < rhs
      }
      .map { directory.appendingPathComponent($0) }
  }

  /// Everything `load` reads. Legacy files come first so that anything the user has since
  /// written in `sprinkles.css` wins the cascade.
  static func sourceFiles(in directory: URL) -> [URL] {
    legacyFiles(in: directory)
      + ScriptSection.Kind.allCases.map { directory.appendingPathComponent($0.filename) }
  }

  /// Identifies a parse result: the files that fed it, their size and modification date, and the
  /// disabled set that filters it.
  private struct Fingerprint: Equatable {
    var stamps: [String]
    var disabled: Set<String>

    init(files: [URL], disabled: Set<String>) {
      self.disabled = disabled
      self.stamps = files.map { url in
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(url.path)|\(values?.fileSize ?? -1)|\(date)"
      }
    }
  }

  private static var cached: (fingerprint: Fingerprint, catalog: ScriptCatalog)?
  private static let cacheLock = NSLock()

  /// Reads and parses the user's files, reusing the last result while nothing on disk has moved.
  ///
  /// This runs on every HTTP request — one extension reload asks for `domains.json`, one script
  /// per domain and one stylesheet per open host — and once a second while the Sites pane is up.
  /// Re-reading and re-parsing both files each time is the dominant cost of a reload; comparing
  /// two `stat`s is not.
  static func load(from directory: URL?, disabled: Set<String> = Defaults[.disabledDomains])
    -> ScriptCatalog
  {
    guard let directory = directory else { return ScriptCatalog() }

    let files = sourceFiles(in: directory)
    let fingerprint = Fingerprint(files: files, disabled: disabled)

    cacheLock.lock()
    defer { cacheLock.unlock() }

    if let cached = cached, cached.fingerprint == fingerprint { return cached.catalog }

    var sections = legacySections(in: directory)

    for kind in ScriptSection.Kind.allCases {
      let url = directory.appendingPathComponent(kind.filename)
      guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
      sections.append(contentsOf: ScriptParser.parse(source, kind: kind))
    }

    let catalog = ScriptCatalog(sections: sections, disabled: disabled, sourceFiles: files)
    cached = (fingerprint, catalog)

    return catalog
  }

  /// Reads leftover `global.css`, `example.com.js`, … files so upgrading never drops a rule.
  /// Not private: `ScriptsMigration` serializes these same sections back out, and a second reader
  /// there could disagree with this one about what a legacy filename means.
  static func legacySections(in directory: URL) -> [ScriptSection] {
    legacyFiles(in: directory).compactMap { url in
      guard let kind = ScriptSection.Kind(rawValue: url.pathExtension.lowercased()) else {
        return nil
      }
      let body = (try? String(contentsOf: url, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let body = body, !body.isEmpty else { return nil }

      let base = url.deletingPathExtension().lastPathComponent
      let domains = base == "global" ? [] : [ScriptParser.normalize(base)]

      return ScriptSection(kind: kind, domains: domains, body: body)
    }
  }

  /// Every domain mentioned by a marker, plus the global entry, in the order shown in Preferences.
  var domains: [String] {
    // `markerDomains` maps `@domain *` to the empty list, so `globalIdentifier` can never appear
    // in a section's own domains - deduping the two against each other would be guarding nothing.
    let global = sections.contains(where: \.isGlobal) ? [ScriptParser.globalIdentifier] : []
    return global + Set(sections.flatMap(\.domains)).sorted()
  }

  /// The domains a browser needs to register scripts for — the global entry is handled separately.
  var registrableDomains: [String] {
    domains.filter { $0 != ScriptParser.globalIdentifier && !disabled.contains($0) }
  }

  func isEnabled(_ domain: String) -> Bool { !disabled.contains(domain) }

  func kinds(for domain: String) -> Set<ScriptSection.Kind> {
    Set(sections.filter { identifiers(of: $0).contains(domain) }.map(\.kind))
  }

  /// Source for exactly one entry in the Preferences list.
  func source(kind: ScriptSection.Kind, domain: String) -> String {
    guard isEnabled(domain) else { return "" }
    return join(sections.filter { $0.kind == kind && identifiers(of: $0).contains(domain) })
  }

  /// Source for a page, i.e. the global section plus every section matching its hostname.
  func source(kind: ScriptSection.Kind, host: String) -> String {
    join(
      sections.filter { section in
        guard section.kind == kind else { return false }
        return identifiers(of: section).contains { domain in
          isEnabled(domain) && ScriptParser.domain(domain, matchesHost: host)
        }
      })
  }

  private func identifiers(of section: ScriptSection) -> [String] {
    section.isGlobal ? [ScriptParser.globalIdentifier] : section.domains
  }

  private func join(_ sections: [ScriptSection]) -> String {
    sections.map(\.body).joined(separator: "\n\n")
  }
}
