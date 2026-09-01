import Foundation

/// The two files Sprinkles creates in a freshly picked scripts directory.
class ExampleFiles {
  /// Explains the marker syntax. Identical in both files, so it lives in one place - a block
  /// comment reads the same either way.
  private static let markerHelp =
    """
    /* Below a marker, the lines apply to that site only — www.example.com counts too.
     * Separate several domains with commas ("twitter.com, x.com"), or start a domain
     * with "*." to include its subdomains ("*.wikipedia.org").
     *
     * Every section shows up in Preferences › Sites, where you can switch it off
     * without deleting it.
     */
    """

  static let css =
    """
    /* sprinkles.css — all of your styles, in one file.
     *
     * Rules up here, above the first marker, apply to every page you visit.
     * Uncomment the line below for an extra creamy web experience.
     */

    /* body { background-color: papayawhip; } */

    \(markerHelp)

    /* Fonts and images saved next to this file are served by Sprinkles, so a webfont of your
     * own can be reached at https://localhost:3133/files/YourFont.woff2 — pages can't load
     * file:// URLs, but they can load that one.
     */

    /* @domain example.com */

    /* h1 { font-family: Georgia, serif; } */
    """

  static let js =
    """
    // sprinkles.js — all of your scripts, in one file.
    //
    // Code up here, above the first marker, runs on every page you visit.
    // Uncomment the lines below to swap every image on the web for a random one.

    // for (const elm of document.querySelectorAll("img")) {
    //   elm.src = `//picsum.photos/${elm.width}`
    // }

    \(markerHelp)

    // @domain example.com

    // console.log("Sprinkles is running here")
    """

  static func copyTo(_ directory: URL) {
    for kind in ScriptSection.Kind.allCases {
      writeIfNotExists(
        url: directory.appendingPathComponent(kind.filename),
        content: kind == .css ? css : js)
    }
  }

  private static func writeIfNotExists(url: URL, content: String) {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    print("Writing default \(url.path)")
    FileManager.default.createFile(
      atPath: url.path, contents: content.data(using: .utf8), attributes: nil)
  }
}
