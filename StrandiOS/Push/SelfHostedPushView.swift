#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// Settings for the Experimental, server-authoritative export to a receiver the user owns.
struct SelfHostedPushView: View {
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = ""
    @State private var token = ""
    @State private var enabled = false
    @State private var wifiOnly = true
    @State private var status = ""
    @State private var testing = false
    @State private var exporting = false
    @State private var restoring = false

    private var settings: SelfHostedPushSettings { model.selfHostedPushSettings }

    private var endpointResult: Result<SelfHostedPushEndpointPolicy.Valid, SelfHostedPushEndpointPolicy.Problem> {
        SelfHostedPushEndpointPolicy.validate(endpoint)
    }

    private var endpointValid: SelfHostedPushEndpointPolicy.Valid? {
        guard case .success(let value) = endpointResult else { return nil }
        return value
    }

    private var hasToken: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.snapshot.hasToken }

    var body: some View {
        ScreenScaffold(
            title: "Self-hosted export",
            subtitle: "Send the complete NOOP database to a receiver you own. Nothing is sent until you enable it."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                destinationCard
                statusCard
            }
        }
        .onAppear { load() }
    }

    private var destinationCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Destination")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                 Text("Use your backup receiver endpoint. The server keeps the canonical copy; NOOP uploads the complete local database after sync and does not merge remote data into the app.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                 TextField("https://your-host.example/api/backup", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                SecureField(settings.snapshot.hasToken ? "Bearer token saved" : "Bearer token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if let problem = endpointProblem {
                    Text(problem)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                }

                HStack(spacing: 10) {
                    NoopButton("Save", systemImage: "checkmark", kind: .primary) { save() }
                    NoopButton(testing ? "Testing…" : "Test connection", systemImage: "antenna.radiowaves.left.and.right", kind: .secondary) {
                        testConnection()
                    }
                    .disabled(testing || endpointValid == nil || !hasToken)
                }

                Toggle("Wi-Fi only", isOn: $wifiOnly)
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: wifiOnly) { settings.setWifiOnly($0) }
                Text("When enabled, automatic export waits for an unmetered Wi-Fi connection. This never changes strap sync.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                Toggle("Enable self-hosted export", isOn: $enabled)
                    .tint(StrandPalette.accent)
                     .onChangeCompat(of: enabled) { value in
                         guard settings.setEnabled(value) else {
                            enabled = false
                            status = "Save a valid endpoint and bearer token before enabling export."
                             return
                         }
                         SelfHostedPushBackgroundScheduler.setEnabled(value)
                     }
                 Text("Experimental and server-authoritative. NOOP uploads the complete database after a completed offload and when you tap Export now.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.snapshot.hasToken {
                     NoopButton("Clear saved token", systemImage: "trash", kind: .tertiary) {
                        _ = settings.saveToken("")
                         enabled = false
                         _ = settings.setEnabled(false)
                         SelfHostedPushBackgroundScheduler.setEnabled(false)
                         status = "Saved token cleared."
                    }
                }

                 NoopButton(exporting ? "Exporting…" : "Export now", systemImage: "arrow.up.circle", kind: .primary, fullWidth: true) {
                     exportNow()
                 }
                 .disabled(exporting || !enabled || endpointValid == nil || !hasToken)

                 NoopButton(restoring ? "Restoring…" : "Restore latest from server", systemImage: "arrow.down.circle", kind: .secondary, fullWidth: true) {
                     restoreLatest()
                 }
                 .disabled(restoring || exporting || !enabled || endpointValid.map { !SelfHostedPush.isBackupEndpoint($0) } ?? true || !hasToken)
                 Text("Restore replaces the local database and takes effect after NOOP relaunches. Use it after reinstall or only when you intentionally want the server copy.")
                     .font(StrandFont.caption)
                     .foregroundStyle(StrandPalette.textTertiary)
                     .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                let snapshot = settings.snapshot
                Text(snapshot.state == .complete ? "Last export: \(snapshot.lastSuccessAt.map(relativeDate) ?? "unknown")" : "Last export: never")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if snapshot.acceptedBatches > 0 {
                    Text("Accepted \(snapshot.acceptedRecords) records in \(snapshot.acceptedBatches) batches")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let error = snapshot.lastError {
                    Text(error)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var endpointProblem: String? {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard case .failure(let problem) = endpointResult else { return nil }
        switch problem {
        case .malformedURL: return "Enter a complete URL."
        case .missingScheme: return "The URL must start with https://."
        case .unsupportedScheme: return "Only HTTPS is allowed for public receivers."
        case .userInfo: return "Do not put credentials in the URL."
        case .fragment: return "The URL cannot contain a fragment."
        case .missingHost: return "The URL needs a host."
        case .invalidPort: return "The port is invalid."
        case .cleartextRequiresNumericLocalAddress: return "HTTP is allowed only for a numeric local/private address. Use HTTPS for a hostname."
        }
    }

    private func load() {
        let current = settings.snapshot
        endpoint = settings.endpointText
        enabled = current.enabled
        wifiOnly = current.wifiOnly
    }

    private func save() {
        guard case .success = settings.saveEndpoint(endpoint) else { status = endpointProblem ?? "Endpoint rejected."; return }
        if !token.isEmpty && !settings.saveToken(token) { status = "The token could not be saved in the Keychain."; return }
        token = ""
        enabled = settings.snapshot.enabled
        status = "Destination saved."
    }

    private func testConnection() {
        guard let endpoint = endpointValid, let url = URL(string: endpoint.url), let token = tokenValue else { return }
        testing = true
        status = ""
        Task {
            defer { testing = false }
            do {
                 let transport = SelfHostedPushTransport(endpoint: url, token: token, wifiOnly: wifiOnly)
                 let response: (status: Int, body: Data)
                 if let endpointValue = endpointValid, SelfHostedPush.isBackupEndpoint(endpointValue) {
                     response = try await transport.probeBackup()
                     guard (200...299).contains(response.status) else {
                         status = "Receiver returned HTTP \(response.status)."
                         return
                     }
                     status = "Backup receiver verified. The complete database will be uploaded."
                     return
                 }
                 response = try await transport.capabilities()
                guard (200...299).contains(response.status) else {
                    status = "Receiver returned HTTP \(response.status)."
                    return
                }
                let capabilities = try SelfHostedPushCapabilities.parse(response.body)
                status = "Connection verified. Receiver accepts \(capabilities.streams.count) of \(SelfHostedPush.registry.count) streams."
            } catch let error as SelfHostedPushError {
                status = pushErrorText(error.failure)
            } catch {
                status = "Connection failed. Check the endpoint, network and receiver certificate."
            }
        }
    }

    private func exportNow() {
        exporting = true
        Task {
            let result = await model.runSelfHostedPush()
            exporting = false
            switch result {
            case .accepted(let records, let batches):
                status = "Exported \(records) records in \(batches) batches."
            case .noData:
                status = "Already up to date."
            case .rejected(let failure):
                status = pushErrorText(failure)
            }
        }
    }

    private func restoreLatest() {
        restoring = true
        Task {
            let result = await model.restoreSelfHostedPushBackup()
            restoring = false
            switch result {
            case .restored:
                status = "Server history restored. Relaunch NOOP to reopen the restored database."
            case .tooLarge:
                status = "The server backup is too large to restore safely."
            case .unavailable:
                status = "No backup receiver is configured."
            case .failed(let failure):
                status = "Restore failed: \(failure.code.rawValue)."
            }
        }
    }

    private var tokenValue: String? {
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.token : token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func pushErrorText(_ failure: SelfHostedPushFailure) -> String {
        let status = failure.status.map { " (HTTP \($0))" } ?? ""
        let code = failure.receiverCode.map { ": \($0)" } ?? ""
        return "Export failed: \(failure.code.rawValue)\(status)\(code)."
    }
}
#endif
