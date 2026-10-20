import Foundation
import SwiftUI
import UIKit

struct SFSPanelView: View {
    @ObservedObject var license: SFSLicenseStore
    let onClose: () -> Void

    @State private var licenseKey = ""
    @State private var isRedeeming = false
    @State private var redeemError: String?
    @State private var redeemSuccess: String?

    var body: some View {
        NavigationView {
            List {
                self.licenseSections
                Section(footer: Text("SFS App \(SFSConfig.appVersion)")) {
                    EmptyView()
                }
            }
            .listStyle(.insetGrouped)
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

    @ViewBuilder
    private var licenseSections: some View {
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
            Section(header: Text("Motor SFS")) {
                Text("El SFS automático (detectar promos, subir a tu historia, gracias, bajadas y traiciones) llega en la próxima versión.")
                    .foregroundColor(.secondary)
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
