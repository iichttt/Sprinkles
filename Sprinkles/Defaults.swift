import Cocoa
import Defaults

extension Defaults.Keys {
  static let userId = Key<String?>("userId")
  static let hasOnboarded = Key<Bool>("hasOnboarded", default: false)

  /// Domains the user has unchecked in Preferences. `"*"` is the global section.
  static let disabledDomains = Key<Set<String>>("disabledDomains", default: [])
  static let hasMigratedToSingleFiles = Key<Bool>("hasMigratedToSingleFiles", default: false)
}
