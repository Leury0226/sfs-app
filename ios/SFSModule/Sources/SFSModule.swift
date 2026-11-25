import Foundation
import UIKit
import SwiftUI
import Combine
import SwiftSignalKit
import Postbox
import TelegramCore

// Punto de entrada del modulo SFS. Telegram (`AppDelegate`) llama `updateAccounts` con todas las cuentas con
// sesion iniciada: el SFS trabaja en todas a la vez, cada una con su licencia, ajustes e historial.
public final class SFSModule {
    public static let shared = SFSModule()
    // Telegram (`SharedWakeupManager`) vuelve a revisar que cuentas mantiene conectadas cuando esto cambia
    public static let keepAliveDidChangeNotification = Notification.Name("SFSKeepAliveDidChange")

    // `SharedWakeupManager` lee estos conjuntos fuera del hilo principal
    private let keepAliveLock = NSLock()
    private var workingUserIds = Set<Int64>()
    private var backgroundUserIds = Set<Int64>()

    @MainActor let accounts = SFSAccountList()
    @MainActor private var statuses: [Int64: SFSButtonStatus] = [:]
    @MainActor private let buttonStatus = CurrentValueSubject<SFSButtonStatus, Never>(.off)
    @MainActor private var floatingWindow: SFSFloatingWindow?
    @MainActor private lazy var backgroundKeeper = SFSBackgroundKeeper()
    @MainActor private var isKeepingScreenAwake = false

    private init() {
    }

    // Con el modo segundo plano trabajando en alguna cuenta, Telegram no deja que iOS suspenda la app
    public var isKeepingAppAlive: Bool {
        self.keepAliveLock.lock()
        defer {
            self.keepAliveLock.unlock()
        }
        return !self.backgroundUserIds.isEmpty
    }

    // Cuentas con el SFS trabajando: Telegram las mantiene conectadas aunque no sean la cuenta abierta.
    // En segundo plano, solo las que tienen ese modo encendido
    public func shouldKeepConnection(userId: Int64, isInForeground: Bool) -> Bool {
        self.keepAliveLock.lock()
        defer {
            self.keepAliveLock.unlock()
        }
        return isInForeground ? self.workingUserIds.contains(userId) : self.backgroundUserIds.contains(userId)
    }

    public func updateAccounts(_ accounts: [Account], primaryAccount: Account?) {
        Task { @MainActor in
            self.syncSessions(accounts: accounts, primaryUserId: primaryAccount.map(Self.userId))
        }
    }

    @MainActor
    private func syncSessions(accounts: [Account], primaryUserId: Int64?) {
        let current = Dictionary(uniqueKeysWithValues: self.accounts.sessions.map { ($0.userId, $0) })
        var sessions: [SFSSession] = []
        for account in accounts {
            let userId = Self.userId(account)
            if sessions.contains(where: { $0.userId == userId }) {
                continue
            }
            sessions.append(current[userId] ?? SFSSession(account: account))
        }
        for session in current.values where !sessions.contains(where: { $0 === session }) {
            session.stop()
            self.updateSession(userId: session.userId, status: nil, isBackgroundModeEnabled: false)
        }

        self.accounts.update(sessions: sessions, primaryUserId: primaryUserId)
        self.updateFloatingButton()
    }

    // Cada sesion avisa su estado; nil cuando la cuenta se cierra
    @MainActor
    func updateSession(userId: Int64, status: SFSButtonStatus?, isBackgroundModeEnabled: Bool) {
        self.statuses[userId] = status
        let isWorking = status == .working

        self.keepAliveLock.lock()
        let previous = (self.workingUserIds, self.backgroundUserIds)
        Self.set(&self.workingUserIds, userId, isWorking)
        Self.set(&self.backgroundUserIds, userId, isWorking && isBackgroundModeEnabled)
        let hasChanged = previous != (self.workingUserIds, self.backgroundUserIds)
        let isKeepingAppAlive = !self.backgroundUserIds.isEmpty
        let hasForegroundOnlyWork = !self.workingUserIds.subtracting(self.backgroundUserIds).isEmpty
        self.keepAliveLock.unlock()

        // Segundo plano: el audio en silencio mantiene la app viva y la pantalla se puede bloquear.
        // Sin ese modo, la pantalla no se apaga (si se bloquea, iOS congela la app y el SFS de esa cuenta se detiene)
        self.backgroundKeeper.setEnabled(isKeepingAppAlive)
        self.setKeepScreenAwake(hasForegroundOnlyWork)
        self.buttonStatus.send(Self.combine(Array(self.statuses.values)))
        if hasChanged {
            NotificationCenter.default.post(name: Self.keepAliveDidChangeNotification, object: nil)
        }
    }

    @MainActor
    private func updateFloatingButton() {
        if self.accounts.sessions.isEmpty {
            self.floatingWindow?.isHidden = true
            self.floatingWindow = nil
            return
        }
        if self.floatingWindow != nil {
            return
        }
        let window = SFSFloatingWindow(status: self.buttonStatus.eraseToAnyPublisher(), onTap: { [weak self] in
            self?.presentPanel()
        })
        window.show()
        self.floatingWindow = window
    }

