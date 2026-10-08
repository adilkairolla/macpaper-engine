import SwiftUI

struct DisplaysView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: [String: FrameStats] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.desktop.displays.count > 1 {
                    Toggle(isOn: Binding(get: { model.prefs.perDisplay }, set: { model.setPerDisplay($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Different wallpaper on each display").font(.headline)
                            Text(model.prefs.perDisplay
                                 ? "Each display keeps its own wallpaper. Apply and Shuffle act on the display the MacPaper window is on."
                                 : "Every display shows the same wallpaper, cropped to fit. Choosing one for a single display below turns this on.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                ForEach(model.desktop.displays) { d in
                    DisplayCard(display: d, stats: stats[d.id])
                }
            }
            .padding(24)
        }
        .navigationTitle("Displays")
        .onReceive(timer) { _ in
            var next: [String: FrameStats] = [:]
            for d in model.desktop.displays { next[d.id] = model.desktop.stats(for: d.id) }
            if next != stats { stats = next }
        }
    }
}

private struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    let display: DisplayInfo
    let stats: FrameStats?

    var body: some View {
        let wp = display.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
        HStack(spacing: 18) {
            Group {
                if let wp { PosterThumbnail(wallpaper: wp, maxSide: 800) } else { Rectangle().fill(.quaternary) }
            }
            .aspectRatio(display.size.width / max(display.size.height, 1), contentMode: .fit)
            .frame(width: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text(display.name).font(.title3.weight(.semibold))
                Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))").font(.callout).foregroundStyle(.secondary)
                if let wp {
                    Text(wp.title).font(.callout.weight(.medium)).padding(.top, 6)
                    if let playlist = model.playlist(onDisplay: display.id) {
                        Label("Playlist “\(playlist.name)”", systemImage: "rectangle.stack").font(.caption).foregroundStyle(.secondary)
                    }
                    if display.paused {
                        Label(model.desktop.pauseReason ?? "Paused while covered by windows", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                    } else if let stats {
                        Text(stats.summary)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No wallpaper").font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                }
                if display.recoveries > 0, let last = display.lastRecovery {
                    Label("Repaired \(display.recoveries == 1 ? "a freeze" : "\(display.recoveries) freezes") since MacPaper started · last at \(last)", systemImage: "wrench.and.screwdriver")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help("MacPaper checks every few seconds that each display’s wallpaper is still moving and repairs it if not. Details are in the log under Info › Develop.")
                }
                Spacer()
                HStack {
                    Menu("Choose Wallpaper") {
                        ForEach(model.sortedWallpapers) { w in
                            Toggle(w.title, isOn: Binding(get: { w.id == display.wallpaperID }, set: { _ in
                                model.apply(w, to: model.desktop.displays.count > 1 ? .display(display.id) : .everywhere)
                            }))
                            .disabled(!model.canApply(w))
                        }
                    }
                    .fixedSize()
                    if !model.playlists.isEmpty {
                        Menu("Play Playlist") {
                            ForEach(model.playlists) { p in
                                Toggle(p.name.isEmpty ? "Untitled Playlist" : p.name, isOn: Binding(get: { model.playlist(onDisplay: display.id)?.id == p.id }, set: { on in
                                    if on { model.play(p, to: model.desktop.displays.count > 1 ? .display(display.id) : .everywhere) } else { model.stop(p) }
                                }))
                                .disabled(p.wallpaperIDs.isEmpty)
                            }
                        }
                        .fixedSize()
                    }
                    if wp != nil {
                        Button("Remove Wallpaper") { model.clear(display: display.id) }
                            .help("Show the macOS desktop picture on this display instead")
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ScreenSaverPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        let installer = model.screenSaver
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "moon.stars.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacPaper Screen Saver").font(.headline)
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch installer.status {
                    case .installed:
                        Button("Open Screen Saver Settings") { installer.openSystemSettings() }
                    case .unavailable:
                        EmptyView()
                    default:
                        Button("Install") { installer.install() }.buttonStyle(.glassProminent)
                    }
                }
                if let e = installer.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                if installer.status == .installed, !installer.isSelected {
                    Text("Installed. Choose MacPaper in System Settings › Screen Saver to use it.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("What plays") {
                Picker("Source", selection: $prefs.saverSource) {
                    ForEach(ScreenSaverSource.allCases) { Text($0.title).tag($0) }
                }
                if prefs.saverSource == .wallpaper {
                    Picker("Wallpaper", selection: $prefs.saverWallpaperID) {
                        Text("None").tag("")
                        ForEach(model.sortedWallpapers) { Text($0.title).tag($0.id) }
                    }
                }
                if prefs.saverSource == .playlist {
                    Picker("Playlist", selection: $prefs.saverPlaylistID) {
                        Text("None").tag("")
                        ForEach(model.playlists) { Text($0.name.isEmpty ? "Untitled Playlist" : $0.name).tag($0.id.uuidString) }
                    }
                    if let playlist = UUID(uuidString: prefs.saverPlaylistID).flatMap(model.playlist) {
                        Text("Plays in the playlist’s order, starting from the wallpaper on your desktop when it’s in the playlist. \(PlaylistPace.detail(playlist))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.playlists.isEmpty {
                        Text("Make a playlist in the sidebar first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if prefs.saverSource == .favorites || prefs.saverSource == .library {
                    Picker("Change every", selection: $prefs.saverRotateMinutes) {
                        Text("Never").tag(0)
                        ForEach([1, 5, 10, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
                Toggle("Play sound", isOn: $prefs.saverSound)
            }
            Section {
                Text("Every MacPaper wallpaper — video, shaders, particles and depth — plays live in the screen saver with your control values and crop. macOS draws its own clock on top; turn it off in System Settings › Lock Screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Screen Saver")
        .onAppear { installer.refresh() }
    }

    private var statusText: String {
        switch model.screenSaver.status {
        case .installed: model.screenSaver.isSelected ? "Installed and selected" : "Installed"
        case .outdated: "An update is ready to install"
        case .notInstalled: "Not installed"
        case .unavailable: "Unavailable — open MacPaper from its app to install the screen saver"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        TabView {
            Form {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Show in Dock", isOn: $prefs.showDockIcon)
                    .onChange(of: prefs.showDockIcon) { _, v in NSApp.setActivationPolicy(v ? .regular : .accessory) }
                Section {
                    Toggle("Match the macOS desktop picture", isOn: $prefs.syncDesktopPicture)
                    Text("Sets a still frame of each wallpaper as the regular desktop picture, so Mission Control, the login screen and menu bar tint match.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Switching wallpapers", selection: $prefs.transitionSeconds) {
                        Text("Cut instantly").tag(0.0)
                        Text("Quick fade").tag(0.35)
                        Text("Slow fade").tag(0.8)
                    }
                    Picker("Shuffle every", selection: $prefs.shuffleMinutes) {
                        Text("Never").tag(0)
                        ForEach([5, 15, 30, 60, 180], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                    }
                    Picker("Shuffle from", selection: $prefs.shuffleSource) {
                        ForEach(ShuffleSource.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(prefs.shuffleMinutes == 0)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Picker("Quality", selection: $prefs.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    Text(prefs.quality.detail).font(.caption).foregroundStyle(.secondary)
                    Picker("Quality on battery", selection: $prefs.batteryQuality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(prefs.pauseOnBattery)
                    Picker("Frame rate limit", selection: $prefs.frameRateCap) {
                        Text("No limit").tag(0)
                        ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Text("A ceiling for every wallpaper; a wallpaper can still choose a lower rate under Adjust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pause when") {
                    Toggle("The desktop is covered by windows", isOn: $prefs.pauseWhenCovered)
                    Toggle("On battery", isOn: $prefs.pauseOnBattery)
                    Toggle("Low Power Mode is on", isOn: $prefs.pauseInLowPowerMode)
                    Toggle("Reduce Motion is on", isOn: $prefs.pauseWithReduceMotion)
                    Picker("Another app is focused", selection: $prefs.focusBehavior) {
                        ForEach(FocusBehavior.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Toggle("Pointer parallax", isOn: $prefs.pointerParallax)
                    Text("Layers with depth shift as the pointer moves. Wallpapers still drift slowly on their own.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.67percent") }

            Form {
                Toggle("Mute all wallpapers", isOn: $prefs.globalMute)
                LabeledContent("Volume for all wallpapers") {
                    HStack {
                        Slider(value: $prefs.masterVolume, in: 0...1)
                            .frame(width: 180)
                            .accessibilityLabel("Volume for all wallpapers")
                            .accessibilityValue("\(Int((prefs.masterVolume * 100).rounded()))%")
                        Text("\(Int((prefs.masterVolume * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(prefs.globalMute)
                Section {
                    Toggle("Wallpapers react to sound", isOn: $prefs.audioReactive)
                    Text("Wallpapers that support it move with the music and sound playing on your Mac. macOS asks for screen-recording permission the first time; no picture is ever captured.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let e = AudioCapture.shared.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
        }
        .frame(width: 540, height: 480)
    }
}

/// The wallpaper's timeline: what is playing, where, and controls to jump or switch between show and rest.
struct NowPlaying: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let session = model.session(for: wallpaper), let p = session.playhead {
                content(session, p)
            }
        }
    }

    private func content(_ session: SceneSession, _ p: SceneSession.Playhead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if p.canSwitch {
                    Picker("Now", selection: Binding(
                        get: { p.phase == .rest },
                        set: { session.switchPhase(toRest: $0) }
                    )) {
                        Text("Show").tag(false)
                        Text("Rest").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(status(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button { session.skipPlayhead(by: -10) } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(.borderless)
                    .help("Back 10 seconds")
                    .accessibilityLabel("Back 10 seconds")
                Text(Self.clock(dragging ?? p.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { dragging ?? p.position },
                    set: { dragging = $0 }
                ), in: 0...max(p.duration, 1)) { editing in
                    if !editing, let v = dragging {
                        session.seekPlayhead(to: v)
                        dragging = nil
                    }
                }
                .overlay(alignment: .leading) { handoffMark(p) }
                .accessibilityLabel(p.phase == .rest ? "Rest so far" : "Position")
                .accessibilityValue("\(Self.clock(dragging ?? p.position)) of \(Self.clock(p.duration))")
                Text(Self.clock(p.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { session.skipPlayhead(by: 10) } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(.borderless)
                    .help("Forward 10 seconds")
                    .accessibilityLabel("Forward 10 seconds")
            }
            .disabled(p.phase == .reaction)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func handoffMark(_ p: SceneSession.Playhead) -> some View {
        if let at = p.handoff, p.duration > 0 {
            GeometryReader { g in
                Capsule().fill(Color.orange).frame(width: 2, height: 10)
                    .position(x: g.size.width * at / p.duration, y: g.size.height / 2)
            }
            .allowsHitTesting(false)
            .help("She sits down to rest here")
        }
    }

    private func status(_ p: SceneSession.Playhead) -> String {
        switch p.phase {
        case .reaction: "Reacting…"
        case .rest: "Resting · \(Self.clock(max(p.duration - p.position, 0))) left"
        case .show: p.handoff.map { "Rests at \(Self.clock($0))" } ?? "Playing"
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hasSound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = model.currentWallpaper {
                ZStack(alignment: .bottomLeading) {
                    PosterThumbnail(wallpaper: current, maxSide: 700)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(model.desktop.pauseReason ?? (model.desktop.displays.first.flatMap { model.playlist(onDisplay: $0.id) }.map { "Playing “\($0.name)”" } ?? "Playing"))
                            .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if RestSpec.decode(current.manifest.raw["rest"]) != nil {
                    RestModePicker(wallpaper: current).controlSize(.small).frame(maxWidth: .infinity)
                }
                NowPlaying(wallpaper: current)
                if current.manifest.allControls.contains(where: \.quick) {
                    ControlsView(wallpaper: current, quickOnly: true)
                }
                if let reactions = ReactionsSpec.decode(current.manifest.raw["reactions"]) {
                    reactionsRow(current, reactions)
                }
                adjustments(current)
            } else {
                Text("No wallpaper playing").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            }

            HStack(spacing: 8) {
                control(model.desktop.userPaused ? "Resume" : "Pause", model.desktop.userPaused ? "play.fill" : "pause.fill") { model.desktop.userPaused.toggle() }
                if let current = model.currentWallpaper, hasSound {
                    let audible = model.isAudible(current.id)
                    control(audible ? "Mute" : "Unmute", audible ? "speaker.wave.2.fill" : "speaker.slash.fill") { model.toggleSound(current.id) }
                }
                if model.isPlayingPlaylist {
                    control("Next", "forward.fill") { model.next() }
                } else {
                    control("Shuffle", "shuffle") { model.shuffle() }
                }
            }

            if !model.state.playlists.isEmpty {
                playlistMenu
            }

            let recents = model.recentWallpapers.prefix(6)
            if !recents.isEmpty {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(recents)) { wp in
                        Button { model.apply(wp) } label: {
                            PosterThumbnail(wallpaper: wp, maxSide: 300)
                                .aspectRatio(16 / 10, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    if model.activeWallpaperIDs.contains(wp.id) {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canApply(wp))
                        .help(wp.title)
                        .accessibilityLabel(wp.title)
                        .accessibilityValue(model.activeWallpaperIDs.contains(wp.id) ? "on your desktop" : "")
                        .onHover { if $0 { model.prewarm(wp) } }
                    }
                }
            }

            Divider()
            HStack {
                Button("Open MacPaper") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 330)
        .task(id: model.currentWallpaper) {
            if let current = model.currentWallpaper { hasSound = await model.hasSound(current) } else { hasSound = false }
        }
    }

    private func reactionsRow(_ wallpaper: Wallpaper, _ spec: ReactionsSpec) -> some View {
        let s = model.settings(wallpaper.id)
        let showOnly = wallpaper.manifest.raw["rest"] != nil && s.restMode == .show
        return HStack {
            Toggle("React to you", isOn: Binding(
                get: { model.settings(wallpaper.id).reactions },
                set: { v in model.update(wallpaper.id) { $0.reactions = v } }
            ))
            .toggleStyle(.switch)
            .disabled(showOnly)
            Spacer()
            Menu("Play a reaction") {
                ForEach(spec.rules, id: \.trigger) { rule in
                    Button(ReactionsSection.title(rule)) { model.tryReaction(rule.trigger, of: wallpaper) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!s.reactions || showOnly)
        }
        .controlSize(.small)
    }

    private func adjustments(_ wallpaper: Wallpaper) -> some View {
        func binding(_ key: WritableKeyPath<WallpaperSettings, Double>) -> Binding<Double> {
            Binding(get: { model.settings(wallpaper.id)[keyPath: key] }, set: { v in model.update(wallpaper.id) { $0[keyPath: key] = v } })
        }
        let s = model.settings(wallpaper.id)
        let changed = s.brightness != 1 || s.speed != 1
        return VStack(spacing: 6) {
            HStack {
                Text("Brightness \(Int((s.brightness * 100).rounded()))% · Speed \(String(format: "%.1f", s.speed))×")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    model.update(wallpaper.id) {
                        $0.brightness = 1
                        $0.speed = 1
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!changed)
                .help("Back to normal brightness and speed")
            }
            slider("Brightness", "sun.min", "sun.max", binding(\.brightness), 0.3...1.6)
            slider("Speed", "tortoise", "hare", binding(\.speed), 0.1...3)
            if hasSound {
                slider("Volume", "speaker", "speaker.wave.3", binding(\.volume), 0...1)
            }
        }
        .controlSize(.small)
    }

    private func slider(_ name: String, _ low: String, _ high: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        Slider(value: value, in: range) {
            Text(name)
        } minimumValueLabel: {
            Image(systemName: low).frame(width: 18).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: high).frame(width: 18).foregroundStyle(.secondary)
        }
        .labelsHidden()
        .help(name)
        .accessibilityValue(name == "Speed" ? String(format: "%.1f times", value.wrappedValue) : "\(Int((value.wrappedValue * 100).rounded())) percent")
    }

    private var playlistMenu: some View {
        let playing = model.desktop.displays.first.flatMap { model.playlist(onDisplay: $0.id) }
        return Menu {
            ForEach(model.state.playlists) { p in
                Button {
                    model.play(p)
                } label: {
                    if p.id == playing?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            if let playing {
                Divider()
                Button("Stop “\(playing.name)”") { model.stop(playing) }
            }
        } label: {
            Label(playing.map { "Playlist: \($0.name)" } ?? "Play a playlist", systemImage: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }
}
