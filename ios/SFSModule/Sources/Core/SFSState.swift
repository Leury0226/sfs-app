import Foundation
import Combine

// `active`: lo tengo subido. `awaitingPhoto`: le pedi su foto. `removed`: lo baje por no publicar.
// `closed`: SFS terminado (vencio o se rehizo)
enum SFSQueueStatus: String, Codable {
    case active
    case awaitingPhoto
    case removed
    case closed
}

// Equivale a una fila de `SFSQueue` del bot del servidor
struct SFSQueueEntry: Codable, Equatable, Identifiable {
    var targetId: Int64
    var username: String?
    var status: SFSQueueStatus
    var storyId: Int32?
    var theirStoryId: Int32?
    var hasTheyPublished = false
    // Otra cuenta del sistema (bot o app): no se le manda gracias ni pedidos
    var isSilent = false
    var activatedAt: Date?
    var expiresAt: Date?
    var publishDeadline: Date?
    // Ultima vez que se subio a esta persona (anti-bucle)
    var lastActionAt: Date?
    // Ultima vez que se le pidio la foto
    var askedPhotoAt: Date?
    var thanksDueAt: Date?
    var isThanksSent = false
    var removedAt: Date?

    var id: Int64 {
        return self.targetId
    }

    init(targetId: Int64, username: String?, status: SFSQueueStatus) {
        self.targetId = targetId
        self.username = username
        self.status = status
    }
}

enum SFSLogLevel: String, Codable {
    case info
    case success
    case warning
    case error
}

struct SFSLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let level: SFSLogLevel
    let text: String
}

struct SFSStats: Codable, Equatable {
    var publishedCount = 0
    var completedCount = 0
    var removedCount = 0
}

struct SFSStateData: Codable, Equatable {
    var queue: [Int64: SFSQueueEntry] = [:]
    var log: [SFSLogEntry] = []
    var stats = SFSStats()
}

@MainActor
final class SFSStateStore: ObservableObject {
    private static let logLimit = 100

    @Published private(set) var data = SFSStateData()

    private let storage: SFSStorage
    private let now: () -> Date
    private var userId: Int64?

    init(storage: SFSStorage, now: @escaping () -> Date) {
        self.storage = storage
        self.now = now
    }

    func load(userId: Int64) {
        self.userId = userId
        if let stored = self.storage.data(forKey: Self.key(userId)),
           let saved = try? JSONDecoder().decode(SFSStateData.self, from: stored) {
            self.data = saved
        } else {
            self.data = SFSStateData()
        }
    }

    var entries: [SFSQueueEntry] {
        return Array(self.data.queue.values)
    }

    func entry(_ targetId: Int64) -> SFSQueueEntry? {
        return self.data.queue[targetId]
    }

    func save(_ entry: SFSQueueEntry) {
        self.mutate { $0.queue[entry.targetId] = entry }
    }

    @discardableResult
    func update(_ targetId: Int64, _ change: (inout SFSQueueEntry) -> Void) -> SFSQueueEntry? {
        guard var entry = self.data.queue[targetId] else {
            return nil
        }
        change(&entry)
        self.save(entry)
        return entry
    }

    func increment(_ keyPath: WritableKeyPath<SFSStats, Int>) {
        self.mutate { $0.stats[keyPath: keyPath] += 1 }
    }

    func log(_ level: SFSLogLevel, _ text: String) {
        let entry = SFSLogEntry(id: UUID(), date: self.now(), level: level, text: text)
        self.mutate { data in
            data.log.insert(entry, at: 0)
            if data.log.count > Self.logLimit {
                data.log.removeLast(data.log.count - Self.logLimit)
            }
        }
    }

    private func mutate(_ change: (inout SFSStateData) -> Void) {
        var newData = self.data
        change(&newData)
        self.data = newData
        if let userId = self.userId, let encoded = try? JSONEncoder().encode(newData) {
            self.storage.set(encoded, forKey: Self.key(userId))
        }
    }

    private static func key(_ userId: Int64) -> String {
        return "sfs.state.\(userId)"
    }
}
