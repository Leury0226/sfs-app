import Foundation

// Motor SFS. Porta el flujo del bot del servidor:
// `_process_message_local` y los listeners de historias (bot/sfs_runner.py), `handle_incoming_sfs`,
// `handle_mention`, `handle_published_first_no_promo`, `handle_sfs_request_no_photo`, `send_pending_thanks`,
// `check_publish_timers` y `expire_old_sfs` (backend/sfs_flow.py). Misma logica que `src/sfs/engine.ts` de Windows.
@MainActor
final class SFSEngine {
    private static let serviceNotificationsId: Int64 = 777000
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * 60

    // Mensajes mas viejos que esto (por ejemplo al reconectar) no se procesan
    private static let maxMessageAge: TimeInterval = 10 * minute
    // Anti-bucle: no volver a subir a la misma persona antes de este tiempo
    private static let actionCooldown: TimeInterval = 3 * minute
    // No repetir mi ADS si ya mande una foto mia a este chat hace poco
    private static let ownAdsRecent: TimeInterval = 30 * minute
    // No volver a pedir la foto a quien ya te publico antes de este tiempo
    private static let askPhotoCooldown: TimeInterval = 30 * minute
    // Un pedido de foto sin respuesta se olvida despues de este tiempo
    private static let awaitingPhotoTtl: TimeInterval = 24 * hour
    // El gracias se manda 1 minuto despues de completar (anti-choque entre cuentas del sistema)
    private static let thanksDelay: TimeInterval = minute
    private static let promoAfterThanksDelay: TimeInterval = 1
    private static let adsAfterNoticeDelay: TimeInterval = 1
    // Si no se puede confirmar que publico, se le da este tiempo extra una sola vez antes de bajarlo
    private static let publishCheckRetryDelay: TimeInterval = 10 * minute
    // Busqueda de fotos en el chat (mismos limites del runner)
    private static let textPromoPhotoLookupLimit = 8
    private static let photoLookupLimit = 50
    private static let requestPhotoMaxAge: TimeInterval = 15 * minute
    private static let telegramStoryLimit = 100
    // Espacio aleatorio entre publicaciones de historias (cola de publicacion del bot)
    private static let publishSpacingMin: TimeInterval = 20
    private static let publishSpacingMax: TimeInterval = 40
    private static let storyCheckCacheTime: TimeInterval = 5 * minute
    // Perfil seguro: pausa entre verificaciones de historias
    private static let checkSpacing: TimeInterval = 1.5
    private static let tickInterval: TimeInterval = minute
    // Otra cuenta del sistema: la de ID menor actua primero para no chocar
    private static let peerSystemFastDelay: ClosedRange<TimeInterval> = 1...3
    private static let peerSystemSlowDelay: ClosedRange<TimeInterval> = 8...14
    private static let allowedStoryHours = [6, 12, 24, 48]

    private struct IncomingSfs {
        let photoMessageId: Int32
        var captionMessageId: Int32?
        let text: String
        let isSilent: Bool
        let check: SFSStoryCheck?
    }

    private struct CachedCheck {
        let result: SFSStoryCheck
        let checkedAt: Date
    }

    let settings: SFSSettingsStore
    let state: SFSStateStore
    private let telegram: SFSTelegram
    private let clock: SFSClock
    private let isLicenseValid: () -> Bool
    private let random: (ClosedRange<TimeInterval>) -> TimeInterval

    private(set) var myId: Int64?
    private var tickTask: Task<Void, Never>?
    private var isTickRunning = false
    private var hasWarnedStoryLimit = false
    private var nextPublishAt = Date.distantPast
    private var publishChain: Task<Void, Never>?
    private var lastPhotoByUser: [Int64: Int32] = [:]
    private var userChains: [Int64: Task<Void, Never>] = [:]
    private var knownUsers: [Int64: SFSUser] = [:]
    private var knownSystemAccounts = Set<Int64>()
    private var storyCheckCache: [Int64: CachedCheck] = [:]
    private var publishCheckRetried = Set<Int64>()

