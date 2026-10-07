import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    @State private var tab = InspectorTab.controls
    @State private var livePreference: Bool?

    /// With Reduce Motion the preview starts on the still poster.
    private var showLive: Bool { livePreference ?? !reduceMotion }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case controls, adjust, info
        var id: String { rawValue }
        var title: String {
            switch self {
            case .controls: "Controls"
            case .adjust: "Adjust"
            case .info: "Info"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Picker("", selection: $tab) {
                    ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch tab {
                case .controls: ControlsTab(wallpaper: wallpaper)
                case .adjust: AdjustTab(wallpaper: wallpaper)
                case .info: InfoTab(wallpaper: wallpaper)
                }
            }
            .padding(16)
        }
        .onAppear { model.prewarm(wallpaper) }
        .onChange(of: wallpaper.id) { model.prewarm(wallpaper) }
    }

    private var previewSettings: RenderSettings {
        var r = model.renderSettings(wallpaper, display: model.desktop.displays.first?.id ?? AppState.allDisplaysKey)
        r.muted = true
        r.allowVideoFastPath = false
        r.renderScale = 1
        r.fpsCap = 30
        return r
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if showLive {
                        LiveWallpaperPreview(wallpaper: wallpaper, values: model.settings(wallpaper.id).values, settings: previewSettings, paused: model.desktop.pauseReason != nil)
                    } else {
                        PosterThumbnail(wallpaper: wallpaper)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview of \(wallpaper.title)")
                Button {
                    livePreference = !showLive
                } label: {
                    Label(showLive ? "Stop Preview" : "Play Preview", systemImage: showLive ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .padding(6)
                        .background(.black.opacity(0.4), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(showLive ? "Show a still picture instead" : "Play a live preview")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(wallpaper.title).font(.title3.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Label(wallpaper.kind.title, systemImage: wallpaper.kind.symbol)
                    if let author = wallpaper.manifest.author { Text("· \(author)") }
                    if wallpaper.linked { Label("Linked", systemImage: "link").labelStyle(.titleAndIcon) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let d = wallpaper.manifest.description?.text, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            IssueBanner(wallpaper: wallpaper) { tab = .info }
            HStack(spacing: 8) {
                let applied = model.isApplied(wallpaper)
                if model.showsPerDisplayChoices {
                    Menu {
                        ApplyTargetItems(wallpaper: wallpaper)
                    } label: {
                        Label(applied ? "Applied" : "Apply", systemImage: "checkmark.circle")
                    } primaryAction: {
                        model.apply(wallpaper)
                    }
                    .buttonStyle(.glassProminent)
                    .fixedSize()
                    .disabled(!model.canApply(wallpaper))
                    .help(model.prefs.perDisplay ? "Apply to the display this window is on; the arrow picks another" : "Apply to all displays; the arrow picks one")
                } else {
                    Button {
                        model.apply(wallpaper)
                    } label: {
                        Label(applied ? "Applied" : "Apply", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canApply(wallpaper))
                    .help("Put this wallpaper on your desktop (⌘↩)")
                }
                let favorite = model.isFavorite(wallpaper.id)
                Button {
                    model.toggleFavorite(wallpaper.id)
                } label: {
                    Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.fill" : "heart")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(favorite ? .pink : .primary)
                }
                .buttonStyle(.glass)
                .help(favorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)")
                Spacer()
                Menu {
                    WallpaperMenuItems(wallpaper: wallpaper, includesApply: false)
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .help("More actions")
                .menuStyle(.button)
                .buttonStyle(.glass)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.large)
        }
    }
}

struct IssueBanner: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var showAll: () -> Void = {}

    var body: some View {
        let errors = model.library.errors(for: wallpaper.id)
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(errors.count) problem\(errors.count == 1 ? "" : "s") in this wallpaper", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(errors.prefix(4)) { issue in
                    Text(issue.description).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if errors.count > 4 {
                    Button("Show all \(errors.count) in Info", action: showAll)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct ControlsTab: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var presetName = ""
    @State private var naming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if wallpaper.manifest.allControls.isEmpty {
                Text("This wallpaper has no controls of its own. Speed, color, framing and sound are under Adjust.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ControlsView(wallpaper: wallpaper)
                Divider()
                HStack {
                    Menu {
                        let presets = model.settings(wallpaper.id).presets
                        ForEach(presets) { p in
                            Button(p.name) { model.applyPreset(p, to: wallpaper) }
                        }
                        if !presets.isEmpty {
                            Divider()
                            Menu("Delete") {
                                ForEach(presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p, of: wallpaper) } }
                            }
                        }
                        Button("Save Current as Preset…") { naming = true }
                    } label: {
                        Label("Presets", systemImage: "square.stack")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Reset", role: .destructive) { model.resetValues(wallpaper) }
                        .disabled(model.settings(wallpaper.id).values.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                model.savePreset(named: name.isEmpty ? "Preset \(model.settings(wallpaper.id).presets.count + 1)" : name, for: wallpaper)
                presetName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct AdjustTab: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var focusDisplay = AppState.allDisplaysKey

    var body: some View {
        let s = model.settings(wallpaper.id)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Framing")
                Picker("Framing", selection: binding(\.showAll)) {
                    Text("Fill Screen").tag(false)
                    Text("Show All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if s.showAll {
                    Text("The whole picture stays in view, with bars where your display's shape differs from the wallpaper's.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    cropPicker(s)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Motion")
                labeled("Speed", ControlRow.format(s.speed, unit: "x", range: 4)) {
                    Slider(value: binding(\.speed), in: 0.1...3)
                }
                labeled("Parallax", "\(Int((s.parallax * 100).rounded()))%") {
                    Slider(value: binding(\.parallax), in: 0...3)
                }
                let ceiling = model.prefs.frameRateCap
                Picker("Frame rate", selection: binding(\.fpsCap)) {
                    Text("Wallpaper’s own (\(wallpaper.manifest.fps) fps)").tag(0)
                    ForEach([15, 24, 30, 60, 120], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps).disabled(ceiling > 0 && fps > ceiling)
                    }
                }
                if ceiling > 0, model.effectiveFPSCap(s) == ceiling, ceiling < max(s.fpsCap, wallpaper.manifest.fps) {
                    Text("Limited to \(ceiling) fps for every wallpaper in Settings › Performance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Color")
                labeled("Brightness", "\(Int((s.brightness * 100).rounded()))%") { Slider(value: binding(\.brightness), in: 0.3...1.6) }
                labeled("Contrast", "\(Int((s.contrast * 100).rounded()))%") { Slider(value: binding(\.contrast), in: 0.5...1.6) }
                labeled("Saturation", "\(Int((s.saturation * 100).rounded()))%") { Slider(value: binding(\.saturation), in: 0...2) }
                labeled("Warmth", String(format: "%+.0f", s.warmth * 100)) { Slider(value: binding(\.warmth), in: -1...1) }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Sound")
                Toggle("Mute", isOn: binding(\.muted)).toggleStyle(.switch)
                labeled("Volume", "\(Int((s.volume * 100).rounded()))%") { Slider(value: binding(\.volume), in: 0...1) }
                    .disabled(s.muted || model.prefs.globalMute)
                if model.prefs.globalMute {
                    HStack {
                        Text("Every wallpaper is muted in Settings.").font(.caption).foregroundStyle(.secondary)
                        Button("Unmute All") { model.prefs.globalMute = false }.buttonStyle(.link).font(.caption)
                    }
                }
            }

            Button("Reset Adjustments") { model.resetDisplaySettings(wallpaper) }
                .controlSize(.small)
                .disabled(!s.hasDisplayChanges)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func cropPicker(_ s: WallpaperSettings) -> some View {
        if model.desktop.displays.count > 1 {
            Picker("Display", selection: $focusDisplay) {
                Text("All displays").tag(AppState.allDisplaysKey)
                ForEach(model.desktop.displays) { Text($0.name).tag($0.id) }
            }
            .controlSize(.small)
        }
        let display = model.desktop.displays.first { $0.id == focusDisplay } ?? model.desktop.displays.first
        PointPad(
            wallpaper: wallpaper,
            point: s.focus(for: focusDisplay) ?? wallpaper.manifest.focus,
            showsCrop: display?.size ?? CGSize(width: 16, height: 10)
        ) { p in
            model.update(wallpaper.id) { $0.focus[focusDisplay] = [p.x, p.y] }
        }
        Text("Drag to choose what stays in view when your display's shape differs from the wallpaper's.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func binding<T>(_ key: WritableKeyPath<WallpaperSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings(wallpaper.id)[keyPath: key] },
            set: { v in model.update(wallpaper.id) { $0[keyPath: key] = v } }
        )
    }

    private func labeled<C: View>(_ title: String, _ value: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            content()
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }
}

private struct InfoTab: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var size: Int64?
    @State private var stats: [String: FrameStats] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let m = wallpaper.manifest
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Package")
                row("Canvas", "\(Int(m.canvas.width)) × \(Int(m.canvas.height))")
                row("Frame rate", "\(m.fps) fps")
                row("Layers", m.layers.compactMap { l in l["id"]?.string.map { "\($0) (\(l["type"]?.string ?? "?"))" } }.joined(separator: ", "))
                row("Controls", "\(m.allControls.count)")
                row("Size", size.map(\.byteString) ?? "…")
                row("Location", wallpaper.url.path)
                if !m.tags.isEmpty { row("Tags", m.tags.joined(separator: ", ")) }
            }

            let active = model.desktop.displays.filter { $0.wallpaperID == wallpaper.id }
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Performance")
                    ForEach(active) { d in
                        let st = stats[d.id] ?? FrameStats()
                        row(d.name, d.paused ? "Paused" : st.summary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Validation")
                let issues = model.library.issues[wallpaper.id] ?? []
                if model.library.validating.contains(wallpaper.id) {
                    ProgressView().controlSize(.small)
                } else if issues.isEmpty {
                    Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(.green).font(.callout)
                } else {
                    ForEach(issues) { i in
                        Label {
                            Text(i.description).font(.caption.monospaced()).textSelection(.enabled)
                        } icon: {
                            Image(systemName: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(i.severity == .error ? .red : .orange)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Develop")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url]) }
                    Button("Edit Manifest") { NSWorkspace.shared.open(wallpaper.url.appendingPathComponent(Manifest.fileName)) }
                }
                HStack {
                    Button("Revalidate") { model.library.validate(wallpaper) }
                    Button("Regenerate Poster") { model.library.makePoster(wallpaper) }
                        .disabled(model.library.makingPoster.contains(wallpaper.id))
                }
                Button("Copy AI Guide") { AIGuide.copy(for: wallpaper) }
                    .help("Copies the format guide plus this wallpaper's manifest, ready to paste into an AI chat")
                Text(wallpaper.linked ? "Edited in place: changes to these files show up live." : "Tip: File › Add Folder to Edit in Place shows changes to a wallpaper’s files live.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .task(id: wallpaper.id) {
            let url = wallpaper.url
            size = await Task.detached { Paths.directorySize(url) }.value
        }
        .onReceive(timer) { _ in
            var next: [String: FrameStats] = [:]
            for d in model.desktop.displays where d.wallpaperID == wallpaper.id {
                next[d.id] = model.desktop.stats(for: d.id)
            }
            if next != stats { stats = next }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// "All Displays" plus one item per display, checked where the wallpaper already plays.
struct ApplyTargetItems: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        Toggle("All Displays", isOn: Binding(get: { model.isApplied(wallpaper, to: .everywhere) }, set: { _ in model.apply(wallpaper, to: .everywhere) }))
        Divider()
        ForEach(model.desktop.displays) { d in
            Toggle(d.name, isOn: Binding(get: { d.wallpaperID == wallpaper.id }, set: { _ in model.apply(wallpaper, to: .display(d.id)) }))
        }
    }
}

struct WallpaperMenuItems: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var includesApply = true

    var body: some View {
        let canApply = model.canApply(wallpaper)
        if includesApply {
            Button("Apply") { model.apply(wallpaper) }.disabled(!canApply)
            if model.showsPerDisplayChoices {
                Menu("Apply To") { ApplyTargetItems(wallpaper: wallpaper) }.disabled(!canApply)
            }
        }
        Button("Use as Screen Saver") { model.useAsScreenSaver(wallpaper) }.disabled(!canApply)
        Divider()
        Button(model.isFavorite(wallpaper.id) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(wallpaper.id) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url]) }
        Divider()
        Button(wallpaper.linked ? "Remove from Library" : "Move to Trash", role: .destructive) { model.delete(wallpaper) }
    }
}
