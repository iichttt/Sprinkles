import XCTest

@testable import Sprinkles

class ScriptParserTests: XCTestCase {
  func testEverythingBeforeTheFirstMarkerIsGlobal() {
    let sections = ScriptParser.parse("body { color: red }", kind: .css)

    XCTAssertEqual(sections.count, 1)
    XCTAssertTrue(sections[0].isGlobal)
    XCTAssertEqual(sections[0].body, "body { color: red }")
  }

  func testMarkerStartsADomainSection() {
    let sections = ScriptParser.parse(
      """
      body { color: red }

      /* @domain example.com */
      h1 { color: blue }
      """, kind: .css)

    XCTAssertEqual(sections.count, 2)
    XCTAssertTrue(sections[0].isGlobal)
    XCTAssertEqual(sections[1].domains, ["example.com"])
    XCTAssertEqual(sections[1].body, "h1 { color: blue }")
  }

  func testMarkerAcceptsSeveralDomains() {
    let sections = ScriptParser.parse("// @domain twitter.com, x.com\nfoo()", kind: .js)

    XCTAssertEqual(sections.first?.domains, ["twitter.com", "x.com"])
  }

  func testGlobalMarkerReopensTheGlobalSection() {
    let sections = ScriptParser.parse(
      """
      // @domain example.com
      one()

      // @global
      two()
      """, kind: .js)

    XCTAssertEqual(sections.map(\.domains), [["example.com"], []])
  }

  func testStarIsSpelledTheSameAsGlobal() {
    XCTAssertEqual(ScriptParser.markerDomains(in: "/* @domain * */"), [])
  }

  func testEmptySectionsAreDropped() {
    let sections = ScriptParser.parse("/* @domain example.com */\n\n", kind: .css)

    XCTAssertTrue(sections.isEmpty)
  }

  func testOrdinaryCommentsAreNotMarkers() {
    XCTAssertNil(ScriptParser.markerDomains(in: "/* just a note about example.com */"))
    XCTAssertNil(ScriptParser.markerDomains(in: "  * continued comment line"))
    XCTAssertNil(ScriptParser.markerDomains(in: "@domain example.com"))
    XCTAssertNil(ScriptParser.markerDomains(in: "// @media example.com"))
  }

  func testNormalizeTidiesHandWrittenDomains() {
    XCTAssertEqual(ScriptParser.normalize("HTTPS://Example.com/path"), "example.com")
    XCTAssertEqual(ScriptParser.normalize(" example.com. "), "example.com")
  }

  func testBareDomainAlsoCoversWWW() {
    XCTAssertTrue(ScriptParser.domain("example.com", matchesHost: "example.com"))
    XCTAssertTrue(ScriptParser.domain("example.com", matchesHost: "www.example.com"))
    XCTAssertFalse(ScriptParser.domain("example.com", matchesHost: "docs.example.com"))
    XCTAssertFalse(ScriptParser.domain("example.com", matchesHost: "notexample.com"))
  }

  func testWildcardCoversSubdomainsAndTheApex() {
    XCTAssertTrue(ScriptParser.domain("*.example.com", matchesHost: "docs.example.com"))
    XCTAssertTrue(ScriptParser.domain("*.example.com", matchesHost: "example.com"))
    XCTAssertFalse(ScriptParser.domain("*.example.com", matchesHost: "example.com.evil.net"))
  }

  func testMatchPatterns() {
    XCTAssertEqual(
      ScriptParser.matchPatterns(for: "example.com"),
      ["*://example.com/*", "*://www.example.com/*"])
    XCTAssertEqual(ScriptParser.matchPatterns(for: "*.example.com"), ["*://*.example.com/*"])
    XCTAssertEqual(ScriptParser.matchPatterns(for: "*"), ["*://*/*"])
  }
}

class ScriptCatalogTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SprinklesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func write(_ name: String, _ contents: String) throws {
    try contents.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  func testListsGlobalFirstThenDomainsAlphabetically() throws {
    try write(
      "sprinkles.css",
      """
      body { color: red }

      /* @domain zombo.com */
      h1 { color: blue }

      /* @domain apple.com */
      h2 { color: green }
      """)

    let catalog = ScriptCatalog.load(from: directory, disabled: [])

    XCTAssertEqual(catalog.domains, ["*", "apple.com", "zombo.com"])
  }

  func testSourceForAHostCombinesGlobalAndMatchingSections() throws {
    try write(
      "sprinkles.css",
      """
      body { color: red }

      /* @domain example.com */
      h1 { color: blue }

      /* @domain other.com */
      h2 { color: green }
      """)

    let catalog = ScriptCatalog.load(from: directory, disabled: [])
    let css = catalog.source(kind: .css, host: "www.example.com")

    XCTAssertTrue(css.contains("body { color: red }"))
    XCTAssertTrue(css.contains("h1 { color: blue }"))
    XCTAssertFalse(css.contains("h2"))
  }

  func testSourceForADomainLeavesOutTheGlobalSection() throws {
    try write(
      "sprinkles.js",
      """
      globalCode()

      // @domain example.com
      siteCode()
      """)

    let catalog = ScriptCatalog.load(from: directory, disabled: [])

    XCTAssertEqual(catalog.source(kind: .js, domain: "example.com"), "siteCode()")
    XCTAssertEqual(catalog.source(kind: .js, domain: "*"), "globalCode()")
  }

  func testDisabledDomainsAreSkippedButStillListed() throws {
    try write(
      "sprinkles.css",
      """
      /* @domain example.com */
      h1 { color: blue }
      """)

    let catalog = ScriptCatalog.load(from: directory, disabled: ["example.com"])

    XCTAssertEqual(catalog.domains, ["example.com"])
    XCTAssertFalse(catalog.isEnabled("example.com"))
    XCTAssertEqual(catalog.registrableDomains, [])
    XCTAssertEqual(catalog.source(kind: .css, host: "example.com"), "")
  }

  func testGlobalIsAddressedAsGlobalOnTheWire() throws {
    try write("sprinkles.js", "globalCode()\n\n// @domain example.com\nsiteCode()")

    let catalog = ScriptCatalog.load(from: directory, disabled: [])

    // Browsers ask for /v4/js/global.js, not /v4/js/*.js.
    XCTAssertEqual(
      catalog.source(kind: .js, domain: Server.domainKey("global")), "globalCode()")
    XCTAssertEqual(
      catalog.source(kind: .js, domain: Server.domainKey("example.com")), "siteCode()")
  }

  func testKindsReportsWhichFileASiteAppearsIn() throws {
    try write("sprinkles.css", "/* @domain example.com */\nh1 { color: blue }")
    try write("sprinkles.js", "/* nothing global */\n// @domain other.com\nfoo()")

    let catalog = ScriptCatalog.load(from: directory, disabled: [])

    XCTAssertEqual(catalog.kinds(for: "example.com"), [.css])
    XCTAssertEqual(catalog.kinds(for: "other.com"), [.js])
  }

  func testLegacyPerDomainFilesStillLoad() throws {
    try write("global.css", "body { color: red }")
    try write("example.com.css", "h1 { color: blue }")

    let catalog = ScriptCatalog.load(from: directory, disabled: [])

    XCTAssertEqual(catalog.domains, ["*", "example.com"])
    XCTAssertTrue(catalog.source(kind: .css, host: "example.com").contains("h1 { color: blue }"))
  }

