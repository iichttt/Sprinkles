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
        3. Press ⌘⇧G, paste the path below, then pick manifest.json
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
        1. Open chrome://extensions and turn on Developer mode
        2. Click “Load unpacked”, press ⌘⇧G, and paste the path below
        3. Open Sprinkles’ Details and turn on “Allow User Scripts”
        """)
  }

  /// Shows the extension that ships inside the app bundle, with the steps for that browser.
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

  /// The unpacked extension as built into the app bundle - the copy that matches this version.
  ///
  /// It used to be mirrored into Application Support, but the app is sandboxed, so that resolves
  /// to ~/Library/Containers/com.brnbw.Sprinkles/Data/Library/Application Support: a path the
  /// user cannot navigate to and would not recognise as theirs.
  private static func unpackedExtension(named name: String) -> URL? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }

    return url
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
