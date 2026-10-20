import Foundation
import SwiftUI
import UIKit

private enum SFSPanelTab: String, CaseIterable, Identifiable {
    case home = "Inicio"
    case messages = "Mensajes"
    case settings = "Ajustes"
    case activity = "Actividad"

    var id: String {
        return self.rawValue
    }
}

struct SFSPanelView: View {
    @ObservedObject var license: SFSLicenseStore
    let session: SFSSession
    @ObservedObject var settings: SFSSettingsStore
    @ObservedObject var state: SFSStateStore
    let onClose: () -> Void

    @State private var tab: SFSPanelTab = .home

    var body: some View {
        NavigationView {
            Group {
                if self.license.isValid {
                    VStack(spacing: 0) {
                        Picker("Sección", selection: self.$tab) {
                            ForEach(SFSPanelTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        switch self.tab {
                        case .home:
                            SFSHomeTab(license: self.license, session: self.session, settings: self.settings, state: self.state)
                        case .messages:
                            SFSMessagesTab(settings: self.settings)
                        case .settings:
                            SFSSettingsTab(settings: self.settings)
                        case .activity:
                            SFSActivityTab(state: self.state)
                        }
                    }
                    .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
                } else {
                    List {
                        SFSLicenseSections(license: self.license)
                        SFSVersionFooter()
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("SFS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo", action: self.onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Inicio

private struct SFSHomeTab: View {
    @ObservedObject var license: SFSLicenseStore
    let session: SFSSession
    @ObservedObject var settings: SFSSettingsStore
    @ObservedObject var state: SFSStateStore

    @State private var isLoadingAds = false
    @State private var adsError: String?

    var body: some View {
        List {
            Section(footer: Text(self.statusFooter)) {
                Toggle(isOn: Binding(
                    get: { self.settings.settings.isEnabled },
                    set: { isOn in self.settings.update { $0.isEnabled = isOn } }
                )) {
                    Label("SFS automático", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.green)
            }

            Section(
                header: Text("Tu ADS"),
                footer: Text(self.adsError ?? "Guarda tu ADS (foto con tu @ y tus enlaces) en Mensajes guardados y toca el botón. Se manda como copia, con tus emojis premium.")
                    .foregroundColor(self.adsError == nil ? .secondary : .red)
            ) {
                Toggle("Mandar mi ADS", isOn: Binding(
                    get: { self.settings.settings.ads.isEnabled },
                    set: { isOn in self.settings.update { $0.ads.isEnabled = isOn } }
                ))
                if self.settings.settings.ads.isEnabled {
                    if self.settings.settings.ads.savedMessageId != nil {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.settings.settings.ads.hasPhoto == true ? "photo" : "text.alignleft")
                                .foregroundColor(.accentColor)
                            Text(self.adsPreview)
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                    }
                    Button(action: self.loadAds) {
                        HStack {
                            Text(self.settings.settings.ads.savedMessageId == nil ? "Usar mi último mensaje guardado" : "Cambiar por mi último mensaje guardado")
                            if self.isLoadingAds {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(self.isLoadingAds)
                }
            }

            Section(header: Text("Estadísticas")) {
                SFSValueRow(title: "Subidos a tu historia", value: String(self.state.data.stats.publishedCount))
                SFSValueRow(title: "SFS completos", value: String(self.state.data.stats.completedCount))
                SFSValueRow(title: "Bajados por no publicar", value: String(self.state.data.stats.removedCount))
            }

            Section(header: Text("En curso")) {
                if self.queue.isEmpty {
                    Text("Nadie en cola por ahora.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(self.queue) { entry in
                        SFSQueueRow(entry: entry)
                    }
                }
            }

            SFSLicenseSections(license: self.license)
            SFSVersionFooter()
        }
        .listStyle(.insetGrouped)
    }

    private var statusFooter: String {
        let settings = self.settings.settings
        if settings.isEnabled && !settings.isAdsReady {
            return "Falta tu ADS: elige tu mensaje guardado abajo para que el SFS pueda empezar."
        }
        if settings.isEnabled {
            return "Trabajando. Deja la app abierta: la pantalla se queda encendida mientras el SFS está prendido."
        }
        return "Apagado: no empieza SFS nuevos, pero termina los que ya están en curso."
    }

    private var adsPreview: String {
        let preview = self.settings.settings.ads.preview ?? ""
        if !preview.isEmpty {
            return preview
        }
        return self.settings.settings.ads.hasPhoto == true ? "Foto" : "Mensaje guardado"
    }

    private var queue: [SFSQueueEntry] {
        return self.state.entries
            .filter { $0.status == .active || $0.status == .awaitingPhoto }
            .sorted { ($0.activatedAt ?? $0.askedPhotoAt ?? .distantPast) > ($1.activatedAt ?? $1.askedPhotoAt ?? .distantPast) }
    }

    private func loadAds() {
        self.isLoadingAds = true
        self.adsError = nil
        Task { @MainActor in
            let message = await self.session.telegram.lastSavedMessage()
            self.isLoadingAds = false
            guard let message = message else {
                self.adsError = "No encontré mensajes en tus Mensajes guardados."
                return
            }
            self.settings.update {
                $0.ads.savedMessageId = message.messageId
                $0.ads.preview = String(message.text.prefix(200))
                $0.ads.hasPhoto = message.hasPhoto
            }
        }
    }
}

private struct SFSQueueRow: View {
    let entry: SFSQueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.entry.username.map { "@\($0)" } ?? String(self.entry.targetId))
                .font(.body.weight(.medium))
            Text(self.statusText)
                .font(.footnote)
                .foregroundColor(self.statusColor)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch self.entry.status {
        case .awaitingPhoto:
            return "Esperando su foto"
        case .active where self.entry.hasTheyPublished:
            return "Completo · vence \(Self.relative(self.entry.expiresAt))"
        case .active:
            if let deadline = self.entry.publishDeadline {
                return "Subido · esperando que te publique (\(Self.relative(deadline)))"
            }
            return "Subido · esperando que te publique"
        case .removed, .closed:
            return ""
        }
    }

    private var statusColor: Color {
        if self.entry.status == .active && self.entry.hasTheyPublished {
            return .green
        }
        return .orange
    }

    private static func relative(_ date: Date?) -> String {
        guard let date = date else {
            return "-"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Mensajes

private struct SFSMessagesTab: View {
    @ObservedObject var settings: SFSSettingsStore

    var body: some View {
        List {
            Section(footer: Text("Puedes apagar o cambiar cada mensaje. Variables: {horas} y {minutos}.")) {
                ForEach(SFSMessageKey.allCases) { key in
                    NavigationLink(destination: SFSMessageEditor(settings: self.settings, key: key)) {
                        HStack {
                            Text(key.title)
                            Spacer()
                            Text(self.settings.settings.message(key).isEnabled ? "Encendido" : "Apagado")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(
                header: Text("Anuncio de SFS App"),
                footer: Text("Se manda después del gracias en cada SFS completo. No se puede apagar.")
            ) {
                Label {
                    Text(SFSConstants.promoText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SFSMessageEditor: View {
    @ObservedObject var settings: SFSSettingsStore
    let key: SFSMessageKey

    var body: some View {
        List {
            Section(footer: Text(self.key.detail)) {
                Toggle("Mandar este mensaje", isOn: Binding(
                    get: { self.settings.settings.message(self.key).isEnabled },
                    set: { isOn in self.settings.updateMessage(self.key, isEnabled: isOn) }
                ))
            }
            Section(header: Text("Texto")) {
                TextEditor(text: Binding(
                    get: { self.settings.settings.message(self.key).text },
                    set: { text in self.settings.updateMessage(self.key, text: text) }
                ))
                .frame(minHeight: 160)
            }
            Section {
                Button("Restaurar texto original") {
                    self.settings.resetMessage(self.key)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(self.key.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Ajustes

private struct SFSSettingsTab: View {
    private static let timeoutStep = 15

    @ObservedObject var settings: SFSSettingsStore

    var body: some View {
        List {
            Section(
                header: Text("Duración del SFS"),
                footer: Text("Cuánto tiempo se queda la persona en tu historia.")
            ) {
                Picker("Duración", selection: Binding(
                    get: { self.settings.settings.durationHours },
                    set: { hours in self.settings.update { $0.durationHours = hours } }
                )) {
                    ForEach(SFSSettings.durationOptions, id: \.self) { hours in
                        Text("\(hours)h").tag(hours)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(
                header: Text("Tiempo para que te publique"),
                footer: Text("Si no te publica en este tiempo, se baja de tu historia. En 0 no se baja a nadie.")
            ) {
                Stepper(value: Binding(
                    get: { self.settings.settings.publishTimeoutMin },
                    set: { minutes in self.settings.update { $0.publishTimeoutMin = minutes } }
                ), in: 0...SFSSettings.publishTimeoutMax, step: Self.timeoutStep) {
                    Text(self.settings.settings.publishTimeoutMin == 0 ? "Sin límite" : "\(self.settings.settings.publishTimeoutMin) min")
                }
            }

            Section(
                header: Text("Perfil seguro"),
                footer: Text("Fijo para proteger tu cuenta: pausas de 13 a 30 segundos antes de responder y de 20 a 40 segundos entre historias.")
            ) {
                Label("Activado", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Actividad

private struct SFSActivityTab: View {
    @ObservedObject var state: SFSStateStore

    var body: some View {
        List {
            if self.state.data.log.isEmpty {
                Text("Todavía no hay actividad.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(self.state.data.log) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.icon(entry.level))
                            .foregroundColor(Self.color(entry.level))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.subheadline)
                            Text(Self.formatTime(entry.date))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private static func icon(_ level: SFSLogLevel) -> String {
        switch level {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private static func color(_ level: SFSLogLevel) -> Color {
        switch level {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.dateFormat = "d MMM, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Licencia

private struct SFSLicenseSections: View {
    @ObservedObject var license: SFSLicenseStore

    @State private var licenseKey = ""
    @State private var isRedeeming = false
    @State private var redeemError: String?
    @State private var redeemSuccess: String?

    var body: some View {
        switch self.license.state {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Verificando tu licencia...")
                        .foregroundColor(.secondary)
                }
            }
        case let .valid(plan, validUntil, timeRemaining, isOffline):
            Section(
                header: Text("Licencia"),
                footer: isOffline ? Text("Sin conexión con el servidor. Usando la última licencia verificada.") : nil
            ) {
                Label("Licencia activa", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                SFSValueRow(title: "Plan", value: plan)
                SFSValueRow(title: "Vence", value: SFSLicenseStore.formatDate(validUntil))
                if let timeRemaining = timeRemaining {
                    SFSValueRow(title: "Te queda", value: timeRemaining)
                }
            }
            if let redeemSuccess = self.redeemSuccess {
                Section {
                    Text(redeemSuccess)
                        .foregroundColor(.green)
                }
            }
        case let .invalid(reason), let .error(reason):
            Section {
                Label("SFS bloqueado", systemImage: "lock.fill")
                    .foregroundColor(.red)
                Text("\(reason). Telegram funciona normal; el módulo SFS necesita una licencia activa.")
                    .foregroundColor(.secondary)
                if case .error = self.license.state {
                    Button("Reintentar") {
                        self.license.check()
                    }
                }
            }
            Section(
                header: Text("Activar licencia"),
                footer: self.redeemError.map { Text($0).foregroundColor(.red) }
            ) {
                TextField("Clave de licencia", text: self.$licenseKey)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                Button(action: self.redeem) {
                    HStack {
                        Text("Activar")
                        if self.isRedeeming {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(self.isRedeeming || self.licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section(header: Text("¿No tienes licencia?")) {
                ForEach(SFSConfig.prices) { price in
                    SFSValueRow(title: price.label, value: price.price, isValueBold: true)
                }
                SFSValueRow(title: "WhatsApp", value: SFSConfig.supportWhatsApp)
                Button("Escribir a @\(SFSConfig.supportUsername)") {
                    if let url = URL(string: "https://t.me/\(SFSConfig.supportUsername)") {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    private func redeem() {
        self.isRedeeming = true
        self.redeemError = nil
        self.redeemSuccess = nil
        self.license.redeem(key: self.licenseKey) { isOk, message in
            self.isRedeeming = false
            if isOk {
                self.licenseKey = ""
                self.redeemSuccess = message
            } else {
                self.redeemError = message
            }
        }
    }
}

private struct SFSVersionFooter: View {
    var body: some View {
        Section(footer: Text("SFS App \(SFSConfig.appVersion)")) {
            EmptyView()
        }
    }
}

private struct SFSValueRow: View {
    let title: String
    let value: String
    var isValueBold = false

    var body: some View {
        HStack {
            Text(self.title)
            Spacer()
            Text(self.value)
                .fontWeight(self.isValueBold ? .semibold : .regular)
                .foregroundColor(.secondary)
        }
    }
}
