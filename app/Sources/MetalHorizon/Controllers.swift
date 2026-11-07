import Foundation
import GameController
import IOKit.hid

// The controllers connected to this Mac, as macOS sees them: the GameController framework names the pads it knows
// (Xbox, PlayStation, Switch, MFi...), and IOKit lists every HID game device, wheels and sticks included.
// In the game they arrive through Wine: winebus.sys reads them (IOKit, and SDL2 for PlayStation, Switch and generic
// pads, mapped to an Xbox layout), XInput serves them, and engine patch 0012 hands them to the game through
// GameInput, the API the GDK's games use. That last part is turned on per launch (WINE_GAMEINPUT=1): by default
// when a controller is connected, so a keyboard-only player keeps exactly the input path that was tested.

enum ControllerMode: String, CaseIterable, Identifiable {
    case automatic, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "Always On"
        case .off: return "Off"
        }
    }
}

struct ControllerInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String          // Gamepad, Racing wheel, Joystick...
    let vendorID: Int
    let productID: Int
    let transport: String     // USB, Bluetooth...

    /// How the game gets it: Xbox pads directly, the others through SDL2's mappings.
    var route: String {
        switch vendorID {
        case 0x045e: return "XInput (Xbox)"
        case 0x054c, 0x057e, 0x2dc8, 0x0f0d, 0x0e6f, 0x24c6, 0x046d, 0x1532, 0x20d6, 0x0738: return "SDL2 → Xbox layout"
        case 0x044f, 0x0eb7, 0x11ff: return "DirectInput (wheel)"
        default: return kind == "Gamepad" ? "SDL2 → Xbox layout" : "DirectInput"
        }
    }
}

enum Controllers {
    /// HID game devices: usage page Generic Desktop, usages Joystick (4), Game Pad (5) and Multi-axis (8).
    static func hidDevices() -> [ControllerInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.compactMap { device -> ControllerInfo? in
            func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            let vendor = prop(kIOHIDVendorIDKey) as? Int ?? 0
            let product = prop(kIOHIDProductIDKey) as? Int ?? 0
            let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
            let name = (prop(kIOHIDProductKey) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Game controller"
            let transport = prop(kIOHIDTransportKey) as? String ?? ""
            let location = prop(kIOHIDLocationIDKey) as? Int ?? 0
            let wheelVendors = [0x044f, 0x0eb7, 0x11ff]
            let kind = wheelVendors.contains(vendor) || name.lowercased().contains("wheel") ? "Racing wheel"
                : usage == 5 ? "Gamepad" : usage == 8 ? "Multi-axis controller" : "Joystick"
            return ControllerInfo(id: String(format: "hid-%04x-%04x-%x", vendor, product, location), name: name, kind: kind,
                                  vendorID: vendor, productID: product, transport: transport)
        }
    }

    /// The pads the GameController framework knows that IOKit did not list (some Bluetooth pads, MFi).
    static func gameControllerDevices(excluding names: Set<String>) -> [ControllerInfo] {
        GCController.controllers().compactMap { controller -> ControllerInfo? in
            let name = controller.vendorName ?? controller.productCategory
            guard !names.contains(name) else { return nil }
            return ControllerInfo(id: "gc-\(ObjectIdentifier(controller).hashValue)", name: name, kind: "Gamepad",
                                  vendorID: 0, productID: 0, transport: controller.isAttachedToDevice ? "built-in" : "")
        }
    }

    static func connected() -> [ControllerInfo] {
        let hid = hidDevices()
        let names = Set(hid.map(\.name))
        return (hid + gameControllerDevices(excluding: names)).sorted { $0.name < $1.name }
    }

    /// Whether this launch gets GameInput (engine patch 0012).
    static func gameInputEnabled(mode: ControllerMode, connected: [ControllerInfo]) -> Bool {
        switch mode {
        case .on: return true
        case .off: return false
        case .automatic: return !connected.isEmpty
        }
    }
}

/// Keeps the list current while the window is open.
@MainActor
final class ControllerMonitor: ObservableObject {
    @Published private(set) var controllers: [ControllerInfo] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init() {
        refresh()
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // wheels and sticks are HID only: a slow poll catches them
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let now = Controllers.connected()
        if now != controllers { controllers = now }
    }
}
