import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        let creator = model.creator
        Group {
            if let draft = creator.draft {
                DraftEditor(draft: draft)
            } else {
                landing
            }
        }
        .navigationTitle("Create")
        .navigationSubtitle(creator.draft == nil ? "Turn videos and images into live wallpapers" : creator.draft!.title)
    }

    private var landing: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop a video or an image").font(.title.weight(.semibold))
                    Text("Videos become seamless loops — drop several to make variants you can switch between. Images come alive with depth, parallax and effects.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Button("Choose Files…") {
                        if let urls = openPanel(types: MediaTools.videoTypes + MediaTools.imageTypes, multiple: true, message: "Choose videos or an image") {
                            model.creator.begin(with: urls)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    if let e = model.creator.error {
                        Text(e).foregroundStyle(.red).font(.callout)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: 300)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                        .background(dropTargeted ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadURLs(providers) { model.importItems($0) }
                    return true
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Making wallpapers with AI")
                    tip("1.circle", "Generate a still at your display's shape (16:10 for a MacBook, 16:9 for most monitors), then upscale it to at least 4K.")
                    tip("2.circle", "For motion, run image-to-video with the same image as both the first and last frame — the clip then loops with no seam. Upscale to 4K.")
                    tip("3.circle", "Drop the result here. Or turn on a crossfade loop below if the clip's ends don't match.")
                    tip("4.circle", "Want something custom? Use Add › New from Template, then ask an AI to write the shader — Copy AI Guide gives it the full format.")
                }
                .frame(maxWidth: 640, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Effects you can add")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(EffectCatalog.all) { e in
                            HStack(spacing: 10) {
                                Image(systemName: e.symbol).frame(width: 22).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.name).font(.callout.weight(.medium))
                                    Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: 900)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .font(.callout)
    }
}

