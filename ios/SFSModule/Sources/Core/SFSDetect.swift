import Foundation

// Reglas de deteccion portadas de `backend/sfs_flow.py` y `bot/sfs_runner.py` del bot del servidor
// (identicas a `src/sfs/detect.ts` de la app de Windows)
enum SFSDetect {
    // Marca invisible para que las cuentas del sistema (bot y apps) se reconozcan entre si
    static let signature = "\u{200B}\u{200C}\u{200B}\u{200D}\u{200B}"

    private static let mention = try! NSRegularExpression(pattern: "@[A-Za-z0-9_]{3,}")
    private static let usernameCapture = try! NSRegularExpression(pattern: "@([A-Za-z0-9_]{3,32})")
    private static let link = try! NSRegularExpression(pattern: "(t\\.me/|telegram\\.me/|https?://)")
    private static let useGo = try! NSRegularExpression(pattern: "\\b(use|go)\\b", options: [.caseInsensitive])
    private static let serviceWords = ["servicio", "canal", "grupo", "promo", "publicidad", "historia", "story"]
    private static let requestKeywords = ["sfs", "s4s", "share for share", "sf?", "sfs?", "send for send"]

    static func addSignature(_ text: String) -> String {
        return text + self.signature
    }

    static func hasSignature(_ text: String) -> Bool {
        return text.contains(self.signature)
    }

    // `is_sfs_message`: la palabra "sfs", o un @usuario junto con un link o palabra de servicio
    static func isSfsMessage(_ text: String) -> Bool {
        if text.isEmpty {
            return false
        }
        let lower = text.lowercased()
        if lower.contains("sfs") {
            return true
        }
        let hasMention = self.matches(self.mention, text)
        let hasLink = self.matches(self.link, lower)
        let hasService = self.serviceWords.contains(where: { lower.contains($0) })
        return hasMention && (hasLink || hasService)
    }

    // `is_sfs_with_photo`: con foto basta un @usuario o un link
    static func isSfsWithPhoto(_ text: String, hasPhoto: Bool) -> Bool {
        if self.isSfsMessage(text) {
            return true
        }
        if !hasPhoto {
            return false
        }
        return self.hasPromoData(text)
    }

    // Texto que trae datos de promo (@usuario o link)
    static func hasPromoData(_ text: String) -> Bool {
        if text.isEmpty {
            return false
        }
        return self.matches(self.mention, text) || self.matches(self.link, text.lowercased())
    }

    // `is_sfs_request_only`: solo pide SFS, sin promo
    static func isSfsRequestOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        return self.requestKeywords.contains(where: { lower.contains($0) })
    }

    // Palabras "use" / "go": la persona da a entender que ya hizo su parte
    static func isUseGoKeyword(_ text: String) -> Bool {
        return self.matches(self.useGo, text)
    }

    // `_foto_parece_promo`: el texto de una foto parece promo
    static func isPromoLikeCaption(_ text: String) -> Bool {
        if text.isEmpty {
            return false
        }
        let lower = text.lowercased()
        return text.contains("@") || lower.contains("t.me") || lower.contains("http")
            || lower.contains("channel") || lower.contains("canal") || lower.contains("vip")
    }

    // `extract_username_from_message`
    static func extractUsername(senderUsername: String?, text: String) -> String? {
        if let senderUsername = senderUsername, !senderUsername.isEmpty {
            return senderUsername
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = self.usernameCapture.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
