import XCTest
@testable import SFSCore

// Mismas pruebas que `src/sfs/__tests__/engine.test.ts` de la app de Windows

@MainActor
final class FakeClock: SFSClock {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now: Date
    private var waiters: [Waiter] = []

    init(now: Date) {
        self.now = now
    }

    func sleep(_ seconds: TimeInterval) async {
        if seconds <= 0 {
            await Task.yield()
            return
        }
        let deadline = self.now.addingTimeInterval(seconds)
        await withCheckedContinuation { continuation in
            self.waiters.append(Waiter(deadline: deadline, continuation: continuation))
        }
    }

    // Deja correr pausas y el ciclo de cada minuto hasta `now + seconds`
    func advance(_ seconds: TimeInterval) async {
        let target = self.now.addingTimeInterval(seconds)
        while true {
            await Self.drain()
            let due = self.waiters.enumerated()
                .filter { $0.element.deadline <= target }
                .min(by: { $0.element.deadline < $1.element.deadline })
            guard let (index, waiter) = due.map({ ($0.offset, $0.element) }) else {
                break
            }
            self.waiters.remove(at: index)
            self.now = max(self.now, waiter.deadline)
            waiter.continuation.resume()
        }
        self.now = target
        await Self.drain()
    }

    private static func drain() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }
}

final class MemoryStorage: SFSStorage {
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        return self.values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        self.values[key] = data
    }
}

// Telegram falso: lo que el motor manda y publica queda registrado aqui
@MainActor
final class FakeTelegram: SFSTelegram {
    struct MyStory: Equatable {
        let userId: Int64
        let photoMessageId: Int32
        let captionMessageId: Int32?
        let suffix: String?
    }

    struct PartnerStory {
        let id: Int32
        let mentionsMe: Bool
    }

    enum Sent: Equatable {
        case text(to: Int64, text: String)
        case ads(to: Int64)
    }

    var myStories: [Int32: MyStory] = [:]
    var partnerStories: [Int64: [PartnerStory]] = [:]
    var lastPhotos: [Int64: Int32] = [:]
    var users: [Int64: SFSUser] = [:]
    var sent: [Sent] = []
    var nextStoryId: Int32 = 1000

    func userHasMeInStory(userId: Int64) async -> SFSStoryCheck? {
        let story = self.partnerStories[userId]?.first(where: { $0.mentionsMe })
        return SFSStoryCheck(hasMe: story != nil, storyId: story?.id)
    }

    func storyMentionsMe(userId: Int64, storyId: Int32) async -> Bool? {
        return self.partnerStories[userId]?.first(where: { $0.id == storyId })?.mentionsMe ?? false
    }

    func hasRecentOwnPhoto(userId: Int64, maxAge: TimeInterval) async -> Bool {
        return false
    }

    func countMyStories() async -> Int? {
        return self.myStories.count
    }

    func publishStory(userId: Int64, photoMessageId: Int32, captionMessageId: Int32?, periodSeconds: Int32, suffixUsername: String?) async -> SFSPublishResult {
        let id = self.nextStoryId
        self.nextStoryId += 1
        self.myStories[id] = MyStory(userId: userId, photoMessageId: photoMessageId, captionMessageId: captionMessageId, suffix: suffixUsername)
        return .published(storyId: id)
    }

    func sendText(userId: Int64, text: String) async -> String? {
        self.sent.append(.text(to: userId, text: text))
        return nil
    }

    func sendAdsCopy(userId: Int64, savedMessageId: Int32) async -> String? {
        self.sent.append(.ads(to: userId))
        return nil
    }

    func findLastIncomingPhoto(userId: Int64, limit: Int, maxAge: TimeInterval?, preferPromo: Bool) async -> Int32? {
        return self.lastPhotos[userId]
    }

    func isMyStoryActive(storyId: Int32) async -> Bool? {
        return self.myStories[storyId] != nil
    }

    func deleteMyStory(storyId: Int32?, username: String?) async -> Bool {
        guard let storyId = storyId else {
            return false
        }
        return self.myStories.removeValue(forKey: storyId) != nil
    }

    func resolveUser(id: Int64) async -> SFSUser? {
        return self.users[id]
    }

    func lastSavedMessage() async -> SFSSavedMessage? {
        return nil
    }