    init(
        telegram: SFSTelegram,
        clock: SFSClock,
        settings: SFSSettingsStore,
        state: SFSStateStore,
        isLicenseValid: @escaping () -> Bool,
        random: @escaping (ClosedRange<TimeInterval>) -> TimeInterval = { TimeInterval.random(in: $0) }
    ) {
        self.telegram = telegram
        self.clock = clock
        self.settings = settings
        self.state = state
        self.isLicenseValid = isLicenseValid
        self.random = random
    }

    func start(userId: Int64) {
        if self.myId == userId {
            return
        }
        self.stop()
        self.myId = userId
        self.settings.load(userId: userId)
        self.state.load(userId: userId)

        self.tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let clock = self?.clock else {
                    return
                }
                await clock.sleep(Self.tickInterval)
                if Task.isCancelled {
                    return
                }
                await self?.runTick()
            }
        }
    }

    func stop() {
        self.tickTask?.cancel()
        self.tickTask = nil
        self.myId = nil
        self.hasWarnedStoryLimit = false
        self.lastPhotoByUser.removeAll()
        self.userChains.values.forEach { $0.cancel() }
        self.userChains.removeAll()
        self.knownUsers.removeAll()
        self.storyCheckCache.removeAll()
        self.publishCheckRetried.removeAll()
    }

    // La pantalla se mantiene encendida mientras el SFS este encendido y con licencia
    var shouldKeepScreenAwake: Bool {
        return self.settings.settings.isEnabled && self.isLicenseValid()
    }

    // El motor vigila (gracias, timers, vencimientos) mientras haya licencia
    private var canRun: Bool {
        return self.myId != nil && self.isLicenseValid()
    }

    // SFS nuevos solo con el SFS encendido y el ADS listo. Apagado = no empieza nada nuevo,
    // pero termina los que estan en curso (igual que "pausado" en el bot)
    var canStartNewSfs: Bool {
        let settings = self.settings.settings
        return self.canRun && settings.isEnabled && settings.isAdsReady
    }

    // MARK: - Entradas desde Telegram

    func handleIncoming(_ message: SFSIncomingMessage) {
        guard let myId = self.myId else {
            return
        }
        let user = message.user
        if user.id == myId || user.id == Self.serviceNotificationsId || user.isBot {
            return
        }
        if message.date < self.clock.now.addingTimeInterval(-Self.maxMessageAge) {
            return
        }

        self.knownUsers[user.id] = user
        if message.hasPhoto {
            self.lastPhotoByUser[user.id] = message.messageId
        }

        if !self.canRun {
            return
        }

        // "Te menciono en su historia": Telegram avisa con un mensaje
        if let storyId = message.storyMentionId {
            if message.storyMentionPeerId == nil || message.storyMentionPeerId == user.id {
                self.runForUser(user.id) { engine in
                    await engine.handleStoryMention(user, storyId: storyId)
                }
            }
            return
        }

        if !self.canStartNewSfs {
            return
        }
        self.runForUser(user.id) { engine in
            await engine.processMessage(user, message)
        }
    }

    // Alguien que tengo en SFS subio una historia: si me menciona, me publico
    func handleStoryUpdate(userId: Int64, storyId: Int32) {
        guard let myId = self.myId, userId != myId, self.canRun else {
            return
        }
        guard let entry = self.state.entry(userId), entry.status != .closed else {
            return
        }
        if entry.status == .active && entry.hasTheyPublished && entry.theirStoryId != nil {
            return
        }

        self.runForUser(userId) { engine in
            guard let user = await engine.getUser(userId) else {
                return
            }
            let doesMention = await engine.telegram.storyMentionsMe(userId: userId, storyId: storyId)
            if doesMention != true {
                return
            }
            engine.storyCheckCache[userId] = CachedCheck(result: SFSStoryCheck(hasMe: true, storyId: storyId), checkedAt: engine.clock.now)
            await engine.handleTheyPublished(user, theirStoryId: storyId)
        }
    }

    private func handleStoryMention(_ user: SFSUser, storyId: Int32) async {
        // El aviso de Telegram ya es prueba; solo se descarta si la historia ya no existe o no me menciona
        let doesMention = await self.telegram.storyMentionsMe(userId: user.id, storyId: storyId)
        if doesMention == false {
            return
        }
        self.storyCheckCache[user.id] = CachedCheck(result: SFSStoryCheck(hasMe: true, storyId: storyId), checkedAt: self.clock.now)
        await self.handleTheyPublished(user, theirStoryId: storyId)
    }

    // MARK: - Flujo

    // `_process_message_local`
    private func processMessage(_ user: SFSUser, _ message: SFSIncomingMessage) async {
        if !self.canStartNewSfs {
            return
        }

        let text = message.text
        let isPeerSystemAccount = SFSDetect.hasSignature(text)
        if isPeerSystemAccount {
            self.knownSystemAccounts.insert(user.id)
            await self.clock.sleep(self.getPeerSystemDelay(user.id))
        }
        let isSilent = isPeerSystemAccount || self.knownSystemAccounts.contains(user.id)

        // SFS completo y vigente: silencio total
        if self.isSfsComplete(user.id) {
            return
        }

        let check = await self.checkUserHasMe(user)
        if check?.hasMe == true {
            await self.handleTheyPublished(user, theirStoryId: check?.storyId)
            return
        }

        // Caso 1: foto. Solo es promo si trae @ o link; si no, se guarda y se espera el texto
        if message.hasPhoto {
            if SFSDetect.isSfsWithPhoto(text, hasPhoto: true) {
                self.lastPhotoByUser[user.id] = nil
                await self.handleIncomingSfs(user, IncomingSfs(photoMessageId: message.messageId, text: text, isSilent: isSilent, check: check))
            }
            return
        }

        // Caso 2: texto con @ o link: se sube con la foto que mando antes
        if SFSDetect.hasPromoData(text) {
            var photoMessageId = self.lastPhotoByUser[user.id]
            if photoMessageId == nil {
                photoMessageId = await self.telegram.findLastIncomingPhoto(userId: user.id, limit: Self.textPromoPhotoLookupLimit, maxAge: nil, preferPromo: false)
            }
            guard let photoMessageId = photoMessageId else {
                self.state.log(.info, "\(user.displayName) mandó su promo sin foto. Esperando la foto.")
                return
            }
            self.lastPhotoByUser[user.id] = nil
            await self.handleIncomingSfs(user, IncomingSfs(photoMessageId: photoMessageId, captionMessageId: message.messageId, text: text, isSilent: isSilent, check: check))
            return
        }

        // Caso 3: "use" / "go": la persona da a entender que ya hizo su parte; se usa su ultima foto
        if SFSDetect.isUseGoKeyword(text) {
            var photoMessageId = self.lastPhotoByUser[user.id]
            if photoMessageId == nil {
                photoMessageId = await self.telegram.findLastIncomingPhoto(userId: user.id, limit: Self.photoLookupLimit, maxAge: nil, preferPromo: true)
            }
            if let photoMessageId = photoMessageId {
                self.lastPhotoByUser[user.id] = nil
                await self.handleIncomingSfs(user, IncomingSfs(photoMessageId: photoMessageId, text: text, isSilent: isSilent, check: check))
            }
            return
        }

        // Caso 4: solo pide SFS ("sfs", "s4s"...). A otra cuenta del sistema no se le responde
        if isSilent || !SFSDetect.isSfsRequestOnly(text) {
            return
        }

        var photoMessageId = self.lastPhotoByUser[user.id]
        if photoMessageId == nil {
            photoMessageId = await self.telegram.findLastIncomingPhoto(userId: user.id, limit: Self.photoLookupLimit, maxAge: Self.requestPhotoMaxAge, preferPromo: true)
        }
        if let photoMessageId = photoMessageId {
            self.lastPhotoByUser[user.id] = nil
            await self.handleIncomingSfs(user, IncomingSfs(photoMessageId: photoMessageId, text: text, isSilent: isSilent, check: check))
            return
        }

        await self.handleRequestWithoutPhoto(user, check: check)
    }

    // `handle_incoming_sfs`: mandar ADS, subir a la historia y esperar que publique
    private func handleIncomingSfs(_ user: SFSUser, _ incoming: IncomingSfs) async {
        let senderUsername = user.username
        guard let username = SFSDetect.extractUsername(senderUsername: senderUsername, text: incoming.text), !self.isSfsComplete(user.id) else {
            return
        }

        var entry = self.state.entry(user.id)
        if let lastActionAt = entry?.lastActionAt, self.clock.now.timeIntervalSince(lastActionAt) < Self.actionCooldown {
            return
        }

        var isAlreadyPublished = incoming.check?.hasMe == true
        var theirStoryId = incoming.check?.storyId

        // Le habia pedido la foto: si ya me habia publicado, al subirlo el SFS queda completo
        if let current = entry, current.status == .awaitingPhoto {
            isAlreadyPublished = isAlreadyPublished || current.hasTheyPublished
            theirStoryId = theirStoryId ?? current.theirStoryId
            entry = self.state.update(user.id) { $0.status = .closed }
        }

        // Si lo tenia subido pero borre la historia a mano, se rehace el SFS
        if let current = entry, current.status == .active, let storyId = current.storyId {
            let isStoryActive = await self.telegram.isMyStoryActive(storyId: storyId)
            if isStoryActive == false {
                entry = self.state.update(user.id) { $0.status = .closed }
                self.state.log(.info, "@\(username): tu historia ya no estaba, rehaciendo el SFS.")
            }
        }

        // Ya esta subido y no me ha publicado: se espera en silencio (sin recordatorios que alimenten bucles)
        if entry?.status == .active {
            let freshCheck = await self.checkUserHasMe(user, shouldSkipCache: true)
            if freshCheck?.hasMe == true {
                self.markCompleted(user, theirStoryId: freshCheck?.storyId)
            }
            return
        }

        if !isAlreadyPublished {
            let freshCheck = await self.checkUserHasMe(user, shouldSkipCache: true)
            if freshCheck?.hasMe == true {
                isAlreadyPublished = true
                theirStoryId = theirStoryId ?? freshCheck?.storyId
            }
        }

        if await self.isStoryLimitReached() {
            return
        }
        if !self.canStartNewSfs {
            return
        }

        // Mi ADS va antes de subirlo, salvo que ya me haya publicado o que ya le haya mandado mi foto hace poco
        if !isAlreadyPublished {
            let hasRecentAds = await self.telegram.hasRecentOwnPhoto(userId: user.id, maxAge: Self.ownAdsRecent)
            if !hasRecentAds {
                await self.clock.sleep(self.getSafeDelay())
                if !self.canStartNewSfs {
                    return
                }
                await self.sendAds(user, username: username)
            }
        }

        let result = await self.publishStory(user, photoMessageId: incoming.photoMessageId, captionMessageId: incoming.captionMessageId, suffixUsername: senderUsername)
        guard case let .published(storyId) = result else {
            self.state.log(.error, "No pude subir a @\(username) a tu historia (\(Self.formatError(result))).")
            await self.sendConfiguredMessage(user, .errorSubir)
            return
        }

        let settings = self.settings.settings
        let now = self.clock.now
        let timeoutMin = settings.publishTimeoutMin
        var newEntry = SFSQueueEntry(targetId: user.id, username: username, status: .active)
        newEntry.storyId = storyId
        newEntry.theirStoryId = theirStoryId
        newEntry.isSilent = incoming.isSilent
        newEntry.activatedAt = now
        newEntry.expiresAt = now.addingTimeInterval(TimeInterval(settings.durationHours) * Self.hour)
        newEntry.publishDeadline = timeoutMin > 0 ? now.addingTimeInterval(TimeInterval(timeoutMin) * Self.minute) : nil
        newEntry.lastActionAt = now
        self.state.save(newEntry)
        self.publishCheckRetried.remove(user.id)
        self.state.increment(\.publishedCount)

        // Re-verificacion final (carrera entre cuentas): quizas me publico mientras lo subia
        if !isAlreadyPublished {
            let finalCheck = await self.checkUserHasMe(user, shouldSkipCache: true)
            if finalCheck?.hasMe == true {
                isAlreadyPublished = true
                theirStoryId = theirStoryId ?? finalCheck?.storyId
            }
        }

        if isAlreadyPublished {
            self.markCompleted(user, theirStoryId: theirStoryId)
            return
        }

        let waitingText = timeoutMin > 0 ? "Esperando que te publique (\(timeoutMin) min)." : "Sin límite de tiempo para que te publique."
        self.state.log(.info, "Nuevo SFS: subí a @\(username) por \(settings.durationHours)h. \(waitingText)")
    }

    // `handle_mention`: la persona ya me tiene en su historia
    private func handleTheyPublished(_ user: SFSUser, theirStoryId: Int32?) async {
        let entry = self.state.entry(user.id)
        if let entry = entry, entry.status == .active {
            if !entry.hasTheyPublished {
                self.markCompleted(user, theirStoryId: theirStoryId)
            } else if let theirStoryId = theirStoryId, entry.theirStoryId == nil {
                self.state.update(user.id) { $0.theirStoryId = theirStoryId }
            }
            return
        }

        if !self.canStartNewSfs {
            // Apagado: no se sube a nadie nuevo, pero se recuerda que ya me publico
            if let entry = entry, entry.status == .awaitingPhoto, !entry.hasTheyPublished {
                self.state.update(user.id) {
                    $0.hasTheyPublished = true
                    $0.theirStoryId = theirStoryId
                }
            }
            return
        }

        await self.handlePublishedFirst(user, theirStoryId: theirStoryId)
    }

    // `handle_published_first_no_promo`: me publico primero; se sube con su ultima foto o se le pide
    private func handlePublishedFirst(_ user: SFSUser, theirStoryId: Int32?) async {
        guard let username = user.username, !username.isEmpty else {
            return
        }

        let entry = self.state.entry(user.id)
        if let lastActionAt = entry?.lastActionAt, self.clock.now.timeIntervalSince(lastActionAt) < Self.actionCooldown {
            return
        }

        var photoMessageId = self.lastPhotoByUser[user.id]
        if photoMessageId == nil {
            photoMessageId = await self.telegram.findLastIncomingPhoto(userId: user.id, limit: Self.photoLookupLimit, maxAge: nil, preferPromo: true)
        }

        guard let photoMessageId = photoMessageId else {
            if let entry = entry, entry.status == .awaitingPhoto, let askedPhotoAt = entry.askedPhotoAt,
               self.clock.now.timeIntervalSince(askedPhotoAt) < Self.askPhotoCooldown {
                if !entry.hasTheyPublished {
                    self.state.update(user.id) {
                        $0.hasTheyPublished = true
                        $0.theirStoryId = theirStoryId
                    }
                }
                return
            }

            await self.sendConfiguredMessage(user, .pedirFotoPublicado)
            var newEntry = SFSQueueEntry(targetId: user.id, username: username, status: .awaitingPhoto)
            newEntry.hasTheyPublished = true
            newEntry.theirStoryId = theirStoryId
            newEntry.isSilent = entry?.isSilent ?? false
            newEntry.askedPhotoAt = self.clock.now
            self.state.save(newEntry)
            self.state.log(.info, "@\(username) te publicó pero no tiene foto en el chat. Le pedí que la envíe.")
            return
        }

        if await self.isStoryLimitReached() {
            return
        }
        if !self.canStartNewSfs {
            return
        }

        self.lastPhotoByUser[user.id] = nil
        let result = await self.publishStory(user, photoMessageId: photoMessageId, captionMessageId: nil, suffixUsername: username)
        guard case let .published(storyId) = result else {
            self.state.log(.error, "@\(username) te publicó primero, pero no pude subirlo (\(Self.formatError(result))).")
            return
        }

        let settings = self.settings.settings
        let now = self.clock.now
        var newEntry = SFSQueueEntry(targetId: user.id, username: username, status: .active)
        newEntry.storyId = storyId
        newEntry.theirStoryId = theirStoryId
        newEntry.isSilent = entry?.isSilent ?? false
        newEntry.activatedAt = now
        newEntry.expiresAt = now.addingTimeInterval(TimeInterval(settings.durationHours) * Self.hour)
        newEntry.lastActionAt = now
        self.state.save(newEntry)
        self.state.increment(\.publishedCount)
        self.state.log(.info, "@\(username) te publicó primero. Lo subí con su última foto del chat.")
        self.markCompleted(user, theirStoryId: theirStoryId)
    }

    // `handle_sfs_request_no_photo`: pide su spam; mi ADS se manda cuando mande su foto
    private func handleRequestWithoutPhoto(_ user: SFSUser, check: SFSStoryCheck?) async {
        if let entry = self.state.entry(user.id) {
            if entry.status == .active && entry.hasTheyPublished {
                return
            }
            if entry.status == .awaitingPhoto, let askedPhotoAt = entry.askedPhotoAt,
               self.clock.now.timeIntervalSince(askedPhotoAt) < Self.askPhotoCooldown {
                return
            }
        }
        if check?.hasMe == true {
            return
        }

        await self.clock.sleep(self.getSafeDelay())
        if !self.canStartNewSfs {
            return
        }

        await self.sendConfiguredMessage(user, .pedirSpam)
        var newEntry = SFSQueueEntry(targetId: user.id, username: user.username, status: .awaitingPhoto)
        newEntry.askedPhotoAt = self.clock.now
        self.state.save(newEntry)
        self.state.log(.info, "\(user.displayName) pidió SFS sin foto. Le pedí su spam.")
    }

    private func markCompleted(_ user: SFSUser, theirStoryId: Int32?) {
        guard let entry = self.state.entry(user.id), entry.status == .active, !entry.hasTheyPublished else {
            return
        }

        let now = self.clock.now
        self.state.update(user.id) {
            $0.hasTheyPublished = true
            $0.publishDeadline = nil
            $0.theirStoryId = theirStoryId ?? entry.theirStoryId
            // A otra cuenta del sistema no se le manda gracias (evita ruido entre bots)
            $0.thanksDueAt = entry.isSilent ? nil : now.addingTimeInterval(Self.thanksDelay)
        }
        self.publishCheckRetried.remove(user.id)
        self.state.increment(\.completedCount)
        self.state.log(.success, "SFS completo con \(user.displayName) (\(self.settings.settings.durationHours)h). Ambos publicados.")
    }

    // MARK: - Ciclo de cada minuto

    // Tareas de cada minuto, como el `_periodic_loop` del runner
    func runTick() async {
        if self.isTickRunning || !self.canRun {
            return
        }
        self.isTickRunning = true
        defer {
            self.isTickRunning = false
        }
        self.expireOldEntries()
        await self.sendPendingThanks()
        await self.checkPublishTimers()
    }

    // `expire_old_sfs`: al vencer, el SFS termina y se puede volver a hacer con esa persona
    private func expireOldEntries() {
        let now = self.clock.now
        for entry in self.state.entries {
            let isExpired = entry.status == .active && (entry.expiresAt.map { $0 <= now } ?? false)
            let isStaleRequest = entry.status == .awaitingPhoto
                && (entry.askedPhotoAt ?? .distantPast).addingTimeInterval(Self.awaitingPhotoTtl) <= now
            let isOldRemoval = entry.status == .removed
                && (entry.removedAt ?? .distantPast).addingTimeInterval(Self.awaitingPhotoTtl) <= now
            if isExpired || isStaleRequest || isOldRemoval {
                self.state.update(entry.targetId) { $0.status = .closed }
            }
        }
    }

    // `send_pending_thanks`: gracias (si esta encendido) y despues el anuncio, que siempre se manda
    private func sendPendingThanks() async {
        let now = self.clock.now
        let pending = self.state.entries.filter { entry in
            guard entry.status == .active, !entry.isThanksSent, let thanksDueAt = entry.thanksDueAt else {
                return false
            }
            return thanksDueAt <= now
        }

        for entry in pending {
            guard let user = await self.getUser(entry.targetId) else {
                continue
            }

            // Se marca antes de mandar para no repetir si algo falla
            self.state.update(entry.targetId) {
                $0.isThanksSent = true
                $0.thanksDueAt = nil
            }
            await self.runForUser(entry.targetId) { engine in
                let hasThanks = await engine.sendConfiguredMessage(user, .gracias)
                if hasThanks {
                    await engine.clock.sleep(Self.promoAfterThanksDelay)
                }
                if let error = await engine.telegram.sendText(userId: user.id, text: SFSConstants.promoText) {
                    engine.state.log(.error, "No pude mandar el anuncio a \(user.displayName) (\(Self.formatError(error))).")
                }
            }.value
        }
    }

    // `check_publish_timers`: baja de mi historia a quien no me publico a tiempo
    private func checkPublishTimers() async {
        if self.settings.settings.publishTimeoutMin <= 0 {
            return
        }

        let now = self.clock.now
        let overdue = self.state.entries.filter { entry in
            guard entry.status == .active, !entry.hasTheyPublished, let publishDeadline = entry.publishDeadline else {
                return false
            }
            return publishDeadline <= now
        }

        for entry in overdue {
            guard let user = await self.getUser(entry.targetId) else {
                continue
            }
            await self.runForUser(entry.targetId) { engine in
                await engine.removeIfNotPublished(user, entry)
            }.value
            await self.clock.sleep(Self.checkSpacing)
        }
    }

    private func removeIfNotPublished(_ user: SFSUser, _ entry: SFSQueueEntry) async {
        guard let current = self.state.entry(user.id), current.status == .active, !current.hasTheyPublished else {
            return
        }

        // Antes de bajarlo, verificar en vivo si ya me publico
        let check = await self.checkUserHasMe(user, shouldSkipCache: true)
        if check?.hasMe == true {
            self.markCompleted(user, theirStoryId: check?.storyId)
            return
        }

        // No se pudo confirmar (tiene muchas historias): una sola oportunidad extra antes de bajarlo
        if check == nil && !self.publishCheckRetried.contains(user.id) {
            self.publishCheckRetried.insert(user.id)
            let deadline = self.clock.now.addingTimeInterval(Self.publishCheckRetryDelay)
            self.state.update(user.id) { $0.publishDeadline = deadline }
            return
        }

        let isDeleted = await self.telegram.deleteMyStory(storyId: entry.storyId, username: entry.username)
        let now = self.clock.now
        self.state.update(user.id) {
            $0.status = .removed
            $0.removedAt = now
            $0.publishDeadline = nil
        }
        self.publishCheckRetried.remove(user.id)
        self.state.increment(\.removedCount)

        let timeoutMin = self.settings.settings.publishTimeoutMin
        self.state.log(.warning, isDeleted
            ? "\(user.displayName) no te publicó en \(timeoutMin) min. Lo bajé de tu historia."
            : "\(user.displayName) no te publicó en \(timeoutMin) min. Intenté bajarlo pero la historia ya no estaba.")
    }

    // MARK: - Ayudantes

    private func isSfsComplete(_ userId: Int64) -> Bool {
        guard let entry = self.state.entry(userId), entry.status == .active, entry.hasTheyPublished else {
            return false
        }
        return entry.expiresAt.map { $0 > self.clock.now } ?? true
    }

    // `send_ads`: primero el aviso de tiempo, despues el ADS
    private func sendAds(_ user: SFSUser, username: String) async {
        let hasNotice = await self.sendConfiguredMessage(user, .avisoTiempo)
        let ads = self.settings.settings.ads
        guard ads.isEnabled, let savedMessageId = ads.savedMessageId else {
            return
        }

        if hasNotice {
            await self.clock.sleep(Self.adsAfterNoticeDelay)
        }
        if let error = await self.telegram.sendAdsCopy(userId: user.id, savedMessageId: savedMessageId) {
            self.state.log(.error, "No pude mandar tu ADS a @\(username) (\(Self.formatError(error))). Revisa que siga en tus Mensajes guardados.")
        }
    }

    // Devuelve true si el mensaje se mando. Llevan la marca invisible, igual que en el bot
    @discardableResult
    private func sendConfiguredMessage(_ user: SFSUser, _ key: SFSMessageKey) async -> Bool {
        guard let text = self.settings.settings.render(key) else {
            return false
        }
        if let error = await self.telegram.sendText(userId: user.id, text: SFSDetect.addSignature(text)) {
            self.state.log(.error, "No pude mandar un mensaje a \(user.displayName) (\(Self.formatError(error))).")
            return false
        }
        return true
    }

    // Cola de publicacion: una historia a la vez, con 20-40s aleatorios entre una y otra
    private func publishStory(_ user: SFSUser, photoMessageId: Int32, captionMessageId: Int32?, suffixUsername: String?) async -> SFSPublishResult {
        let durationHours = self.settings.settings.durationHours
        let periodHours = Self.allowedStoryHours.min(by: { abs($0 - durationHours) < abs($1 - durationHours) }) ?? 24

        let previous = self.publishChain
        let task = Task { @MainActor [weak self] () -> SFSPublishResult in
            await previous?.value
            guard let self = self else {
                return .failed(error: "STOPPED")
            }
            let wait = self.nextPublishAt.timeIntervalSince(self.clock.now)
            if wait > 0 {
                await self.clock.sleep(wait)
            }
            self.nextPublishAt = self.clock.now.addingTimeInterval(self.random(Self.publishSpacingMin...Self.publishSpacingMax))
            return await self.telegram.publishStory(
                userId: user.id,
                photoMessageId: photoMessageId,
                captionMessageId: captionMessageId,
                periodSeconds: Int32(TimeInterval(periodHours) * Self.hour),
                suffixUsername: suffixUsername
            )
        }
        self.publishChain = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }

    private func isStoryLimitReached() async -> Bool {
        guard let count = await self.telegram.countMyStories(), count >= Self.telegramStoryLimit else {
            self.hasWarnedStoryLimit = false
            return false
        }

        if !self.hasWarnedStoryLimit {
            self.hasWarnedStoryLimit = true
            self.state.log(.warning, "Historia llena (\(count)/\(Self.telegramStoryLimit)). No se suben más SFS hasta que se libere espacio (cuando expiren o bajes historias).")
        }
        return true
    }

    private func checkUserHasMe(_ user: SFSUser, shouldSkipCache: Bool = false) async -> SFSStoryCheck? {
        if !shouldSkipCache, let cached = self.storyCheckCache[user.id],
           self.clock.now.timeIntervalSince(cached.checkedAt) < Self.storyCheckCacheTime {
            return cached.result
        }

        let result = await self.telegram.userHasMeInStory(userId: user.id)
        if let result = result {
            self.storyCheckCache[user.id] = CachedCheck(result: result, checkedAt: self.clock.now)
        }
        return result
    }

    private func getUser(_ userId: Int64) async -> SFSUser? {
        if let user = self.knownUsers[userId] {
            return user
        }
        let user = await self.telegram.resolveUser(id: userId)
        if let user = user {
            self.knownUsers[userId] = user
        }
        return user
    }

    // Un paso a la vez por persona, como el lock por usuario del runner
    @discardableResult
    private func runForUser(_ userId: Int64, _ work: @escaping @MainActor (SFSEngine) async -> Void) -> Task<Void, Never> {
        let previous = self.userChains[userId]
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self = self, !Task.isCancelled else {
                return
            }
            await work(self)
        }
        self.userChains[userId] = task
        return task
    }

    private func getSafeDelay() -> TimeInterval {
        return self.random(SFSConstants.safeDelayMin...SFSConstants.safeDelayMax)
    }

    private func getPeerSystemDelay(_ peerId: Int64) -> TimeInterval {
        let range = (self.myId ?? 0) < peerId ? Self.peerSystemFastDelay : Self.peerSystemSlowDelay
        return self.random(range)
    }

    private static func formatError(_ result: SFSPublishResult) -> String {
        if case let .failed(error) = result {
            return self.formatError(error)
        }
        return "error desconocido"
    }

    private static func formatError(_ error: String) -> String {
        switch error {
        case "STORIES_TOO_MUCH":
            return "llegaste al límite de historias"
        case "NO_PHOTO":
            return "no encontré la foto"
        case "":
            return "error desconocido"
        default:
            return error
        }
    }
}
