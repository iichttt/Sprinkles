import Cocoa
import Foundation
import SafariServices

class ExtensionLinks {
  private static let extensionIdentifier = "com.brnbw.Sprinkles.Sprinkles-Extension"

  /// Sprinkles on the Mac App Store. The Safari extension has no listing of its own - it ships
  /// inside the app - so this is where a copy Safari will load comes from.
  private static let appStoreURL = URL(string: "https://apps.apple.com/app/id1500209074")!

  /// Asks Safari what it knows about the extension, then offers the one thing worth doing next.
  ///
  /// The two failures look identical from the outside - no Sprinkles styling in Safari - but they
  /// want opposite things: an extension Safari has never seen needs installing, while one it has
  /// only needs switching on. Guessing wrong sends the reader to the App Store for an app they
  /// already own, or to a settings pane with nothing in it, so ask first.
  static func safari() {
    SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) {
      state, _ in
      DispatchQueue.main.async { offerSafariNextStep(state) }
    }
  }

  private static func offerSafariNextStep(_ state: SFSafariExtensionState?) {
    let alert = NSAlert()
    alert.alertStyle = .informational

    guard let state else {
      alert.messageText = "You don't have the Sprinkles extension installed"
      alert.informativeText = """
        Safari's extension ships inside the Sprinkles app rather than on its own, so installing it \
        means installing Sprinkles from the App Store.
        """
      alert.addButton(withTitle: "Install from the App Store")
      alert.addButton(withTitle: "Cancel")

      if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(appStoreURL) }
      return
    }

    alert.messageText =
      state.isEnabled
      ? "You already have the Sprinkles extension, and it's on"
      : "You already have the Sprinkles extension, it just isn't on"
    alert.informativeText =
      state.isEnabled
      ? "Safari is running it. Take a look at its settings if you want to check what it can reach."
      : "Open Safari's settings and tick “Sprinkles” under Extensions."
    alert.addButton(withTitle: "Take Me to Safari's Settings")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { error in
      guard let error else { return }

      DispatchQueue.main.async {
        self.alert(
          "Safari couldn't open its extension settings.\n\n\(error.localizedDescription)",
          style: .warning)
      }
    }
  }

  static func firefox() {
    load(
      Browser(
        name: "Firefox",
        bundleIdentifier: "org.mozilla.firefox",
        directory: "ff",
        // Firefox's picker wants the manifest itself, not the folder holding it.
        target: { $0.appendingPathComponent("manifest.json") },
        steps: """
          1. Go to about:debugging#/runtime/this-firefox
          2. Click “Load Temporary Add-on…”
          3. Press ⌘⇧G, then ⌘V, then Return twice

          Firefox drops temporary add-ons when it quits, so this has to be done again after a \
          restart.
          """))
  }

  static func chrome() {
    load(
      Browser(
        name: "Chrome",
        bundleIdentifier: "com.google.Chrome",
        directory: "chrome",
        target: { $0 },
        steps: """
          1. Go to chrome://extensions and turn on “Developer mode”, top right
          2. Click “Load unpacked”, then press ⌘⇧G, ⌘V and Return twice
          3. Open Sprinkles’ “Details” and turn on “Allow user scripts” to run JavaScript
          """))
  }

  private struct Browser {
    let name: String
    let bundleIdentifier: String
    /// Folder inside the app bundle holding that browser's build of the extension.
    let directory: String
    /// What its file picker expects, given that folder.
    let target: (URL) -> URL
    let steps: String
  }

  /// Puts the extension's path on the clipboard and brings the browser forward.
  ///
  /// Neither browser can be handed an unpacked extension directly - Chrome removed `--load-extension`
  /// and Firefox never had an equivalent - so the last few steps are unavoidably manual. What can be
  /// removed is everything around them: finding the folder, typing the browser's own URL from memory,
  /// and clicking a button to copy a path that was always going to be needed.
  private static func load(_ browser: Browser) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier)
    else {
      return alert(
        "You don't seem to have \(browser.name) installed?", style: .warning)
    }

    guard let directory = unpackedExtension(named: browser.directory) else {
      return alert(
        "Sprinkles couldn't find its \(browser.name) extension. Try reinstalling Sprinkles.",
        style: .warning)
    }

    let path = browser.target(directory).path
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)

    let alert = NSAlert()
    alert.messageText = "Load the Sprinkles extension in \(browser.name)"
    alert.informativeText = "\(browser.steps)\n\nCopied to your clipboard:\n\(path)"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open \(browser.name)")
    alert.addButton(withTitle: "Cancel")

    // Read first, then leave: the alert belongs to an accessory app, so bringing the browser
    // forward ahead of it would put the steps behind the window they describe.
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    // The app, and not the page inside it: handing a chrome:// or about: URL to a named app works
    // from an ordinary process but not from inside the sandbox, where it comes back as "Google
    // Chrome cannot open the specified document or URL" - and Sprinkles has to stay sandboxed to
    // ship on the App Store. Passing the address as a launch argument is no better: a browser that
    // is already running ignores it. So the address is written into the steps for the reader to
    // open themselves.
    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
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

  private static func alert(_ text: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.messageText = text
    alert.alertStyle = style
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
