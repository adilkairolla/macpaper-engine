import SwiftUI

enum SidebarItem: String, Hashable {
    case library, favorites, create, displays, screenSaver
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @AppStorage("tab") private var selection: SidebarItem = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Wallpapers") {
                    Label("Library", systemImage: "square.grid.2x2")
                        .badge(model.library.wallpapers.count)
                        .tag(SidebarItem.library)
                    Label("Favorites", systemImage: "heart").tag(SidebarItem.favorites)
                    HStack {
                        Label("Create", systemImage: "wand.and.stars")
                        if model.creator.busy {
                            Spacer()
                            ProgressView(value: model.creator.progress)
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .help(model.creator.status)
                        }
                    }
                    .tag(SidebarItem.create)
                }
                Section("Device") {
                    Label("Displays", systemImage: "display.2").tag(SidebarItem.displays)
                    Label("Screen Saver", systemImage: "moon.stars").tag(SidebarItem.screenSaver)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                if selection != .library {
                    NowPlayingMini().padding(10)
                }
            }
        } detail: {
            Group {
                switch selection {
                case .library: LibraryView(favoritesOnly: false, goCreate: { selection = .create })
                case .favorites: LibraryView(favoritesOnly: true, goCreate: { selection = .create })
                case .create: CreateView()
                case .displays: DisplaysView()
                case .screenSaver: ScreenSaverPage()
                }
            }
            .frame(minWidth: 560, minHeight: 480)
            .overlay(alignment: .bottom) { ToastView() }
        }
        .onOpenURL { url in
            if url.isFileURL {
                model.open([url])
                selection = .library
            } else if url.host == "screensaver" {
                selection = .screenSaver
            } else {
                _ = model.handle(url)
            }
        }
        .onChange(of: model.creator.draft == nil) { _, isNil in
            if !isNil { selection = .create }
        }
        .onChange(of: model.requestedPage) { _, page in
            guard let page else { return }
            selection = page
            model.requestedPage = nil
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast.message)
                        .font(.callout)
                        .lineLimit(2)
                    if let action = toast.action {
                        Button(action.title) {
                            model.dismissToast()
                            action.run()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                    Button {
                        model.dismissToast()
                    } label: {
                        Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 20)
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.toast?.id)
        .onChange(of: model.toast?.id) { _, id in
            guard id != nil, let message = model.toast?.message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

struct NowPlayingMini: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let current = model.currentWallpaper {
            HStack(spacing: 10) {
                PosterThumbnail(wallpaper: current, maxSide: 200)
                    .frame(width: 54, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(model.desktop.pauseReason ?? "Playing").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    model.desktop.userPaused.toggle()
                } label: {
                    Label(model.desktop.userPaused ? "Resume" : "Pause", systemImage: model.desktop.userPaused ? "play.fill" : "pause.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(model.desktop.userPaused ? "Resume" : "Pause")
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
