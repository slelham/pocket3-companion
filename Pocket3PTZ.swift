import SwiftUI
import AVFoundation
import Carbon.HIToolbox

// Pan/tilt approach follows amirmxt/gimbal-bar (MIT). Zoom uses the same
// UVC camera-terminal path, selector 0x0B, which this Pocket 3 answers.

final class Preview: ObservableObject {
    let session = AVCaptureSession()
    @Published var status = ""
    private let queue = DispatchQueue(label: "pocket3.preview")
    private var configured = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Camera access is off in System Settings" }
                return
            }
            self.queue.async {
                if !self.configured { self.configure() }
                if self.configured, !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first {
            $0.localizedName.localizedCaseInsensitiveContains("pocket") || $0.modelID.contains("VendorID_11427")
        }
        guard let device = found, let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.status = "Pocket 3 camera is not available" }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
        DispatchQueue.main.async { self.status = "" }
    }
}

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    final class LayerView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer
        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> LayerView { LayerView(session: session) }
    func updateNSView(_ nsView: LayerView, context: Context) {}
}

// The USB thread and the UI both write the target. The gimbal is told that
// target again until the readback arrives, instead of trusting one SET.
final class AimTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var pan: Double?
    private var tilt: Double?
    private var zoom: Double?

    func setAim(_ pan: Double, _ tilt: Double) {
        lock.lock()
        self.pan = pan
        self.tilt = tilt
        lock.unlock()
    }

    func setZoom(_ zoom: Double) {
        lock.lock()
        self.zoom = zoom
        lock.unlock()
    }

    func snapshot() -> (Double?, Double?, Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (pan, tilt, zoom)
    }

    func clearAimIf(pan: Double, tilt: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.pan == pan, self.tilt == tilt else { return false }
        self.pan = nil
        self.tilt = nil
        return true
    }

    func clearZoomIf(_ zoom: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.zoom == zoom else { return false }
        self.zoom = nil
        return true
    }
}

@MainActor
final class Gimbal: ObservableObject {
    static let shared = Gimbal()

    @Published var pan = 0.0
    @Published var tilt = 0.0
    @Published var zoom = 100.0
    // Last zoom the camera reported. The slider can sit on a preset while this catches up.
    @Published var zoomNow = 100.0
    @Published var zoomMin = 100.0
    @Published var zoomMax = 400.0
    @Published var connected = false
    @Published var range = ptz_range_t(panMin: -35, panMax: 215, tiltMin: -90, tiltMax: 90)
    // Where the pad and the zoom slider are asking to go. Nil once the camera is there.
    @Published var aimPan: Double?
    @Published var aimTilt: Double?
    @Published var aimZoom: Double?

    @AppStorage("step") var step = 5.0
    @AppStorage("invertPan") var invertPan = false
    @AppStorage("homePan") var homePan = 0.0
    @AppStorage("homeTilt") var homeTilt = 0.0

    // Straight ahead is the middle of the pad. The legal pan range is not
    // symmetric (it runs out to the flipped selfie side), so the pad covers
    // the forward view and the arrows can still walk past it.
    var padPanMin: Double { max(range.panMin, -45) }
    var padPanMax: Double { min(range.panMax, 45) }
    var padTiltMin: Double { max(range.tiltMin, -40) }
    var padTiltMax: Double { min(range.tiltMax, 40) }

    private let usb = DispatchQueue(label: "pocket3.usb")
    private let target = AimTarget()
    private var driving = false
    private var timer: Timer?

