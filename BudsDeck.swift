// BudsDeck — menu bar control for OnePlus / OPPO / realme earbuds that speak the
// HeyMelody ("enco link") protocol over Bluetooth Classic RFCOMM.
//
// Frame:  AA <len varint> 00 00 <cmd u16le> <seq u8> <paylen u16le> <payload>
// Reply:  same cmd with bit 15 set; payload[0] is a status byte (00 = ok).
// Verified on OnePlus Buds 3 (2026-10-31): battery 0x0106, noise mode get 0x010C / set 0x0404.
import AppKit
import SwiftUI
import IOBluetooth
import CoreBluetooth
import ServiceManagement

// MARK: - Noise modes (bit index in the 0x0404 / 0x010C bitmap)

let modeOff = 3
let modeTransparency = 9

/// Noise-cancelling levels. Naming: one automatic mode called "Adaptive" (Apple / Samsung /
/// Nothing; OnePlus says "Smart Scene") plus OnePlus's Max / Moderate / Mild ladder.
/// Bit order matches a hands-on Buds 4 / Buds Pro 3 implementation (0x10 High, 0x20 Moderate,
/// 0x40 Low, 0x80 Auto) and our own data: Smart's auto-pick (0x010C type 4) reported bits 5
/// and 6, i.e. strengths, never 7. Bit 8 is accepted but left out (transparency on siblings).
let ancVariants: [(bit: Int, label: String)] = [
    (7, "Adaptive"),
    (4, "Max"),
    (5, "Moderate"),
    (6, "Mild"),
]

// MARK: - Protocol

enum Cmd: UInt16 {
    case battery = 0x0106, noiseGet = 0x010C, noiseSet = 0x0404
    case eqGet = 0x010F, eqListGet = 0x0122, eqPresetSet = 0x0406, eqCustomSet = 0x0418
    case wearGet = 0x0109, notify = 0x0204, productGet = 0x0103
}

/// Per-bud status pairs `(idx, flags)…` (idx 1 = L, 2 = R, 3 = case) → in-ear map.
/// In each flags byte, 0x02 set = in an ear (0x01 clear = in the case).
func parseWear(_ pairs: ArraySlice<UInt8>) -> [String: Bool] {
    var out: [String: Bool] = [:], i = pairs.startIndex
    while i + 1 < pairs.endIndex {
        if let n = [1: "L", 2: "R"][Int(pairs[i])] { out[n] = pairs[i + 1] & 0x02 != 0 }
        i += 2
    }
    return out
}

let notWornMessage = "Put an earbud in to change noise control"

/// Sound Master presets. IDs verified on Buds 3 (set + read back); names are OnePlus's,
/// matching the IDs the Buds Pro 3 uses (Balanced 0, Bold 1, Serenade 2, Bass 3).
let eqPresets: [(id: Int, name: String)] = [(0, "Balanced"), (1, "Bold"), (2, "Serenade"), (3, "Bass")]
let eqBands = [62, 250, 1000, 4000, 8000, 16000]

/// A user EQ slot as the buds report it (0x8122).
struct CustomEQ { var id: Int; var name: String; var min: Int; var max: Int; var db: [Int] }

/// 0x8122 payload: [status][count] then per slot
/// [selected][min s8][max s8][id][nameLen][name][n][(freq u16le, dB s8) × n].
func parseEQList(_ p: [UInt8]) -> [CustomEQ] {
    guard p.count >= 2, p[0] == 0 else { return [] }
    var out: [CustomEQ] = [], i = 2
    for _ in 0..<Int(p[1]) {
        guard i + 5 <= p.count else { break }
        let mn = Int(Int8(bitPattern: p[i + 1])), mx = Int(Int8(bitPattern: p[i + 2])), id = Int(p[i + 3])
        let nl = Int(p[i + 4]); i += 5
        guard i + nl < p.count else { break }
        let name = String(decoding: p[i..<(i + nl)], as: UTF8.self); i += nl
        let n = Int(p[i]); i += 1
        guard i + n * 3 <= p.count else { break }
        let db = (0..<n).map { Int(Int8(bitPattern: p[i + $0 * 3 + 2])) }; i += n * 3
        out.append(CustomEQ(id: id, name: name, min: mn, max: mx, db: db))
    }
    return out
}

/// 0x0418 payload. op: 1 create (id 0 = new slot), 2 save + select, 3 delete.
func customEQPayload(op: UInt8, id: Int, name: String, db: [Int], min: Int = -6, max: Int = 6) -> [UInt8] {
    let nb = Array(name.utf8)
    var p: [UInt8] = [op, UInt8(bitPattern: Int8(min)), UInt8(bitPattern: Int8(max)), UInt8(id), UInt8(nb.count)] + nb
    p.append(UInt8(eqBands.count))
    for (f, d) in zip(eqBands, db) {
        p += [UInt8(f & 0xFF), UInt8(f >> 8), UInt8(bitPattern: Int8(Swift.min(Swift.max(d, min), max)))]
    }
    return p
}

