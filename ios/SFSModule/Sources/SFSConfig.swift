import Foundation

struct SFSPrice: Identifiable {
    let label: String
    let price: String

    var id: String {
        return self.label
    }
}

enum SFSConfig {
    static let appVersion = "0.7.0"

    static let apiURL = URL(string: "https://followmytg.com/api")!
    static let requestTimeout: TimeInterval = 15
    // Cada cuanto se vuelve a consultar la licencia con la app abierta
    static let licenseRecheckInterval: TimeInterval = 60 * 60
    // Si el servidor no responde, se acepta la ultima licencia valida guardada durante este tiempo
    static let licenseOfflineGrace: TimeInterval = 12 * 60 * 60

    static let supportUsername = "rip0226"
    static let supportWhatsApp = "809 324 5449"

    static let prices: [SFSPrice] = [
        SFSPrice(label: "1 Mes", price: "RD$800"),
        SFSPrice(label: "3 Meses", price: "RD$2,200"),
        SFSPrice(label: "6 Meses", price: "RD$4,000"),
        SFSPrice(label: "1 Año", price: "RD$7,000"),
    ]
}
