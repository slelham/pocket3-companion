import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import Carbon.HIToolbox

// Pan/tilt approach follows amirmxt/gimbal-bar (MIT). Zoom uses the same
// UVC camera-terminal path, selector 0x0B, which this Pocket 3 answers.

final class Preview: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = Preview()

    let session = AVCaptureSession()
    @Published var status = ""
    @Published var picture = ""
    @Published var popped = false

    private let queue = DispatchQueue(label: "pocket3.preview")
    private let samples = DispatchQueue(label: "pocket3.frames")
    private var configured = false
    private var camera: AVCaptureDevice?
    private var dataOutput: AVCaptureVideoDataOutput?
    private let stateLock = NSLock()
    private var holds = Set<String>()
    private var menuVisible = false
    /// Bumped on every acquire and release so a late stop cannot
    /// shut the camera after a newer start.
    private var runTicket = 0
    private let frameLock = NSLock()
    private var latest: Double?
    private var waiter: DispatchSemaphore?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionFailed(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    func acquire(_ id: String) {
        stateLock.lock()
        holds.insert(id)
        runTicket += 1
        let ticket = runTicket
        stateLock.unlock()
        start(ticket)
    }

    func release(_ id: String) {
        stateLock.lock()
        holds.remove(id)
        let idle = holds.isEmpty
        runTicket += 1
        let ticket = runTicket
        stateLock.unlock()
        if id == "sweep" {
            queue.async { self.removeDataOutput() }
        }
        if idle { stop(ticket) }
    }

    func permitCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.status = "Camera access is off in System Settings"
                    return
                }
                self.status = ""
                self.acquire("menu")
            }
        }
    }

    /// Applies the saved 1080 or 4K choice. The camera's own default is a
    /// vertical 1080 frame, which sits in the middle of the wide preview.
    func useCaptureSize() {
        keepCaptureSize()
    }

    /// Puts the saved size back after the session starts, after a configuration
    /// batch, or after the preview layer is attached or removed. Disconnecting
    /// that layer while the session is running selects portrait 1080 again.
    func keepCaptureSize() {
        queue.async {
            guard self.configured else { return }
            self.applyFormat()
        }
    }

    func setMenuAttached(_ on: Bool) {
        stateLock.lock()
        menuVisible = on
        stateLock.unlock()
    }

    func menuWantsPicture() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return menuVisible
    }

    /// One sharpness sample from the next frame. `discard` throws away a frame
    /// that may have been captured before the lens settled. The frame grabber
    /// is added here, not when the preview opens, so the picture still starts.
    func measure(timeout: TimeInterval, discard: Bool) -> Double? {
        let ready = DispatchSemaphore(value: 0)
        queue.async {
            if !self.configured { self.configure() }
            self.ensureDataOutput()
            if self.configured, !self.session.isRunning {
                _ = p3_session_start(Unmanaged.passUnretained(self.session).toOpaque())
            }
            if self.configured { self.applyFormat() }
            ready.signal()
        }
        if ready.wait(timeout: .now() + 2) != .success { return nil }
        if discard { _ = waitFrame(min(timeout, 0.45)) }
        let score = waitFrame(timeout)
        return score
    }

    private func waitFrame(_ timeout: TimeInterval) -> Double? {
        let sem = DispatchSemaphore(value: 0)
        frameLock.lock()
        latest = nil
        waiter = sem
        frameLock.unlock()
        let got = sem.wait(timeout: .now() + timeout) == .success
        frameLock.lock()
        if waiter === sem { waiter = nil }
        let value = latest
        frameLock.unlock()
        return got ? value : nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let score = sharpness(buffer)
        frameLock.lock()
        latest = score
        waiter?.signal()
        waiter = nil
        frameLock.unlock()
    }

    private func sharpness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 16, h > 16 else { return 0 }
        var sum = 0.0
        var n = 0
        var y = h / 5
        let yEnd = h * 4 / 5
        while y + 2 < yEnd {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            let next = base.advanced(by: (y + 2) * stride).assumingMemoryBound(to: UInt8.self)
            var x = w / 5
            let xEnd = w * 4 / 5
            while x + 2 < xEnd {
                let g = Int(row[x * 4 + 1])
                let gx = Int(row[(x + 2) * 4 + 1])
                let gy = Int(next[x * 4 + 1])
                sum += Double(abs(g - gx) + abs(g - gy))
                x += 4
                n += 1
            }
            y += 4
        }
        return n > 0 ? sum / Double(n) : 0
    }

    private func start(_ ticket: Int) {
        DispatchQueue.main.async {
            let auth = AVCaptureDevice.authorizationStatus(for: .video)
            if auth == .denied || auth == .restricted {
                self.status = "Camera access is off in System Settings"
                return
            }
            if auth == .notDetermined {
                self.status = "Allow camera access to see the picture"
                return
            }
            self.queue.async {
                self.stateLock.lock()
                let current = self.runTicket
                let want = !self.holds.isEmpty
                self.stateLock.unlock()
                guard want, current == ticket else { return }
                if !self.configured { self.configure() }
                guard self.configured else { return }
                if !self.session.isRunning {
                    _ = p3_session_start(Unmanaged.passUnretained(self.session).toOpaque())
                }
                guard self.session.isRunning else {
                    DispatchQueue.main.async { self.status = "Couldn't open the Pocket 3 picture" }
                    return
                }
                // Starting selects the camera's portrait 1080. Set the wide
                // size after that, or the preview stays a strip in the middle.
                self.applyFormat()
            }
        }
    }

    private func stop(_ ticket: Int) {
        queue.async {
            self.stateLock.lock()
            let current = self.runTicket
            let want = !self.holds.isEmpty
            self.stateLock.unlock()
            guard current == ticket, !want, self.session.isRunning else { return }
            _ = p3_session_stop(Unmanaged.passUnretained(self.session).toOpaque())
            // The chosen size survives the stop. Put it back in case the
            // preview layer was disconnected first and selected portrait 1080.
            self.applyFormat()
        }
    }

    private func configure() {
        if configured { return }
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first {
            $0.localizedName.localizedCaseInsensitiveContains("pocket") || $0.modelID.contains("VendorID_11427")
        }
        guard let device = found else {
            DispatchQueue.main.async { self.status = "Pocket 3 is not available" }
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            let busy = device.isInUseByAnotherApplication
            DispatchQueue.main.async {
                self.status = busy ? "Pocket 3 is in use by another app" : "Couldn't open the Pocket 3 picture"
            }
            return
        }
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "Couldn't open the Pocket 3 picture" }
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        camera = device
        configured = true
        // Do not set the format here. The first startRunning selects portrait
        // 1080, and a later begin/commit does it again. applyFormat runs after
        // the session is running and is never wrapped in that batch.
    }

    /// Wide 1080 or 4K at 30 fps or below. 4K above 30 fps is listed by this
    /// camera and does not deliver a picture over USB. The lower-bandwidth
    /// 420v format is preferred over uncompressed 2vuy.
    private func chooseFormat(on device: AVCaptureDevice, size: String) -> (format: AVCaptureDevice.Format, fps: Int32)? {
        let wantW: Int32 = size == "4k" ? 3840 : 1920
        let wantH: Int32 = size == "4k" ? 2160 : 1080
        let wanted = [30, 25, 24]
        let matches: [(AVCaptureDevice.Format, Int32, Bool)] = device.formats.compactMap { format in
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dim.width == wantW, dim.height == wantH else { return nil }
            let rates = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate.rounded()) }
            guard let fps = wanted.first(where: { rates.contains($0) }) else { return nil }
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let preferred = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return (format, Int32(fps), preferred)
        }
        guard let best = matches.sorted(by: { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 && !rhs.2 }
            return lhs.1 > rhs.1
        }).first else { return nil }
        return (best.0, best.1)
    }

    /// Sets the wide 1080 or 4K format directly. Wrapping this in
    /// beginConfiguration/commitConfiguration makes the camera show the new
    /// size for a moment and then return to portrait 1080, while the control
    /// still says 4K. Must run on the preview queue.
    private func applyFormat() {
        applyFormat(attempt: 0)
    }

    private func applyFormat(attempt: Int) {
        guard let camera else { return }
        let size = UserDefaults.standard.string(forKey: "captureSize") ?? "1080"
        guard let choice = chooseFormat(on: camera, size: size) else {
            DispatchQueue.main.async { self.status = "That resolution is not available" }
            return
        }
        let rc = p3_apply_format(
            Unmanaged.passUnretained(camera).toOpaque(),
            Unmanaged.passUnretained(choice.format).toOpaque(),
            choice.fps
        )
        let dim = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let fps = p3_active_fps(Unmanaged.passUnretained(camera).toOpaque())
        let wantW: Int32 = size == "4k" ? 3840 : 1920
        let wantH: Int32 = size == "4k" ? 2160 : 1080
        if rc == 0, dim.width == wantW, dim.height == wantH {
            let width = dim.width
            let height = dim.height
            DispatchQueue.main.async {
                self.notePicture(width: width, height: height, fps: fps)
                self.clearPictureStatus()
            }
            return
        }
        if attempt < 1 {
            applyFormat(attempt: 1)
            return
        }
        DispatchQueue.main.async {
            if rc != 0 {
                self.status = "Couldn't switch the picture size"
                return
            }
            let actual = (dim.width == 3840 && dim.height == 2160) ? "4k" : "1080"
            if UserDefaults.standard.string(forKey: "captureSize") != actual {
                UserDefaults.standard.set(actual, forKey: "captureSize")
            }
            self.status = "Camera stayed on \(dim.width)×\(dim.height)"
            self.notePicture(width: dim.width, height: dim.height, fps: fps)
        }
    }

    private func notePicture(width: Int32, height: Int32, fps: Double) {
        if fps >= 1 {
            picture = "\(width)×\(height) · \(Int(fps.rounded())) fps"
        } else {
            picture = "\(width)×\(height)"
        }
    }

    private func clearPictureStatus() {
        if status == "That resolution is not available"
            || status == "Couldn't switch the picture size"
            || status.hasPrefix("Camera stayed on") {
            status = ""
        }
    }

    /// Frames for autofocus. Added only while a sweep is measuring, then
    /// removed. Leaving this output on the preview session turned the picture black.
    private func ensureDataOutput() {
        if dataOutput != nil { return }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: samples)
        session.beginConfiguration()
        if session.canAddOutput(output) {
            session.addOutput(output)
            dataOutput = output
        }
        session.commitConfiguration()
        // Adding an output batches a configuration, which drops the camera
        // back to portrait 1080. Put the selected size back immediately.
        applyFormat()
    }

    private func removeDataOutput() {
        guard let output = dataOutput else { return }
        output.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        session.removeOutput(output)
        session.commitConfiguration()
        dataOutput = nil
        applyFormat()
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        let busy = (session.inputs.first as? AVCaptureDeviceInput)?.device.isInUseByAnotherApplication ?? false
        DispatchQueue.main.async {
            self.status = busy ? "Pocket 3 is in use by another app" : "Couldn't open the Pocket 3 picture"
        }
    }

    @objc private func sessionFailed(_ note: Notification) {
        DispatchQueue.main.async { self.status = "Couldn't open the Pocket 3 picture" }
    }
}

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    /// The layer is created with the session and resized to the view.
    /// The menu builds this view at zero size first, so layout has to
    /// apply the real size or the picture stays a speck in the middle.
    final class LayerView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspect
            previewLayer.backgroundColor = NSColor.black.cgColor
            previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(previewLayer)
            // Attaching this layer to a running session selects portrait 1080.
            Preview.shared.keepCaptureSize()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            previewLayer.videoGravity = .resizeAspect
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView { LayerView(session: session) }

    func updateNSView(_ nsView: LayerView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
            Preview.shared.keepCaptureSize()
        }
    }

    /// The menu will not open a second time if this layer is still attached
    /// when the panel closes. Disconnecting it while the session is running
    /// selects portrait 1080, so the saved size is put back afterwards.
    static func dismantleNSView(_ nsView: LayerView, coordinator: ()) {
        nsView.previewLayer.session = nil
        nsView.previewLayer.removeFromSuperlayer()
        Preview.shared.keepCaptureSize()
    }

    /// Never echo an infinite proposal. That collapsed the preview to nothing.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerView, context: Context) -> CGSize? {
        func finite(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite, value > 1 else { return fallback }
            return value
        }
        return CGSize(width: finite(proposal.width, fallback: 296), height: finite(proposal.height, fallback: 167))
    }
}