private struct DraftEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: CreatorDraft
    @State private var painting: DraftEffect.ID?
    @State private var confirmDiscard = false

    var body: some View {
        let creator = model.creator
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    Text("Drag the dot to choose what stays in view on displays with a different shape.")
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.analyzing {
                        Label("Analyzing…", systemImage: "sparkle.magnifyingglass").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 360, maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("Title", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    if draft.isVideo { videoOptions } else { imageOptions }
                    effectsSection
                    if let e = creator.error {
                        Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                    footer
                }
                .padding(24)
            }
            .frame(width: 400)
        }
        .confirmationDialog("Discard this wallpaper?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { model.creator.cancel() }
        } message: {
            Text("Your title, effects and masks for it will be lost.")
        }
        .sheet(item: Binding(get: { painting.flatMap { id in draft.effects.first { $0.id == id } } }, set: { painting = $0?.id })) { effect in
            MaskPainter(
                image: draft.preview,
                subject: draft.subjectMask,
                hint: effect.definition.maskHint,
                initial: effect.mask
            ) { mask in
                if let i = draft.effects.firstIndex(where: { $0.id == effect.id }) { draft.effects[i].mask = mask }
                painting = nil
            }
        }
    }

    private var preview: some View {
        ZStack {
            if let image = draft.preview {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        Circle()
                            .fill(Color.accentColor)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .frame(width: 16, height: 16)
                            .shadow(radius: 3)
                            .offset(x: geo.size.width * draft.focus.x - 8, y: geo.size.height * draft.focus.y - 8)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        draft.focus = SIMD2(min(max(g.location.x / geo.size.width, 0), 1), min(max(g.location.y / geo.size.height, 0), 1))
                    })
                }
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { if draft.analyzing { ProgressView() } else { Text("No preview").foregroundStyle(.secondary) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: draft.sources.count > 1 ? "Variants" : "Video")
            ForEach($draft.sources) { $source in
                HStack(spacing: 10) {
                    Group {
                        if let p = source.preview { Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(.quaternary) }
                    }
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $source.label).textFieldStyle(.plain).font(.callout.weight(.medium))
                        Text(detail(source)).font(.caption).foregroundStyle(source.playable && source.efficient ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if draft.sources.count > 1 {
                        Button { draft.sources.removeAll { $0.id == source.id } } label: {
                            Label("Remove \(source.label)", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this variant")
                    }
                }
            }
            Button("Add Variant…", systemImage: "plus") {
                if let urls = openPanel(types: MediaTools.videoTypes, multiple: true, message: "Each video becomes a variant you can switch between") {
                    let added = urls.map { DraftSource(url: $0, isVideo: true, label: Creator.label(for: $0)) }
                    draft.sources += added
                    Task { await Creator.analyze(draft) }
                }
            }
            .controlSize(.small)
            Picker("Seamless loop", selection: $draft.loopCrossfade) {
                Text("Off").tag(0.0)
                Text("0.5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
            }
            .pickerStyle(.segmented)
            Text(draft.loopCrossfade == 0 ? "Use when the clip already starts and ends on the same frame." : "The end dissolves into the start, so the loop point disappears. The clip gets \(draft.loopCrossfade.formatted()) s shorter.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Resolution", selection: $draft.quality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private func detail(_ s: DraftSource) -> String {
        guard s.size.width > 0 || !s.playable else { return "Reading…" }
        if !s.playable { return MediaTools.ffmpeg == nil ? "Needs ffmpeg to convert (brew install ffmpeg)" : "Will be converted to HEVC" }
        var t = "\(Int(s.size.width))×\(Int(s.size.height)) · \(s.duration.formatted(.number.precision(.fractionLength(1)))) s"
        if !s.efficient { t += " · will convert to HEVC" }
        return t
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Depth & motion")
            Picker("Depth", selection: $draft.depthMode) {
                ForEach(DepthMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.depthMode) { _, mode in
                if mode == .file, draft.depthFile == nil {
                    if let url = openPanel(types: [.png, .jpeg, .heic], multiple: false, message: "Choose a grayscale depth map (white = near)")?.first {
                        draft.depthFile = url
                    } else {
                        draft.depthMode = .subject
                    }
                }
            }
            Text(draft.depthMode == .subject ? "Finds the subject on-device and lifts it off the background." : draft.depthMode == .file ? (draft.depthFile?.lastPathComponent ?? "") : "The image stays flat.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.depthMode != .none {
                LabeledSlider(title: "Depth strength", value: $draft.depthStrength, range: 0...0.08, display: "\(Int((draft.depthStrength / 0.08 * 100).rounded()))%")
            }
            LabeledSlider(title: "Drift", value: $draft.drift, range: 0...1, display: "\(Int(draft.drift * 100))%")
            Text("Slow automatic sway, so depth shows even when you're not moving the pointer — and in the screen saver.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Effects")
            ForEach(draft.effects) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.definition.symbol).frame(width: 20).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.definition.name).font(.callout.weight(.medium))
                        if e.definition.usesMask {
                            Text(e.mask == nil ? "Everywhere — paint to limit it" : "Limited to the painted area")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if e.definition.usesMask {
                        Button("Paint") { painting = e.id }.controlSize(.small)
                    }
                    Button { draft.effects.removeAll { $0.id == e.id } } label: {
                        Label("Remove \(e.definition.name)", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this effect")
                }
            }
            Menu {
                Section("Shaders") {
                    ForEach(EffectCatalog.shaders) { def in Button(def.name, systemImage: def.symbol) { draft.add(def) } }
                }
                Section("Particles") {
                    ForEach(EffectCatalog.particles) { def in Button(def.name, systemImage: def.symbol) { draft.add(def) } }
                }
            } label: {
                Label("Add Effect", systemImage: "plus")
            }
            .fixedSize()
            Text("Every effect gets its own controls in the inspector, and can be switched off there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        let creator = model.creator
        return VStack(alignment: .leading, spacing: 10) {
            if creator.busy {
                ProgressView(value: creator.progress) { Text(creator.status).font(.callout) }
            }
            HStack {
                if creator.busy {
                    Button("Stop") { creator.cancelBuild() }
                        .help("Stop creating; your choices are kept")
                } else {
                    Button("Discard") {
                        if draft.isEdited { confirmDiscard = true } else { creator.cancel() }
                    }
                }
                Spacer()
                Button {
                    creator.build()
                } label: {
                    Label("Create Wallpaper", systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
                .disabled(creator.busy || draft.analyzing || draft.sources.isEmpty || (draft.sources.contains { !$0.playable } && MediaTools.ffmpeg == nil))
            }
            .controlSize(.large)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(display).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
        .controlSize(.small)
    }
}
