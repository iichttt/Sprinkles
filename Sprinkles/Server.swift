import CryptoKit
import Defaults
import Foundation
import Telegraph
import UniformTypeIdentifiers

public enum ServerState {
  case stopped
  case booting
  case running
}

class Server {
  static var instance = Server()

  var server: Telegraph.Server?

  /// Everything Sprinkles serves is fetched cross-origin by a page or an extension, so every
  /// response carries the same CORS header and differs only in its content type.
  private func headers(_ contentType: String) -> HTTPHeaders {
    [.accessControlAllowOrigin: "*", .contentType: contentType]
  }

  private var jsonHeaders: HTTPHeaders { headers("application/json; charset=utf-8") }

  var state: ServerState = .stopped {
    didSet {
      guard state != oldValue else { return }
      store.dispatch(.serverStateChanged(state))
    }
  }

  public func start(_ port: Int = 3133) {
    if state != .stopped { return }

    state = .booting

    guard let caCert = Certificate(derURL: URL(fileURLWithPath: SprinklesCertificate.caPath)) else {
      print("no ca cert")
      stop()
      return
    }

    guard
      let identity = CertificateIdentity(
        p12URL: URL(fileURLWithPath: SprinklesCertificate.p12Path), passphrase: Defaults[.userId]!)
    else {
      print("no p12 cert")
      stop()
      return
    }

    let server = Telegraph.Server(identity: identity, caCertificates: [caCert])

    // Current API: CSS and JavaScript are served separately so that browser extensions can
    // hand the CSS to the engine themselves instead of building a <style> element from a
    // page-world script, which the page's Content Security Policy is free to veto.
    server.route(.GET, "/v4/domains.json", handleDomainsReq)
    server.route(.GET, "/v4/checksum.json", handleChecksumReq)
    for kind in ScriptSection.Kind.allCases {
      // Registration and handler share one `prefix`: they had to agree, and `identifier(in:)`
      // answers `nil` rather than erroring when they don't.
      let prefix = "/v4/\(kind.rawValue)/"
      server.route(.GET, prefix + "*") { request in
        self.source(request, prefix: prefix, kind: kind) { catalog, identifier in
          catalog.source(kind: kind, domain: Self.domainKey(identifier))
        }
      }
    }
    server.route(.GET, "/v4/site/*", handleSiteReq)
    // Clients that need CSS wrapped in the JavaScript: Sprinkles extensions before 1.5, and
    // Safari's bundled extension, which still uses /s/* today.
    server.route(.GET, "/v3/domains.json", handleLegacyListReq)
    server.route(.GET, "/v3/checksum.json", handleChecksumReq)
    server.route(.GET, "/v3/s/*", handleLegacyDomainScriptReq)
    // v2 manifest/legacy (resolves a hostname, includes the global section)
    server.route(.GET, "/s/*", handleLegacySiteReq)
    // assets: anything sitting next to sprinkles.css, so that
    // `src: url("https://localhost:3133/files/MyFont.woff2")` works from a styled page
    server.route(.GET, "/files/*", handleFileReq)
    // meta
    server.route(.GET, "/version.json", handleVersionReq)
    server.serveBundle(.main, "/")

    do {
      try server.start(port: port)
    } catch {
      print(error)
      stop()
      return
    }

    state = .running
    self.server = server
  }

  public func stop() {
    server?.stop()
    server = nil
    state = .stopped
  }

  func serverDidStop(_ server: Server, error: Error?) {
    state = .stopped

    if let error = error {
      print(error)
    }
  }

  // MARK: - v4