    init() {
        refresh()
        usb.async {
            var r = ptz_range_t()
            var zmin: Int32 = 0, zmax: Int32 = 0
            let haveRange = ptz_range(&r) == 0
            let haveZoom = ptz_zoom_range(&zmin, &zmax) == 0
            Task { @MainActor in
                if haveRange { self.range = r }
                if haveZoom, zmax > zmin {
                    self.zoomMin = Double(zmin)
                    self.zoomMax = Double(zmax)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        guard !driving else { return }
        usb.async {
            var p = 0.0, t = 0.0
            var z: Int32 = 0
            let ok = ptz_read(&p, &t, &z) == 0
            Task { @MainActor in
                guard !self.driving else { return }
                self.connected = ok
                if ok {
                    self.pan = p
                    self.tilt = t
                    self.zoomNow = Double(z)
                    if self.aimZoom == nil { self.zoom = Double(z) }
                }
            }
        }
    }

    func go(pan: Double, tilt: Double) {
        let p = min(max(pan, range.panMin), range.panMax)
        let t = min(max(tilt, range.tiltMin), range.tiltMax)
        aimPan = p
        aimTilt = t
        target.setAim(p, t)
        startDrive()
    }

    func nudge(dx: Double, dy: Double) {
        let sign = invertPan ? -1.0 : 1.0
        let basePan = aimPan ?? pan
        let baseTilt = aimTilt ?? tilt
        go(pan: basePan + dx * step * sign, tilt: baseTilt + dy * step)
    }

    func recenter() { go(pan: homePan, tilt: homeTilt) }
    func setHome() { homePan = aimPan ?? pan; homeTilt = aimTilt ?? tilt }

    func setZoom(_ value: Double) {
        let z = min(max(value, zoomMin), zoomMax).rounded()
        zoom = z
        aimZoom = z
        target.setZoom(z)
        startDrive()
    }

    func nudgeZoom(_ delta: Double) { setZoom((aimZoom ?? zoom) + delta) }

    private func startDrive() {
        guard !driving else { return }
        driving = true
        let target = self.target
        usb.async { self.drive(target) }
    }

    nonisolated private func drive(_ target: AimTarget) {
        var link: UnsafeMutableRawPointer?
        guard ptz_link_open(&link) == 0, let link else {
            Task { @MainActor in
                self.driving = false
                self.connected = false
            }
            return
        }
        defer { ptz_link_close(link) }

        var ticks = 0
        var aimStill = 0
        var zoomStill = 0
        var lastZoomSend = -100
        var primed = false
        var prevPan = 0.0, prevTilt = 0.0
        var prevZoom: Int32 = 0
        while ticks < 100 {
            let (wantPan, wantTilt, wantZoom) = target.snapshot()
            if wantPan == nil && wantZoom == nil { break }
            var p = 0.0, t = 0.0
            var z: Int32 = 0
            if ptz_link_read(link, &p, &t, &z) != 0 {
                Task { @MainActor in self.connected = false }
                break
            }
            var aimPending = false
            if let wantPan, let wantTilt {
                if abs(p - wantPan) > 1.05 || abs(t - wantTilt) > 1.05 {
                    aimPending = true
                    if ptz_link_aim(link, wantPan, wantTilt) != 0 { break }
                } else {
                    _ = target.clearAimIf(pan: wantPan, tilt: wantTilt)
                }
            }
            if let wantZoom {
                if abs(Double(z) - wantZoom) > 3 {
                    // One absolute zoom command is enough. Repeating it every
                    // frame holds the lens; zoom out then never leaves the
                    // current stop. Retry only a few times a second.
                    if ticks - lastZoomSend >= 6 {
                        if ptz_link_zoom(link, Int32(wantZoom.rounded())) != 0 { break }
                        lastZoomSend = ticks
                        zoomStill = 0
                    }
                    // The lens reports the new stop about 400ms after the command.
                    if ticks - lastZoomSend >= 8 {
                        if abs(Int(z) - Int(prevZoom)) <= 1 { zoomStill += 1 } else { zoomStill = 0 }
                        if zoomStill >= 20 { _ = target.clearZoomIf(wantZoom) }
                    }
                } else {
                    _ = target.clearZoomIf(wantZoom)
                }
            }
            let hp = p, ht = t, hz = Double(z)
            Task { @MainActor in
                self.connected = true
                self.pan = hp
                self.tilt = ht
                self.zoomNow = hz
                if self.aimZoom == nil { self.zoom = hz }
            }
            if aimPending {
                if primed && abs(p - prevPan) < 0.2 && abs(t - prevTilt) < 0.2 {
                    aimStill += 1
                } else {
                    aimStill = 0
                }
                if aimStill >= 16, let wantPan, let wantTilt {
                    _ = target.clearAimIf(pan: wantPan, tilt: wantTilt)
                }
            } else {
                aimStill = 0
            }
            let (leftPan, _, leftZoom) = target.snapshot()
            if leftPan == nil && leftZoom == nil { break }
            prevPan = p
            prevTilt = t
            prevZoom = z
            primed = true
            ticks += 1
            usleep(50_000)
        }
        Task { @MainActor in
            let (pan, tilt, zoom) = self.target.snapshot()
            self.aimPan = pan
            self.aimTilt = tilt
            self.aimZoom = zoom
            self.driving = false
            if pan != nil || zoom != nil { self.startDrive() }
            else { self.refresh() }
        }
    }
}

enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Task { @MainActor in
                let g = Gimbal.shared
                switch id.id {
                case 1: g.nudge(dx: -1, dy: 0)
                case 2: g.nudge(dx: 1, dy: 0)
                case 3: g.nudge(dx: 0, dy: 1)
                case 4: g.nudge(dx: 0, dy: -1)
                case 5: g.recenter()
                case 6, 9: g.nudgeZoom(-25)
                case 7, 10: g.nudgeZoom(25)
                case 8: g.setZoom(100)
                case 11: g.setZoom(100)
                case 12: g.setZoom(150)
                case 13: g.setZoom(200)
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey)
        let keys = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_ANSI_C,
            kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_0,
            kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadPlus,
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        ]
        for (i, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5033545A), id: UInt32(i + 1)),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

struct Pad: View {
    @ObservedObject var g: Gimbal
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let panMin = g.padPanMin, panMax = g.padPanMax
            let tiltMin = g.padTiltMin, tiltMax = g.padTiltMax
            let spanP = max(panMax - panMin, 1)
            let spanT = max(tiltMax - tiltMin, 1)
            let sign = g.invertPan ? -1.0 : 1.0
            let shownPan = g.aimPan ?? g.pan
            let shownTilt = g.aimTilt ?? g.tilt
            let fx = (min(max(shownPan, panMin), panMax) - panMin) / spanP
            let x = (sign > 0 ? fx : 1 - fx) * w
            let y = (1 - (min(max(shownTilt, tiltMin), tiltMax) - tiltMin) / spanT) * h

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                Circle()
                    .fill(.tint)
                    .frame(width: dragging ? 22 : 16, height: dragging ? 22 : 16)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    var fx = min(max(v.location.x / w, 0), 1)
                    if sign < 0 { fx = 1 - fx }
                    let fy = 1 - min(max(v.location.y / h, 0), 1)
                    g.go(pan: panMin + fx * spanP, tilt: tiltMin + fy * spanT)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ArrowButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ZoomPreset: View {
    let title: String
    let value: Double
    @ObservedObject var g: Gimbal

    private var selected: Bool {
        abs((g.aimZoom ?? g.zoomNow) - value) <= 8
    }

    var body: some View {
        Button(title) { g.setZoom(value) }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
    }
}

struct ZoomStepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(enabled ? 0.08 : 0.03), in: Circle())
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

struct Panel: View {
    @ObservedObject var g = Gimbal.shared
    @StateObject private var preview = Preview()
    @AppStorage("showPreview") private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pocket 3").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(g.connected ? .green : .secondary).frame(width: 6, height: 6)
                        Text(g.connected ? "Webcam connected" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Pan \(Int(g.pan.rounded()))°")
                    Text("Tilt \(Int(g.tilt.rounded()))°")
                    Text(String(format: "Zoom %.2f×", g.zoomNow / 100.0))
                }
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if showPreview {
                ZStack {
                    Rectangle().fill(.black)
                    PreviewView(session: preview.session)
                    if !preview.status.isEmpty {
                        Text(preview.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                }
                .frame(width: 288, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Pad(g: g)
            Text("Straight ahead is the center")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 16) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        ArrowButton(symbol: "chevron.up") { g.nudge(dx: 0, dy: 1) }
                        Color.clear.frame(width: 34, height: 34)
                    }
                    GridRow {
                        ArrowButton(symbol: "chevron.left") { g.nudge(dx: -1, dy: 0) }
                        ArrowButton(symbol: "scope") { g.recenter() }
                        ArrowButton(symbol: "chevron.right") { g.nudge(dx: 1, dy: 0) }
                    }
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        ArrowButton(symbol: "chevron.down") { g.nudge(dx: 0, dy: -1) }
                        Color.clear.frame(width: 34, height: 34)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step").font(.caption).foregroundStyle(.secondary)
                    Picker("Step", selection: $g.step) {
                        Text("1°").tag(1.0)
                        Text("5°").tag(5.0)
                        Text("15°").tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button("Set as Center") { g.setHome() }.controlSize(.small)
                    Toggle("Invert Pan", isOn: $g.invertPan).toggleStyle(.checkbox).controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                ZoomPreset(title: "1×", value: 100, g: g)
                ZoomPreset(title: "1.5×", value: 150, g: g)
                ZoomPreset(title: "2×", value: 200, g: g)
            }

            HStack(spacing: 8) {
                ZoomStepButton(symbol: "minus", enabled: (g.aimZoom ?? g.zoom) > g.zoomMin + 0.5) {
                    g.nudgeZoom(-25)
                }
                Slider(value: Binding(get: { g.zoom }, set: { g.setZoom($0) }), in: g.zoomMin...g.zoomMax, step: 1)
                ZoomStepButton(symbol: "plus", enabled: (g.aimZoom ?? g.zoom) < g.zoomMax - 0.5) {
                    g.nudgeZoom(25)
                }
            }

            Divider()
            HStack {
                Text("⌃⌥ arrows · ⌃⌥C center · ⌃⌥ −/+ zoom · ⌃⌥1 2 3 presets")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Live preview", isOn: $showPreview)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: showPreview) { _, on in
                    if on { preview.start() } else { preview.stop() }
                }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { if showPreview { preview.start() } }
        .onDisappear { preview.stop() }
    }
}

@main
struct Pocket3PTZApp: App {
    init() { HotKeys.register() }
    var body: some Scene {
        MenuBarExtra("Pocket 3", systemImage: "camera.viewfinder") {
            Panel()
        }
        .menuBarExtraStyle(.window)
    }
}
