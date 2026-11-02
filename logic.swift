import Foundation

// A saved pan, tilt, and zoom. `move` walks there at a speed. A jump sends
// the angle once. Nil speeds use the app's 15°/s or 32°/s choice.
struct Framing: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var pan: Double
    var tilt: Double
    var zoom: Double
    var move: Bool
    var panSpeed: Double?
    var zoomSpeed: Double?

    var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Preset" : trimmed
    }
}

struct FramingFile: Codable {
    var version: Int
    var presets: [Framing]
}

// Import accepts a hand-written list that has no ids. `glide` is the older
// name of `move`.
struct FramingIn: Codable {
    var name: String?
    var pan: Double
    var tilt: Double
    var zoom: Double
    var move: Bool?
    var glide: Bool?
    var panSpeed: Double?
    var zoomSpeed: Double?

    var framing: Framing {
        Framing(
            id: UUID(),
            name: name ?? "Preset",
            pan: pan,
            tilt: tilt,
            zoom: zoom,
            move: move ?? glide ?? true,
            panSpeed: panSpeed,
            zoomSpeed: zoomSpeed
        )
    }
}

struct LooseFile: Codable {
    var presets: [FramingIn]
}

func approach(_ current: Double, _ dest: Double, _ step: Double) -> Double {
    let delta = dest - current
    if abs(delta) <= step || step <= 0 { return dest }
    return current + (delta > 0 ? step : -step)
}

struct HoldAxes: Equatable {
    var pan: Int
    var tilt: Int
    var zoom: Int
}

// Virtual key codes: A S D W Q E Z X, then arrow up and down.
// Opposite keys cancel. Diagonals share an axis with the letter keys and
// still clamp to one step, so holding both does not double the speed.
func holdAxes(keys: Set<UInt16>) -> HoldAxes {
    var pan = 0
    var tilt = 0
    var zoom = 0
    if keys.contains(0x00) { pan -= 1 }
    if keys.contains(0x02) { pan += 1 }
    if keys.contains(0x0D) { tilt += 1 }
    if keys.contains(0x01) { tilt -= 1 }
    if keys.contains(0x0C) { pan -= 1; tilt += 1 }
    if keys.contains(0x0E) { pan += 1; tilt += 1 }
    if keys.contains(0x06) { pan -= 1; tilt -= 1 }
    if keys.contains(0x07) { pan += 1; tilt -= 1 }
    if keys.contains(0x7E) { zoom += 1 }
    if keys.contains(0x7D) { zoom -= 1 }
    return HoldAxes(
        pan: max(-1, min(1, pan)),
        tilt: max(-1, min(1, tilt)),
        zoom: max(-1, min(1, zoom))
    )
}

let holdKeyCodes: Set<UInt16> = [0x00, 0x01, 0x02, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x7D, 0x7E]

func sanitizeFramings(_ items: [Framing]) -> [Framing] {
    var out: [Framing] = []
    for var item in items.prefix(20) {
        guard item.pan.isFinite, item.tilt.isFinite, item.zoom.isFinite else { continue }
        item.name = String(item.name.replacingOccurrences(of: "\n", with: " ").prefix(40))
        if let speed = item.panSpeed, !(speed.isFinite && speed > 0) { item.panSpeed = nil }
        if let speed = item.zoomSpeed, !(speed.isFinite && speed > 0) { item.zoomSpeed = nil }
        out.append(item)
    }
    return out
}

func decodeFramings(_ data: Data) -> [Framing]? {
    let decoder = JSONDecoder()
    if let file = try? decoder.decode(FramingFile.self, from: data) {
        return sanitizeFramings(file.presets)
    }
    if let list = try? decoder.decode([Framing].self, from: data) {
        return sanitizeFramings(list)
    }
    if let loose = try? decoder.decode(LooseFile.self, from: data) {
        return sanitizeFramings(loose.presets.map(\.framing))
    }
    if let list = try? decoder.decode([FramingIn].self, from: data) {
        return sanitizeFramings(list.map(\.framing))
    }
    return nil
}

func jsonEscape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

struct HttpRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: String
}

func contentLength(_ header: String) -> Int {
    for line in header.components(separatedBy: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard name == "content-length" else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Int(value) ?? 0
    }
    return 0
}

/// Headers are not enough when the request declares a body. Hold and release
/// send a short JSON body after the header block.
func requestReady(_ raw: String) -> Bool {
    guard let range = raw.range(of: "\r\n\r\n") else { return false }
    let header = String(raw[..<range.lowerBound])
    let bodyBytes = raw[range.upperBound...].utf8.count
    return bodyBytes >= contentLength(header)
}

func parseHttpRequest(_ raw: String) -> HttpRequest? {
    guard let range = raw.range(of: "\r\n\r\n") else { return nil }
    let lines = raw[..<range.lowerBound].components(separatedBy: "\r\n")
    guard let request = lines.first else { return nil }
    let bits = request.split(separator: " ")
    guard bits.count >= 2 else { return nil }
    var path = String(bits[1])
    if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { headers[name] = value }
    }
    let body = String(raw[range.upperBound...])
    return HttpRequest(method: String(bits[0]).uppercased(), path: path, headers: headers, body: body)
}

func recallPresetID(_ path: String) -> UUID? {
    let prefix = "/v1/presets/recall/"
    guard path.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(path.dropFirst(prefix.count)))
}

struct HoldCommand {
    var id: String
    var pan: Int
    var tilt: Int
    var zoom: Int
}

func parseHold(_ json: String) -> HoldCommand? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String,
          validHoldID(id) else { return nil }
    return HoldCommand(id: id, pan: axis(object["pan"]), tilt: axis(object["tilt"]), zoom: axis(object["zoom"]))
}

func parseRelease(_ json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String,
          validHoldID(id) else { return nil }
    return id
}

private func validHoldID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
}

private func axis(_ value: Any?) -> Int {
    let number = (value as? NSNumber)?.intValue ?? 0
    return max(-1, min(1, number))
}

func presetSlot(_ path: String) -> Int? {
    let prefix = "/v1/presets/"
    let suffix = "/recall"
    guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
    let middle = path.dropFirst(prefix.count).dropLast(suffix.count)
    guard let slot = Int(middle), (1...20).contains(slot), String(slot) == middle else { return nil }
    return slot
}

func tokensMatch(_ offered: String, _ expected: String) -> Bool {
    let left = Array(offered.utf8)
    let right = Array(expected.utf8)
    if left.count != right.count || left.isEmpty { return false }
    var diff: UInt8 = 0
    for index in left.indices { diff |= left[index] ^ right[index] }
    return diff == 0
}

func authorized(_ headers: [String: String], token: String) -> Bool {
    if let key = headers["x-pocket3-key"], tokensMatch(key, token) { return true }
    guard let header = headers["authorization"] else { return false }
    let parts = header.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
    return tokensMatch(String(parts[1]), token)
}
