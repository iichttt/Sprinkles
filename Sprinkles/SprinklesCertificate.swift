import Defaults
import Foundation
import Security

class SprinklesCertificate {
  static let dir = "\(NSHomeDirectory())/Certs"
  static let scriptPath = Bundle.main.path(forResource: "gen_cert", ofType: "sh")!
  static let caPath = "\(dir)/ca.der"
  static let keyPath = "\(dir)/key.pem"
  static let certPath = "\(dir)/cert.pem"
  static let p12Path = "\(dir)/identity.p12"

  static var exists: Bool {
    return FileManager.default.fileExists(atPath: caPath)
      && FileManager.default.fileExists(atPath: keyPath)
      && FileManager.default.fileExists(atPath: certPath)
      && FileManager.default.fileExists(atPath: p12Path)
  }

  static func generateCertsIfMissing(_ callback: @escaping (Bool) -> Void) {
    if exists {
      callback(true)
    } else {
      let task = Process()
      task.launchPath = SprinklesCertificate.scriptPath
      task.arguments = [Bundle.main.resourcePath!, Defaults[.userId]!]

      DispatchQueue.main.async {
        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
          callback(false)
        }

        self.acceptCert()

        callback(true)
      }
    }
  }

  /// Whether browsers will accept the certificate the local server presents.
  ///
  /// The CA signs its own certificate, so evaluation succeeds only while it is an anchor in the
  /// user's trust store. That setting lives in the keychain rather than beside the files in
  /// `Certs`, so it can go missing on its own - a keychain reset or an OS migration is enough -
  /// and until it is restored every browser rejects https://localhost:3133 while the files on
  /// disk still look perfectly healthy.
  static var isTrusted: Bool {
    guard let rootCert = rootCert() else { return false }

    var trust: SecTrust?

    guard
      SecTrustCreateWithCertificates(rootCert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
      let trust
    else { return false }

    return SecTrustEvaluateWithError(trust, nil)
  }

  /// Records the certificate's trust in the store, so the menu bar icon follows it.
  ///
  /// Only dispatches on a change: this runs on a timer, and every dispatch runs all the reducers
  /// and wakes every subscriber.
  static func publishTrust(_ trusted: Bool) {
    guard trusted != store.state.isCertTrusted else { return }
    store.dispatch(.certificateTrusted(trusted))
  }

  /// Re-evaluates trust off the main thread and publishes the result. Needed on a timer rather
  /// than once at launch because the setting lives in the keychain, where Keychain Access can
  /// revoke it without Sprinkles hearing anything about it.
  static func refreshTrust() {
    DispatchQueue.global(qos: .utility).async { publishTrust(isTrusted) }
  }

  /// Files the existing CA in the keychain and marks it trusted, reporting whether it took.
  /// macOS asks the user to authorise the trust change, so this can legitimately be declined.
  static func trust() -> Bool {
    acceptCert()

    return isTrusted
  }

  static func acceptCert() {
    guard let rootCert = rootCert() else { return }

    let dict = NSDictionary.init(
      objects: [kSecClassCertificate, rootCert],
      forKeys: [kSecClass as! NSCopying, kSecValueRef as! NSCopying])

    // A duplicate is not a failure: the certificate is already filed and only the trust settings
    // below are missing, which is exactly the state this repairs.
    let added = SecItemAdd(dict, nil)
    if added != errSecSuccess && added != errSecDuplicateItem {
      report("Could not add the Sprinkles certificate", added)
    }

    // Passing no settings means "use the default", which for a self-signed root is to trust it as
    // an anchor.
    let trusted = SecTrustSettingsSetTrustSettings(rootCert, SecTrustSettingsDomain.user, nil)
    if trusted != errSecSuccess {
      report("Could not trust the Sprinkles certificate", trusted)
    }
  }

  private static func report(_ message: String, _ status: OSStatus) {
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    print("\(message): \(reason)")
  }

  private static func rootCert() -> SecCertificate? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: caPath)) else { return nil }

    return SecCertificateCreateWithData(nil, data as CFData)
  }
}
