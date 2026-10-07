import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model else { return }
            NSApp.setActivationPolicy(model.prefs.showDockIcon ? .regular : .accessory)
            model.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let model else { return }
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty { model.open(files) }
            for url in urls where !url.isFileURL { _ = model.handle(url) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.save()
            model?.desktop.tearDownAll()
        }
    }
}

@main
struct MacPaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        if let code = CLI.runIfRequested() { exit(code) }
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
    }

    var body: some Scene {
        Window("MacPaper", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            FileCommands(model: model)
            WallpaperCommands(model: model)
            CommandGroup(replacing: .help) {
                Button("Copy AI Guide") { AIGuide.copy(for: nil) }
                Button("Open Format Reference") { AIGuide.openReference() }
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Label("MacPaper", systemImage: model.desktop.userPaused ? "pause.rectangle" : "photo.on.rectangle.angled")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
