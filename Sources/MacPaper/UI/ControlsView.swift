import AppKit
import SwiftUI

/// Draws a wallpaper's declared controls natively. Values go to the app's state, never into the package.
struct ControlsView: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var quickOnly = false

    var body: some View {
        let values = model.values(for: wallpaper)
        let controls = quickOnly ? wallpaper.manifest.allControls.filter(\.quick) : wallpaper.manifest.controls
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                ControlNode(wallpaper: wallpaper, control: control, values: values, compact: quickOnly)
            }
        }
    }
}

private struct ControlNode: View {
    let wallpaper: Wallpaper
    let control: Control
    let values: [String: JSONValue]
    let compact: Bool
    @State private var expanded: Bool?

    var body: some View {
        if control.kind == .section {
            let open = Binding(get: { expanded ?? !control.collapsed }, set: { expanded = $0 })
            DisclosureGroup(isExpanded: open) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(control.children.enumerated()), id: \.offset) { _, child in
                        ControlNode(wallpaper: wallpaper, control: child, values: values, compact: compact)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 2)
            } label: {
                Text(control.label.text).font(.callout.weight(.semibold))
            }
        } else if control.isVisible(values: values) {
            ControlRow(wallpaper: wallpaper, control: control, value: values[control.id] ?? .null, compact: compact)
                .transition(.opacity)
        }
    }
}

