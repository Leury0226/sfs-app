import Foundation

// Lo que el motor necesita de Telegram. En la app lo implementa `SFSTelegramAdapter` (Telegram-iOS);
// en las pruebas, un Telegram falso.
struct SFSUser: Equatable {
    let id: Int64
    let username: String?
    let firstName: String
    let isBot: Bool

    var displayName: String {
        if let username = self.username, !username.isEmpty {
            return "@\(username)"
        }
        return self.firstName.isEmpty ? String(self.id) : self.firstName
    }
}

struct SFSIncomingMessage {
    let user: SFSUser
    let messageId: Int32
    let date: Date
    let text: String
    let hasPhoto: Bool
    // Id de la historia cuando el mensaje es el aviso "te menciono en su historia"
    let storyMentionId: Int32?
    // Dueño de la historia del aviso (debe ser el mismo que escribe)
    let storyMentionPeerId: Int64?
}

struct SFSStoryCheck: Equatable {
    let hasMe: Bool
    let storyId: Int32?
}

enum SFSPublishResult: Equatable {
    case published(storyId: Int32)
    case failed(error: String)
}

struct SFSSavedMessage: Equatable {
    let messageId: Int32
    let text: String
    let hasPhoto: Bool
}

@MainActor
protocol SFSTelegram: AnyObject {
    // nil = no se pudo saber (por ejemplo, tiene muchas historias)
    func userHasMeInStory(userId: Int64) async -> SFSStoryCheck?
    // true si me menciona, false si no (o ya no existe), nil si no se puede ver
    func storyMentionsMe(userId: Int64, storyId: Int32) async -> Bool?
    func hasRecentOwnPhoto(userId: Int64, maxAge: TimeInterval) async -> Bool
    func countMyStories() async -> Int?
    func publishStory(userId: Int64, photoMessageId: Int32, captionMessageId: Int32?, periodSeconds: Int32, suffixUsername: String?) async -> SFSPublishResult
    // Devuelve el error, o nil si se mando
    func sendText(userId: Int64, text: String) async -> String?
    func sendAdsCopy(userId: Int64, savedMessageId: Int32) async -> String?
    func findLastIncomingPhoto(userId: Int64, limit: Int, maxAge: TimeInterval?, preferPromo: Bool) async -> Int32?
    func isMyStoryActive(storyId: Int32) async -> Bool?
    func deleteMyStory(storyId: Int32?, username: String?) async -> Bool
    func resolveUser(id: Int64) async -> SFSUser?
    func lastSavedMessage() async -> SFSSavedMessage?
}

// Reloj del motor: en la app es el real; en las pruebas avanza a mano
@MainActor
protocol SFSClock: AnyObject {
    var now: Date { get }
    func sleep(_ seconds: TimeInterval) async
}

@MainActor
final class SFSSystemClock: SFSClock {
    var now: Date {
        return Date()
    }

    func sleep(_ seconds: TimeInterval) async {
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}