func varint(_ v: Int) -> [UInt8] {
    var v = v, out: [UInt8] = []
    repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
    return out
}

func frame(_ cmd: UInt16, seq: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    let inner = [UInt8(cmd & 0xFF), UInt8(cmd >> 8), seq,
                 UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)] + payload
    return [0xAA] + varint(2 + inner.count) + [0x00, 0x00] + inner
}

/// Pull whole frames out of `buf`, leaving any partial tail in place.
func takeFrames(_ buf: inout [UInt8]) -> [(cmd: UInt16, payload: [UInt8])] {
    var out: [(UInt16, [UInt8])] = [], i = 0
    while i < buf.count {
        guard buf[i] == 0xAA else { i += 1; continue }
        var p = i + 1, shift = 0, done = false
        while p < buf.count { let b = buf[p]; shift += 7; p += 1; if b & 0x80 == 0 { done = true; break } }
        guard done, p + 7 <= buf.count else { break }
        guard buf[p] == 0, buf[p + 1] == 0 else { i += 1; continue }
        let cmd = UInt16(buf[p + 2]) | UInt16(buf[p + 3]) << 8
        let len = Int(buf[p + 5]) | Int(buf[p + 6]) << 8
        let end = p + 7 + len
        guard end <= buf.count else { break }
        out.append((cmd, Array(buf[(p + 7)..<end])))
        i = end
    }
    buf.removeFirst(min(i, buf.count))
    return out
}

func bitmap(_ bit: Int) -> [UInt8] { let v = 1 << bit; return [UInt8(v & 0xFF), UInt8(v >> 8)] }

// MARK: - Link to the buds

final class BudsLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    static let serviceUUID: IOBluetoothSDPUUID = {
        let hex = "0000079ad10211e19b2300025b00a5a5"
        let bytes = stride(from: 0, to: 32, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        return IOBluetoothSDPUUID(bytes: bytes, length: 16)
    }()

    var device: IOBluetoothDevice?
    var channel: IOBluetoothRFCOMMChannel?
    var opening = false          // one open at a time; extra opens never complete and leak
    var ready = false            // false until the buds' on-open burst has passed
    /// Injectable for tests; default finds a connected HeyMelody device.
    var deviceProvider: () -> IOBluetoothDevice? = BudsLink.findConnected
    var seq: UInt8 = 0
    var rx: [UInt8] = []
    var queue: [[UInt8]] = []

    var battery: [String: (level: Int, charging: Bool)] = [:]
    var mode: Int?               // current bit index
    var eq: Int?                 // current EQ id (preset 0–3, or a custom slot id)
    var customEQs: [CustomEQ] = []
    /// Model code the buds report (0x8103), e.g. "063C14" on OnePlus Buds 3. Same for every
    /// unit of a model, so it identifies unknown models without anything personal.
    var productID: String?
    /// Reports why connecting failed (permission, no device, timeout); the model forwards it.
    var onFailure: (String) -> Void = { _ in }
    /// The buds only report the case while docked / lid recently open, so keep the last reading.
    var store = UserDefaults.standard
    /// Keyed per device so a second pair of buds never shows the first pair's case.
    private var caseKey: String { "case-" + (device?.addressString ?? "") }
    var lastCase: (level: Int, charging: Bool, at: Date)? {
        guard let d = store.dictionary(forKey: caseKey), let at = d["at"] as? Date,
              let level = d["level"] as? Int else { return nil }
        return (level, d["charging"] as? Bool ?? false, at)
    }
    var lastError: String?       // connection problems
    var noiseNotice: String?     // why the last noise-mode change didn't happen
    var inEar: [String: Bool] = [:]
    /// nil until the buds have reported wear status. The buds run noise control with one
    /// bud in, so only "no bud in" blocks a mode change.
    var anyWorn: Bool? { inEar.isEmpty ? nil : inEar.values.contains(true) }

    /// The custom EQ slot that is actually selected (falls back to the first one).
    var selectedCustom: CustomEQ? { customEQs.first { $0.id == eq } ?? customEQs.first }
    var onChange: () -> Void = {}

