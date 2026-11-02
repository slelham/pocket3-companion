import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI
import UniformTypeIdentifiers

let bridgePort = 47323

@MainActor
final class Presets: ObservableObject {
    static let shared = Presets()

    @Published var items: [Framing] = []
    @Published var selected: UUID?
    @Published var note = ""

    private let key = "framings"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let loaded = decodeFramings(data) else { return }
        items = loaded
    }

    func add(pan: Double, tilt: Double, zoom: Double) {
        guard items.count < 20 else {
            note = "Twenty presets is the limit."
            return
        }
        let item = Framing(
            id: UUID(),
            name: "Preset \(items.count + 1)",
            pan: pan,
            tilt: tilt,
            zoom: zoom.rounded(),
            move: true,
            panSpeed: nil,
            zoomSpeed: nil
        )
        items.append(item)
        selected = item.id
        note = ""
        save()
    }

    func recall(_ item: Framing, on gimbal: Gimbal) {
        selected = item.id
        note = ""
        gimbal.recall(
            pan: item.pan,
            tilt: item.tilt,
            zoom: item.zoom,
            move: item.move,
            panSpeed: item.panSpeed,
            zoomSpeed: item.zoomSpeed
        )
    }

    func rename(_ id: UUID, _ name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = String(name.prefix(40))
        save()
    }

    func setMove(_ id: UUID, _ move: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].move = move
        save()
    }

    func setSpeeds(_ id: UUID, custom: Bool, pan: Double, zoom: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].panSpeed = custom ? pan : nil
        items[index].zoomSpeed = custom ? zoom : nil
        save()
    }

    func replace(_ id: UUID, pan: Double, tilt: Double, zoom: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pan = pan
        items[index].tilt = tilt
        items[index].zoom = zoom.rounded()
        note = "Updated \(items[index].label)."
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selected == id { selected = nil }
        note = ""
        save()
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "pocket3-presets.json"
        panel.title = "Export presets"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let file = FramingFile(version: 1, presets: self.items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(file) else { return }
            do {
                try data.write(to: url, options: .atomic)
                Task { @MainActor in self.note = "Exported \(self.items.count) presets." }
            } catch {
                Task { @MainActor in self.note = "Couldn't export the presets." }
            }
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import presets"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            guard let data = try? Data(contentsOf: url), let loaded = decodeFramings(data) else {
                Task { @MainActor in self.note = "That file has no presets." }
                return
            }
            Task { @MainActor in
                let room = 20 - self.items.count
                guard room > 0 else {
                    self.note = "Twenty presets is the limit."
                    return
                }
                let adding = Array(loaded.prefix(room))
                self.items.append(contentsOf: adding)
                self.note = "Added \(adding.count) presets."
                self.save()
            }
        }
    }

    private func save() {
        let file = FramingFile(version: 1, presets: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum DeckLink {
    static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocket3 Companion/streamdeck.json")
    }

    /// Writes the Stream Deck key beside the app, not into a Stream Deck profile.
    /// Disconnect replaces the key and deletes the file, so an old plugin stops.
    @MainActor
    static func connect() {
        let token = ensureToken()
        let url = fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = "{\"port\":\(bridgePort),\"token\":\"\(token)\"}\n"
        try? json.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Bridge.shared.start()
    }

    @MainActor
    static func disconnect() {
        UserDefaults.standard.set(newBridgeToken(), forKey: "deckToken")
        try? FileManager.default.removeItem(at: fileURL())
    }

    private static func ensureToken() -> String {
        if let saved = UserDefaults.standard.string(forKey: "deckToken"), saved.count >= 32 {
            return saved
        }
        let created = newBridgeToken()
        UserDefaults.standard.set(created, forKey: "deckToken")
        return created
    }
}

func newBridgeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    arc4random_buf(&bytes, bytes.count)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func bridgeToken() -> String {
    if let saved = UserDefaults.standard.string(forKey: "bridgeToken"), saved.count >= 32 {
        return saved
    }
    let created = newBridgeToken()
    UserDefaults.standard.set(created, forKey: "bridgeToken")
    return created
}

final class Bridge: ObservableObject {
    static let shared = Bridge()

    @Published var running = false
    @Published var status = ""

    private let queue = DispatchQueue(label: "pocket3.bridge")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    func start() {
        queue.async { self.listen() }
    }

    func stop() {
        queue.async {
            self.listenFD = -1
            self.source?.cancel()
            self.source = nil
            DispatchQueue.main.async {
                self.running = false
                self.status = ""
            }
        }
    }

    private func listen() {
        if listenFD >= 0 { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("Couldn't open a local port") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(bridgePort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return fail("Port \(bridgePort) is already in use")
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        DispatchQueue.main.async {
            self.running = true
            self.status = "Listening on 127.0.0.1:\(bridgePort)"
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.running = false
            self.status = message
        }
    }

    private func acceptClients() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
    }

    /// Localhost only. The token is a header, never part of the path, so a
    /// copied URL does not carry it. Repeating one zoom command holds the
    /// lens, so recall goes through the same paced move as a click.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var used = 0
        while used < buffer.count {
            let count = read(client, &buffer[used], buffer.count - used)
            if count <= 0 { break }
            used += count
            if let text = String(bytes: buffer[0..<used], encoding: .utf8), requestReady(text) {
                break
            }
        }
        let raw = String(bytes: buffer[0..<used], encoding: .utf8) ?? ""
        var response = Data()
        let wait = DispatchSemaphore(value: 0)
        Task { @MainActor in
            response = Bridge.reply(raw)
            wait.signal()
        }
        if wait.wait(timeout: .now() + 2) == .timedOut {
            response = http(500, "Error", "{\"error\":\"timeout\"}")
        }
        response.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = write(client, base + sent, rawBuffer.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    @MainActor
    private static func reply(_ raw: String) -> Data {
        guard let request = parseHttpRequest(raw) else {
            return http(400, "Bad Request", "{\"error\":\"bad request\"}")
        }
        let deck = UserDefaults.standard.string(forKey: "deckToken") ?? ""
        let allowed = authorized(request.headers, token: bridgeToken())
            || (deck.count >= 32 && authorized(request.headers, token: deck))
        guard allowed else {
            return http(401, "Unauthorized", "{\"error\":\"unauthorized\"}")
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            return http(200, "OK", statusJSON())
        case ("GET", "/v1/presets"):
            return http(200, "OK", presetsJSON())
        case ("POST", "/v1/stop"):
            HoldKeys.releaseAll()
            Gimbal.shared.stopMotion()
            return http(200, "OK", "{\"ok\":true}")
        case ("POST", "/v1/recenter"):
            Gimbal.shared.recenter()
            return http(200, "OK", "{\"ok\":true}")
        case ("POST", "/v1/hold"):
            guard let hold = parseHold(request.body) else {
                return http(400, "Bad Request", "{\"error\":\"bad request\"}")
            }
            Gimbal.shared.setHold(
                id: "deck:\(hold.id)",
                axes: HoldAxes(pan: hold.pan, tilt: hold.tilt, zoom: hold.zoom)
            )
            return http(200, "OK", "{\"ok\":true}")
        case ("POST", "/v1/release"):
            guard let id = parseRelease(request.body) else {
                return http(400, "Bad Request", "{\"error\":\"bad request\"}")
            }
            Gimbal.shared.setHold(id: "deck:\(id)", axes: HoldAxes(pan: 0, tilt: 0, zoom: 0))
            return http(200, "OK", "{\"ok\":true}")
        case ("POST", _):
            if let id = recallPresetID(request.path) {
                return http(200, "OK", recallIDJSON(id))
            }
            guard let slot = presetSlot(request.path) else {
                return http(404, "Not Found", "{\"error\":\"not found\"}")
            }
            return http(200, "OK", recallJSON(slot))
        default:
            return http(405, "Method Not Allowed", "{\"error\":\"method\"}")
        }
    }

    @MainActor
    private static func statusJSON() -> String {
        let gimbal = Gimbal.shared
        return """
        {"connected":\(gimbal.connected),"pan":\(num(gimbal.pan)),"tilt":\(num(gimbal.tilt)),"zoom":\(num(gimbal.zoomNow)),"busy":\(gimbal.busy)}
        """
    }

    @MainActor
    private static func presetsJSON() -> String {
        let items = Presets.shared.items
        var slots: [String] = []
        for slot in 1...20 {
            if slot <= items.count {
                let item = items[slot - 1]
                slots.append(
                    "{\"slot\":\(slot),\"empty\":false,\"id\":\"\(item.id.uuidString)\",\"name\":\"\(jsonEscape(item.label))\","
                    + "\"pan\":\(num(item.pan)),\"tilt\":\(num(item.tilt)),\"zoom\":\(num(item.zoom))}"
                )
            } else {
                slots.append("{\"slot\":\(slot),\"empty\":true}")
            }
        }
        return "{\"presets\":[\(slots.joined(separator: ","))]}"
    }

    @MainActor
    private static func recallJSON(_ slot: Int) -> String {
        let items = Presets.shared.items
        guard slot >= 1, slot <= items.count else { return "{\"ok\":true,\"noop\":true,\"slot\":\(slot)}" }
        let item = items[slot - 1]
        Presets.shared.recall(item, on: Gimbal.shared)
        return "{\"ok\":true,\"noop\":false,\"slot\":\(slot),\"name\":\"\(jsonEscape(item.label))\"}"
    }

    @MainActor
    private static func recallIDJSON(_ id: UUID) -> String {
        guard let item = Presets.shared.items.first(where: { $0.id == id }) else {
            return "{\"ok\":true,\"noop\":true}"
        }
        Presets.shared.recall(item, on: Gimbal.shared)
        return "{\"ok\":true,\"noop\":false,\"id\":\"\(item.id.uuidString)\",\"name\":\"\(jsonEscape(item.label))\"}"
    }
}

private func num(_ value: Double) -> String { String(format: "%.2f", value) }

private func http(_ code: Int, _ reason: String, _ json: String) -> Data {
    let body = Data(json.utf8)
    let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
}

enum HoldKeys {
    private static var down = Set<UInt16>()
    private static var monitor: Any?
    private static var resign: NSObjectProtocol?

    static func install() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handle(event)
        }
        resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { _ in releaseAll() }
    }

    static func releaseAll() {
        down.removeAll()
        Task { @MainActor in
            Gimbal.shared.setHold(id: "keyboard", axes: HoldAxes(pan: 0, tilt: 0, zoom: 0))
        }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if !mods.isEmpty { releaseAll() }
            return event
        }
        let code = event.keyCode
        let watched = holdKeyCodes.contains(code) || code == UInt16(kVK_Escape)
        guard watched else { return event }
        if isTyping(event) { return event }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if !mods.isEmpty { return event }
        if code == UInt16(kVK_Escape) {
            if event.type == .keyDown, !event.isARepeat {
                down.removeAll()
                Task { @MainActor in
                    Gimbal.shared.setHold(id: "keyboard", axes: HoldAxes(pan: 0, tilt: 0, zoom: 0))
                    Gimbal.shared.stopMotion()
                }
            }
            return nil
        }
        if event.type == .keyDown {
            if event.isARepeat { return nil }
            down.insert(code)
            publish()
            return nil
        }
        down.remove(code)
        publish()
        return nil
    }

    private static func isTyping(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        let name = String(describing: type(of: responder))
        return name.contains("Text") || name.contains("Field")
    }

    private static func publish() {
        let axes = holdAxes(keys: down)
        Task { @MainActor in
            Gimbal.shared.setHold(id: "keyboard", axes: axes)
        }
    }
}

