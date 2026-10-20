import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

// Puente del modulo SFS de SFS App con TelegramCore (codigo propio, no viene de Telegram-iOS).
// `apply.sh` lo copia a `submodules/TelegramCore/Sources/SFS/` para usar piezas internas de TelegramCore.

public struct SFSBridgeUser {
    public let userId: Int64
    public let username: String?
    public let firstName: String
    public let isBot: Bool
}

public struct SFSBridgeIncomingMessage {
    public let user: SFSBridgeUser
    public let messageId: Int32
    public let timestamp: Int32
    public let text: String
    public let hasPhoto: Bool
    public let storyMentionId: Int32?
    public let storyMentionPeerId: Int64?
}

public struct SFSBridgeStoryUpdate {
    public let userId: Int64
    public let storyId: Int32
}

public struct SFSBridgeStoryCheck {
    public let hasMe: Bool
    public let storyId: Int32?
}

public struct SFSBridgeHistoryMessage {
    public let messageId: Int32
    public let timestamp: Int32
    public let text: String
    public let isOutgoing: Bool
    public let hasPhoto: Bool
}

public enum SFSBridgePublishResult {
    case published(storyId: Int32)
    case failed(error: String)
}

public enum SFSBridge {
    // Telegram limita el texto de una historia; el bot del servidor usa el mismo tope
    private static let storyCaptionLimit = 2000
    // `GetPeerStories` devuelve solo un lote de las historias mas recientes. Si el lote es grande puede haber
    // mas que no vemos: en ese caso no se confirma "no me tiene" (evita acusar en falso)
    private static let uncertainBatchSize = 10
    private static let storyUploadTimeout: Double = 180
    private static let outgoingFlag: Int32 = 1 << 1

    // Mensajes nuevos que llegan a chats privados (tambien de chats silenciados)
    public static func incomingMessages(account: Account) -> Signal<[SFSBridgeIncomingMessage], NoError> {
        let postbox = account.postbox
        return account.stateManager.sfsIncomingMessageIds
        |> mapToQueue { ids -> Signal<[SFSBridgeIncomingMessage], NoError> in
            let privateIds = ids.filter { $0.peerId.namespace == Namespaces.Peer.CloudUser && $0.namespace == Namespaces.Message.Cloud }
            if privateIds.isEmpty {
                return .single([])
            }
            return postbox.transaction { transaction -> [SFSBridgeIncomingMessage] in
                return privateIds.compactMap { id -> SFSBridgeIncomingMessage? in
                    guard let message = transaction.getMessage(id), message.flags.contains(.Incoming), let user = transaction.getPeer(id.peerId) as? TelegramUser else {
                        return nil
                    }
                    var hasPhoto = false
                    var storyMentionId: Int32?
                    var storyMentionPeerId: Int64?
                    for media in message.media {
                        if media is TelegramMediaImage {
                            hasPhoto = true
                        } else if let story = media as? TelegramMediaStory, story.isMention {
                            storyMentionId = story.storyId.id
                            storyMentionPeerId = story.storyId.peerId.id._internalGetInt64Value()
                        }
                    }
                    return SFSBridgeIncomingMessage(
                        user: self.makeUser(user),
                        messageId: id.id,
                        timestamp: message.timestamp,
                        text: message.text,
                        hasPhoto: hasPhoto,
                        storyMentionId: storyMentionId,
                        storyMentionPeerId: storyMentionPeerId
                    )
                }
            }
        }
        |> filter { !$0.isEmpty }
    }

    // Historias nuevas de usuarios
    public static func addedStories(account: Account) -> Signal<[SFSBridgeStoryUpdate], NoError> {
        return account.stateManager.storyUpdates
        |> map { updates -> [SFSBridgeStoryUpdate] in
            return updates.compactMap { update -> SFSBridgeStoryUpdate? in
                if case let .added(peerId, item) = update, peerId.namespace == Namespaces.Peer.CloudUser {
                    return SFSBridgeStoryUpdate(userId: peerId.id._internalGetInt64Value(), storyId: item.id)
                }
                return nil
            }
        }
        |> filter { !$0.isEmpty }
    }

    public static func resolveUser(account: Account, userId: Int64) -> Signal<SFSBridgeUser?, NoError> {
        return account.postbox.transaction { transaction -> SFSBridgeUser? in
            return (transaction.getPeer(self.userPeerId(userId)) as? TelegramUser).flatMap(self.makeUser)
        }
    }