/// Menu-bar apps are not active, so a normal title-bar drag never starts
/// unless the window is allowed to become key.
final class PreviewPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct WindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragWell() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragWell: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The whole control panel, in a window that stays on the desktop.
final class PreviewWindow: NSObject, NSWindowDelegate {
    static let shared = PreviewWindow()
    private var window: NSWindow?
    private let originKey = "panelWindowOrigin"

    func open() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: Panel(floating: true))
        let size = NSSize(width: 320, height: max(host.fittingSize.height, 360))
        let w = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Pocket3 Companion"
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.isMovable = true
        w.hidesOnDeactivate = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.delegate = self
        w.setFrameOrigin(clampedOrigin(size: w.frame.size))
        if UserDefaults.standard.bool(forKey: "showPreview") {
            Preview.shared.acquire("window")
        }
        Preview.shared.popped = true
        window = w
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func fit(height: CGFloat) {
        guard let window, height > 80 else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        if abs(content.height - height) < 2, abs(content.width - 320) < 2 { return }
        let top = window.frame.maxY
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 320, height: height))
        var next = window.frame
        next.size = frame.size
        next.origin.y = top - next.height
        let vis = (window.screen ?? NSScreen.main)?.visibleFrame
        if let vis {
            next.origin.x = min(max(next.origin.x, vis.minX + 8), vis.maxX - next.width - 8)
            next.origin.y = min(max(next.origin.y, vis.minY + 8), vis.maxY - next.height - 8)
        }
        window.setFrame(next, display: true)
    }

    private func clampedOrigin(size: NSSize) -> NSPoint {
        let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var origin = NSPoint(x: vis.maxX - size.width - 16, y: vis.maxY - size.height - 16)
        if let raw = UserDefaults.standard.string(forKey: originKey) {
            let saved = NSPointFromString(raw)
            if saved.x != 0 || saved.y != 0 { origin = saved }
        }
        origin.x = min(max(origin.x, vis.minX + 8), max(vis.minX + 8, vis.maxX - size.width - 8))
        origin.y = min(max(origin.y, vis.minY + 8), max(vis.minY + 8, vis.maxY - size.height - 8))
        return origin
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: originKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: originKey)
        if w == window { window = nil }
        let preview = Preview.shared
        if preview.menuWantsPicture(), UserDefaults.standard.bool(forKey: "showPreview") {
            preview.acquire("menu")
        }
        preview.release("window")
        preview.popped = false
    }
}