    /// Any paired device (connected or not) that advertises the HeyMelody service.
    static func hasPairedCompatible() -> Bool {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).contains { d in
            ((d.services as? [IOBluetoothSDPServiceRecord]) ?? []).contains { $0.matchesUUIDArray([serviceUUID]) }
        }
    }

    /// First paired + connected device that advertises the HeyMelody service.
    static func findConnected() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { d in
            d.isConnected() && ((d.services as? [IOBluetoothSDPServiceRecord]) ?? [])
                .contains { $0.matchesUUIDArray([BudsLink.serviceUUID]) }
        }
    }

    /// Forget everything about the last connection so the panel never shows stale data.
    func resetState() {
        device = nil; channel = nil; opening = false; ready = false
        queue.removeAll(); rx.removeAll()
        battery = [:]; mode = nil; eq = nil; customEQs = []; inEar = [:]; noiseNotice = nil; productID = nil
    }

    func ensureOpen() {
        if channel?.isOpen() == true || opening { return }
        ready = false
        guard let dev = deviceProvider() else {
            resetState(); lastError = nil; onChange()  // the header already says "No buds connected"
            // Not a failure if compatible buds are paired but just not connected right now.
            if !BudsLink.hasPairedCompatible() { onFailure("no_compatible_device") }
            return
        }
        device = dev
        let rec = (dev.services as? [IOBluetoothSDPServiceRecord])?
            .first { $0.matchesUUIDArray([BudsLink.serviceUUID]) }
        var chID: BluetoothRFCOMMChannelID = 0
        guard rec?.getRFCOMMChannelID(&chID) == kIOReturnSuccess else {
            lastError = "No control channel"; onChange(); onFailure("no_control_channel"); return
        }
        var ch: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: chID, delegate: self)
        guard r == kIOReturnSuccess, let ch else {
            lastError = "Couldn't reach the earbuds"; channel = nil; queue.removeAll(); onChange()
            onFailure("open_failed"); return
        }
        channel = ch; opening = true
        // If the open never completes, give up so the next refresh can retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.opening, self.channel === ch else { return }
            ch.close(); self.channel = nil; self.opening = false; self.queue.removeAll()
            self.lastError = "Couldn't reach the earbuds"; self.onChange()
            self.onFailure("timeout")
        }
    }

    func send(_ cmd: Cmd, _ payload: [UInt8] = []) {
        ensureOpen()
        // No connection and none in progress: drop it. Queueing would replay stale
        // commands (including settings changes) whenever the buds reconnect.
        guard channel != nil else { return }
        seq = seq &+ 1; if seq == 0 { seq = 1 }
        queue.append(frame(cmd.rawValue, seq: seq, payload))
        flush()
    }

    /// light: just what changes often (battery, wear, mode); used while the panel is open.
    func refresh(light: Bool = false) {
        send(.battery); send(.wearGet); send(.noiseGet, [0x01, 0x01])
        if !light { send(.eqGet); send(.eqListGet); if productID == nil { send(.productGet) } }
    }

    func setPreset(_ id: Int) { send(.eqPresetSet, [UInt8(id)]); send(.eqGet) }

    /// Save gains into the first custom slot and select it (op 2); create one if none exists.
    func setCustom(_ db: [Int]) {
        if let slot = selectedCustom {
            send(.eqCustomSet, customEQPayload(op: 2, id: slot.id, name: slot.name, db: db, min: slot.min, max: slot.max))
        } else {
            send(.eqCustomSet, customEQPayload(op: 1, id: 0, name: "Custom", db: db))
        }
        send(.eqGet); send(.eqListGet)
    }

    func setMode(_ bit: Int) {
        // The firmware rejects mode changes with no bud worn; don't send a doomed command.
        // With one bud in, send it and let the firmware decide (0x0E → notice).
        if anyWorn == false { noiseNotice = notWornMessage; onChange(); return }
        send(.noiseSet, [0x01, 0x01] + bitmap(bit))
        send(.noiseGet, [0x01, 0x01])
    }

    private func flush() {
        guard ready, let ch = channel, ch.isOpen() else { return }
        while !queue.isEmpty {
            var f = queue.removeFirst()
            _ = ch.writeSync(&f, length: UInt16(f.count))
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard ch === channel else { return }   // a superseded/timed-out attempt
        opening = false
        guard status == kIOReturnSuccess else {
            lastError = "Couldn't reach the earbuds"; channel = nil; queue.removeAll(); onChange()
            onFailure("open_failed"); return
        }
        lastError = nil
        // The buds push a host-list notification right after open and drop
        // commands sent during that burst; give it a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.channel === ch else { return }
            self.ready = true; self.flush()
        }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        guard ch === channel else { return }
        resetState(); onChange()   // e.g. buds went into the case; next refresh reconnects
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
        rx += UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length)
        for f in takeFrames(&rx) { handle(f.cmd, f.payload) }
        onChange()
    }

    private func handle(_ cmd: UInt16, _ p: [UInt8]) {
        switch cmd {
        case Cmd.battery.rawValue | 0x8000 where p.count >= 2 && p[0] == 0:
            let names = [1: "L", 2: "R", 3: "Case"]
            battery = [:]   // drop entries the buds no longer report (e.g. the case)
            var i = 2
            while i + 1 < p.count, i < 2 + Int(p[1]) * 2 {
                if let n = names[Int(p[i])], p[i + 1] != 0xFF { battery[n] = (Int(p[i + 1] & 0x7F), p[i + 1] & 0x80 != 0) }
                i += 2
            }
            if let c = battery["Case"] {
                store.set(["level": c.level, "charging": c.charging, "at": Date()], forKey: caseKey)
            }
        case Cmd.noiseGet.rawValue | 0x8000 where p.count >= 4 && p[0] == 0 && p[2] == 0x01:
            let bits = p[3...].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            mode = (0..<16).first { bits & (1 << $0) != 0 }
        case Cmd.noiseSet.rawValue | 0x8000:
            // 0x0E = buds refuse while not worn (observed on Buds 3).
            switch p.first {
            case 0?: noiseNotice = nil
            case 0x0E?: noiseNotice = notWornMessage
            case let s?: noiseNotice = "The earbuds didn't accept that mode (code \(s))"
            case nil: break
            }
        case Cmd.wearGet.rawValue | 0x8000 where p.count >= 2 && p[0] == 0:
            applyWear(parseWear(p[2...]))
        case Cmd.notify.rawValue where p.count >= 6 && p[0] == 0x02:
            applyWear(parseWear(p[2...]))   // live wear change: [02, ?, 01, L, 02, R, …]
        case Cmd.eqGet.rawValue | 0x8000 where p.count >= 2 && p[0] == 0:
            eq = Int(p[1])
        case Cmd.productGet.rawValue | 0x8000 where p.count >= 4 && p[0] == 0:
            productID = String(format: "%02X%02X%02X", p[3], p[2], p[1])
        case Cmd.eqListGet.rawValue | 0x8000:
            customEQs = parseEQList(p)
        default: break  // other notifications (e.g. 0x0204 host list) ignored
        }
    }

    private func applyWear(_ w: [String: Bool]) {
        guard !w.isEmpty else { return }
        inEar.merge(w) { $1 }
        if anyWorn == true, noiseNotice == notWornMessage { noiseNotice = nil }
    }
}

