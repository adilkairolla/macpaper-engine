import SwiftUI

enum PlaylistPace {
    static let choices = [0, 5, 15, 30, 60, 180]

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Once through"
        case ..<60: "\(minutes) min"
        default: "\(minutes / 60) h"
        }
    }

    static func detail(_ playlist: Playlist) -> String {
        playlist.minutes == 0
            ? "Each video plays to its end, then the next wallpaper comes on. Short loops repeat until \(Int(Playlist.onceThroughMinimum / 60)) minutes have passed; wallpapers without video stay \(Playlist.stillMinutes) minutes."
            : "Each wallpaper stays \(title(playlist.minutes)), then the next one comes on."
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    @State private var choosing = false
    @State private var selection: Set<String> = []
    @AppStorage("libraryInspector") private var showInspector = true

    var body: some View {
        if let playlist = model.playlist(playlistID) {
            content(playlist)
        } else {
            EmptyStateView(symbol: "rectangle.stack", title: "No Playlist", message: "This playlist was deleted.")
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let items = playlist.wallpaperIDs.compactMap(model.library.wallpaper(id:))
        let playing = model.isPlaying(playlist)
        let inspected = inspected(in: items, playing: playing)
        return VStack(spacing: 0) {
            PlaylistHeader(playlist: playlist, items: items) { choosing = true }
                .padding(24)
            if items.isEmpty {
                EmptyStateView(
                    symbol: "rectangle.stack.badge.plus",
                    title: "No Wallpapers Yet",
                    message: "Choose the wallpapers this playlist plays, one after another.",
                    actionTitle: "Choose Wallpapers…"
                ) { choosing = true }
            } else {
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, wp in
                        PlaylistRow(index: index + 1, wallpaper: wp, onDesktop: playing && model.activeWallpaperIDs.contains(wp.id))
                            .tag(wp.id)
                    }
                    .onMove { from, to in move(items, from: from, to: to) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Play from Here") { model.play(playlist, from: id) }
                            .disabled(model.library.wallpaper(id: id).map { !model.canApply($0) } ?? true)
                    }
                    Button(ids.count > 1 ? "Remove \(ids.count) from Playlist" : "Remove from Playlist") { remove(ids) }
                } primaryAction: { ids in
                    if let id = ids.first { model.play(playlist, from: id) }
                }
                .onDeleteCommand { remove(selection) }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(playlist.name.isEmpty ? "Untitled Playlist" : playlist.name)
        .navigationSubtitle("\(items.count) wallpaper\(items.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItem {
                Button { choosing = true } label: { Label("Choose Wallpapers", systemImage: "plus") }
                    .help("Choose which wallpapers this playlist plays")
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let inspected {
                    InspectorView(wallpaper: inspected)
                } else {
                    EmptyStateView(symbol: "photo.on.rectangle.angled", title: "No Selection", message: "Select a wallpaper to adjust it. Its settings are the same ones it uses everywhere else.")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .focusedSceneValue(\.library, LibraryFocus(selected: inspected, toggleInspector: { showInspector.toggle() }))
        .sheet(isPresented: $choosing) { WallpaperChooser(playlist: playlist) }
        .task(id: model.choosingWallpapersFor) {
            guard model.choosingWallpapersFor == playlistID else { return }
            model.choosingWallpapersFor = nil
            choosing = true
        }
    }

    /// The one selected row, else the playlist's wallpaper on the desktop.
    private func inspected(in items: [Wallpaper], playing: Bool) -> Wallpaper? {
        if selection.count == 1, let id = selection.first, let wp = items.first(where: { $0.id == id }) { return wp }
        guard selection.isEmpty, playing else { return nil }
        return items.first { model.activeWallpaperIDs.contains($0.id) }
    }

    /// Wallpapers missing from the library keep their place at the end, so they come back if the package does.
    private func move(_ items: [Wallpaper], from: IndexSet, to: Int) {
        var ids = items.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        model.updatePlaylist(playlistID) { p in
            p.wallpaperIDs = ids + p.wallpaperIDs.filter { !ids.contains($0) }
        }
    }

    private func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        model.updatePlaylist(playlistID) { $0.wallpaperIDs.removeAll(where: ids.contains) }
        selection.subtract(ids)
    }
}

private struct PlaylistHeader: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let items: [Wallpaper]
    var choose: () -> Void

    private var playingOn: [DisplayInfo] {
        model.desktop.displays.filter { model.playlist(onDisplay: $0.id)?.id == playlist.id }
    }

    private var status: String {
        let count = "\(items.count) wallpaper\(items.count == 1 ? "" : "s")"
        let on = playingOn
        if on.isEmpty { return count }
        if on.count == model.desktop.displays.count { return "\(count) · Playing on your desktop" }
        return "\(count) · Playing on \(on.map(\.name).formatted(.list(type: .and)))"
    }

    var body: some View {
        let playing = !playingOn.isEmpty
        HStack(alignment: .top, spacing: 22) {
            PlaylistCover(items: items)
                .frame(width: 230, height: 144)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Playlist Name", text: Binding(get: { playlist.name }, set: { name in model.updatePlaylist(playlist.id) { $0.name = name } }))
                    .textFieldStyle(.plain)
                    .font(.largeTitle.weight(.bold))
                Text(status).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if playing {
                        Button { model.stop(playlist) } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.glass)
                            .help("Keep the current wallpaper and stop changing it")
                        Button { model.next() } label: { Label("Next", systemImage: "forward.fill") }
                            .buttonStyle(.glass)
                            .help("Go to the next wallpaper now")
                    } else {
                        Button { model.play(playlist) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.glassProminent)
                            .disabled(items.isEmpty)
                    }
                    if model.showsPerDisplayChoices {
                        Menu("Play On") {
                            Button("All Displays") { model.play(playlist, to: .everywhere) }
                            Divider()
                            ForEach(model.desktop.displays) { d in
                                Button(d.name) { model.play(playlist, to: .display(d.id)) }
                            }
                        }
                        .fixedSize()
                        .disabled(items.isEmpty)
                    }
                    Button { model.useAsScreenSaver(playlist) } label: { Label("Use as Screen Saver", systemImage: "moon.stars") }
                        .buttonStyle(.glass)
                        .disabled(items.isEmpty)
                }
                .controlSize(.large)
                HStack(spacing: 18) {
                    Picker("Play each", selection: Binding(get: { playlist.minutes }, set: { m in model.updatePlaylist(playlist.id) { $0.minutes = m } })) {
                        ForEach(PlaylistPace.choices, id: \.self) { Text(PlaylistPace.title($0)).tag($0) }
                    }
                    .fixedSize()
                    Toggle("Shuffle", isOn: Binding(get: { playlist.shuffle }, set: { v in model.updatePlaylist(playlist.id) { $0.shuffle = v } }))
                }
                Text(PlaylistPace.detail(playlist))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The first four posters in a grid, like an album cover.
private struct PlaylistCover: View {
    let items: [Wallpaper]

    var body: some View {
        let shown = Array(items.prefix(4))
        Group {
            if shown.isEmpty {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.tertiary) }
            } else if shown.count < 4 {
                PosterThumbnail(wallpaper: shown[0], maxSide: 600)
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        PosterThumbnail(wallpaper: shown[0], maxSide: 300)
                        PosterThumbnail(wallpaper: shown[1], maxSide: 300)
                    }
                    GridRow {
                        PosterThumbnail(wallpaper: shown[2], maxSide: 300)
                        PosterThumbnail(wallpaper: shown[3], maxSide: 300)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .accessibilityHidden(true)
    }
}

private struct PlaylistRow: View {
    let index: Int
    let wallpaper: Wallpaper
    let onDesktop: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            PosterThumbnail(wallpaper: wallpaper, maxSide: 240)
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 10) {
                    Label(wallpaper.kind.title, systemImage: wallpaper.kind.symbol)
                    if onDesktop {
                        Label("On your desktop", systemImage: "play.circle.fill").foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Picks the playlist's wallpapers from the whole library; search narrows the grid, e.g. by a tag.
struct WallpaperChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var chosen: Set<String> = []
    @State private var search = ""
    @State private var kind = ""

    private var shown: [Wallpaper] {
        var list = model.sortedWallpapers
        if let k = Wallpaper.Kind(rawValue: kind) { list = list.filter { $0.kind == k } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { w in
                w.title.lowercased().contains(q) || w.manifest.tags.contains { $0.lowercased().contains(q) }
                    || (w.manifest.author?.lowercased().contains(q) ?? false)
            }
        }
        return list
    }

    var body: some View {
        let shown = self.shown
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Wallpapers").font(.title2.weight(.semibold))
                    Text("for “\(playlist.name.isEmpty ? "Untitled Playlist" : playlist.name)”").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Kind", selection: $kind) {
                    Text("All Kinds").tag("")
                    ForEach([Wallpaper.Kind.video, .scene, .shader, .image], id: \.self) { k in
                        Label(k.title, systemImage: k.symbol).tag(k.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Search names and tags", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(20)
            Divider()
            ScrollView {
                if shown.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No Matches", message: "Try a different search or kind.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 16) {
                        ForEach(shown) { wp in
                            ChooserCard(wallpaper: wp, chosen: chosen.contains(wp.id), playable: model.canApply(wp)) {
                                if chosen.contains(wp.id) { chosen.remove(wp.id) } else { chosen.insert(wp.id) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button(search.isEmpty && kind.isEmpty ? "Select All" : "Select All Shown") { chosen.formUnion(shown.map(\.id)) }
                Button(search.isEmpty && kind.isEmpty ? "Select None" : "Deselect Shown") { chosen.subtract(shown.map(\.id)) }
                Spacer()
                Text("\(chosen.count) chosen").foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
            .padding(16)
        }
        .frame(width: 880, height: 640)
        .onAppear { chosen = Set(playlist.wallpaperIDs) }
    }

    /// Wallpapers already in the playlist keep their order; new ones join at the end in library order.
    private func save() {
        let kept = playlist.wallpaperIDs.filter { chosen.contains($0) || model.library.wallpaper(id: $0) == nil }
        let added = model.sortedWallpapers.map(\.id).filter { chosen.contains($0) && !kept.contains($0) }
        model.updatePlaylist(playlist.id) { $0.wallpaperIDs = kept + added }
    }
}

private struct ChooserCard: View {
    let wallpaper: Wallpaper
    let chosen: Bool
    let playable: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterThumbnail(wallpaper: wallpaper, maxSide: 480)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(chosen ? Color.accentColor : .white.opacity(0.08), lineWidth: chosen ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, chosen ? Color.accentColor : .black.opacity(0.3))
                        .shadow(radius: 2)
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    KindBadge(kind: wallpaper.kind).padding(8)
                }
            Text(wallpaper.title).font(.callout.weight(.medium)).lineLimit(1)
        }
        .opacity(playable ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wallpaper.title)
        .accessibilityValue(playable ? wallpaper.kind.title : "\(wallpaper.kind.title), has problems")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
    }
}

struct PlaylistMenuItems: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        if model.isPlaying(playlist) {
            Button("Stop") { model.stop(playlist) }
            Button("Next Wallpaper") { model.next() }
        } else {
            Button("Play") { model.play(playlist) }.disabled(playlist.wallpaperIDs.isEmpty)
        }
        Button("Use as Screen Saver") { model.useAsScreenSaver(playlist) }.disabled(playlist.wallpaperIDs.isEmpty)
        Divider()
        Button("Delete Playlist", role: .destructive) { model.deletePlaylist(playlist) }
    }
}

/// The library's "Add to Playlist" submenu for one wallpaper.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(model.playlists) { p in
                Button(p.name.isEmpty ? "Untitled Playlist" : p.name) { model.add(wallpaper, to: p) }
                    .disabled(p.wallpaperIDs.contains(wallpaper.id))
            }
            if !model.playlists.isEmpty { Divider() }
            Button("New Playlist") {
                let p = model.createPlaylist(with: [wallpaper.id])
                model.requestedPage = .playlist(p.id)
            }
        }
    }
}
