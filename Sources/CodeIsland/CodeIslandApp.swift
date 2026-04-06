import SwiftUI

@main
struct CodeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        MenuBarExtra("CodeIsland", systemImage: "sparkle") {
            VStack(alignment: .leading) {
                Text("CodeIsland v1.0")
                    .font(.headline)
                Text("Socket: /tmp/codeisland-\(getuid()).sock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            Divider()

            Button(l10n["settings_ellipsis"]) {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",")

            Divider()

            Button(l10n["reinstall_hooks"]) {
                _ = ConfigInstaller.install()
            }

            Button(l10n["remove_hooks"]) {
                ConfigInstaller.uninstall()
            }

            Divider()

            Button(l10n["quit"]) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