// MARK: - Anonymous usage ping

/// One `app_active` event per day (on days the buds connect) so the maintainer can count active installs.
/// Sent: a random install ID (not derived from anything about the user or Mac), app version,
/// macOS version, CPU architecture and the buds model name. Not sent: names, emails,
/// Bluetooth addresses, listening data. IP addresses are discarded by the analytics project.
/// Users can turn it off in the panel's settings menu.
enum Telemetry {
    static let host = "https://us.i.posthog.com"
    /// PostHog project token: write-only, safe to ship in client code. Empty = disabled.
    static let token = "phc_CgEzRxuLFuHTpnpjSeNU8u54PDffGwPX64YvPaG2Rktf"
    static var store = UserDefaults.standard

    static var enabled: Bool {
        get { !store.bool(forKey: "telemetryOff") }
        set { store.set(!newValue, forKey: "telemetryOff") }
    }

    static var installID: String {
        if let id = store.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        store.set(id, forKey: "installID")
        return id
    }

    /// Known model names. The Bluetooth name is user-editable ("Alex's OnePlus Buds 3"),
    /// so it is never sent as-is: only a canonical name from this list, or "other".
    /// Longer names first so "Buds Pro 3" wins over "Buds 3".
    static let knownModels = [
        "OnePlus Nord Buds 3 Pro", "OnePlus Nord Buds 3r", "OnePlus Nord Buds 3", "OnePlus Nord Buds 2r",
        "OnePlus Nord Buds 2", "OnePlus Nord Buds", "OnePlus Buds Pro 3", "OnePlus Buds Pro 2R",
        "OnePlus Buds Pro 2", "OnePlus Buds Pro", "OnePlus Buds Z2", "OnePlus Buds Z", "OnePlus Buds 4",
        "OnePlus Buds 3", "OnePlus Buds", "OPPO Enco X3", "OPPO Enco X2", "OPPO Enco X", "OPPO Enco Air4 Pro",
        "OPPO Enco Air4", "OPPO Enco Air3 Pro", "OPPO Enco Air3", "OPPO Enco Air2 Pro", "OPPO Enco Air2",
        "OPPO Enco Air", "OPPO Enco Buds3 Pro", "OPPO Enco Buds3", "OPPO Enco Buds2 Pro", "OPPO Enco Buds2",
        "OPPO Enco Free3", "OPPO Enco Free2", "realme Buds Air 7 Pro", "realme Buds Air 7", "realme Buds Air 6 Pro",
        "realme Buds Air 6", "realme Buds Air 5 Pro", "realme Buds Air 5", "realme Buds T310", "realme Buds T300",
    ]

    static func modelName(_ bluetoothName: String) -> String {
        let n = bluetoothName.lowercased()
        return knownModels.first { n.contains($0.lowercased()) } ?? "other"
    }

    /// Earbuds fields for an event: canonical model name (never the Bluetooth name) and model code.
    static func budsProps(name: String?, productID: String?) -> [String: Any] {
        var p: [String: Any] = [:]
        if let name { p["buds_model"] = modelName(name) }
        if let productID { p["product_id"] = productID }
        return p
    }