  // `load` reuses its last parse while nothing on disk has moved, so the two things that must
  // invalidate it get their own tests: the files, and the disabled set that filters them.
  func testAnEditIsPickedUpOnTheNextLoad() throws {
    try write("sprinkles.css", "/* @domain example.com */\nh1 { color: blue }")
    XCTAssertTrue(
      ScriptCatalog.load(from: directory, disabled: []).source(kind: .css, host: "example.com")
        .contains("blue"))

    try write("sprinkles.css", "/* @domain example.com */\nh1 { color: rebeccapurple }")
    XCTAssertTrue(
      ScriptCatalog.load(from: directory, disabled: []).source(kind: .css, host: "example.com")
        .contains("rebeccapurple"))
  }

  func testDisablingIsNotHiddenByTheCache() throws {
    try write("sprinkles.css", "/* @domain example.com */\nh1 { color: blue }")

    XCTAssertFalse(
      ScriptCatalog.load(from: directory, disabled: []).source(kind: .css, host: "example.com")
        .isEmpty)
    XCTAssertTrue(
      ScriptCatalog.load(from: directory, disabled: ["example.com"])
        .source(kind: .css, host: "example.com").isEmpty)
  }

  func testCombiningMovesLegacyFilesAsideAndKeepsTheirRules() throws {
    try write("global.css", "body { color: red }")
    try write("example.com.css", "h1 { color: blue }")
    try write("example.com.js", "foo()")

    let files = ScriptCatalog.legacyFiles(in: directory)
    try ScriptsMigration.combine(files, in: directory)

    let css = try String(
      contentsOf: directory.appendingPathComponent("sprinkles.css"), encoding: .utf8)
    XCTAssertTrue(css.contains("/* @global */"))
    XCTAssertTrue(css.contains("/* @domain example.com */"))
    XCTAssertTrue(css.contains("h1 { color: blue }"))

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("global.css").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          directory
          .appendingPathComponent(ScriptsMigration.legacyDirectoryName)
          .appendingPathComponent("global.css").path))

    // Combining is not allowed to change what any page ends up with.
    let catalog = ScriptCatalog.load(from: directory, disabled: [])
    XCTAssertTrue(catalog.source(kind: .css, host: "example.com").contains("h1 { color: blue }"))
    XCTAssertTrue(catalog.source(kind: .css, host: "example.com").contains("body { color: red }"))
    XCTAssertEqual(catalog.source(kind: .js, host: "example.com"), "foo()")
  }

  func testCombiningKeepsWhatIsAlreadyInSprinklesCSSWinningTheCascade() throws {
    // The user has since written their own rule; the legacy file disagrees with it.
    try write("sprinkles.css", "/* @domain example.com */\n\nbody { color: blue }")
    try write("example.com.css", "body { color: red }")

    let before = ScriptCatalog.load(from: directory, disabled: [])
      .source(kind: .css, host: "example.com")
    XCTAssertLessThan(
      before.range(of: "red")!.lowerBound, before.range(of: "blue")!.lowerBound,
      "precondition: the legacy rule is overridden by sprinkles.css")

    try ScriptsMigration.combine(ScriptCatalog.legacyFiles(in: directory), in: directory)

    let after = ScriptCatalog.load(from: directory, disabled: [])
      .source(kind: .css, host: "example.com")
    XCTAssertLessThan(
      after.range(of: "red")!.lowerBound, after.range(of: "blue")!.lowerBound,
      "combining must not hand precedence back to the old per-domain file")
  }

  func testCombiningKeepsImportsAboveEveryRule() throws {
    try write(
      "sprinkles.css",
      "@import url(\"https://example.com/fonts.css\");\n\nbody { font-family: Demo }")
    try write("other.com.css", "h1 { color: red }")

    try ScriptsMigration.combine(ScriptCatalog.legacyFiles(in: directory), in: directory)

    let css = try String(
      contentsOf: directory.appendingPathComponent("sprinkles.css"), encoding: .utf8)
    XCTAssertTrue(css.hasPrefix("@import"), "an @import below a rule is ignored by the browser")
    XCTAssertLessThan(css.range(of: "@import")!.lowerBound, css.range(of: "h1")!.lowerBound)
  }
}
