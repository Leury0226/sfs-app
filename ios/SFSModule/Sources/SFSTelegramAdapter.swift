import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

// Lo que el motor necesita, hecho con TelegramCore (a traves de `SFSBridge`)
@MainActor
final class SFSTelegramAdapter: SFSTelegram {
    private static let ownPhotoLookupLimit: Int32 = 20

    private let account: Account

    init(account: Account) {
        self.account = account
    }

    func userHasMeInStory(userId: Int64) async -> SFSStoryCheck? {
        let result = await sfsAwaitFirst(SFSBridge.userHasMeInStory(account: self.account, userId: userId), fallback: nil)
        return result.map { SFSStoryCheck(hasMe: $0.hasMe, storyId: $0.storyId) }
    }

    func storyMentionsMe(userId: Int64, storyId: Int32) async -> Bool? {
        return await sfsAwaitFirst(SFSBridge.storyMentionsMe(account: self.account, userId: userId, storyId: storyId), fallback: nil)
    }

    // `my_ads_sent_recently`: si ya mande una foto mia a este chat hace poco
    func hasRecentOwnPhoto(userId: Int64, maxAge: TimeInterval) async -> Bool {
        let messages = await self.history(userId: userId, limit: Self.ownPhotoLookupLimit)
        guard let lastOwnPhoto = messages.first(where: { $0.isOutgoing && $0.hasPhoto }) else {
            return false
        }
        return TimeInterval(lastOwnPhoto.timestamp) >= Date().timeIntervalSince1970 - maxAge
    }

    func countMyStories() async -> Int? {
        return await sfsAwaitFirst(SFSBridge.countMyStories(account: self.account), fallback: nil)
    }

    func publishStory(userId: Int64, photoMessageId: Int32, captionMessageId: Int32?, periodSeconds: Int32, suffixUsername: String?) async -> SFSPublishResult {
        let signal = SFSBridge.publishStory(
            account: self.account,
            userId: userId,
            photoMessageId: photoMessageId,
            captionMessageId: captionMessageId,
            periodSeconds: periodSeconds,
            suffixUsername: suffixUsername
        )
        let result = await sfsAwaitFirst(signal, fallback: SFSBridgePublishResult.failed(error: "NO_RESULT"))
        switch result {
        case let .published(storyId):
            return .published(storyId: storyId)
        case let .failed(error):
            return .failed(error: error)
        }
    }

    func sendText(userId: Int64, text: String) async -> String? {
        return await sfsAwaitFirst(SFSBridge.sendText(account: self.account, userId: userId, text: text), fallback: "NO_RESULT")
    }

    func sendAdsCopy(userId: Int64, savedMessageId: Int32) async -> String? {
        return await sfsAwaitFirst(SFSBridge.sendAdsCopy(account: self.account, userId: userId, savedMessageId: savedMessageId), fallback: "NO_RESULT")
    }

    // `find_last_photo_in_chat` (con `preferPromo`) o la busqueda simple del runner (sin el)
    func findLastIncomingPhoto(userId: Int64, limit: Int, maxAge: TimeInterval?, preferPromo: Bool) async -> Int32? {
        let messages = await self.history(userId: userId, limit: Int32(limit))
        let minTimestamp = maxAge.map { Date().timeIntervalSince1970 - $0 } ?? 0
        var fallback: Int32?

        for message in messages {
            if message.isOutgoing || !message.hasPhoto {
                continue
            }
            if TimeInterval(message.timestamp) < minTimestamp {
                break
            }
            if !preferPromo || SFSDetect.isPromoLikeCaption(message.text) {
                return message.messageId
            }
            if fallback == nil {
                fallback = message.messageId
            }
        }
        return fallback
    }

    func isMyStoryActive(storyId: Int32) async -> Bool? {
        return await sfsAwaitFirst(SFSBridge.isMyStoryActive(account: self.account, storyId: storyId), fallback: nil)
    }

    func deleteMyStory(storyId: Int32?, username: String?) async -> Bool {
        return await sfsAwaitFirst(SFSBridge.deleteMyStory(account: self.account, storyId: storyId, username: username), fallback: false)
    }

    func resolveUser(id: Int64) async -> SFSUser? {
        let user = await sfsAwaitFirst(SFSBridge.resolveUser(account: self.account, userId: id), fallback: nil)
        return user.map(SFSUser.init(bridgeUser:))
    }

    // Ultimo mensaje de "Mensajes guardados": se usa como ADS
    func lastSavedMessage() async -> SFSSavedMessage? {
        guard let message = await sfsAwaitFirst(SFSBridge.history(account: self.account, userId: nil, limit: 1), fallback: nil)?.first else {
            return nil
        }
        return SFSSavedMessage(messageId: message.messageId, text: message.text, hasPhoto: message.hasPhoto)
    }

    private func history(userId: Int64, limit: Int32) async -> [SFSBridgeHistoryMessage] {
        return await sfsAwaitFirst(SFSBridge.history(account: self.account, userId: userId, limit: limit), fallback: nil) ?? []
    }
}

extension SFSUser {
    init(bridgeUser: SFSBridgeUser) {
        self.init(id: bridgeUser.userId, username: bridgeUser.username, firstName: bridgeUser.firstName, isBot: bridgeUser.isBot)
    }
}

extension SFSIncomingMessage {
    init(bridgeMessage: SFSBridgeIncomingMessage) {
        self.init(
            user: SFSUser(bridgeUser: bridgeMessage.user),
            messageId: bridgeMessage.messageId,
            date: Date(timeIntervalSince1970: TimeInterval(bridgeMessage.timestamp)),
            text: bridgeMessage.text,
            hasPhoto: bridgeMessage.hasPhoto,
            storyMentionId: bridgeMessage.storyMentionId,
            storyMentionPeerId: bridgeMessage.storyMentionPeerId
        )
    }
}

// Espera el primer valor de una senal de Telegram; si termina sin valor, devuelve `fallback`
private final class SFSOnce {
    private let lock = NSLock()
    private var isDone = false

    func claim() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.isDone {
            return false
        }
        self.isDone = true
        return true
    }
}

func sfsAwaitFirst<T>(_ signal: Signal<T, NoError>, fallback: T) async -> T {
    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let once = SFSOnce()
        let _ = (signal |> take(1)).start(next: { value in
            if once.claim() {
                continuation.resume(returning: value)
            }
        }, completed: {
            if once.claim() {
                continuation.resume(returning: fallback)
            }
        })
    }
}