    static func payload(event: String = "app_active", extra: [String: Any] = [:]) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var props: [String: Any] = [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "arch": { var u = utsname(); uname(&u); return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }(),
            "$process_person_profile": false,   // no person profiles
            "$geoip_disable": true,             // no location lookup
        ]
        props.merge(extra) { $1 }
        return ["api_key": token, "event": event, "distinct_id": installID, "properties": props]
    }

    /// Sends `event` at most once per UTC day per `key` (default: the event name), only when enabled.
    /// Events: app_launched (every day the app runs), app_active (days the buds connect),
    /// connect_failed with a reason code.
    static func captureDaily(_ event: String, key: String? = nil, extra: [String: Any] = [:]) {
        guard enabled, !token.isEmpty else { return }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withFullDate])
        let dedupe = "sent-" + (key ?? event)
        guard store.string(forKey: dedupe) != day,
              let body = try? JSONSerialization.data(withJSONObject: payload(event: event, extra: extra)) else { return }
        var req = URLRequest(url: URL(string: host + "/i/v0/e/")!)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                DispatchQueue.main.async { store.set(day, forKey: dedupe) }
            }
        }.resume()
    }
}

// MARK: - Update check

/// Once a day, asks GitHub for the latest release. Sends nothing about the user (a plain
/// public API request); works even with usage stats turned off.
enum Updater {
    static let api = URL(string: "https://api.github.com/repos/notacp/BudsDeck/releases/latest")!
    static var store = UserDefaults.standard
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Numeric compare of dotted versions ("0.10.0" > "0.9.2"); a leading "v" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Newer release than the running one, if the last check found one.
    static var available: (version: String, url: URL)? {
        guard let v = store.string(forKey: "latestVersion"), isNewer(v, than: current),
              let u = store.string(forKey: "latestURL").flatMap(URL.init(string:)) else { return nil }
        return (v, u)
    }

    static func checkIfDue(_ done: @escaping () -> Void) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withFullDate])
        guard store.string(forKey: "updateCheckedDay") != day else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let url = json["html_url"] as? String else { return }
            DispatchQueue.main.async {
                store.set(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), forKey: "latestVersion")
                store.set(url, forKey: "latestURL"); store.set(day, forKey: "updateCheckedDay")
                done()
            }
        }.resume()
    }
}

// MARK: - Glass panel UI (macOS 26+ Liquid Glass)

/// Bridges BudsLink's callbacks into SwiftUI.
final class BudsModel: ObservableObject {
    let link = BudsLink()
    /// ANC variant the big "Noise Cancelling" button returns to; remembered across launches.
    @Published var ancBit: Int = UserDefaults.standard.object(forKey: "ancLevelBit") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(ancBit, forKey: "ancLevelBit") }
    }
    private var timer: Timer?

    init() {
        link.onChange = { [weak self] in
            guard let self else { return }
            if let m = link.mode, ancVariants.contains(where: { $0.bit == m }) { ancBit = m }
            objectWillChange.send()
        }
        link.onFailure = { [weak self] reason in
            let buds = Telemetry.budsProps(name: self?.link.device?.name, productID: self?.link.productID)
            Telemetry.captureDaily("connect_failed", key: "connect_failed-" + reason, extra: buds.merging(["reason": reason]) { $1 })
        }
        // Defer the first refresh: publishing during @StateObject init is not allowed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            link.refresh()
            Telemetry.captureDaily("app_launched")
            if bluetoothDenied { Telemetry.captureDaily("connect_failed", key: "connect_failed-permission_denied", extra: ["reason": "permission_denied"]) }
            Updater.checkIfDue { [weak self] in self?.objectWillChange.send() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            link.refresh()
            // Once a day at most, and only on days the buds actually connect (and the model
            // code has been read), so "active" means used with earbuds.
            if let name = link.device?.name, let pid = link.productID {
                Telemetry.captureDaily("app_active", extra: Telemetry.budsProps(name: name, productID: pid))
            }
            Updater.checkIfDue { [weak self] in self?.objectWillChange.send() }
        }
    }

    var shareUsage: Bool {
        get { Telemetry.enabled }
        set { Telemetry.enabled = newValue; objectWillChange.send() }
    }

    /// Bluetooth permission for this app (IOBluetooth is gated by the same TCC grant).
    var bluetoothDenied: Bool { [.denied, .restricted].contains(CBManager.authorization) }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }

    var isANC: Bool { link.mode.map { m in ancVariants.contains { $0.bit == m } } ?? false }
    /// Same symbols as the panel's mode buttons, so the menu bar shows the mode at a glance.
    var menuSymbol: String {
        switch link.mode {
        case modeTransparency?: "ear.badge.waveform"
        case let m? where ancVariants.contains(where: { $0.bit == m }): "waveform.slash"
        default: "earbuds"
        }
    }
}

struct ModeButton: View {
    let title: String, symbol: String, active: Bool, enabled: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(active ? .white : .primary)
                    .glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                 in: .circle)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct BatteryPill: View {
    let label: String, level: Int, charging: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: charging ? "battery.100percent.bolt"
                  : level > 60 ? "battery.100percent" : level > 25 ? "battery.50percent" : "battery.25percent")
                .foregroundStyle(level <= 20 && !charging ? .red : .primary)
            Text("\(label) \(level)%").font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