struct ControlRow: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let control: Control
    let value: JSONValue
    var compact = false

    private func set(_ v: JSONValue) { model.setValue(v, control: control.id, of: wallpaper) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch control.kind {
            case .toggle:
                Toggle(control.label.text, isOn: Binding(get: { value.bool ?? false }, set: { set(.bool($0)) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            case .slider:
                slider
            case .color:
                ColorPicker(control.label.text, selection: Binding(
                    get: { Color(nsColor: (RGBA(value) ?? .white).nsColor) },
                    set: { set(RGBA(NSColor($0)).json) }
                ), supportsOpacity: control.alpha)
            case .point:
                Text(control.label.text).font(.callout)
                PointPad(wallpaper: wallpaper, point: SIMD2<Double>(value) ?? SIMD2(0.5, 0.5)) { p in set(JSONValue([p.x, p.y])) }
            case .choice:
                choice
            case .section:
                EmptyView()
            }
            if let help = control.help?.text, !compact {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(control.help?.text ?? "")
    }

    private var slider: some View {
        let number = value.number ?? control.min
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.label.text).font(.callout)
                Spacer()
                Text(Self.format(number, unit: control.unit, range: control.max - control.min))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Group {
                if let step = control.step {
                    Slider(value: Binding(get: { number }, set: { set(.number($0)) }), in: control.min...control.max, step: step)
                } else {
                    Slider(value: Binding(get: { number }, set: { set(.number($0)) }), in: control.min...control.max)
                }
            }
            .accessibilityLabel(control.label.text)
            .accessibilityValue(Self.format(number, unit: control.unit, range: control.max - control.min))
        }
        .controlSize(.small)
    }

    static func format(_ v: Double, unit: String?, range: Double) -> String {
        switch unit {
        case "%": return "\(Int((v * 100).rounded()))%"
        case "x": return String(format: "%.2g×", v)
        case "s": return String(format: "%.1f s", v)
        case "°": return "\(Int(v.rounded()))°"
        case "px": return "\(Int(v.rounded())) px"
        default: return range >= 20 ? "\(Int(v.rounded()))" : String(format: range >= 2 ? "%.1f" : "%.2f", v)
        }
    }

    @ViewBuilder private var choice: some View {
        let selected = Binding<Int>(
            get: { control.options.firstIndex { $0.value == value } ?? 0 },
            set: { set(control.options[$0].value) }
        )
        HStack {
            if control.style != .menu || compact {
                Text(control.label.text).font(.callout)
                Spacer()
            }
            if !compact, control.options.count > 1 { CycleMenu(wallpaper: wallpaper, control: control) }
        }
        switch control.style {
        case .gallery where !compact || control.options.count <= 12:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 64 : 92), spacing: 8)], spacing: 8) {
                ForEach(Array(control.options.enumerated()), id: \.offset) { i, option in
                    Button { selected.wrappedValue = i } label: {
                        VStack(spacing: 4) {
                            Thumbnail(url: option.thumb.flatMap(wallpaper.file), stamp: wallpaper.stamp, maxSide: 300)
                                .aspectRatio(16 / 10, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(selected.wrappedValue == i ? Color.accentColor : .clear, lineWidth: 2.5)
                                }
                            if !compact {
                                Text(option.label.text).font(.caption).lineLimit(1)
                                    .foregroundStyle(selected.wrappedValue == i ? .primary : .secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(option.label.text)
                }
            }
        case .segmented:
            Picker(control.label.text, selection: selected) {
                ForEach(Array(control.options.enumerated()), id: \.offset) { i, o in Text(o.label.text).tag(i) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .list:
            Picker(control.label.text, selection: selected) {
                ForEach(Array(control.options.enumerated()), id: \.offset) { i, o in Text(o.label.text).tag(i) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        default:
            Picker(control.label.text, selection: selected) {
                ForEach(Array(control.options.enumerated()), id: \.offset) { i, o in Text(o.label.text).tag(i) }
            }
            .pickerStyle(.menu)
            .labelsHidden(compact)
        }
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// Changes a choice control on its own — e.g. a new outfit every 30 minutes, or each time the video ends.
private struct CycleMenu: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let control: Control

    private static let afterClip = -1

    var body: some View {
        let cycle = model.settings(wallpaper.id).cycles(for: wallpaper.manifest)[control.id]
        let hasVideo = wallpaper.manifest.layers.contains { $0["type"]?.string == "video" }
        Menu {
            Picker("Change automatically", selection: Binding(
                get: { cycle.map { $0.afterClip ? Self.afterClip : $0.minutes } ?? 0 },
                set: { m in
                    model.update(wallpaper.id) {
                        guard m != 0 else { $0.cycles[control.id] = CycleSetting(); return }
                        var c = cycle ?? CycleSetting()
                        c.afterClip = m == Self.afterClip
                        c.minutes = max(m, 0)
                        $0.cycles[control.id] = c
                    }
                }
            )) {
                Text("Never").tag(0)
                if hasVideo { Text("When the Video Ends").tag(Self.afterClip) }
                ForEach([5, 15, 30, 60, 180, 720], id: \.self) { m in
                    Text(m < 60 ? "Every \(m) minutes" : m == 60 ? "Every hour" : "Every \(m / 60) hours").tag(m)
                }
            }
            .pickerStyle(.inline)
            if cycle != nil {
                Toggle("Shuffle", isOn: Binding(
                    get: { cycle?.shuffle ?? false },
                    set: { s in
                        guard var c = cycle else { return }
                        c.shuffle = s
                        model.update(wallpaper.id) { $0.cycles[control.id] = c }
                    }
                ))
                Menu("Include") {
                    ForEach(Array(control.options.enumerated()), id: \.offset) { _, option in
                        Toggle(option.label.text, isOn: Binding(
                            get: { !(cycle?.skip.contains(option.value) ?? false) },
                            set: { on in setIncluded(option.value, on) }
                        ))
                    }
                }
            }
            Divider()
            Button("Next Now") { model.advance(control, of: wallpaper, cycle: cycle) }
        } label: {
            Image(systemName: cycle == nil ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(cycle == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(cycle.map { $0.afterClip ? "Changes when the video ends" : "Changes every \($0.minutes) min" } ?? "Change automatically")
    }

    private func setIncluded(_ value: JSONValue, _ on: Bool) {
        model.update(wallpaper.id) { s in
            guard var c = s.cycles(for: wallpaper.manifest)[control.id] else { return }
            c.skip.removeAll { $0 == value }
            if !on { c.skip.append(value) }
            guard c.skip.count < control.options.count else { return }
            s.cycles[control.id] = c
        }
    }
}

/// A draggable point over the wallpaper's poster; used for point controls and the crop focus.
struct PointPad: View {
    let wallpaper: Wallpaper
    let point: SIMD2<Double>
    var showsCrop: CGSize?
    let onChange: (SIMD2<Double>) -> Void

    var body: some View {
        let canvas = wallpaper.manifest.canvas
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                PosterThumbnail(wallpaper: wallpaper, maxSide: 800)
                if let display = showsCrop {
                    let r = SceneEncoder.region(canvas: canvas, output: display, focus: point)
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(Color.white.opacity(0.08))
                        .frame(width: size.width * CGFloat(r.z), height: size.height * CGFloat(r.w))
                        .offset(x: size.width * CGFloat(r.x), y: size.height * CGFloat(r.y))
                        .shadow(radius: 2)
                }
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: size.width * point.x - 7, y: size.height * point.y - 7)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let x = min(max(g.location.x / max(size.width, 1), 0), 1)
                let y = min(max(g.location.y / max(size.height, 1), 0), 1)
                onChange(SIMD2(Double(x), Double(y)))
            })
        }
        .aspectRatio(canvas.width / max(canvas.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension RGBA {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