    @MainActor
    private func setKeepScreenAwake(_ isAwake: Bool) {
        if self.isKeepingScreenAwake == isAwake {
            return
        }
        self.isKeepingScreenAwake = isAwake
        UIApplication.shared.isIdleTimerDisabled = isAwake
    }

    @MainActor
    func presentPanel() {
        guard !self.accounts.sessions.isEmpty, let presenter = Self.topViewController(), !(presenter is SFSPanelHostingController) else {
            return
        }

        let controller = SFSPanelHostingController(accounts: self.accounts)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !($0 is SFSFloatingWindow) && !$0.isHidden }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // Verde si alguna cuenta trabaja; rojo solo si ninguna tiene licencia
    private static func combine(_ statuses: [SFSButtonStatus]) -> SFSButtonStatus {
        if statuses.contains(.working) {
            return .working
        }
        if statuses.contains(.off) || statuses.isEmpty {
            return .off
        }
        return .noLicense
    }

    private static func set(_ ids: inout Set<Int64>, _ userId: Int64, _ isIncluded: Bool) {
        if isIncluded {
            ids.insert(userId)
        } else {
            ids.remove(userId)
        }
    }

    private static func userId(_ account: Account) -> Int64 {
        return account.peerId.id._internalGetInt64Value()
    }
}

// Cuentas con sesion iniciada, en el orden de Telegram, para el panel
@MainActor
final class SFSAccountList: ObservableObject {
    @Published private(set) var sessions: [SFSSession] = []
    private(set) var primaryUserId: Int64?

    nonisolated init() {
    }

    func update(sessions: [SFSSession], primaryUserId: Int64?) {
        self.primaryUserId = primaryUserId
        if self.sessions.map(\.userId) != sessions.map(\.userId) {
            self.sessions = sessions
        }
    }
}

// Todo lo del SFS de una cuenta con sesion iniciada
@MainActor
final class SFSSession: ObservableObject, Identifiable {
    let userId: Int64
    let license: SFSLicenseStore
    let settings: SFSSettingsStore
    let state: SFSStateStore
    let engine: SFSEngine
    let telegram: SFSTelegramAdapter

    @Published private(set) var title: String
    @Published private(set) var status: SFSButtonStatus = .off

    private let disposables = DisposableSet()
    private var cancellables = Set<AnyCancellable>()

    nonisolated var id: Int64 {
        return self.userId
    }

    init(account: Account) {
        let storage = SFSUserDefaultsStorage()
        let userId = account.peerId.id._internalGetInt64Value()
        let settings = SFSSettingsStore(storage: storage)
        let state = SFSStateStore(storage: storage, now: { Date() })
        let telegram = SFSTelegramAdapter(account: account)
        let license = SFSLicenseStore()
        let engine = SFSEngine(
            telegram: telegram,
            clock: SFSSystemClock(),
            settings: settings,
            state: state,
            isLicenseValid: { [weak license] in
                return license?.isValid ?? false
            }
        )
        self.userId = userId
        self.license = license
        self.title = String(userId)
        self.settings = settings
        self.state = state
        self.telegram = telegram
        self.engine = engine

        engine.start(userId: userId)

        self.disposables.add((SFSBridge.profile(account: account)
        |> deliverOnMainQueue).start(next: { [weak self] profile in
            guard let self = self else {
                return
            }
            self.title = profile.fullName ?? profile.username.map { "@\($0)" } ?? String(userId)
            self.license.start(userId: userId, username: profile.username, fullName: profile.fullName)
        }))

        license.$state
            .combineLatest(settings.$settings)
            .map { licenseState, settings -> (SFSButtonStatus, Bool) in
                let status: SFSButtonStatus
                switch licenseState {
                case .valid:
                    status = settings.isEnabled ? .working : .off
                case .loading:
                    status = .off
                case .invalid, .error:
                    status = .noLicense
                }
                return (status, settings.isBackgroundModeEnabled)
            }
            .removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })
            .sink { [weak self] status, isBackgroundModeEnabled in
                guard let self = self else {
                    return
                }
                self.status = status
                SFSModule.shared.updateSession(userId: userId, status: status, isBackgroundModeEnabled: isBackgroundModeEnabled)
            }
            .store(in: &self.cancellables)

        self.disposables.add((SFSBridge.incomingMessages(account: account)
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self = self else {
                return
            }
            for message in messages {
                self.engine.handleIncoming(SFSIncomingMessage(bridgeMessage: message))
            }
        }))

        self.disposables.add((SFSBridge.addedStories(account: account)
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let self = self else {
                return
            }
            for update in updates {
                self.engine.handleStoryUpdate(userId: update.userId, storyId: update.storyId)
            }
        }))
    }

    func stop() {
        self.disposables.dispose()
        self.cancellables.removeAll()
        self.engine.stop()
        self.license.stop()
    }
}

final class SFSPanelHostingController: UIHostingController<SFSPanelView> {
    init(accounts: SFSAccountList) {
        var dismissAction: (() -> Void)?
        super.init(rootView: SFSPanelView(accounts: accounts, onClose: {
            dismissAction?()
        }))
        dismissAction = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
