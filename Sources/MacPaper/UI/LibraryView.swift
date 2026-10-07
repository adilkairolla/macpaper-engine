import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Date Added"
        case .title: "Name"
        case .kind: "Kind"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let favoritesOnly: Bool
    var goCreate: () -> Void

    @State private var search = ""
    @AppStorage("libraryKind") private var kindFilter = ""
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("libraryInspector") private var showInspector = true
    @State private var selectedID: String?
    @State private var dropTargeted = false
    @State private var showBroken = false
    @State private var gridWidth: CGFloat = 800
    @FocusState private var gridFocused: Bool

    private static let cardMinWidth: CGFloat = 230
    private static let cardSpacing: CGFloat = 18

    private var items: [Wallpaper] {
        var list = model.sortedWallpapers
        if favoritesOnly { list = list.filter { model.isFavorite($0.id) } }
        if let kind = Wallpaper.Kind(rawValue: kindFilter) { list = list.filter { $0.kind == kind } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { w in
                w.title.lowercased().contains(q) || w.manifest.tags.contains { $0.lowercased().contains(q) }
                    || (w.manifest.author?.lowercased().contains(q) ?? false)
            }
        }
        switch sort {
        case .recent: break
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .kind: list.sort { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) }
        }
        return list
    }

    /// The explicit selection, else what's playing — but only if it's on this page.
    private func selected(in items: [Wallpaper]) -> Wallpaper? {
        if let selectedID, let wp = model.library.wallpaper(id: selectedID) { return wp }
        return model.currentWallpaper.flatMap { current in items.contains { $0.id == current.id } ? current : nil }
    }

    private var columns: Int {
        max(1, Int((gridWidth + Self.cardSpacing) / (Self.cardMinWidth + Self.cardSpacing)))
    }

    var body: some View {
        let items = self.items
        let selected = selected(in: items)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !favoritesOnly, model.currentWallpaper != nil, search.isEmpty {
                        NowPlayingHero { id in
                            selectedID = id
                            showInspector = true
                        }
                    }
                    if !model.library.broken.isEmpty {
                        BrokenBanner(expanded: $showBroken)
                    }
                    if items.isEmpty && model.importing.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardMinWidth, maximum: 360), spacing: Self.cardSpacing)], spacing: 22) {
                            ForEach(model.importing) { job in
                                ImportingCard(title: job.title)
                            }
                            ForEach(items) { wp in
                                WallpaperCard(wallpaper: wp, isSelected: selected?.id == wp.id, showsFocus: gridFocused && selected?.id == wp.id)
                                    .id(wp.id)
                                    .onTapGesture(count: 2) { model.apply(wp) }
                                    .simultaneousGesture(TapGesture().onEnded {
                                        selectedID = wp.id
                                        gridFocused = true
                                    })
                                    .contextMenu { WallpaperMenuItems(wallpaper: wp) }
                                    .accessibilityAction { selectedID = wp.id }
                                    .accessibilityAction(named: "Apply") { model.apply(wp) }
                                    .accessibilityAction(named: model.isFavorite(wp.id) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(wp.id) }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                        .focusable()
                        .focusEffectDisabled()
                        .focused($gridFocused)
                        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
                            move(press.key, in: items, from: selected, proxy: proxy)
                        }
                        .onKeyPress(.return) {
                            guard let selected else { return .ignored }
                            model.apply(selected)
                            return .handled
                        }
                        .onKeyPress(.space) {
                            showInspector.toggle()
                            return .handled
                        }
                        .onKeyPress(keys: [.delete], phases: .down) { press in
                            guard press.modifiers.contains(.command), let selected else { return .ignored }
                            model.delete(selected)
                            return .handled
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(favoritesOnly ? "Favorites" : "Wallpapers")
                    }
                }
                .padding(24)
            }
        }
        .scrollContentBackground(.hidden)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .navigationTitle(favoritesOnly ? "Favorites" : "Library")
        .navigationSubtitle("\(items.count) wallpaper\(items.count == 1 ? "" : "s")")
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .focusedSceneValue(\.library, LibraryFocus(selected: selected, toggleInspector: { showInspector.toggle() }))
        .toolbar {
            ToolbarItem {
                Picker("Kind", selection: $kindFilter) {
                    Text("All Kinds").tag("")
                    ForEach([Wallpaper.Kind.video, .scene, .shader, .image], id: \.self) { k in
                        Label(k.title, systemImage: k.symbol).tag(k.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Show one kind of wallpaper")
            }
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort wallpapers")
            }
            ToolbarItem {
                Button { model.shuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Play a random wallpaper (⇧⌘R)")
            }
            ToolbarItem {
                AddMenu()
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let selected {
                    InspectorView(wallpaper: selected)
                } else {
                    EmptyStateView(symbol: "photo.on.rectangle.angled", title: "No Selection", message: "Select a wallpaper to see its controls and settings.")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in model.importItems(urls) }
            return true
        }
    }

    private func move(_ key: KeyEquivalent, in items: [Wallpaper], from selected: Wallpaper?, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = selected.flatMap { s in items.firstIndex { $0.id == s.id } }
        let next: Int
        switch (key, current) {
        case (_, nil): next = 0
        case (.leftArrow, let i?): next = max(i - 1, 0)
        case (.rightArrow, let i?): next = min(i + 1, items.count - 1)
        case (.upArrow, let i?): next = i - columns >= 0 ? i - columns : i
        case (.downArrow, let i?): next = i + columns < items.count ? i + columns : i
        case (.home, _): next = 0
        case (.end, _): next = items.count - 1
        default: return .ignored
        }
        selectedID = items[next].id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[next].id) }
        return .handled
    }

    @ViewBuilder private var emptyState: some View {
        if favoritesOnly {
            EmptyStateView(symbol: "heart", title: "No Favorites Yet", message: "Heart wallpapers you love to collect them here. Shuffle can rotate through your favorites.")
        } else if !search.isEmpty || !kindFilter.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No Matches", message: "Try a different search or filter.", actionTitle: "Show Everything") {
                search = ""
                kindFilter = ""
            }
        } else {
            EmptyStateView(
                symbol: "sparkles.rectangle.stack",
                title: "Your Library Is Empty",
                message: "Drop a video or image here to turn it into a wallpaper, or drop a .macpaper package to add it.",
                actionTitle: "Create a Wallpaper",
                action: goCreate
            )
            .frame(minHeight: 420)
        }
    }
}