struct EQSection: View {
    @ObservedObject var model: BudsModel
    @State private var open = false
    @State private var draft: [Double] = Array(repeating: 0, count: 6)
    @State private var dragging: Int?   // band being dragged; don't overwrite it from the buds
    var link: BudsLink { model.link }
    var isCustom: Bool { link.eq.map { id in !eqPresets.contains { $0.id == id } } ?? false }
    var currentName: String {
        guard let id = link.eq else { return "—" }
        return eqPresets.first { $0.id == id }?.name ?? "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.vertical.3")
                    Text("Equalizer").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(currentName).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(link.device == nil)

            if open {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(eqPresets, id: \.id) { p in chip(p.name, active: link.eq == p.id) { link.setPreset(p.id) } }
                        chip("Custom", active: isCustom) { link.setCustom(draft.map { Int($0) }) }
                    }
                }
                if isCustom {
                    VStack(spacing: 4) {
                        ForEach(0..<eqBands.count, id: \.self) { i in
                            HStack(spacing: 8) {
                                Text(bandLabel(eqBands[i])).font(.caption.monospacedDigit())
                                    .frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                                Slider(value: $draft[i], in: -6...6, step: 1) { editing in
                                    dragging = editing ? i : nil
                                    if !editing { link.setCustom(draft.map { Int($0) }) }
                                }
                                Text(String(format: "%+d", Int(draft[i]))).font(.caption.monospacedDigit())
                                    .frame(width: 26, alignment: .trailing)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Flat") { draft = Array(repeating: 0, count: 6); link.setCustom(Array(repeating: 0, count: 6)) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: link.selectedCustom?.db ?? []) { syncDraft() }
        .onChange(of: link.selectedCustom?.id) { syncDraft() }
    }

    private func syncDraft() {
        guard dragging == nil, let db = link.selectedCustom?.db, db.count == 6 else { return }
        draft = db.map(Double.init)
    }

    private func bandLabel(_ f: Int) -> String { f >= 1000 ? "\(f / 1000)k" : "\(f)" }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .foregroundStyle(active ? .white : .primary)
                .glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Calm, glass-styled status row (replaces a bare orange warning label).
struct Notice: View {
    let text: String, symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 12))
    }
}

struct Panel: View {
    @ObservedObject var model: BudsModel
    @State private var panelOpen = false
    var link: BudsLink { model.link }

    var body: some View {
        let connected = link.device != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "earbuds").font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.device?.name ?? "No buds connected").font(.headline)
                    Text(!connected ? "OnePlus, OPPO or realme earbuds"
                         : link.anyWorn == false ? "Not in your ears" : "Listening Mode")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let update = Updater.available {
                Button { NSWorkspace.shared.open(update.url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                        Text("BudsDeck \(update.version) is available").font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Text("Download").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            if !link.battery.isEmpty {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(["L", "R"], id: \.self) { k in
                            if let b = link.battery[k] { BatteryPill(label: k, level: b.level, charging: b.charging) }
                        }
                        // Live when docked; otherwise the most recent reading (the buds stop reporting the case).
                        if let c = link.battery["Case"] ?? link.lastCase.map({ ($0.level, $0.charging) }) {
                            BatteryPill(label: "Case", level: c.level, charging: c.charging)
                        }
                    }
                }
            }

            if !connected {
                // Empty state: no dead controls, just the way to connect.
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension")!)
                } label: {
                    Label("Open Bluetooth Settings", systemImage: "gearshape")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ModeButton(title: "Off", symbol: "circle.slash", active: link.mode == modeOff,
                                   enabled: connected) { link.setMode(modeOff) }
                        ModeButton(title: "Noise Cancelling", symbol: "waveform.slash", active: model.isANC,
                                   enabled: connected) { link.setMode(model.ancBit) }
                        ModeButton(title: "Transparency", symbol: "ear.badge.waveform", active: link.mode == modeTransparency,
                                   enabled: connected) { link.setMode(modeTransparency) }
                    }
                }

                if model.isANC && ancVariants.count > 1 {
                    Picker("Level", selection: Binding(get: { model.ancBit }, set: { model.ancBit = $0; link.setMode($0) })) {
                        ForEach(ancVariants, id: \.bit) { Text($0.label).tag($0.bit) }
                    }
                    .pickerStyle(.menu)
                }

                EQSection(model: model)
            }

            if model.bluetoothDenied {
                Notice(text: "BudsDeck needs Bluetooth access. Turn it on in System Settings › Privacy & Security › Bluetooth.",
                       symbol: "lock.shield")
                Button("Open Bluetooth Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .buttonStyle(.borderless).font(.caption)
            }

            if connected, let notice = link.noiseNotice ?? (link.anyWorn == false ? notWornMessage : nil) {
                Notice(text: notice, symbol: notice == notWornMessage ? "earbuds" : "exclamationmark.circle")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let e = link.lastError {
                Notice(text: e, symbol: "exclamationmark.triangle")
            }

            Divider()
            HStack {
                Button("Refresh") { link.refresh() }
                Spacer()
                Menu {
                    Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
                    Toggle("Share Anonymous Usage Stats", isOn: Binding(get: { model.shareUsage }, set: { model.shareUsage = $0 }))
                    Divider()
                    Button("What's Shared…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/notacp/BudsDeck#privacy")!)
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(16)
        .frame(width: 320)
        .animation(.snappy, value: link.noiseNotice)
        .animation(.snappy, value: link.anyWorn)
        // Refresh when the panel comes forward, then every 3 s while it stays open:
        // the buds don't announce wear changes, so polling is the only way to stay current.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            panelOpen = true; link.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in panelOpen = false }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if panelOpen { link.refresh(light: true) }
        }
    }
}