    // `user_has_me_in_story`: nil si no se puede saber
    public static func userHasMeInStory(account: Account, userId: Int64) -> Signal<SFSBridgeStoryCheck?, NoError> {
        return self.myInfo(account: account)
        |> mapToSignal { me -> Signal<SFSBridgeStoryCheck?, NoError> in
            return self.request(account: account, peerId: self.userPeerId(userId)) { inputPeer in
                return Api.functions.stories.getPeerStories(peer: inputPeer)
            }
            |> map { result -> SFSBridgeStoryCheck? in
                guard let result = result else {
                    return nil
                }
                let stories = self.storyItems(result)
                if let story = stories.first(where: { self.doesStoryMentionMe($0, me: me) }) {
                    return SFSBridgeStoryCheck(hasMe: true, storyId: story.id)
                }
                return stories.count >= self.uncertainBatchSize ? nil : SFSBridgeStoryCheck(hasMe: false, storyId: nil)
            }
        }
    }

    // true si me menciona, false si no (o ya no existe), nil si no se deja ver
    public static func storyMentionsMe(account: Account, userId: Int64, storyId: Int32) -> Signal<Bool?, NoError> {
        return self.myInfo(account: account)
        |> mapToSignal { me -> Signal<Bool?, NoError> in
            return self.request(account: account, peerId: self.userPeerId(userId)) { inputPeer in
                return Api.functions.stories.getStoriesByID(peer: inputPeer, id: [storyId])
            }
            |> map { result -> Bool? in
                guard let result = result, case let .stories(data) = result else {
                    return nil
                }
                guard let story = data.stories.first(where: { self.storyItemId($0) == storyId }) else {
                    return false
                }
                switch story {
                case let .storyItem(item):
                    return self.doesStoryMentionMe(item, me: me)
                case .storyItemDeleted:
                    return false
                case .storyItemSkipped:
                    return nil
                }
            }
        }
    }