// The USB thread and the UI both write the target. The gimbal is told that
// target again until the readback arrives, instead of trusting one SET.
struct Shot {
    var pan: Double?
    var tilt: Double?
    var zoom: Double?
    var roll: Double?
    var focus: Double?
    var focusAuto: Int?
    var idle: Bool { pan == nil && zoom == nil && roll == nil && focus == nil && focusAuto == nil }
}

final class AimTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var shot = Shot()

    func setAim(_ pan: Double, _ tilt: Double) {
        lock.lock()
        shot.pan = pan
        shot.tilt = tilt
        lock.unlock()
    }

    func setZoom(_ zoom: Double) {
        lock.lock()
        shot.zoom = zoom
        lock.unlock()
    }

    func setRoll(_ roll: Double) {
        lock.lock()
        shot.roll = roll
        lock.unlock()
    }

    func setFocus(_ focus: Double) {
        lock.lock()
        shot.focus = focus
        lock.unlock()
    }

    func setFocusAuto(_ on: Int) {
        lock.lock()
        shot.focusAuto = on
        lock.unlock()
    }

    func clearFocus() {
        lock.lock()
        shot.focus = nil
        lock.unlock()
    }

    func clearFocusAuto() {
        lock.lock()
        shot.focusAuto = nil
        lock.unlock()
    }

    func snapshot() -> Shot {
        lock.lock()
        defer { lock.unlock() }
        return shot
    }

    func clearAimIf(pan: Double, tilt: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shot.pan == pan, shot.tilt == tilt else { return false }
        shot.pan = nil
        shot.tilt = nil
        return true
    }

    func clearZoomIf(_ zoom: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shot.zoom == zoom else { return false }
        shot.zoom = nil
        return true
    }

    func clearRollIf(_ roll: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shot.roll == roll else { return false }
        shot.roll = nil
        return true
    }

    func clearFocusIf(_ focus: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shot.focus == focus else { return false }
        shot.focus = nil
        return true
    }

    func clearFocusAutoIf(_ on: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard shot.focusAuto == on else { return false }
        shot.focusAuto = nil
        return true
    }

    func clearPanTilt() {
        lock.lock()
        shot.pan = nil
        shot.tilt = nil
        lock.unlock()
    }

    func clearZoom() {
        lock.lock()
        shot.zoom = nil
        lock.unlock()
    }
}

final class FocusToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private func focusStops(lo: Int, hi: Int, origin: Int) -> [Int] {
    var raw = [origin]
    if hi > lo {
        for i in 0..<5 {
            raw.append(lo + (hi - lo) * i / 4)
        }
    }
    var out: [Int] = []
    for v in raw {
        let c = min(max(v, lo), hi)
        if !out.contains(where: { abs($0 - c) < 40 }) { out.append(c) }
    }
    return out
}

