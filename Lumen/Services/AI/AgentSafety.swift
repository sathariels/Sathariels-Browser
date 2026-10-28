import Foundation

/// Decides which agent actions need a confirmation before they run.
enum AgentSafety {
    static func clickNeedsConfirm(type: String, text: String) -> Bool {
        let blob = text.lowercased()
        let hot = ["pay", "purchase", "buy", "checkout", "place order", "send", "donate", "subscribe", "confirm order", "transfer", "log in", "sign in", "login", "signin"]
        if hot.contains(where: { blob.contains($0) }) { return true }
        guard type.lowercased() == "submit" else { return false }
        let benign = ["search", "go", "find", "look up"]
        if benign.contains(where: { blob == $0 || blob.hasPrefix($0 + " ") }) { return false }
        return true
    }

    static func isPasswordField(type: String, autocomplete: String) -> Bool {
        let type = type.lowercased()
        let auto = autocomplete.lowercased()
        return type == "password" || auto.contains("password")
    }

    /// Credential and payment fields. Password values are still never read.
    static func typeNeedsConfirm(type: String, name: String, autocomplete: String) -> Bool {
        if isPasswordField(type: type, autocomplete: autocomplete) { return true }
        let blob = "\(type) \(name) \(autocomplete)".lowercased()
        let keys = ["cc-", "card", "cvv", "cvc", "otp", "ssn", "pin"]
        return keys.contains { blob.contains($0) }
    }
}