    // Ultimos mensajes del chat (`userId` nil = Mensajes guardados). nil si fallo
    public static func history(account: Account, userId: Int64?, limit: Int32) -> Signal<[SFSBridgeHistoryMessage]?, NoError> {
        let peerId = userId.flatMap(self.userPeerId) ?? account.peerId
        return self.request(account: account, peerId: peerId) { inputPeer in
            return Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: limit, maxId: 0, minId: 0, hash: 0)
        }
        |> map { result -> [SFSBridgeHistoryMessage]? in
            guard let result = result else {
                return nil
            }
            let messages: [Api.Message]
            switch result {
            case let .messages(data):
                messages = data.messages
            case let .messagesSlice(data):
                messages = data.messages
            case let .channelMessages(data):
                messages = data.messages
            case .messagesNotModified:
                messages = []
            }
            return messages.compactMap { message -> SFSBridgeHistoryMessage? in
                guard case let .message(data) = message else {
                    return nil
                }
                var hasPhoto = false
                if let media = data.media, case .messageMediaPhoto = media {
                    hasPhoto = true
                }
                return SFSBridgeHistoryMessage(
                    messageId: data.id,
                    timestamp: data.date,
                    text: data.message,
                    isOutgoing: (data.flags & self.outgoingFlag) != 0,
                    hasPhoto: hasPhoto
                )
            }
        }
    }

    public static func countMyStories(account: Account) -> Signal<Int?, NoError> {
        return account.network.request(Api.functions.stories.getPeerStories(peer: .inputPeerSelf))
        |> map { result -> Int? in
            return self.storyItems(result).count
        }
        |> `catch` { _ -> Signal<Int?, NoError> in
            return .single(nil)
        }
    }

    // `my_story_still_active`
    public static func isMyStoryActive(account: Account, storyId: Int32) -> Signal<Bool?, NoError> {
        return account.network.request(Api.functions.stories.getStoriesByID(peer: .inputPeerSelf, id: [storyId]))
        |> map { result -> Bool? in
            guard case let .stories(data) = result, let story = data.stories.first(where: { self.storyItemId($0) == storyId }) else {
                return false
            }
            if case .storyItemDeleted = story {
                return false
            }
            return true
        }
        |> `catch` { _ -> Signal<Bool?, NoError> in
            return .single(nil)
        }
    }

    // `delete_story`: por ID; si no se puede, busca entre mis historias la que menciona a la persona
    public static func deleteMyStory(account: Account, storyId: Int32?, username: String?) -> Signal<Bool, NoError> {
        let findById: Signal<Int32?, NoError>
        if let storyId = storyId {
            findById = self.isMyStoryActive(account: account, storyId: storyId)
            |> map { isActive -> Int32? in
                return isActive == true ? storyId : nil
            }
        } else {
            findById = .single(nil)
        }

        return findById
        |> mapToSignal { foundId -> Signal<Int32?, NoError> in
            if let foundId = foundId {
                return .single(foundId)
            }
            guard let username = username, !username.isEmpty else {
                return .single(nil)
            }
            let mention = "@\(username.lowercased())"
            return account.network.request(Api.functions.stories.getPeerStories(peer: .inputPeerSelf))
            |> map { result -> Int32? in
                return self.storyItems(result).first(where: { ($0.caption ?? "").lowercased().contains(mention) })?.id
            }
            |> `catch` { _ -> Signal<Int32?, NoError> in
                return .single(nil)
            }
        }
        |> mapToSignal { foundId -> Signal<Bool, NoError> in
            guard let foundId = foundId else {
                return .single(false)
            }
            // Borra tambien de la vista de historias de la app
            return Signal { subscriber in
                return _internal_deleteStories(account: account, peerId: account.peerId, ids: [foundId]).start(completed: {
                    subscriber.putNext(true)
                    subscriber.putCompletion()
                })
            }
        }
    }

    // `publish_story_from_message`: sube la foto como historia conservando texto y formato (emojis premium, links)
    public static func publishStory(account: Account, userId: Int64, photoMessageId: Int32, captionMessageId: Int32?, periodSeconds: Int32, suffixUsername: String?) -> Signal<SFSBridgePublishResult, NoError> {
        let peerId = self.userPeerId(userId)
        var ids = [MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: photoMessageId)]
        if let captionMessageId = captionMessageId {
            ids.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: captionMessageId))
        }

        return _internal_getMessagesLoadIfNecessary(ids, postbox: account.postbox, network: account.network, accountPeerId: account.peerId)
        |> `catch` { _ -> Signal<GetMessagesResult, NoError> in
            return .single(.result([]))
        }
        |> mapToSignal { result -> Signal<SFSBridgePublishResult, NoError> in
            guard case let .result(messages) = result else {
                return .complete()
            }
            guard let photoMessage = messages.first(where: { $0.id.id == photoMessageId }),
                  let image = photoMessage.media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage else {
                return .single(.failed(error: "NO_PHOTO"))
            }
            let captionMessage = captionMessageId.flatMap { captionId in messages.first(where: { $0.id.id == captionId }) }
            let (text, entities) = self.buildStoryCaption(photoMessage: photoMessage, captionMessage: captionMessage, suffixUsername: suffixUsername)

            guard let pendingStoryManager = account.pendingStoryManager else {
                return .single(.failed(error: "NO_STORY_MANAGER"))
            }
            let uploadEvents = pendingStoryManager.allStoriesUploadEvents()
            let privacy = EngineStoryPrivacy(base: .everyone, additionallyIncludePeers: [])

            return _internal_uploadStory(
                account: account,
                target: .myStories,
                media: .existing(media: image),
                mediaAreas: [],
                text: text,
                entities: entities,
                pin: false,
                privacy: privacy,
                isForwardingDisabled: false,
                period: Int(periodSeconds),
                randomId: Int64.random(in: Int64.min ... Int64.max),
                forwardInfo: nil,
                folders: [],
                music: nil
            )
            |> mapToSignal { stableId -> Signal<SFSBridgePublishResult, NoError> in
                return uploadEvents
                |> filter { $0.0 == stableId }
                |> take(1)
                |> map { event -> SFSBridgePublishResult in
                    return .published(storyId: event.1)
                }
                |> timeout(self.storyUploadTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(.failed(error: "UPLOAD_TIMEOUT")))
            }
        }
        |> take(1)
    }

    // Devuelve el error, o nil si se mando
    public static func sendText(account: Account, userId: Int64, text: String) -> Signal<String?, NoError> {
        let message = EnqueueMessage.message(
            text: text,
            attributes: [OutgoingContentInfoMessageAttribute(flags: [.disableLinkPreviews])],
            inlineStickers: [:],
            mediaReference: nil,
            threadId: nil,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: nil,
            bubbleUpEmojiOrStickersets: []
        )
        return enqueueMessages(account: account, peerId: self.userPeerId(userId), messages: [message])
        |> map { ids -> String? in
            return ids.first.flatMap({ $0 }) == nil ? "SEND_FAILED" : nil
        }
    }

    // El ADS se manda como copia (sin "reenviado de") de un mensaje guardado, asi conserva foto y emojis premium
    public static func sendAdsCopy(account: Account, userId: Int64, savedMessageId: Int32) -> Signal<String?, NoError> {
        let sourceId = MessageId(peerId: account.peerId, namespace: Namespaces.Message.Cloud, id: savedMessageId)
        return _internal_getMessagesLoadIfNecessary([sourceId], postbox: account.postbox, network: account.network, accountPeerId: account.peerId)
        |> `catch` { _ -> Signal<GetMessagesResult, NoError> in
            return .single(.result([]))
        }
        |> mapToSignal { result -> Signal<String?, NoError> in
            guard case let .result(messages) = result else {
                return .complete()
            }
            if !messages.contains(where: { $0.id == sourceId }) {
                return .single("ADS_NOT_FOUND")
            }
            let forward = EnqueueMessage.forward(
                source: sourceId,
                threadId: nil,
                grouping: .auto,
                attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: false)],
                correlationId: nil
            )
            return enqueueMessages(account: account, peerId: self.userPeerId(userId), messages: [forward])
            |> map { ids -> String? in
                return ids.first.flatMap({ $0 }) == nil ? "SEND_FAILED" : nil
            }
        }
        |> take(1)
    }

    // MARK: - Ayudantes

    private struct MyInfo {
        let userId: Int64
        let username: String?
    }

    private static func myInfo(account: Account) -> Signal<MyInfo, NoError> {
        return account.postbox.transaction { transaction -> MyInfo in
            return MyInfo(userId: account.peerId.id._internalGetInt64Value(), username: transaction.getPeer(account.peerId)?.addressName)
        }
    }

    private static func userPeerId(_ userId: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userId))
    }

    private static func makeUser(_ user: TelegramUser) -> SFSBridgeUser {
        return SFSBridgeUser(
            userId: user.id.id._internalGetInt64Value(),
            username: user.addressName,
            firstName: user.firstName ?? "",
            isBot: user.botInfo != nil
        )
    }

    // Peticion con el `InputPeer` de un usuario guardado en la app. nil si no se pudo
    private static func request<T>(account: Account, peerId: PeerId, _ makeRequest: @escaping (Api.InputPeer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<T>)) -> Signal<T?, NoError> {
        return account.postbox.transaction { transaction -> Api.InputPeer? in
            return transaction.getPeer(peerId).flatMap(apiInputPeer)
        }
        |> mapToSignal { inputPeer -> Signal<T?, NoError> in
            guard let inputPeer = inputPeer else {
                return .single(nil)
            }
            return account.network.request(makeRequest(inputPeer))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<T?, NoError> in
                return .single(nil)
            }
        }
    }

    private static func storyItems(_ result: Api.stories.PeerStories) -> [Api.StoryItem.Cons_storyItem] {
        guard case let .peerStories(data) = result, case let .peerStories(peerStories) = data.stories else {
            return []
        }
        return peerStories.stories.compactMap { item -> Api.StoryItem.Cons_storyItem? in
            if case let .storyItem(story) = item {
                return story
            }
            return nil
        }
    }

    private static func storyItemId(_ item: Api.StoryItem) -> Int32 {
        switch item {
        case let .storyItem(data):
            return data.id
        case let .storyItemDeleted(data):
            return data.id
        case let .storyItemSkipped(data):
            return data.id
        }
    }

    // Mismas reglas que `user_has_me_in_story`: mi @ en el texto, o una mencion con mi ID o mi @
    private static func doesStoryMentionMe(_ story: Api.StoryItem.Cons_storyItem, me: MyInfo) -> Bool {
        let caption = story.caption ?? ""
        let mention = me.username.flatMap { $0.isEmpty ? nil : "@\($0.lowercased())" }
        if let mention = mention, caption.lowercased().contains(mention) {
            return true
        }

        let utf16 = Array(caption.utf16)
        return (story.entities ?? []).contains { entity in
            switch entity {
            case let .messageEntityMentionName(data):
                return data.userId == me.userId
            case let .messageEntityMention(data):
                guard let mention = mention else {
                    return false
                }
                let start = Int(data.offset)
                let end = start + Int(data.length)
                if start < 0 || end > utf16.count || start >= end {
                    return false
                }
                return String(decoding: utf16[start ..< end], as: UTF16.self).lowercased() == mention
            default:
                return false
            }
        }
    }

    // Igual que el bot: si la foto trae texto con formato se usa ese; si no, el texto de la promo; y siempre se agrega
    // el @ de la persona al final en una linea nueva (respaldo para que la mencion nunca falle)
    private static func buildStoryCaption(photoMessage: Message, captionMessage: Message?, suffixUsername: String?) -> (String, [MessageTextEntity]) {
        let photoEntities = photoMessage.textEntitiesAttribute?.entities ?? []
        let hasFormattedPhotoText = !photoMessage.text.isEmpty && !photoEntities.isEmpty
        let source: Message
        if !hasFormattedPhotoText, let captionMessage = captionMessage, !captionMessage.text.isEmpty {
            source = captionMessage
        } else {
            source = photoMessage
        }

        let suffix = suffixUsername.flatMap { $0.isEmpty ? nil : "@\($0)" } ?? ""
        let separator = !source.text.isEmpty && !suffix.isEmpty ? "\n" : ""
        let maxTextLength = max(0, self.storyCaptionLimit - suffix.utf16.count - separator.utf16.count)
        let sourceUtf16 = Array(source.text.utf16)
        let text = sourceUtf16.count > maxTextLength ? String(decoding: sourceUtf16[0 ..< maxTextLength], as: UTF16.self) : source.text
        let textLength = text.utf16.count
        let entities = (source.textEntitiesAttribute?.entities ?? []).filter { $0.range.upperBound <= textLength }

        return ("\(text)\(separator)\(suffix)", entities)
    }
}