    func texts(to userId: Int64) -> [String] {
        return self.sent.compactMap { item in
            if case let .text(to, text) = item, to == userId {
                return text
            }
            return nil
        }
    }

    func adsCount(to userId: Int64) -> Int {
        return self.sent.filter { $0 == .ads(to: userId) }.count
    }

    func sentCount(to userId: Int64) -> Int {
        return self.sent.filter { item in
            switch item {
            case let .text(to, _), let .ads(to):
                return to == userId
            }
        }.count
    }
}

@MainActor
final class SFSEngineTests: XCTestCase {
    private static let signature = "\u{200B}\u{200C}\u{200B}\u{200D}\u{200B}"
    private static let minute: TimeInterval = 60
    private static let me: Int64 = 100
    private static let ana: Int64 = 200
    private static let beto: Int64 = 300

    private var clock: FakeClock!
    private var tg: FakeTelegram!
    private var engine: SFSEngine!
    private var messageId: Int32 = 1

    override func setUp() async throws {
        self.clock = FakeClock(now: ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!)
        self.tg = FakeTelegram()
        self.messageId = 1
        self.addUser(Self.me, "yo_mismo")
        self.addUser(Self.ana, "ana")

        let storage = MemoryStorage()
        let clock = self.clock!
        self.engine = SFSEngine(
            telegram: self.tg,
            clock: clock,
            settings: SFSSettingsStore(storage: storage),
            state: SFSStateStore(storage: storage, now: { clock.now }),
            isLicenseValid: { true },
            // Siempre el minimo: pausas de 13s, cola de 20s
            random: { $0.lowerBound }
        )
        self.engine.start(userId: Self.me)
        self.updateSettings {
            $0.isEnabled = true
            $0.ads = SFSAdsSettings(isEnabled: true, savedMessageId: 5, preview: nil, hasPhoto: nil)
        }
    }

    override func tearDown() async throws {
        self.engine.stop()
    }

    private func addUser(_ id: Int64, _ username: String?) {
        self.tg.users[id] = SFSUser(id: id, username: username, firstName: "X", isBot: false)
    }

    private func updateSettings(_ change: (inout SFSSettings) -> Void) {
        self.engine.settings.update(change)
    }

    @discardableResult
    private func receive(_ userId: Int64, text: String = "", hasPhoto: Bool = false, storyMentionId: Int32? = nil) -> Int32 {
        let id = self.messageId
        self.messageId += 1
        if hasPhoto {
            self.tg.lastPhotos[userId] = id
        }
        self.engine.handleIncoming(SFSIncomingMessage(
            user: self.tg.users[userId]!,
            messageId: id,
            date: self.clock.now,
            text: text,
            hasPhoto: hasPhoto,
            storyMentionId: storyMentionId,
            storyMentionPeerId: storyMentionId == nil ? nil : userId
        ))
        return id
    }

    private func partnerPublishes(_ userId: Int64, _ storyId: Int32, mentionsMe: Bool = true) {
        self.tg.partnerStories[userId, default: []].append(FakeTelegram.PartnerStory(id: storyId, mentionsMe: mentionsMe))
        self.engine.handleStoryUpdate(userId: userId, storyId: storyId)
    }

    private func wait(_ seconds: TimeInterval) async {
        await self.clock.advance(seconds)
    }

    private func entry(_ userId: Int64) -> SFSQueueEntry? {
        return self.engine.state.entry(userId)
    }

