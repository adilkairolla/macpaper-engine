import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the menu bar's Wallpaper commands act on: the library's selection.
struct LibraryFocus {
    var selected: Wallpaper?
    var toggleInspector: () -> Void
}

struct LibraryFocusKey: FocusedValueKey {
    typealias Value = LibraryFocus
}

extension FocusedValues {
    var library: LibraryFocus? {
        get { self[LibraryFocusKey.self] }
        set { self[LibraryFocusKey.self] = newValue }
    }
}

extension AppModel {
    func chooseMediaToCreate() {
        guard let urls = openPanel(types: MediaTools.videoTypes + MediaTools.imageTypes, multiple: true, message: "Choose videos (each becomes a variant) or one image") else { return }
        creator.begin(with: urls)
        requestedPage = .create
    }

    func chooseImport() {
        guard let urls = openPanel(types: [.package, .folder], multiple: true, directories: true, message: "Choose .macpaper packages") else { return }
        requestedPage = .library
        importItems(urls)
    }

    func chooseLinkFolder() {
        guard let url = openPanel(types: [.package, .folder], multiple: false, directories: true, message: "Choose a .macpaper folder to use where it is — edits to its files show up live")?.first else { return }
        requestedPage = .library
        link(url)
    }

    func newTemplate(_ template: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.macpaper"
        panel.message = "Where should the new wallpaper live? MacPaper uses it in place, so edits show up live."
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != Manifest.packageExtension { url.appendPathExtension(Manifest.packageExtension) }
        do {
            try Scaffold.create(at: url, template: template, title: url.deletingPathExtension().lastPathComponent)
            requestedPage = .library
            link(url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
func openPanel(types: [UTType], multiple: Bool, directories: Bool = false, message: String) -> [URL]? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = directories
    panel.treatsFilePackagesAsDirectories = false
    panel.allowsMultipleSelection = multiple
    panel.allowedContentTypes = types
    panel.message = message
    return panel.runModal() == .OK ? panel.urls : nil
}

struct FileCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Wallpaper from Video or Image…") { model.chooseMediaToCreate() }
                .keyboardShortcut("n")
            Button("Import Package…") { model.chooseImport() }
                .keyboardShortcut("o")
            Button("Add Folder to Edit in Place…") { model.chooseLinkFolder() }
            Menu("New from Template") {
                Button("Shader") { model.newTemplate("shader") }
                Button("Video") { model.newTemplate("video") }
                Button("Image with Depth") { model.newTemplate("image") }
            }
        }
    }
}

struct WallpaperCommands: Commands {
    let model: AppModel
    @FocusedValue(\.library) private var library

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Inspector") { library?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(library == nil)
        }
        CommandMenu("Wallpaper") {
            let selected = library?.selected
            Button("Apply") { selected.map { model.apply($0) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selected.map { !model.canApply($0) } ?? true)
            if model.showsPerDisplayChoices {
                Menu("Apply To") {
                    Button("All Displays") { selected.map { model.apply($0, to: .everywhere) } }
                    Divider()
                    ForEach(model.desktop.displays) { d in
                        Button(d.name) { selected.map { model.apply($0, to: .display(d.id)) } }
                    }
                }
                .disabled(selected.map { !model.canApply($0) } ?? true)
            }
            Button(selected.map { model.isFavorite($0.id) } == true ? "Remove from Favorites" : "Add to Favorites") {
                selected.map { model.toggleFavorite($0.id) }
            }
            .keyboardShortcut("d")
            .disabled(selected == nil)
            Button("Use as Screen Saver") { selected.map { model.useAsScreenSaver($0) } }
                .disabled(selected == nil)
            Button("Show in Finder") { selected.map { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) } }
                .disabled(selected == nil)
            Divider()
            Button(model.desktop.userPaused ? "Resume Wallpapers" : "Pause Wallpapers") { model.desktop.userPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Shuffle") { model.shuffle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(selected?.linked == true ? "Remove from Library" : "Move to Trash") { selected.map { model.delete($0) } }
                .disabled(selected == nil)
        }
    }
}