  private func handleDomainsReq(request: HTTPRequest) -> HTTPResponse {
    let catalog = ScriptCatalog.load(from: store.state.directory)

    let domains: [[String: Any]] = catalog.registrableDomains.map { domain in
      let kinds = catalog.kinds(for: domain)
      return [
        "id": domain,
        "matches": ScriptParser.matchPatterns(for: domain),
        "css": kinds.contains(.css),
        "js": kinds.contains(.js),
      ]
    }

    let globalKinds = catalog.kinds(for: ScriptParser.globalIdentifier)
    let payload: [String: Any] = [
      "global": [
        "enabled": catalog.isEnabled(ScriptParser.globalIdentifier),
        "matches": ScriptParser.matchPatterns(for: ScriptParser.globalIdentifier),
        "css": globalKinds.contains(.css),
        "js": globalKinds.contains(.js),
      ],
      "domains": domains,
    ]

    return json(payload, fallback: #"{"global":{"enabled":false},"domains":[]}"#)
  }

  /// Everything that applies to one hostname — the global section plus each matching domain.
  /// Safari asks for this, because a content script only knows the page it was injected into.
  private func handleSiteReq(request: HTTPRequest) -> HTTPResponse {
    let kind: ScriptSection.Kind = request.uri.path.hasSuffix(".css") ? .css : .js
    return source(request, prefix: "/v4/site/", kind: kind) { catalog, identifier in
      catalog.source(kind: kind, host: identifier)
    }
  }

  // MARK: - Combined-JS clients
  //
  // Not dead code: Safari's extension ships inside the app and still fetches `/s/*`, so this is
  // the current and only transport for one of the three supported browsers. The axis is not
  // old-vs-new, it is whether the client can take CSS separately or needs it wrapped in the
  // JavaScript - which is why `injectStyleElement` lives here and not in the v4 handlers.

  private func handleLegacyListReq(request: HTTPRequest) -> HTTPResponse {
    let catalog = ScriptCatalog.load(from: store.state.directory)
    // Extensions before 1.5 build their own match patterns and can't express a wildcard domain.
    return json(catalog.registrableDomains.filter { !$0.hasPrefix("*.") }, fallback: "[]")
  }

  private func handleLegacyDomainScriptReq(request: HTTPRequest) -> HTTPResponse {
    source(request, prefix: "/v3/s/", kind: .js) { catalog, identifier in
      let domain = Self.domainKey(identifier)
      let js = catalog.source(kind: .js, domain: domain)
      let css = catalog.source(kind: .css, domain: domain)
      return js + self.injectStyleElement(domain, css)
    }
  }

  private func handleLegacySiteReq(request: HTTPRequest) -> HTTPResponse {
    source(request, prefix: "/s/", kind: .js) { catalog, identifier in
      let js = catalog.source(kind: .js, host: identifier)
      let css = catalog.source(kind: .css, host: identifier)
      return js + self.injectStyleElement(identifier, css)
    }
  }

  // MARK: - Assets

  /// Serves a file from the scripts directory. Fonts and images referenced from injected CSS
  /// can't be loaded over `file://`, so they need somewhere on the local server to live.
  private func handleFileReq(request: HTTPRequest) -> HTTPResponse {
    let prefix = "/files/"
    guard let directory = store.state.directory, request.uri.path.hasPrefix(prefix) else {
      return HTTPResponse(.notFound)
    }

    let relative = String(request.uri.path.dropFirst(prefix.count))
    guard let name = relative.removingPercentEncoding, !name.isEmpty else {
      return HTTPResponse(.notFound)
    }

    // Resolved, not merely standardized: `standardizedFileURL` collapses ".." but follows no
    // symlinks, so a link inside the scripts directory could otherwise serve any file the app
    // can read - and these responses are sent with `Access-Control-Allow-Origin: *`, which
    // would let any page the user visits read them back.
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let url = directory.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL

    guard url.path.hasPrefix(root.path + "/"),
      let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    else {
      return HTTPResponse(.notFound)
    }

    return HTTPResponse(
      .ok, headers: headers(Self.mimeType(for: url.pathExtension.lowercased())), body: data)
  }

  private static func mimeType(for pathExtension: String) -> String {
    // Sprinkles' own two extensions answer from `Kind`, so `/files/x.css` and `/v4/css/x.css`
    // cannot disagree about a content type.
    if let kind = ScriptSection.Kind(rawValue: pathExtension) { return kind.contentType }

    // The font types predate UTType's table on some systems, so spell them out.
    switch pathExtension {
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    default:
      return UTType(filenameExtension: pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
    }
  }

  // MARK: - Meta

  private func handleVersionReq(request: HTTPRequest) -> HTTPResponse {
    let bundle = Bundle.main
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let build = Int(buildString) ?? 0

    return json(["version": version, "build": build], fallback: "{}")
  }

  /// A digest of everything that can change what the browser should be running: the sources
  /// themselves and the domains switched off in Preferences. Extensions poll this and reload
  /// when it moves, so it has to be stable across launches — `hashValue` is not.
  private func handleChecksumReq(request: HTTPRequest) -> HTTPResponse {
    var hasher = SHA256()

    if let directory = store.state.directory {
      for url in ScriptCatalog.sourceFiles(in: directory) {
        hasher.update(data: Data(url.lastPathComponent.utf8))
        if let data = try? Data(contentsOf: url) { hasher.update(data: data) }
      }
    }

    for domain in Defaults[.disabledDomains].sorted() {
      hasher.update(data: Data("disabled:\(domain)".utf8))
    }

    let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return json(["checksum": checksum], fallback: "{}")
  }

  // MARK: - Plumbing

  private func source(
    _ request: HTTPRequest, prefix: String, kind: ScriptSection.Kind,
    body: (ScriptCatalog, String) -> String
  ) -> HTTPResponse {
    let headers = self.headers("\(kind.contentType); charset=utf-8")

    guard let identifier = identifier(in: request.uri.path, prefix: prefix) else {
      return HTTPResponse(.unprocessableEntity, headers: headers, content: "")
    }

    guard store.state.directory != nil else {
      return HTTPResponse(.internalServerError, headers: headers, content: "")
    }

    let catalog = ScriptCatalog.load(from: store.state.directory)
    return HTTPResponse(.ok, headers: headers, content: body(catalog, identifier))
  }

  /// Pulls `example.com` out of `/v4/css/example.com.css`.
  private func identifier(in path: String, prefix: String) -> String? {
    guard path.hasPrefix(prefix) else { return nil }

    var identifier = String(path.dropFirst(prefix.count))
    for suffix in [".css", ".js"] where identifier.hasSuffix(suffix) {
      identifier = String(identifier.dropLast(suffix.count))
    }

    identifier = identifier.removingPercentEncoding ?? identifier
    guard !identifier.isEmpty, !identifier.contains("/") else { return nil }

    return ScriptParser.normalize(identifier)
  }

  /// Browsers spell the global section `global` on the wire, because a bare `*` makes for an
  /// awkward URL. Everywhere else it is `ScriptParser.globalIdentifier`.
  static func domainKey(_ identifier: String) -> String {
    identifier == "global" ? ScriptParser.globalIdentifier : identifier
  }

  private func json(_ object: Any, fallback: String) -> HTTPResponse {
    let data = try? JSONSerialization.data(withJSONObject: object)
    let string = data.flatMap { String(data: $0, encoding: .utf8) } ?? fallback

    return HTTPResponse(.ok, headers: jsonHeaders, content: string)
  }

  /// Wraps CSS in the JavaScript that older extensions expect. The CSS travels as a JSON
  /// string literal rather than a template literal — a stray backtick or a CSS escape such as
  /// `content: "\2014"` would otherwise corrupt the script or fail to parse outright.
  private func injectStyleElement(_ label: String, _ css: String) -> String {
    guard !css.isEmpty, let literal = jsStringLiteral(css) else { return "" }

    return """

      ;(function () {
        var e = document.createElement('style');
        e.dataset.sprinkles = \(jsStringLiteral(label) ?? "\"\"");
        e.textContent = \(literal);
        (document.head || document.documentElement).appendChild(e);
      })();
      """
  }

  private func jsStringLiteral(_ value: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    else { return nil }

    return String(data: data, encoding: .utf8)
  }
}
