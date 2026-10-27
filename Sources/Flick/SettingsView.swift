import AppKit
import FlickCore
import SwiftUI

/// The settings window's contents.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Gestures") {
                LabeledContent("Swipe distance") {
                    HStack {
                        Slider(value: binding(\.swipeThreshold), in: FlickSettings.swipeThresholds, step: 5)
                        Text("\(Int(store.settings.swipeThreshold)) pt")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Animation") {
                    HStack {
                        Slider(value: binding(\.animationDuration), in: 0...0.5, step: 0.05)
                        Text(store.settings.animationDuration == 0 ? "off"
                             : String(format: "%.2f s", store.settings.animationDuration))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Show previews", isOn: binding(\.showPreviews))
                Toggle("Keep pointer on title bar", isOn: binding(\.keepPointerOnTitleBar))
            }
            Section {
                if store.settings.excludedApps.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(store.settings.excludedApps, id: \.self) { id in
                    HStack {
                        AppLabel(bundleIdentifier: id)
                        Spacer()
                        Button {
                            store.update { $0.excludedApps.removeAll { $0 == id } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop ignoring")
                    }
                }
                Menu("Add Running App") {
                    ForEach(addableApps(), id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            guard let id = app.bundleIdentifier else { return }
                            store.update { $0.excludedApps = ($0.excludedApps + [id]).sorted() }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("Ignored apps")
            } footer: {
                Text("Gestures on these apps' windows pass through untouched.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(displayPath).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url])
                    }
                }
            } footer: {
                Text("Settings are saved here and reloaded when the file changes, so they can be synced with your dotfiles.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = store.url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FlickSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] },
                set: { value in store.update { $0[keyPath: keyPath] = value } })
    }

    /// Running apps with windows that aren't ignored yet, by name.
    private func addableApps() -> [NSRunningApplication] {
        let excluded = Set(store.settings.excludedApps)
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                      id != own, !excluded.contains(id) else { return false }
                return seen.insert(id).inserted
            }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "")
                == .orderedAscending }
    }
}

/// An app's icon and name, from its bundle identifier.
private struct AppLabel: View {
    let bundleIdentifier: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 18, height: 18)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier)
        }
        .help(bundleIdentifier)
    }
}
