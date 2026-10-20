import Foundation
import Combine

enum SFSMessageKey: String, Codable, CaseIterable, Identifiable {
    case avisoTiempo
    case gracias
    case pedirSpam
    case pedirFotoPublicado
    case errorSubir

    var id: String {
        return self.rawValue
    }

    var title: String {
        switch self {
        case .avisoTiempo:
            return "Aviso de tiempo"
        case .gracias:
            return "Gracias"
        case .pedirSpam:
            return "Pedir su spam"
        case .pedirFotoPublicado:
            return "Te publicó sin foto"
        case .errorSubir:
            return "Error al subir"
        }
    }

    var detail: String {
        switch self {
        case .avisoTiempo:
            return "Se manda justo antes de tu ADS, cuando subes a alguien."
        case .gracias:
            return "Un minuto después de completar el SFS. Una variante por línea: se elige una al azar."
        case .pedirSpam:
            return "Cuando alguien escribe \"sfs\" sin mandar su foto."
        case .pedirFotoPublicado:
            return "Cuando alguien te publica primero pero no tiene foto en el chat."
        case .errorSubir:
            return "Si Telegram no deja publicar la historia."
        }
    }
}

struct SFSMessageSetting: Codable, Equatable {
    var isEnabled: Bool
    var text: String
}

struct SFSAdsSettings: Codable, Equatable {
    var isEnabled: Bool
    var savedMessageId: Int32?
    var preview: String?
    var hasPhoto: Bool?
}

struct SFSSettings: Codable, Equatable {
    static let durationOptions: [Int] = [6, 12, 24, 48]
    static let publishTimeoutMax = 240

    var isEnabled: Bool
    var durationHours: Int
    var publishTimeoutMin: Int
    var messages: [SFSMessageKey: SFSMessageSetting]
    var ads: SFSAdsSettings

    // Textos que manda el bot del servidor (`sfs_flow.py`). Variables: {horas}, {minutos}
    static let defaults = SFSSettings(
        isEnabled: false,
        durationHours: 24,
        // Perfil seguro del bot del servidor
        publishTimeoutMin: 60,
        messages: [
            .avisoTiempo: SFSMessageSetting(isEnabled: true, text: "✅ Te subí a mi historia por {horas}h. Súbeme tú también 🙌"),
            // `THANKS_VARIANTS`: mismo significado, distinto texto, para no repetir siempre el mismo mensaje
            .gracias: SFSMessageSetting(isEnabled: true, text: [
                "¡Gracias por el SFS! 🤝 Te tengo arriba por {horas}h.",
                "¡Listo! SFS completo ✅ Ambos publicados por {horas}h. 🙌",
                "¡Perfecto! Ya estamos los dos arriba por {horas}h. 🔄",
                "¡Hecho! 🤝 Gracias por el intercambio, es por {horas}h.",
                "¡Genial! SFS confirmado ✅ Nos tenemos {horas}h. 🙌",
                "¡Excelente! Ya te tengo en mi historia {horas}h. Gracias 🤝",
                "¡Todo listo! 🔄 Intercambio hecho por {horas}h. 🙌",
                "¡Gracias! 🙌 Ambos publicados, válido por {horas}h. ✅",
            ].joined(separator: "\n")),
            .pedirSpam: SFSMessageSetting(isEnabled: true, text: "¡Hola! 📸 Reenvíame tu spam (foto con tu @ y tus enlaces) y te subo a mi historia por {horas}h."),
            .pedirFotoPublicado: SFSMessageSetting(isEnabled: true, text: "¡Hola! Vi que me publicaste 🙌 Para subirte a mi historia necesito tu foto de SFS. Envíamela por aquí y te subo por {horas}h. 📸"),
            .errorSubir: SFSMessageSetting(isEnabled: true, text: "Tuve un problema subiéndote a mi historia. Inténtalo de nuevo."),
        ],
        ads: SFSAdsSettings(isEnabled: true, savedMessageId: nil, preview: nil, hasPhoto: nil)
    )

    func message(_ key: SFSMessageKey) -> SFSMessageSetting {
        return self.messages[key] ?? SFSSettings.defaults.messages[key]!
    }

    // Texto listo para mandar, o nil si el mensaje esta apagado o vacio
    func render(_ key: SFSMessageKey) -> String? {
        let message = self.message(key)
        if !message.isEnabled {
            return nil
        }
        let template = key == .gracias ? Self.pickRandomLine(message.text) : message.text
        let text = template
            .replacingOccurrences(of: "{horas}", with: String(self.durationHours))
            .replacingOccurrences(of: "{minutos}", with: String(self.publishTimeoutMin))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var isAdsReady: Bool {
        return !self.ads.isEnabled || self.ads.savedMessageId != nil
    }

    private static func pickRandomLine(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.randomElement() ?? ""
    }

    // Las versiones nuevas pueden traer mensajes que una configuracion vieja no tiene
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SFSSettings.defaults
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        self.durationHours = try container.decodeIfPresent(Int.self, forKey: .durationHours) ?? defaults.durationHours
        self.publishTimeoutMin = try container.decodeIfPresent(Int.self, forKey: .publishTimeoutMin) ?? defaults.publishTimeoutMin
        let savedMessages = try container.decodeIfPresent([SFSMessageKey: SFSMessageSetting].self, forKey: .messages) ?? [:]
        self.messages = defaults.messages.merging(savedMessages, uniquingKeysWith: { _, saved in saved })
        self.ads = try container.decodeIfPresent(SFSAdsSettings.self, forKey: .ads) ?? defaults.ads
    }

    init(isEnabled: Bool, durationHours: Int, publishTimeoutMin: Int, messages: [SFSMessageKey: SFSMessageSetting], ads: SFSAdsSettings) {
        self.isEnabled = isEnabled
        self.durationHours = durationHours
        self.publishTimeoutMin = publishTimeoutMin
        self.messages = messages
        self.ads = ads
    }
}

// Donde se guardan los datos del SFS en el telefono (en las pruebas, en memoria)
protocol SFSStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

final class SFSUserDefaultsStorage: SFSStorage {
    func data(forKey key: String) -> Data? {
        return UserDefaults.standard.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class SFSSettingsStore: ObservableObject {
    @Published private(set) var settings = SFSSettings.defaults

    private let storage: SFSStorage
    private var userId: Int64?

    init(storage: SFSStorage) {
        self.storage = storage
    }

    func load(userId: Int64) {
        self.userId = userId
        if let data = self.storage.data(forKey: Self.key(userId)),
           let saved = try? JSONDecoder().decode(SFSSettings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = SFSSettings.defaults
        }
    }

    func update(_ change: (inout SFSSettings) -> Void) {
        var newSettings = self.settings
        change(&newSettings)
        self.settings = newSettings
        if let userId = self.userId, let data = try? JSONEncoder().encode(newSettings) {
            self.storage.set(data, forKey: Self.key(userId))
        }
    }

    func updateMessage(_ key: SFSMessageKey, isEnabled: Bool? = nil, text: String? = nil) {
        self.update { settings in
            var message = settings.message(key)
            if let isEnabled = isEnabled {
                message.isEnabled = isEnabled
            }
            if let text = text {
                message.text = text
            }
            settings.messages[key] = message
        }
    }

    func resetMessage(_ key: SFSMessageKey) {
        self.updateMessage(key, text: SFSSettings.defaults.message(key).text)
    }

    private static func key(_ userId: Int64) -> String {
        return "sfs.settings.\(userId)"
    }
}
