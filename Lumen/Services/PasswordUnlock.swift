import Foundation
import LocalAuthentication

/// Asks for Touch ID, then the device password, once per site for this launch.
enum PasswordUnlock {
    private static let cap = 32
    private static var unlocked: [String] = []

    static func authorize(host: String, completion: @escaping (Bool) -> Void) {
        let key = host.lowercased()
        if unlocked.contains(key) {
            completion(true)
            return
        }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock the saved password for \(host)") { ok, _ in
            DispatchQueue.main.async {
                if ok {
                    if !unlocked.contains(key) { unlocked.append(key) }
                    if unlocked.count > cap { unlocked.removeFirst(unlocked.count - cap) }
                }
                completion(ok)
            }
        }
    }
}