private func focusFineStops(lo: Int, hi: Int, best: Int) -> [Int] {
    let step = max(80, (hi - lo) / 18)
    var out: [Int] = []
    for k in [-2, -1, 1, 2] {
        let c = min(max(best + k * step, lo), hi)
        if !out.contains(where: { abs($0 - c) < 40 }) { out.append(c) }
    }
    return out
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
    @Published var roll = 0.0
    @Published var rollMin = -30.0
    @Published var rollMax = 30.0
    @Published var focus = 0.0
    @Published var focusMin = 0.0
    @Published var focusMax = 4095.0
    @Published var focusAuto = true
    @Published var connected = false
    @Published var range = ptz_range_t(panMin: -35, panMax: 215, tiltMin: -90, tiltMax: 90)
    // Where a control is asking to go. Nil once the camera is there.
    @Published var aimPan: Double?
    @Published var aimTilt: Double?
    @Published var aimZoom: Double?
    @Published var aimRoll: Double?
    @Published var aimFocus: Double?
    @Published var aimFocusAuto: Bool?
    @Published var focusNote = ""
    @Published private(set) var busy = false

    @AppStorage("stepDegrees") var step = 5
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
    private let focusToken = FocusToken()
    private var driving = false
    private var sweeping = false
    private var timer: Timer?
    private var motionTimer: Timer?
    private var motionGen = 0
    private var zoomGoal: Double?
    private var zoomPace = 15.0
    /// The last held zoom step can be under five units. Finish that step once
    /// the previous command has landed, and not before.
    private var zoomFinish = false
    private var holds: [String: HoldAxes] = [:]
    private var holdTimer: Timer?
    private var heldZoom = false

    var motionSpeed: Double {
        UserDefaults.standard.integer(forKey: "moveSpeed") == 32 ? 32 : 15
    }

    init() {
        refresh()
        usb.async {
            var r = ptz_range_t()
            var zmin: Int32 = 0, zmax: Int32 = 0
            var rmin = 0.0, rmax = 0.0
            var fmin: Int32 = 0, fmax: Int32 = 0
            let haveRange = ptz_range(&r) == 0
            let haveZoom = ptz_zoom_range(&zmin, &zmax) == 0
            let haveRoll = ptz_roll_range(&rmin, &rmax) == 0
            let haveFocus = ptz_focus_range(&fmin, &fmax) == 0
            Task { @MainActor in
                if haveRange { self.range = r }
                if haveZoom, zmax > zmin {
                    self.zoomMin = Double(zmin)
                    self.zoomMax = Double(zmax)
                }
                if haveRoll, rmax > rmin {
                    self.rollMin = rmin
                    self.rollMax = rmax
                }
                if haveFocus, fmax > fmin {
                    self.focusMin = Double(fmin)
                    self.focusMax = Double(fmax)
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
            var s = ptz_sense_t()
            let ok = ptz_sense(&s) == 0
            Task { @MainActor in
                guard !self.driving else { return }
                self.connected = ok
                if ok { self.apply(s) }
            }
        }
    }

    func go(pan: Double, tilt: Double) {
        aim(pan: pan, tilt: tilt, fromMotion: false)
    }

    /// A glide and a held key pass `fromMotion` so they do not cancel themselves.
    private func aim(pan: Double, tilt: Double, fromMotion: Bool) {
        if !fromMotion { cancelMotion() }
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
        go(pan: basePan + dx * Double(step) * sign, tilt: baseTilt + dy * Double(step))
    }

    /// Walks to the saved center. Esc stops the walk. The default center is
    /// straight ahead, pan 0° and tilt 0°.
    func recenter() {
        recall(pan: homePan, tilt: homeTilt, zoom: nil, move: true, panSpeed: nil, zoomSpeed: nil)
    }

    func setHome() { homePan = aimPan ?? pan; homeTilt = aimTilt ?? tilt }

    func setZoom(_ value: Double) {
        cancelMotion()
        commitZoom(value)
    }

    func nudgeZoom(_ delta: Double) { setZoom((aimZoom ?? zoom) + delta) }

    /// Recalls a framing. A new recall replaces one that is still running.
    /// Zoom is sent in steps: repeating one zoom command holds the lens.
    func recall(pan: Double, tilt: Double, zoom: Double?, move: Bool, panSpeed: Double?, zoomSpeed: Double?) {
        cancelMotion()
        let destPan = min(max(pan, range.panMin), range.panMax)
        let destTilt = min(max(tilt, range.tiltMin), range.tiltMax)
        let destZoom = zoom.map { min(max($0, zoomMin), zoomMax).rounded() }
        guard move else {
            aim(pan: destPan, tilt: destTilt, fromMotion: true)
            if let destZoom { commitZoom(destZoom) }
            return
        }
        let gen = motionGen
        let pSpeed = max(5, panSpeed ?? motionSpeed)
        let zSpeed = max(5, zoomSpeed ?? motionSpeed)
        let started = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.motionGen == gen else {
                    timer.invalidate()
                    return
                }
                self.glide(
                    timer: timer,
                    destPan: destPan,
                    destTilt: destTilt,
                    destZoom: destZoom,
                    pSpeed: pSpeed,
                    zSpeed: zSpeed,
                    started: started
                )
            }
        }
        motionTimer = timer
        busy = true
        RunLoop.main.add(timer, forMode: .common)
        glide(timer: timer, destPan: destPan, destTilt: destTilt, destZoom: destZoom, pSpeed: pSpeed, zSpeed: zSpeed, started: started)
    }

    func holdMove(dPan: Double, dTilt: Double, dZoom: Double) {
        let tookOver = motionTimer != nil
        stopGlideTimer()
        if tookOver {
            zoomGoal = nil
            zoomFinish = false
        }
        if dPan != 0 || dTilt != 0 {
            aim(pan: (aimPan ?? pan) + dPan, tilt: (aimTilt ?? tilt) + dTilt, fromMotion: true)
        }
        if dZoom != 0 {
            let base = zoomGoal ?? aimZoom ?? zoom
            zoomGoal = min(max(base + dZoom, zoomMin), zoomMax)
            zoomPace = motionSpeed
            flushZoomGoal(final: false)
        }
    }

    /// Sends a last zoom step smaller than five units when a held key is released.
    func releaseHold() {
        zoomFinish = true
        flushZoomGoal(final: true)
    }

    /// Keyboard and Stream Deck keys share one clock. Each source is one key.
    /// Opposite directions cancel, and releasing one key leaves the others running.
    func setHold(id: String, axes: HoldAxes) {
        if axes.pan == 0, axes.tilt == 0, axes.zoom == 0 {
            holds.removeValue(forKey: id)
        } else if holds[id] != nil || holds.count < 32 {
            holds[id] = axes
        }
        let sum = summedHolds()
        if sum.zoom == 0, heldZoom { releaseHold() }
        heldZoom = sum.zoom != 0
        guard sum.pan != 0 || sum.tilt != 0 || sum.zoom != 0 else {
            holdTimer?.invalidate()
            holdTimer = nil
            return
        }
        if holdTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in Gimbal.shared.repeatHold() }
            }
            holdTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        repeatHold()
    }

    func repeatHold() {
        let sum = summedHolds()
        guard sum.pan != 0 || sum.tilt != 0 || sum.zoom != 0 else { return }
        let sign = invertPan ? -1.0 : 1.0
        let step = motionSpeed * 0.05
        holdMove(
            dPan: Double(sum.pan) * sign * step,
            dTilt: Double(sum.tilt) * step,
            dZoom: Double(sum.zoom) * step
        )
    }

    private func summedHolds() -> HoldAxes {
        var pan = 0
        var tilt = 0
        var zoom = 0
        for axes in holds.values {
            pan += axes.pan
            tilt += axes.tilt
            zoom += axes.zoom
        }
        return HoldAxes(pan: max(-1, min(1, pan)), tilt: max(-1, min(1, tilt)), zoom: max(-1, min(1, zoom)))
    }

    /// Drops pan, tilt, and zoom commands that have not been sent yet.
    /// A command the camera already accepted can still finish.
    func stopMotion() {
        holds.removeAll()
        holdTimer?.invalidate()
        holdTimer = nil
        heldZoom = false
        cancelMotion()
        target.clearPanTilt()
        target.clearZoom()
        aimPan = nil
        aimTilt = nil
        aimZoom = nil
        zoom = zoomNow
        if !driving { busy = false }
    }

    private func commitZoom(_ value: Double) {
        let z = min(max(value, zoomMin), zoomMax).rounded()
        zoom = z
        aimZoom = z
        target.setZoom(z)
        startDrive()
    }

    private func cancelMotion() {
        motionGen &+= 1
        motionTimer?.invalidate()
        motionTimer = nil
        zoomGoal = nil
        zoomFinish = false
    }

    private func stopGlideTimer() {
        guard motionTimer != nil else { return }
        motionGen &+= 1
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func glide(
        timer: Timer,
        destPan: Double,
        destTilt: Double,
        destZoom: Double?,
        pSpeed: Double,
        zSpeed: Double,
        started: Date
    ) {
        if Date().timeIntervalSince(started) > 30 {
            aim(pan: destPan, tilt: destTilt, fromMotion: true)
            if let destZoom {
                zoomGoal = nil
                commitZoom(destZoom)
            }
            finishGlide(timer)
            return
        }
        let nextPan = approach(aimPan ?? pan, destPan, pSpeed * 0.05)
        let nextTilt = approach(aimTilt ?? tilt, destTilt, pSpeed * 0.05)
        aim(pan: nextPan, tilt: nextTilt, fromMotion: true)
        if let destZoom {
            zoomGoal = destZoom
            zoomPace = zSpeed
            flushZoomGoal(final: true)
        }
        let panDone = abs(nextPan - destPan) < 0.05 && abs(nextTilt - destTilt) < 0.05
        let zoomDone: Bool
        if let destZoom {
            zoomDone = zoomGoal == nil && abs((aimZoom ?? zoomNow) - destZoom) < 1
        } else {
            zoomDone = true
        }
        if panDone && zoomDone { finishGlide(timer) }
    }

    private func finishGlide(_ timer: Timer) {
        timer.invalidate()
        if motionTimer === timer { motionTimer = nil }
        if !driving { busy = false }
    }

    /// One zoom command at a time. A repeated command, or a new one before
    /// the lens reports, holds the lens where it is.
    private func flushZoomGoal(final: Bool) {
        guard let goal = zoomGoal else {
            zoomFinish = false
            return
        }
        let at = aimZoom ?? zoomNow
        if abs(at - goal) < 1 {
            zoomGoal = nil
            zoomFinish = false
            return
        }
        if let aimZoom, abs(zoomNow - aimZoom) >= 2 { return }
        let remaining = abs(goal - at)
        if remaining < 5, !final, !zoomFinish { return }
        let pace = max(5, zoomPace * 0.45)
        let step = min(pace, remaining)
        let next = approach(at, goal, step).rounded()
        if abs(next - at) < 0.5 { return }
        commitZoom(next)
        if abs(next - goal) < 0.5 {
            zoomGoal = nil
            zoomFinish = false
        }
    }

    func setRoll(_ value: Double) {
        let r = min(max(value, rollMin), rollMax).rounded()
        roll = r
        aimRoll = r
        target.setRoll(r)
        startDrive()
    }

    func setFocus(_ value: Double) {
        let f = min(max(value, focusMin), focusMax).rounded()
        _ = focusToken.bump()
        focusAuto = false
        aimFocusAuto = false
        focus = f
        aimFocus = f
        focusNote = ""
        target.setFocusAuto(0)
        target.setFocus(f)
        if sweeping { scheduleDrive() } else { startDrive() }
    }

    func setFocusAuto(_ on: Bool) {
        _ = focusToken.bump()
        focusAuto = on
        aimFocusAuto = on
        focusNote = ""
        if on {
            aimFocus = nil
            target.clearFocus()
            target.clearFocusAuto()
            focusNote = "Focusing…"
            sweeping = true
            driving = true
            let gen = focusToken.current()
            let start = Int(focus.rounded())
            let lo = Int(focusMin.rounded())
            let hi = Int(focusMax.rounded())
            usb.async { self.refocus(generation: gen, lo: lo, hi: hi, start: start) }
        } else {
            target.clearFocus()
            target.setFocusAuto(0)
            if sweeping { scheduleDrive() } else { startDrive() }
        }
    }

    private func scheduleDrive() {
        usb.async {
            Task { @MainActor in
                self.sweeping = false
                self.driving = false
                self.startDrive()
            }
        }
    }

    private func apply(_ s: ptz_sense_t) {
        pan = s.pan
        tilt = s.tilt
        zoomNow = Double(s.zoom)
        if aimZoom == nil { zoom = Double(s.zoom) }
        if aimRoll == nil { roll = s.roll }
        if aimFocus == nil { focus = Double(s.focus) }
        if aimFocusAuto == nil { focusAuto = s.focusAuto != 0 }
        flushZoomGoal(final: false)
    }

    private func startDrive() {
        busy = true
        guard !driving else { return }
        driving = true
        let target = self.target
        usb.async { self.drive(target) }
    }

    // The Pocket 3's USB autofocus control is only a flag. It does not hunt.
    // Absolute focus is ignored while that flag still reads on, and sometimes
    // the body accepts a focus SET and leaves the lens where it is. Try one
    // move first. A sweep only runs when the lens actually goes.
    nonisolated private func refocus(generation gen: Int, lo: Int, hi: Int, start: Int) {
        if focusToken.current() != gen { return }
        var link: UnsafeMutableRawPointer?
        guard ptz_link_open(&link) == 0, let link else {
            finishRefocus(gen: gen, focus: nil, auto: false, note: "Couldn't reach the camera")
            return
        }
        defer { ptz_link_close(link) }

        var moved = false
        func cancelled() -> Bool {
            guard focusToken.current() != gen else { return false }
            if moved, target.snapshot().focus == nil {
                _ = moveFocus(link, start)
            }
            return true
        }

        if ptz_link_focus_auto(link, 0) != 0 {
            finishRefocus(gen: gen, focus: Double(start), auto: false, note: "Couldn't reach the camera")
            return
        }
        var manual = false
        for _ in 0..<12 {
            if cancelled() { return }
            usleep(100_000)
            var s = ptz_sense_t()
            if ptz_link_sense(link, &s) != 0 { break }
            if s.focusAuto == 0 { manual = true; break }
        }
        if cancelled() { return }
        guard manual else {
            _ = ptz_link_focus_auto(link, 1)
            finishRefocus(gen: gen, focus: Double(start), auto: true, note: "The camera kept this focus")
            return
        }

        let probe = min(max(start > (lo + hi) / 2 ? start - 1600 : start + 1600, lo), hi)
        guard let probed = moveFocus(link, probe), abs(probed - start) >= 40 else {
            _ = ptz_link_focus(link, Int32(start))
            usleep(200_000)
            _ = ptz_link_focus_auto(link, 1)
            waitFocusAuto(link, 1)
            finishRefocus(gen: gen, focus: Double(start), auto: true, note: "The camera kept this focus")
            return
        }

        moved = true
        Preview.shared.acquire("sweep")
        defer { Preview.shared.release("sweep") }
        guard let probeScore = Preview.shared.measure(timeout: 2.0, discard: true) else {
            _ = moveFocus(link, start)
            _ = ptz_link_focus_auto(link, 1)
            waitFocusAuto(link, 1)
            finishRefocus(gen: gen, focus: Double(start), auto: true, note: "Couldn't see the picture to refocus")
            return
        }

        var best = probed
        var bestScore = probeScore
        var originScore = probeScore
        for stop in focusStops(lo: lo, hi: hi, origin: start) {
            if cancelled() { return }
            if abs(stop - probed) < 40 { continue }
            guard let landed = moveFocus(link, stop), abs(landed - stop) <= 80 else { continue }
            guard let score = Preview.shared.measure(timeout: 0.7, discard: true) else { continue }
            if abs(stop - start) < 40 { originScore = score }
            if score > bestScore {
                bestScore = score
                best = landed
            }
        }
        if cancelled() { return }
        for stop in focusFineStops(lo: lo, hi: hi, best: best) {
            if cancelled() { return }
            guard let landed = moveFocus(link, stop), abs(landed - stop) <= 80 else { continue }
            guard let score = Preview.shared.measure(timeout: 0.7, discard: true) else { continue }
            if score > bestScore {
                bestScore = score
                best = landed
            }
        }
        if cancelled() { return }

        let useful = bestScore > originScore * 1.12 && bestScore > originScore + 0.8
        let landed = useful ? best : start
        _ = moveFocus(link, landed)
        if cancelled() { return }
        _ = ptz_link_focus_auto(link, 1)
        waitFocusAuto(link, 1)
        let note = useful ? "" : "Couldn't find a sharper focus"
        finishRefocus(gen: gen, focus: Double(landed), auto: true, note: note)
    }

    nonisolated private func moveFocus(_ link: UnsafeMutableRawPointer, _ focus: Int) -> Int? {
        if ptz_link_focus(link, Int32(focus)) != 0 { return nil }
        var last: Int?
        for _ in 0..<8 {
            usleep(120_000)
            var s = ptz_sense_t()
            if ptz_link_sense(link, &s) != 0 { return last }
            last = Int(s.focus)
            if abs(Int(s.focus) - focus) <= 30 { return Int(s.focus) }
        }
        return last
    }

    nonisolated private func waitFocusAuto(_ link: UnsafeMutableRawPointer, _ on: Int32) {
        for _ in 0..<8 {
            usleep(100_000)
            var s = ptz_sense_t()
            if ptz_link_sense(link, &s) == 0, s.focusAuto == on { return }
        }
    }

    nonisolated private func finishRefocus(gen: Int, focus: Double?, auto: Bool?, note: String) {
        let token = focusToken
        Task { @MainActor in
            guard token.current() == gen else { return }
            self.sweeping = false
            self.driving = false
            self.focusNote = note
            if let focus { self.focus = focus }
            if let auto { self.focusAuto = auto }
            self.aimFocus = nil
            self.aimFocusAuto = nil
            if !self.target.snapshot().idle { self.startDrive() }
            else { self.refresh() }
        }
    }

    nonisolated private func drive(_ target: AimTarget) {
        var link: UnsafeMutableRawPointer?
        guard ptz_link_open(&link) == 0, let link else {
            Task { @MainActor in
                self.driving = false
                self.connected = false
                self.cancelMotion()
                self.busy = false
            }
            return
        }
        defer { ptz_link_close(link) }

        var ticks = 0
        var aimStill = 0
        var rollStill = 0
        var primed = false
        var prevPan = 0.0, prevTilt = 0.0, prevRoll = 0.0
        var zoomSent: Double?
        var zoomTries = 0
        var zoomAtSend: Int32 = 0
        var lastZoomSend = -100
        var focusSent: Double?
        var focusTries = 0
        var focusAtSend: Int32 = 0
        var lastFocusSend = -100
        var autoSent: Int?
        var lastAutoSend = -100
        while ticks < 120 {
            let want = target.snapshot()
            if want.idle { break }
            var s = ptz_sense_t()
            if ptz_link_sense(link, &s) != 0 {
                Task { @MainActor in self.connected = false }
                break
            }
            var aimPending = false
            var rollPending = false
            // Half a degree, not a full degree. A 1° step is exactly 1.0 from
            // the current angle, and a 1.05° window treated that as arrived
            // and never sent it.
            if let wantPan = want.pan, let wantTilt = want.tilt {
                if abs(s.pan - wantPan) >= 0.5 || abs(s.tilt - wantTilt) >= 0.5 {
                    aimPending = true
                    if ptz_link_aim(link, wantPan, wantTilt) != 0 { break }
                } else {
                    _ = target.clearAimIf(pan: wantPan, tilt: wantTilt)
                }
            }
            if let wantRoll = want.roll {
                if abs(s.roll - wantRoll) >= 0.5 {
                    rollPending = true
                    if ptz_link_roll(link, wantRoll) != 0 { break }
                } else {
                    _ = target.clearRollIf(wantRoll)
                }
            }
            if let wantZoom = want.zoom {
                let diff = abs(Double(s.zoom) - wantZoom)
                if diff < 1 {
                    _ = target.clearZoomIf(wantZoom)
                } else if zoomSent != wantZoom {
                    // One command. Sending the same zoom again before the lens
                    // reports holds it, and zoom out never leaves the stop.
                    if ptz_link_zoom(link, Int32(wantZoom.rounded())) != 0 { break }
                    zoomSent = wantZoom
                    zoomTries = 1
                    zoomAtSend = s.zoom
                    lastZoomSend = ticks
                } else if ticks - lastZoomSend >= 8 {
                    let moved = abs(Int(s.zoom) - Int(zoomAtSend)) >= 1
                    if moved || diff <= 2 || zoomTries >= 2 {
                        _ = target.clearZoomIf(wantZoom)
                    } else if ticks - lastZoomSend >= 10 {
                        if ptz_link_zoom(link, Int32(wantZoom.rounded())) != 0 { break }
                        zoomTries = 2
                        zoomAtSend = s.zoom
                        lastZoomSend = ticks
                    }
                }
            }
            if let wantAuto = want.focusAuto, Int(s.focusAuto) != wantAuto {
                if autoSent != wantAuto {
                    if ptz_link_focus_auto(link, Int32(wantAuto)) != 0 { break }
                    autoSent = wantAuto
                    lastAutoSend = ticks
                } else if ticks - lastAutoSend >= 8 {
                    _ = target.clearFocusAutoIf(wantAuto)
                }
            } else if let wantAuto = want.focusAuto {
                _ = target.clearFocusAutoIf(wantAuto)
            }
            if let wantFocus = want.focus {
                // A focus position sent while the autofocus flag still reads on
                // is accepted and ignored. Wait until the camera says manual.
                let wantsManual = (want.focusAuto ?? 0) == 0
                let diff = abs(Double(s.focus) - wantFocus)
                if !wantsManual || diff < 1 {
                    _ = target.clearFocusIf(wantFocus)
                } else if s.focusAuto != 0 {
                    if ticks >= 20 { _ = target.clearFocusIf(wantFocus) }
                } else {
                    if focusSent != wantFocus {
                        if ptz_link_focus(link, Int32(wantFocus.rounded())) != 0 { break }
                        focusSent = wantFocus
                        focusTries = 1
                        focusAtSend = s.focus
                        lastFocusSend = ticks
                    } else if ticks - lastFocusSend >= 8 {
                        let moved = abs(Int(s.focus) - Int(focusAtSend)) >= 8
                        if moved || diff <= 8 || focusTries >= 2 {
                            _ = target.clearFocusIf(wantFocus)
                        } else if ticks - lastFocusSend >= 10 {
                            if ptz_link_focus(link, Int32(wantFocus.rounded())) != 0 { break }
                            focusTries = 2
                            focusAtSend = s.focus
                            lastFocusSend = ticks
                        }
                    }
                }
            }
            let sample = s
            Task { @MainActor in
                self.connected = true
                self.apply(sample)
            }
            if aimPending {
                if primed && abs(s.pan - prevPan) < 0.2 && abs(s.tilt - prevTilt) < 0.2 {
                    aimStill += 1
                } else {
                    aimStill = 0
                }
                if aimStill >= 16, let wantPan = want.pan, let wantTilt = want.tilt {
                    _ = target.clearAimIf(pan: wantPan, tilt: wantTilt)
                }
            } else {
                aimStill = 0
            }
            if rollPending {
                if primed && abs(s.roll - prevRoll) < 0.2 {
                    rollStill += 1
                } else {
                    rollStill = 0
                }
                if rollStill >= 16, let wantRoll = want.roll {
                    _ = target.clearRollIf(wantRoll)
                }
            } else {
                rollStill = 0
            }
            if target.snapshot().idle { break }
            prevPan = s.pan
            prevTilt = s.tilt
            prevRoll = s.roll
            primed = true
            ticks += 1
            usleep(50_000)
        }
        Task { @MainActor in
            if self.sweeping { return }
            let left = self.target.snapshot()
            self.aimPan = left.pan
            self.aimTilt = left.tilt
            self.aimZoom = left.zoom
            self.aimRoll = left.roll
            self.aimFocus = left.focus
            self.aimFocusAuto = left.focusAuto.map { $0 != 0 }
            self.driving = false
            self.flushZoomGoal(final: false)
            let still = self.target.snapshot()
            if !still.idle {
                self.startDrive()
            } else if self.motionTimer != nil {
                self.busy = true
            } else {
                self.busy = false
                self.refresh()
            }
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
        .frame(height: 108)
        .overlay(alignment: .top) {
            Text("Center is straight ahead")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ArrowButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
            .padding(.vertical, 4)
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

struct AxisSlider: View {
    let title: String
    let readout: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: step)
        }
    }
}

struct Panel: View {
    var floating = false
    @ObservedObject var g = Gimbal.shared
    @ObservedObject var preview = Preview.shared
    @AppStorage("showPreview") private var showPreview = false
    @AppStorage("captureSize") private var captureSize = "1080"
    @AppStorage("advanced") private var advanced = false

    private var manualFocus: Bool { !(g.aimFocusAuto ?? g.focusAuto) }
    private var showsControls: Bool { floating || !preview.popped }

    var body: some View {
        Group {
            if showsControls {
                controls
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pocket3 Companion").font(.headline)
                    Text("The controls are in a window on the desktop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Bring back") { PreviewWindow.shared.close() }
                        .controlSize(.small)
                }
                .padding(12)
                .frame(width: 260)
            }
        }
        .onAppear {
            if !floating { preview.setMenuAttached(true) }
            if !floating { holdMenuWindow() }
            syncPreview()
        }
        .onDisappear {
            if !floating { preview.setMenuAttached(false) }
            preview.release(floating ? "window" : "menu")
        }
        .onChange(of: showPreview) { _, _ in syncPreview() }
        .onChange(of: preview.popped) { _, _ in syncPreview() }
        .background(KeyableMenu())
    }

    /// A menu panel closes itself when the app is no longer the active one.
    /// Starting the camera does that. Keep this panel on screen.
    private func holdMenuWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is PreviewPanel) {
                let name = window.contentView.map { String(describing: type(of: $0)) } ?? ""
                if name.contains("NSHostingView") {
                    window.hidesOnDeactivate = false
                }
            }
        }
    }

    private func syncPreview() {
        guard showsControls else {
            preview.release(floating ? "window" : "menu")
            return
        }
        if showPreview {
            preview.acquire(floating ? "window" : "menu")
        } else {
            preview.release(floating ? "window" : "menu")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if !floating {
                    Text("Pocket3 Companion").font(.headline)
                }
                HStack(spacing: 6) {
                    Circle().fill(g.connected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(g.connected ? "Webcam connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                    if g.busy {
                        Button("Stop") {
                            HoldKeys.releaseAll()
                            g.stopMotion()
                        }
                        .controlSize(.small)
                        .help("Stop scheduling the move. Esc does this too.")
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "P %.1f°  T %.1f°  %.2f×", g.pan, g.tilt, g.zoomNow / 100))
                        .font(.system(.caption, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if floating {
                    WindowDrag().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Picker("Controls", selection: $advanced) {
                Text("Simple").tag(false)
                Text("Advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if showPreview {
                ZStack {
                    Color.black
                    PreviewView(session: preview.session)
                    if !preview.status.isEmpty {
                        Text(preview.status)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(width: 296, height: 167)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Toggle("Live preview", isOn: $showPreview)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            if preview.status == "Allow camera access to see the picture" {
                Button("Allow camera") { preview.permitCamera() }
                    .controlSize(.small)
            }

            Picker("Resolution", selection: $captureSize) {
                Text("1080").tag("1080")
                Text("4K").tag("4k")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: captureSize) { _, _ in preview.useCaptureSize() }
            if showPreview, !preview.picture.isEmpty {
                Text(preview.picture)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Pad(g: g)

            HStack(alignment: .top, spacing: 12) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        Color.clear.frame(width: 28, height: 28)
                        ArrowButton(symbol: "chevron.up") { g.nudge(dx: 0, dy: 1) }
                        Color.clear.frame(width: 28, height: 28)
                    }
                    GridRow {
                        ArrowButton(symbol: "chevron.left") { g.nudge(dx: -1, dy: 0) }
                        ArrowButton(symbol: "scope", help: "Move back to the saved center. Esc stops the move.") { g.recenter() }
                        ArrowButton(symbol: "chevron.right") { g.nudge(dx: 1, dy: 0) }
                    }
                    GridRow {
                        Color.clear.frame(width: 28, height: 28)
                        ArrowButton(symbol: "chevron.down") { g.nudge(dx: 0, dy: -1) }
                        Color.clear.frame(width: 28, height: 28)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step").font(.caption).foregroundStyle(.secondary)
                    Picker("Step", selection: $g.step) {
                        Text("1°").tag(1)
                        Text("5°").tag(5)
                        Text("15°").tag(15)
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
                Slider(value: Binding(get: { g.zoom }, set: { g.setZoom($0) }), in: g.zoomMin...g.zoomMax, step: 5)
                ZoomStepButton(symbol: "plus", enabled: (g.aimZoom ?? g.zoom) < g.zoomMax - 0.5) {
                    g.nudgeZoom(25)
                }
            }

            PresetSection()

            if advanced {
                AxisSlider(
                    title: "Roll",
                    readout: String(format: "%.0f°", g.roll),
                    value: g.aimRoll ?? g.roll,
                    range: g.rollMin...g.rollMax,
                    step: 1
                ) { g.setRoll($0) }
                Button("Level horizon") { g.setRoll(0) }
                    .controlSize(.small)
                Toggle("Autofocus", isOn: Binding(
                    get: { g.aimFocusAuto ?? g.focusAuto },
                    set: { g.setFocusAuto($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                if !g.focusNote.isEmpty {
                    Text(g.focusNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                AxisSlider(
                    title: "Focus",
                    readout: String(format: "%.0f", g.focus),
                    value: g.aimFocus ?? g.focus,
                    range: g.focusMin...g.focusMax,
                    step: 1
                ) { g.setFocus($0) }
                .disabled(!manualFocus)
                .opacity(manualFocus ? 1 : 0.45)
                AxisSlider(
                    title: "Pan",
                    readout: String(format: "%.1f°", g.aimPan ?? g.pan),
                    value: g.aimPan ?? g.pan,
                    range: g.range.panMin...g.range.panMax,
                    step: 1
                ) { g.go(pan: $0, tilt: g.aimTilt ?? g.tilt) }
                AxisSlider(
                    title: "Tilt",
                    readout: String(format: "%.1f°", g.aimTilt ?? g.tilt),
                    value: g.aimTilt ?? g.tilt,
                    range: g.range.tiltMin...g.range.tiltMax,
                    step: 1
                ) { g.go(pan: g.aimPan ?? g.pan, tilt: $0) }
                Text("Zoom \(Int(g.zoomNow.rounded())) of \(Int(g.zoomMin.rounded()))–\(Int(g.zoomMax.rounded()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()
            HStack {
                Button(floating ? "Dock" : "Pop out") {
                    if floating {
                        PreviewWindow.shared.close()
                    } else {
                        PreviewWindow.shared.open()
                    }
                }
                .controlSize(.small)
                .help(floating
                      ? "Put the controls back in the menu"
                      : "Keep the controls in a window on the desktop")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("⌃⌥ arrows, C, −/+, 1–3")
                    Text("WASD in the window · Esc stops")
                }
                .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
            }
        }
        .onPreferenceChange(PanelHeightKey.self) { height in
            if floating { PreviewWindow.shared.fit(height: height) }
        }
    }
}

@main
struct Pocket3CompanionApp: App {
    init() {
        HotKeys.register()
        HoldKeys.install()
        if UserDefaults.standard.bool(forKey: "bridgeOn") {
            _ = bridgeToken()
            Bridge.shared.start()
        }
    }
    var body: some Scene {
        MenuBarExtra("Pocket3 Companion", systemImage: "camera.viewfinder") {
            Panel()
        }
        .menuBarExtraStyle(.window)
    }
}