struct KeyableMenu: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.tune(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.tune(nsView.window) }
    }

    static func tune(_ window: NSWindow?) {
        guard let panel = window as? NSPanel else { return }
        panel.becomesKeyOnlyIfNeeded = false
    }
}

struct PresetSection: View {
    @ObservedObject var presets = Presets.shared
    @ObservedObject var gimbal = Gimbal.shared
    @ObservedObject var bridge = Bridge.shared
    @AppStorage("presetLayout") private var layout = "grid"
    @AppStorage("moveSpeed") private var moveSpeed = 15
    @AppStorage("bridgeOn") private var bridgeOn = false
    @State private var confirmDelete = false

    private var selected: Framing? { presets.items.first { $0.id == presets.selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Presets").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Picker("Speed", selection: $moveSpeed) {
                    Text("15°/s").tag(15)
                    Text("32°/s").tag(32)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .help("How fast a move, a held key, and recenter travel")
                Picker("Layout", selection: $layout) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
            }

            Button("Add Preset") { addCurrent() }
                .controlSize(.small)
                .disabled(presets.items.count >= 20)
                .help("Save the pan, tilt, and zoom you have now")

            if !presets.items.isEmpty {
                ScrollView {
                    if layout == "list" {
                        list
                    } else {
                        grid
                    }
                }
                .frame(maxHeight: 220)
            }

            if let item = selected {
                editor(item)
            }

            if !presets.note.isEmpty {
                Text(presets.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Preset tools") {
                tools
            }
            .font(.caption)
        }
        .onAppear {
            if bridgeOn { bridge.start() }
        }
        .onChange(of: bridgeOn) { _, on in
            if on {
                _ = bridgeToken()
                bridge.start()
            } else {
                bridge.stop()
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
            ForEach(presets.items) { item in
                presetButton(item)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            ForEach(presets.items) { item in
                presetButton(item, detail: true)
            }
        }
    }

    private func presetButton(_ item: Framing, detail: Bool = false) -> some View {
        let on = presets.selected == item.id
        return Button {
            presets.recall(item, on: gimbal)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if detail {
                    Text(caption(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, detail ? 4 : 5)
            .background(on ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func editor(_ item: Framing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: Binding(
                get: { item.name },
                set: { presets.rename(item.id, $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            Picker("Transition", selection: Binding(
                get: { item.move },
                set: { presets.setMove(item.id, $0) }
            )) {
                Text("Move").tag(true)
                Text("Jump").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if item.move {
                Toggle("Custom speeds", isOn: Binding(
                    get: { item.panSpeed != nil || item.zoomSpeed != nil },
                    set: { presets.setSpeeds(item.id, custom: $0, pan: item.panSpeed ?? Double(moveSpeed), zoom: item.zoomSpeed ?? Double(moveSpeed)) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                if item.panSpeed != nil || item.zoomSpeed != nil {
                    Stepper(value: Binding(
                        get: { item.panSpeed ?? Double(moveSpeed) },
                        set: { presets.setSpeeds(item.id, custom: true, pan: $0, zoom: item.zoomSpeed ?? Double(moveSpeed)) }
                    ), in: 5...90, step: 1) {
                        Text("Pan and tilt \(Int((item.panSpeed ?? Double(moveSpeed)).rounded()))°/s")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                    Stepper(value: Binding(
                        get: { item.zoomSpeed ?? Double(moveSpeed) },
                        set: { presets.setSpeeds(item.id, custom: true, pan: item.panSpeed ?? Double(moveSpeed), zoom: $0) }
                    ), in: 5...80, step: 1) {
                        Text("Zoom \(Int((item.zoomSpeed ?? Double(moveSpeed)).rounded())) /s")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                }
            }
            Text(caption(item))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Replace with current") {
                    let shot = currentShot()
                    presets.replace(item.id, pan: shot.pan, tilt: shot.tilt, zoom: shot.zoom)
                }
                .controlSize(.small)
                Spacer()
                Button("Delete") { confirmDelete = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog("Delete \(item.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(item.label)", role: .destructive) { presets.remove(item.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Export") { presets.export() }.controlSize(.small)
                Button("Import") { presets.importFile() }.controlSize(.small)
            }
            Toggle("Local control", isOn: $bridgeOn)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Recall the twenty preset slots from other software on this Mac")
            if bridgeOn {
                Text(bridge.status.isEmpty ? "127.0.0.1:\(bridgePort)" : bridge.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copy recall") { copy(recallSample()) }.controlSize(.small)
                    Button("Copy stop") { copy(stopSample()) }.controlSize(.small)
                    Button("New key") {
                        UserDefaults.standard.set(newBridgeToken(), forKey: "bridgeToken")
                        presets.note = "Curl commands need the new key. Stream Deck keeps its own."
                    }
                    .controlSize(.small)
                }
                Text("Empty slots do nothing. The key stays in the header.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            Text("Stream Deck").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Install") { installDeck() }.controlSize(.small)
                Button("Connect") { connectDeck() }.controlSize(.small)
                Button("Disconnect") { disconnectDeck() }.controlSize(.small)
            }
            Text("Recall, hold to move, recenter, and stop. Stream Deck 6.6 or later. The plugin pairs itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func connectDeck() {
        DeckLink.connect()
        bridgeOn = true
        presets.note = "Stream Deck is paired with this Mac."
    }

    private func disconnectDeck() {
        DeckLink.disconnect()
        presets.note = "Stream Deck is disconnected. Connect pairs it again."
    }

    private func installDeck() {
        connectDeck()
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.elgato.StreamDeck") != nil else {
            presets.note = "Install Stream Deck 6.6 or later, then choose Install again."
            return
        }
        guard let url = Bundle.main.url(forResource: "Pocket3Companion", withExtension: "streamDeckPlugin") else {
            presets.note = "The Stream Deck plugin was not in the app."
            return
        }
        NSWorkspace.shared.open(url)
        presets.note = "Confirm the plugin in Stream Deck."
    }

    private func addCurrent() {
        let shot = currentShot()
        presets.add(pan: shot.pan, tilt: shot.tilt, zoom: shot.zoom)
    }

    private func currentShot() -> (pan: Double, tilt: Double, zoom: Double) {
        (gimbal.aimPan ?? gimbal.pan, gimbal.aimTilt ?? gimbal.tilt, gimbal.aimZoom ?? gimbal.zoomNow)
    }

    private func caption(_ item: Framing) -> String {
        let pace = item.move ? "Move" : "Jump"
        return String(format: "%@  P %.1f°   T %.1f°   %.2f×", pace, item.pan, item.tilt, item.zoom / 100)
    }

    private func recallSample() -> String {
        "curl -s -X POST http://127.0.0.1:\(bridgePort)/v1/presets/1/recall -H \"Authorization: Bearer \(bridgeToken())\""
    }

    private func stopSample() -> String {
        "curl -s -X POST http://127.0.0.1:\(bridgePort)/v1/stop -H \"Authorization: Bearer \(bridgeToken())\""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        presets.note = "Copied."
    }
}
