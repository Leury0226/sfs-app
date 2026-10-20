import Foundation
import Combine

// Licencia del cliente contra el backend de followmytg.com (mismo flujo que la app de Windows):
// GET /client/status/{telegram_id} y POST /client/redeem
final class SFSLicenseStore: ObservableObject {
    enum State: Equatable {
        case loading
        case valid(plan: String, validUntil: Date, timeRemaining: String?, isOffline: Bool)
        case invalid(reason: String)
        case error(reason: String)
    }

    @Published private(set) var state: State = .loading

    private(set) var userId: Int64?
    private var username: String?
    private var fullName: String?
    private var timer: Timer?

    var isValid: Bool {
        if case .valid = self.state {
            return true
        }
        return false
    }

    func start(userId: Int64, username: String?, fullName: String?) {
        self.username = username
        self.fullName = fullName
        if self.userId == userId {
            return
        }

        self.stop()
        self.userId = userId
        self.state = .loading
        self.check()
        self.timer = Timer.scheduledTimer(withTimeInterval: SFSConfig.licenseRecheckInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.userId = nil
        self.state = .loading
    }

    func check() {
        guard let userId = self.userId else {
            return
        }

        var request = URLRequest(url: SFSConfig.apiURL.appendingPathComponent("client/status/\(userId)"))
        request.timeoutInterval = SFSConfig.requestTimeout
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let json = Self.parseJson(data: data, response: response, error: error, acceptsErrorStatus: false)
            DispatchQueue.main.async {
                self?.handleStatus(userId: userId, json: json)
            }
        }.resume()
    }

    func redeem(key: String, completion: @escaping (_ isOk: Bool, _ message: String) -> Void) {
        guard let userId = self.userId else {
            completion(false, "Todavía no se cargó tu cuenta de Telegram.")
            return
        }

        var body: [String: Any] = [
            "key": key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            "telegram_id": String(userId),
        ]
        if let username = self.username {
            body["telegram_username"] = username
        }
        if let fullName = self.fullName, !fullName.isEmpty {
            body["telegram_name"] = fullName
        }

        var request = URLRequest(url: SFSConfig.apiURL.appendingPathComponent("client/redeem"))
        request.httpMethod = "POST"
        request.timeoutInterval = SFSConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let json = Self.parseJson(data: data, response: response, error: error, acceptsErrorStatus: true)
            DispatchQueue.main.async {
                guard let json = json else {
                    completion(false, "No pude conectar con el servidor. Revisa tu internet e intenta de nuevo.")
                    return
                }
                if json["success"] as? Bool == true {
                    self?.check()
                    completion(true, json["message"] as? String ?? "Licencia activada")
                } else {
                    completion(false, json["detail"] as? String ?? "No se pudo activar la licencia")
                }
            }
        }.resume()
    }

    private func handleStatus(userId: Int64, json: [String: Any]?) {
        guard userId == self.userId else {
            return
        }
        guard let json = json else {
            self.applyOfflineFallback(userId: userId)
            return
        }

        guard json["valid"] as? Bool == true,
              let validUntilString = json["valid_until"] as? String,
              let validUntil = Self.parseServerDate(validUntilString) else {
            self.removeCachedLicense(userId: userId)
            self.state = .invalid(reason: json["reason"] as? String ?? "Sin licencia activa")
            return
        }

        let plan = json["plan"] as? String ?? ""
        self.saveCachedLicense(userId: userId, plan: plan, validUntil: validUntil)
        self.state = .valid(
            plan: plan,
            validUntil: validUntil,
            timeRemaining: json["time_remaining_str"] as? String,
            isOffline: false
        )
    }

    private func applyOfflineFallback(userId: Int64) {
        let now = Date()
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey(userId: userId)),
           let plan = cached["plan"] as? String,
           let validUntil = cached["validUntil"] as? TimeInterval,
           let checkedAt = cached["checkedAt"] as? TimeInterval,
           now.timeIntervalSince1970 - checkedAt < SFSConfig.licenseOfflineGrace,
           validUntil > now.timeIntervalSince1970 {
            self.state = .valid(
                plan: plan,
                validUntil: Date(timeIntervalSince1970: validUntil),
                timeRemaining: nil,
                isOffline: true
            )
            return
        }
        self.state = .error(reason: "No pude conectar con el servidor de licencias")
    }

    private func saveCachedLicense(userId: Int64, plan: String, validUntil: Date) {
        UserDefaults.standard.set([
            "plan": plan,
            "validUntil": validUntil.timeIntervalSince1970,
            "checkedAt": Date().timeIntervalSince1970,
        ], forKey: Self.cacheKey(userId: userId))
    }

    private func removeCachedLicense(userId: Int64) {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey(userId: userId))
    }

    private static func cacheKey(userId: Int64) -> String {
        return "sfs.license.\(userId)"
    }

    private static func parseJson(data: Data?, response: URLResponse?, error: Error?, acceptsErrorStatus: Bool) -> [String: Any]? {
        guard error == nil, let data = data, let response = response as? HTTPURLResponse else {
            return nil
        }
        if !acceptsErrorStatus && !(200 ..< 300).contains(response.statusCode) {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // El backend manda las fechas en UTC sin zona horaria, por ejemplo "2026-11-17T00:16:46.822287"
    static func parseServerDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(value.prefix(19)))
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_DO")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
}
