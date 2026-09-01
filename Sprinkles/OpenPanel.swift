import Cocoa

class OpenPanel {
  /// Where Sprinkles suggests keeping your files, alongside everything else in ~/.config.
  static var suggestedDirectory: URL {
    realHomeDirectory.appendingPathComponent(".config/sprinkles")
  }

  /// The sandbox rewrites `NSHomeDirectory()` to the app container, but the open panel runs
  /// outside the sandbox and needs the real home to start in the right place.
  private static var realHomeDirectory: URL {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
      return URL(fileURLWithPath: NSHomeDirectory())
    }
    return URL(fileURLWithPath: String(cString: dir))
  }

  static func pick(_ cb: @escaping (URL?) -> Void) {
    let openPanel = NSOpenPanel()
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = true
    openPanel.canCreateDirectories = true
    openPanel.directoryURL = store.state.directory ?? suggestedDirectory
    openPanel.canChooseFiles = false
    openPanel.resolvesAliases = true
    openPanel.prompt = "Pick directory"
    openPanel.begin { (result) in
      guard result == NSApplication.ModalResponse.OK else { return cb(nil) }
      cb(openPanel.url)
    }
  }
}
