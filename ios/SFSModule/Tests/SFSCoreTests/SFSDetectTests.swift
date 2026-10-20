import XCTest
@testable import SFSCore

final class SFSDetectTests: XCTestCase {
    func testDetectaPromosIgualQueElBot() {
        XCTAssertTrue(SFSDetect.isSfsMessage("hacemos SFS?"))
        XCTAssertTrue(SFSDetect.isSfsMessage("@canal_vip t.me/canalvip"))
        XCTAssertTrue(SFSDetect.isSfsMessage("@canal_vip mi canal"))
        XCTAssertFalse(SFSDetect.isSfsMessage("@amigo hola"))
        XCTAssertFalse(SFSDetect.isSfsMessage("hola como estas"))
    }

    func testConFotoBastaUnArrobaOUnLink() {
        XCTAssertTrue(SFSDetect.isSfsWithPhoto("@amigo", hasPhoto: true))
        XCTAssertTrue(SFSDetect.isSfsWithPhoto("https://x.com", hasPhoto: true))
        XCTAssertFalse(SFSDetect.isSfsWithPhoto("hola", hasPhoto: true))
        XCTAssertFalse(SFSDetect.isSfsWithPhoto("@amigo", hasPhoto: false))
    }

    func testPeticionesYPalabrasClave() {
        XCTAssertTrue(SFSDetect.isSfsRequestOnly("s4s?"))
        XCTAssertFalse(SFSDetect.isSfsRequestOnly("hola"))
        XCTAssertTrue(SFSDetect.isUseGoKeyword("GO"))
        XCTAssertFalse(SFSDetect.isUseGoKeyword("google"))
        XCTAssertTrue(SFSDetect.hasPromoData("t.me/algo"))
    }

    func testFirmaInvisibleYUsername() {
        XCTAssertTrue(SFSDetect.hasSignature(SFSDetect.addSignature("hola")))
        XCTAssertFalse(SFSDetect.hasSignature("hola"))
        XCTAssertEqual(SFSDetect.extractUsername(senderUsername: nil, text: "sigan a @mi_canal"), "mi_canal")
        XCTAssertEqual(SFSDetect.extractUsername(senderUsername: "real", text: "@otro"), "real")
    }

    func testAjustesViejosSeCompletanConLosNuevos() throws {
        let old = #"{"isEnabled":true,"durationHours":12}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(SFSSettings.self, from: old)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.durationHours, 12)
        XCTAssertEqual(settings.publishTimeoutMin, 60)
        XCTAssertEqual(settings.render(.avisoTiempo), "✅ Te subí a mi historia por 12h. Súbeme tú también 🙌")
    }
}