struct BudsDeckApp: App {
    @StateObject private var model = BudsModel()
    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

func feed2(_ l: BudsLink, _ bytes: [UInt8]) {
    var b = bytes; b.withUnsafeMutableBytes { l.rfcommChannelData(nil, data: $0.baseAddress, length: $0.count) }
}

// `BudsDeck --selftest`: frame codec against bytes captured from real Buds 3.
if CommandLine.arguments.contains("--selftest") {
    precondition(frame(0x010C, seq: 1, [0x01, 0x01]) == [0xAA, 0x09, 0, 0, 0x0C, 0x01, 0x01, 0x02, 0x00, 0x01, 0x01])
    var buf: [UInt8] = [0xAA, 0x0F, 0, 0, 0x06, 0x81, 0x01, 0x08, 0x00, 0x00, 0x03, 0x01, 0x64, 0x02, 0x64, 0x03, 0x28,
                        0xAA, 0x0C, 0, 0, 0x0C, 0x81, 0x02, 0x05, 0x00, 0x00, 0x01, 0x01, 0x00, 0x02, 0xAA, 0x0C]
    let fs = takeFrames(&buf)
    precondition(fs.count == 2 && fs[0].cmd == 0x8106 && fs[1].payload == [0, 1, 1, 0x00, 0x02])
    precondition(buf == [0xAA, 0x0C])  // partial tail kept
    let l = BudsLink()
    l.store = UserDefaults(suiteName: "budsdeck.selftest")!
    l.store.removePersistentDomain(forName: "budsdeck.selftest")
    func feed(_ bytes: [UInt8]) { var b = bytes; b.withUnsafeMutableBytes { l.rfcommChannelData(nil, data: $0.baseAddress, length: $0.count) } }
    feed([0xAA, 0x0F, 0, 0, 0x06, 0x81, 0x01, 0x08, 0x00, 0x00, 0x03, 0x01, 0xE4, 0x02, 0x64, 0x03, 0x28])
    precondition(l.battery["L"]! == (100, true) && l.battery["Case"]!.level == 40)
    feed([0xAA, 0x0C, 0, 0, 0x0C, 0x81, 0x02, 0x05, 0x00, 0x00, 0x01, 0x01, 0x00, 0x02])
    precondition(l.mode == modeTransparency)
    let eqReply: [UInt8] = [0x00, 0x01, 0x01, 0xFA, 0x06, 0x04, 0x06] + Array("Custom".utf8) +
        [0x06, 0x3E, 0x00, 0x03, 0xFA, 0x00, 0x00, 0xE8, 0x03, 0x00, 0xA0, 0x0F, 0x00, 0x40, 0x1F, 0x00, 0x80, 0x3E, 0xFE]
    let eqs = parseEQList(eqReply)
    precondition(eqs.count == 1 && eqs[0].id == 4 && eqs[0].min == -6 && eqs[0].db == [3, 0, 0, 0, 0, -2])
    // Exactly the op-2 bytes that were sent to the buds and confirmed by read-back.
    precondition(customEQPayload(op: 2, id: 4, name: "Custom", db: [3, 0, 0, 0, 0, -2]) == [0x02] + Array(eqReply[3...]))
    // Wear: real 0x8109 payload (both worn), and a live notification with both out.
    precondition(parseWear([0x00, 0x03, 0x01, 0x07, 0x02, 0x07, 0x03, 0x04][2...]) == ["L": true, "R": true])
    precondition(parseWear([0x02, 0x00, 0x01, 0x05, 0x02, 0x05, 0x03, 0x04][2...]) == ["L": false, "R": false])
    let w = BudsLink()
    feed2(w, [0xAA, 0x08, 0, 0, 0x04, 0x84, 0x01, 0x01, 0x00, 0x0E])          // SET rejected → notice
    precondition(w.noiseNotice == notWornMessage)
    feed2(w, [0xAA, 0x0C, 0, 0, 0x0C, 0x81, 0x02, 0x05, 0x00, 0x00, 0x01, 0x01, 0x08, 0x00])  // mode poll
    precondition(w.noiseNotice == notWornMessage)                                 // must not flicker away
    feed2(w, [0xAA, 0x0F, 0, 0, 0x09, 0x81, 0x03, 0x08, 0x00, 0x00, 0x03, 0x01, 0x07, 0x02, 0x07, 0x03, 0x04])
    precondition(w.anyWorn == true && w.noiseNotice == nil)                      // worn → cleared
    // Case battery: live reading is remembered; a later report without the case keeps it as lastCase.
    feed2(l, [0xAA, 0x0D, 0, 0, 0x06, 0x81, 0x09, 0x06, 0x00, 0x00, 0x02, 0x01, 0x5A, 0x02, 0x5A])  // real: L 90, R 90
    precondition(l.battery["Case"] == nil && l.battery["L"]!.level == 90 && l.lastCase?.level == 40)
    // Disconnected: commands are dropped, not queued for a later replay.
    let d = BudsLink(); d.deviceProvider = { nil }
    d.battery = ["L": (90, false)]; d.mode = 4
    d.setMode(modeTransparency); d.refresh()
    precondition(d.queue.isEmpty && d.device == nil && d.battery.isEmpty && d.mode == nil)
    // Channel closed (buds into the case): stale state cleared.
    let c = BudsLink(); c.battery = ["L": (90, false)]; c.inEar = ["L": true]; c.queue = [[0xAA]]
    c.rfcommChannelClosed(nil)
    precondition(c.battery.isEmpty && c.inEar.isEmpty && c.queue.isEmpty)
    // One bud in: allowed (anyWorn). Both out: blocked with the notice.
    let o = BudsLink(); o.deviceProvider = { nil }
    o.inEar = ["L": true, "R": false]; precondition(o.anyWorn == true)
    o.inEar = ["L": false, "R": false]; o.setMode(4); precondition(o.noiseNotice == notWornMessage)
    // EQ edits target the selected custom slot, not the first one.
    let e = BudsLink()
    e.customEQs = [CustomEQ(id: 4, name: "Custom", min: -6, max: 6, db: [0, 0, 0, 0, 0, 0]),
                   CustomEQ(id: 6, name: "Mine", min: -6, max: 6, db: [2, 2, 2, 2, 2, 2])]
    e.eq = 6; precondition(e.selectedCustom?.name == "Mine")
    e.eq = 1; precondition(e.selectedCustom?.id == 4)   // preset active → first slot
    // Telemetry payload carries only the documented, non-identifying fields.
    Telemetry.store = UserDefaults(suiteName: "budsdeck.selftest")!
    let tp = Telemetry.payload(extra: Telemetry.budsProps(name: "OnePlus Buds 3", productID: "063C14"))
    let props = tp["properties"] as! [String: Any]
    precondition(Set(props.keys) == ["app_version", "os_version", "arch", "buds_model", "product_id", "$process_person_profile", "$geoip_disable"])
    precondition(tp["event"] as? String == "app_active" && UUID(uuidString: tp["distinct_id"] as! String) != nil)
    precondition(props["$process_person_profile"] as? Bool == false)
    // A renamed device never leaks the user's chosen name.
    precondition(Telemetry.modelName("Pradyumn’s OnePlus Buds 3") == "OnePlus Buds 3")
    precondition(Telemetry.modelName("OnePlus Buds Pro 3") == "OnePlus Buds Pro 3")
    precondition(Telemetry.modelName("Alex's earbuds") == "other")
    precondition(Telemetry.budsProps(name: "Sam's Nord Buds", productID: nil)["buds_model"] as? String == "other")
    let launched = Telemetry.payload(event: "app_launched")["properties"] as! [String: Any]
    precondition(launched["buds_model"] == nil && launched["product_id"] == nil)   // launch carries no buds data
    // Product ID: real 0x8103 reply from Buds 3 ("00 14 3C 06").
    feed2(l, [0xAA, 0x0B, 0, 0, 0x03, 0x81, 0x04, 0x04, 0x00, 0x00, 0x14, 0x3C, 0x06])
    precondition(l.productID == "063C14")
    // Failure reporting: no device paired → reason sent once; update compare.
    var reasons: [String] = []
    let f = BudsLink(); f.deviceProvider = { nil }; f.onFailure = { reasons.append($0) }
    f.ensureOpen()
    precondition(reasons.allSatisfy { $0 == "no_compatible_device" })
    precondition(Updater.isNewer("0.3.1", than: "0.3.0") && Updater.isNewer("v0.10.0", than: "0.9.9"))
    precondition(!Updater.isNewer("0.3.0", than: "0.3.0") && !Updater.isNewer("0.2.9", than: "0.3"))
    Telemetry.enabled = false; precondition(!Telemetry.enabled)
    l.store.removePersistentDomain(forName: "budsdeck.selftest")
    print("selftest ok"); exit(0)
}

BudsDeckApp.main()
