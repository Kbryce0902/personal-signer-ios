import Foundation
import SwiftUI

@main
struct StorageProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

private struct ProbeView: View {
    @State private var draft = ""
    @State private var stored = ""
    @State private var status = ""

    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

    var body: some View {
        NavigationStack {
            Form {
                Section("Installed copy") {
                    LabeledContent("Build", value: build)
                    LabeledContent("Install stamp", value: installStamp)
                }
                Section("Local value") {
                    TextField("Value to keep", text: $draft)
                        .accessibilityIdentifier("probe-edit-value")
                    Button("Save Value") { save() }
                    LabeledContent("Saved value", value: stored)
                        .accessibilityIdentifier("probe-saved-value")
                    if !status.isEmpty { Text(status) }
                }
            }
            .navigationTitle("Storage Probe")
            .task { load() }
        }
    }

    private var installStamp: String {
        let url = Bundle.main.bundleURL.appendingPathComponent("PersonalSignerInstallStamp.txt")
        guard let stamp = try? String(contentsOf: url, encoding: .utf8) else { return "USB build" }
        return String(stamp.prefix(8))
    }

    private func storageURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent("saved-probe-value.txt")
    }

    private func load() {
        do {
            let url = try storageURL()
            if FileManager.default.fileExists(atPath: url.path) {
                stored = try String(contentsOf: url, encoding: .utf8)
                draft = stored
            }
        } catch {
            status = "Could not read the saved value. Unlock the iPhone and reopen Storage Probe."
        }
    }

    private func save() {
        do {
            try Data(draft.utf8).write(to: storageURL(), options: [.atomic, .completeFileProtection])
            stored = try String(contentsOf: storageURL(), encoding: .utf8)
            status = "Saved on this iPhone."
        } catch {
            status = "The value could not be saved."
        }
    }
}