private struct ImportingCard: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adding \(title)")
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.withLock { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(urls) }
    }
}

struct AddMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Create from Video or Image…", systemImage: "wand.and.stars") { model.chooseMediaToCreate() }
            Button("Import Package…", systemImage: "square.and.arrow.down") { model.chooseImport() }
            Button("Add Folder to Edit in Place…", systemImage: "link") { model.chooseLinkFolder() }
            Divider()
            Menu("New from Template", systemImage: "doc.badge.plus") {
                Button("Shader") { model.newTemplate("shader") }
                Button("Video") { model.newTemplate("video") }
                Button("Image with Depth") { model.newTemplate("image") }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Create, import or add wallpapers")
    }
}

struct WallpaperCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    let isSelected: Bool
    var showsFocus = false
    @State private var hovering = false
    @State private var prewarm: Task<Void, Never>?

    var body: some View {
        let favorite = model.isFavorite(wallpaper.id)
        let broken = !model.library.errors(for: wallpaper.id).isEmpty
        let active = model.activeWallpaperIDs.contains(wallpaper.id)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                PosterThumbnail(wallpaper: wallpaper)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if model.library.makingPoster.contains(wallpaper.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                HStack {
                    KindBadge(kind: wallpaper.kind)
                    if broken {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .help("This wallpaper has problems — see the inspector")
                    }
                    if wallpaper.linked {
                        Image(systemName: "link")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .help("Edited in place — changes to its files show up live")
                    }
                    Spacer()
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                            .shadow(radius: 3)
                            .help("On your desktop")
                    }
                }
                .padding(8)
                if hovering || favorite || isSelected {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                model.toggleFavorite(wallpaper.id)
                            } label: {
                                Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.fill" : "heart")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(favorite ? .pink : .white)
                                    .padding(7)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help(favorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)")
                        }
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.08), lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay {
                if showsFocus {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 3)
                        .padding(-4)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)

            Text(wallpaper.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { hovering = h }
            prewarm?.cancel()
            guard h else { return }
            // Only a pointer that rests on a card pays for decoding its full-size poster.
            prewarm = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { model.prewarm(wallpaper) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wallpaper.title)
        .accessibilityValue([
            wallpaper.kind.title,
            active ? "on your desktop" : nil,
            favorite ? "favorite" : nil,
            broken ? "has problems" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct NowPlayingHero: View {
    @Environment(AppModel.self) private var model
    var onCustomize: (String) -> Void
    @State private var displayID: String?
    @State private var hasSound = false

    /// Displays grouped by what they show; one entry when every display plays the same wallpaper.
    private var playing: [(display: DisplayInfo, wallpaper: Wallpaper)] {
        var seen: Set<String> = []
        return model.desktop.displays.compactMap { d in
            guard let id = d.wallpaperID, let wp = model.library.wallpaper(id: id), seen.insert(id).inserted else { return nil }
            return (d, wp)
        }
    }

    var body: some View {
        let playing = self.playing
        if let entry = playing.first(where: { $0.display.id == displayID }) ?? playing.first {
            VStack(alignment: .leading, spacing: 10) {
                hero(entry.wallpaper, display: playing.count > 1 ? entry.display : nil)
                if playing.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(playing, id: \.display.id) { item in
                            Button {
                                displayID = item.display.id
                            } label: {
                                HStack(spacing: 8) {
                                    PosterThumbnail(wallpaper: item.wallpaper, maxSide: 160)
                                        .frame(width: 40, height: 25)
                                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(item.display.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(item.wallpaper.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.glass)
                            .tint(item.display.id == entry.display.id ? .accentColor : nil)
                            .accessibilityLabel("\(item.display.name): \(item.wallpaper.title)")
                        }
                    }
                }
            }
        }
    }

    private func hero(_ wallpaper: Wallpaper, display: DisplayInfo?) -> some View {
        ZStack(alignment: .bottomLeading) {
            PosterThumbnail(wallpaper: wallpaper, maxSide: 1600)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.15),
                .init(color: .black.opacity(0.45), location: 0.55),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(display.map { "NOW PLAYING ON \($0.name.uppercased())" } ?? "NOW PLAYING")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(wallpaper.title)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        KindBadge(kind: wallpaper.kind)
                        if let reason = model.desktop.pauseReason {
                            Label(reason, systemImage: "pause.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        model.desktop.userPaused.toggle()
                    } label: {
                        Label(model.desktop.userPaused ? "Resume" : "Pause", systemImage: model.desktop.userPaused ? "play.fill" : "pause.fill")
                    }
                    .help(model.desktop.userPaused ? "Resume all wallpapers (⇧⌘P)" : "Pause all wallpapers (⇧⌘P)")
                    if hasSound {
                        let audible = model.isAudible(wallpaper.id)
                        Button {
                            model.toggleSound(wallpaper.id)
                        } label: {
                            Label(audible ? "Mute" : "Unmute", systemImage: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .labelStyle(.iconOnly)
                        }
                        .help(audible ? "Mute this wallpaper" : "Play this wallpaper's sound")
                    }
                    Button {
                        onCustomize(wallpaper.id)
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                    .help("Show this wallpaper's controls in the inspector")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .task(id: wallpaper) { hasSound = await model.hasSound(wallpaper) }
    }
}

struct BrokenBanner: View {
    @Environment(AppModel.self) private var model
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(model.library.broken.count) package\(model.library.broken.count == 1 ? "" : "s") couldn’t be read")
                        .font(.headline)
                    Spacer()
                    Text(expanded ? "Hide" : "Show Details").font(.callout).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.library.broken.count) packages couldn’t be read")
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            if expanded {
                ForEach(model.library.broken) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(b.url.lastPathComponent).font(.callout.weight(.semibold))
                        Text(b.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                            Button("Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(b.url.path): \(b.message)", forType: .string)
                            }
                            Spacer()
                            Button(model.library.isLinked(b.url) ? "Remove from Library" : "Move to Trash", role: .destructive) {
                                model.removeBroken(b)
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