    func testPromoConFotoSubeYAlPublicarmeMandaGraciasYAnuncio() async {
        self.receive(Self.ana, text: "Sigue a @ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)

        XCTAssertEqual(self.tg.texts(to: Self.ana), ["✅ Te subí a mi historia por 24h. Súbeme tú también 🙌\(Self.signature)"])
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 1)
        XCTAssertEqual(self.tg.myStories.count, 1)
        let story = self.tg.myStories.values.first
        XCTAssertEqual(story?.userId, Self.ana)
        XCTAssertEqual(story?.suffix, "ana")

        let entry = self.entry(Self.ana)
        XCTAssertEqual(entry?.status, .active)
        XCTAssertEqual(entry?.hasTheyPublished, false)
        XCTAssertEqual(entry?.username, "ana")
        XCTAssertEqual(entry?.publishDeadline?.timeIntervalSince(entry!.activatedAt!), 60 * Self.minute)

        self.partnerPublishes(Self.ana, 77)
        await self.wait(1)
        XCTAssertEqual(self.entry(Self.ana)?.hasTheyPublished, true)
        XCTAssertEqual(self.entry(Self.ana)?.theirStoryId, 77)
        XCTAssertEqual(self.tg.texts(to: Self.ana).count, 1)

        // El gracias sale 1 minuto despues, en el ciclo de cada minuto
        await self.wait(2 * Self.minute)
        let texts = self.tg.texts(to: Self.ana)
        XCTAssertEqual(texts.count, 3)
        XCTAssertTrue(texts[1].hasSuffix(Self.signature))
        XCTAssertTrue(texts[1].contains("24h"))
        XCTAssertEqual(texts[2], SFSConstants.promoText)

        // SFS completo: silencio total aunque vuelva a escribir
        self.receive(Self.ana, text: "sfs?")
        await self.wait(Self.minute)
        XCTAssertEqual(self.tg.texts(to: Self.ana).count, 3)
    }

    func testSiNoMePublicaATiempoLoBaja() async {
        self.receive(Self.ana, text: "@ana_vip promo", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.myStories.count, 1)

        await self.wait(62 * Self.minute)
        XCTAssertEqual(self.tg.myStories.count, 0)
        XCTAssertEqual(self.entry(Self.ana)?.status, .removed)
        XCTAssertEqual(self.engine.state.data.stats.removedCount, 1)
        XCTAssertEqual(self.tg.texts(to: Self.ana).count, 1)
    }

