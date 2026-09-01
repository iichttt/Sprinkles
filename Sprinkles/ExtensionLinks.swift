import Cocoa
import Foundation
import SafariServices

class ExtensionLinks {
  /// Safari's extension ships inside the app, so it is enabled from Safari's own settings.
  static func safari() {
    SFSafariApplication.showPreferencesForExtension(
      withIdentifier: "com.brnbw.Sprinkles.Sprinkles-Extension"
    ) { err in
      if let err = err { print(err) }
    }
  }

  static func firefox() {
    guard isInstalled("org.mozilla.firefox") else {
      return missingAppAlert(
        text: "You don't seem to have Firefox installed?")
    }

    revealUnpackedExtension(
      named: "ff", browser: "Firefox",
      steps: """
        1. Open about:debugging#/runtime/this-firefox
        2. Click “Load Temporary Add-on…”
        3. Pick manifest.json in the folder Sprinkles just revealed in Finder.
        """)
  }

  static func chrome() {
    guard isInstalled("com.google.Chrome") else {
      return missingAppAlert(
        text: "You don't seem to have Google Chrome installed?")
    }

    revealUnpackedExtension(
      named: "chrome", browser: "Chrome",
      steps: """
        1. Open chrome://extensions
        2. Turn on Developer mode, then “Allow User Scripts” for Sprinkles
        3. Click “Load unpacked” and pick the folder Sprinkles just revealed in Finder.
        """)
  }

  /// Copies the extension out of the app bundle so the browser can load it unpacked from a
  /// stable location, then shows it in Finder along with the steps for that browser.
  private static func revealUnpackedExtension(named name: String, browser: String, steps: String) {
    guard let url = unpackedExtension(named: name) else {
      return missingAppAlert(
        text: "Sprinkles couldn't find its \(browser) extension. Try reinstalling Sprinkles.")
    }

    NSWorkspace.shared.activateFileViewerSelecting([url])

    let alert = NSAlert()
    alert.messageText = "Load the Sprinkles extension in \(browser)"
    alert.informativeText = "\(steps)\n\n\(url.path)"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Copy Path")

    if alert.runModal() == .alertSecondButtonReturn {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.path, forType: .string)
    }
  }

  /// The bundled copy is read-only and replaced on every app update, so it is mirrored into
  /// Application Support where a browser can keep pointing at the same path.
  private static func unpackedExtension(named name: String) -> URL? {
    guard let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
      FileManager.default.fileExists(atPath: bundled.path)
    else { return nil }

    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return bundled }

    // Scoped to Sprinkles: this path is deleted before each copy, and
    // <Application Support>/Extensions is not ours to remove.
    let destination = support.appendingPathComponent("Sprinkles/Extensions/\(name)")

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: bundled, to: destination)
    } catch {
      print(error)
      return bundled
    }

    return destination
  }

  private static func isInstalled(_ bundleIdentifier: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  static private func missingAppAlert(text: String) {
    let alert = NSAlert()
    alert.messageText = text
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