    func testPideElSpamYSubeLaFotoQueMandanDespues() async {
        self.receive(Self.ana, text: "hacemos sfs?")
        await self.wait(31)
        XCTAssertTrue(self.tg.texts(to: Self.ana).first?.contains("Reenvíame tu spam") ?? false)
        XCTAssertEqual(self.entry(Self.ana)?.status, .awaitingPhoto)

        // Manda la foto despues: no la bloquea el anti-bucle
        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 1)
        XCTAssertEqual(self.tg.myStories.count, 1)
        XCTAssertEqual(self.entry(Self.ana)?.status, .active)
    }

    func testSfsEnDosMensajesFotoYDespuesTexto() async {
        let photoId = self.receive(Self.ana, hasPhoto: true)
        await self.wait(5)
        XCTAssertEqual(self.tg.myStories.count, 0)

        let textId = self.receive(Self.ana, text: "mi canal @ana_vip t.me/anavip")
        await self.wait(31)
        let story = self.tg.myStories.values.first
        XCTAssertEqual(story?.photoMessageId, photoId)
        XCTAssertEqual(story?.captionMessageId, textId)
    }

    func testRespetaMensajesApagadosPeroElAnuncioSeMandaSiempre() async {
        self.engine.settings.updateMessage(.avisoTiempo, isEnabled: false)
        self.engine.settings.updateMessage(.gracias, isEnabled: false)

        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.texts(to: Self.ana), [])
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 1)

        self.partnerPublishes(Self.ana, 77)
        await self.wait(2 * Self.minute)
        XCTAssertEqual(self.tg.texts(to: Self.ana), [SFSConstants.promoText])
    }

    func testUsaElTextoEditadoDelCliente() async {
        self.engine.settings.updateMessage(.avisoTiempo, text: "Listo, {horas} horas arriba")
        self.updateSettings { $0.durationHours = 12 }

        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.texts(to: Self.ana), ["Listo, 12 horas arriba\(Self.signature)"])
    }

    func testConAdsApagadoNoMandaAdsPeroSiSube() async {
        self.updateSettings { $0.ads = SFSAdsSettings(isEnabled: false, savedMessageId: nil, preview: nil, hasPhoto: nil) }

        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 0)
        XCTAssertEqual(self.tg.myStories.count, 1)
    }

    func testApagadoNoEmpiezaNadaNuevoPeroTerminaElEnCurso() async {
        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        self.updateSettings { $0.isEnabled = false }

        self.addUser(Self.beto, "beto")
        self.receive(Self.beto, text: "@beto_vip t.me/beto", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.sentCount(to: Self.beto), 0)
        XCTAssertEqual(self.tg.myStories.count, 1)

        self.partnerPublishes(Self.ana, 77)
        await self.wait(2 * Self.minute)
        XCTAssertEqual(self.tg.texts(to: Self.ana).last, SFSConstants.promoText)
    }

    func testOtraCuentaDelSistemaRecibeAdsPeroNoGraciasNiAnuncio() async {
        self.receive(Self.ana, text: "@ana_vip t.me/anavip\(Self.signature)", hasPhoto: true)
        await self.wait(45)
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 1)

        self.partnerPublishes(Self.ana, 77)
        await self.wait(2 * Self.minute)
        XCTAssertEqual(self.tg.texts(to: Self.ana).count, 1)
    }

    func testMePublicaPrimeroConFotoLoSubeSinAds() async {
        self.tg.lastPhotos[Self.ana] = 42
        self.tg.partnerStories[Self.ana] = [FakeTelegram.PartnerStory(id: 77, mentionsMe: true)]
        self.receive(Self.ana, storyMentionId: 77)
        await self.wait(45)

        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 0)
        XCTAssertEqual(self.tg.myStories.values.first?.photoMessageId, 42)
        XCTAssertEqual(self.entry(Self.ana)?.status, .active)
        XCTAssertEqual(self.entry(Self.ana)?.hasTheyPublished, true)
        XCTAssertEqual(self.entry(Self.ana)?.theirStoryId, 77)

        await self.wait(2 * Self.minute)
        XCTAssertEqual(self.tg.texts(to: Self.ana).last, SFSConstants.promoText)
    }

    func testMePublicaPrimeroSinFotoLePideLaFoto() async {
        self.tg.partnerStories[Self.ana] = [FakeTelegram.PartnerStory(id: 77, mentionsMe: true)]
        self.receive(Self.ana, storyMentionId: 77)
        await self.wait(5)
        XCTAssertTrue(self.tg.texts(to: Self.ana).first?.contains("Vi que me publicaste") ?? false)
        XCTAssertEqual(self.entry(Self.ana)?.status, .awaitingPhoto)
        XCTAssertEqual(self.entry(Self.ana)?.hasTheyPublished, true)

        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(45)
        XCTAssertEqual(self.tg.adsCount(to: Self.ana), 0)
        XCTAssertEqual(self.entry(Self.ana)?.status, .active)
        XCTAssertEqual(self.entry(Self.ana)?.hasTheyPublished, true)
        XCTAssertEqual(self.entry(Self.ana)?.theirStoryId, 77)
    }

    func testHistoriaQueNoMeMencionaNoCuenta() async {
        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)

        self.partnerPublishes(Self.ana, 88, mentionsMe: false)
        await self.wait(1)
        XCTAssertEqual(self.entry(Self.ana)?.hasTheyPublished, false)
    }

    func testSinAdsConfiguradoNoSePuedeEmpezar() async {
        self.updateSettings { $0.ads = SFSAdsSettings(isEnabled: true, savedMessageId: nil, preview: nil, hasPhoto: nil) }
        XCTAssertFalse(self.engine.canStartNewSfs)

        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        await self.wait(31)
        XCTAssertEqual(self.tg.sent, [])
    }

    func testPantallaEncendidaSoloConElSfsEncendido() {
        XCTAssertTrue(self.engine.shouldKeepScreenAwake)
        self.updateSettings { $0.isEnabled = false }
        XCTAssertFalse(self.engine.shouldKeepScreenAwake)
    }

    func testMensajesNormalesNoDisparanNada() async {
        self.receive(Self.ana, text: "hola, como estas?")
        self.receive(Self.ana, text: "jaja ok")
        await self.wait(Self.minute)
        XCTAssertEqual(self.tg.sent, [])
        XCTAssertEqual(self.tg.myStories.count, 0)
    }

    func testDosPublicacionesSeguidasRespetanLaColaDe20Segundos() async {
        self.addUser(Self.beto, "beto")
        self.receive(Self.ana, text: "@ana_vip t.me/anavip", hasPhoto: true)
        self.receive(Self.beto, text: "@beto_vip t.me/beto", hasPhoto: true)
        await self.wait(14)
        XCTAssertEqual(self.tg.myStories.count, 1)
        await self.wait(20)
        XCTAssertEqual(self.tg.myStories.count, 2)
    }
}
