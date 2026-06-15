// DeviceWatch.swift -- attached-USB-device-to-port pairing and negotiated-speed
// floor, the M5 device-speed FALLBACK path.
//
// Why this exists: a non-e-marked cable presents no readable SOP' e-marker, so the
// coordinator can only report "Unknown [port active]" for it -- even with a charger
// on the far end. But when a USB3+ DEVICE (hub, dock, drive) enumerates on the far
// end of the cable, macOS negotiates a USB link speed end-to-end. That negotiated
// speed is a conservative FLOOR for the cable: the cable carried at least that rate,
// so the port can honestly report "At least <speed>". This is the M5 fallback the
// plan calls for; the SOP'-read PRIMARY path (the cable's own e-marker, read once a
// PD partner triggers Discover Identity) is separate and always takes precedence.
//
// Adapted from whatcable
//   Sources/WhatCableDarwinBackend/Watchers/USBWatcher.swift:
//     makeDevice (per-device IOKit property read: idVendor, idProduct, locationID,
//       "Device Speed"),
//     controllerInfo (parent-chain walk collecting the UsbIOPort port name and the
//       XHCI controller busIndex),
//     usbIOPortPath / portName(fromUSBIOPortPath:) (UsbIOPort value -> port name),
//     busIndex(fromLocationID:) (locationID upper byte fallback),
//     start / stop / handleAdded (IOServiceMatching("IOUSBHostDevice") +
//       IOServiceGetMatchingServices enumeration of attached USB devices)
//   and Sources/WhatCableCore/USB/USBDevice.swift:
//     speedRaw "Device Speed" enum (3 = 5 Gbps, 4 = 10 Gbps, 5 = 20 Gbps),
//     rootSuperSpeed / portMatchedSuperSpeed (speedRaw >= 3 is the USB3+ floor).
// MIT license, Darryl Morley 2026.
//
// This file strips whatcable's SwiftUI/ObservableObject coupling (the @MainActor
// @Published devices array, the GUI sort, the Billboard descriptor read, the full
// rawProperties bulk fetch) down to the CLI's need: the negotiated speed and the
// physical port a USB3+ device paired to, expressed as a CableSpeedTier floor. The
// pure DeviceState factory, the speed-floor map, and the per-port correlation are
// hardware-free so DeviceWatchTests can drive them from injected snapshots with the
// same keys real IOKit delivers.

import Foundation
import IOKit

//============================================
// MARK: Detected USB device state
//============================================

/// One attached USB device decoded into the fields this app reads to compute a
/// per-port speed floor.
///
/// This is the device-side analogue of `PortState` (port occupancy) and
/// `DetectedCable` (cable e-marker): a `DeviceState` carries a device's negotiated
/// USB link speed and the physical USB-C port it paired to, so the coordinator can
/// derive a conservative "At least <speed>" floor for the cable on that port.
public struct DeviceState: Equatable {
	/// IOKit registry entry ID of the IOUSBHostDevice service. Stable per service
	/// within a session; used to dedup across repeated callbacks.
	public let registryID: UInt64
	/// The device's negotiated USB "Device Speed" enum value, or nil when absent.
	/// whatcable's IOUSBHostDevice speed map: 0 Low, 1 Full, 2 High (USB2), 3 Super
	/// (5 Gbps), 4 Super+ (10 Gbps), 5 Super+ Gen 2x2 (20 Gbps). A USB3+ device is
	/// `speedRaw >= 3`; only those produce a speed floor.
	public let speedRaw: UInt8?
	/// The device's IOKit `locationID`. Bits 31-24 are the bus/controller index; the
	/// lower bytes are the hub-path nibbles. Used as the busIndex fallback when the
	/// XHCI parent walk does not resolve a controller.
	public let locationID: UInt32
	/// The physical USB-C port number this device paired to, recovered from the first
	/// ancestor `UsbIOPort` port name's "@N" suffix (e.g. "Port-USB-C@3" -> 3). This
	/// is the join key that correlates a device to a port controller's `PortNumber`.
	/// `unknownPortNumber` (-1) when no `UsbIOPort` ancestor named a port.
	public let portNumber: Int

	/// Sentinel for "no UsbIOPort ancestor named a physical port for this device".
	/// A real directly-attached device resolves a port number; this value marks a
	/// device whose port could not be paired, so correlation skips it instead of
	/// matching port 0 (or -1) by accident.
	public static let unknownPortNumber = -1

	public init(
		registryID: UInt64,
		speedRaw: UInt8?,
		locationID: UInt32,
		portNumber: Int = DeviceState.unknownPortNumber
	) {
		self.registryID = registryID
		self.speedRaw = speedRaw
		self.locationID = locationID
		self.portNumber = portNumber
	}

	/// True when this device negotiated a USB3+ (SuperSpeed or faster) link, the only
	/// case that yields a meaningful cable speed floor. Mirrors whatcable's
	/// `speedRaw >= 3` USB3+ gate in `rootSuperSpeed` / `portMatchedSuperSpeed`.
	public var isSuperSpeedOrFaster: Bool {
		let raw = speedRaw ?? 0
		let isFast = raw >= 3
		return isFast
	}

	/// The conservative cable speed-tier FLOOR implied by this device's negotiated
	/// link speed, or nil when the device is USB2/below (no floor) or the speed is
	/// absent. A device that negotiated N Gbps proves the cable carried at least N.
	public var speedFloorTier: CableSpeedTier? {
		let tier = deviceSpeedFloorTier(speedRaw: speedRaw)
		return tier
	}

	/// Build a `DeviceState` from a property-read closure plus the resolved pairing
	/// inputs, reading each key one at a time.
	///
	/// Faithful to whatcable `USBWatcher.makeDevice`'s per-key reads of the device
	/// service (idVendor / idProduct / locationID / "Device Speed"), narrowed to the
	/// fields this app needs (the negotiated speed and the locationID). The physical
	/// port pairing is supplied as `usbIOPortName` (the port name parsed from the
	/// first ancestor that publishes `UsbIOPort`, faithful to
	/// `USBWatcher.controllerInfo`); the live walk is done by `DeviceWatcher`, and the
	/// pure factory just turns that name into a port number so tests inject the name
	/// directly without a synthetic IOKit parent chain.
	///
	/// Args:
	///   registryID: the IOKit registry entry ID of the IOUSBHostDevice service.
	///   usbIOPortName: the port name from the device's first `UsbIOPort` ancestor
	///     (e.g. "Port-USB-C@3"), or nil when no ancestor named a port. The "@N"
	///     suffix yields the paired port number.
	///   read: closure mapping an IOKit property key to its value, or nil.
	///
	/// Returns:
	///   A `DeviceState` describing the device's speed and paired port.
	public static func from(
		registryID: UInt64,
		usbIOPortName: String?,
		read: (String) -> Any?
	) -> DeviceState {
		// "Device Speed" is the negotiated USB link speed enum. Read it individually
		// and coerce to UInt8; absent -> nil so the floor decision can tell "speed
		// absent" from a real value.
		let speedRaw = coerceDeviceSpeedRaw(read("Device Speed"))
		// locationID is the bus/path word; absent -> 0 (the busIndex fallback then
		// reads 0, which simply does not pair, never a false port).
		let locationID = coerceLocationID(read("locationID"))
		// Pair the device to a physical port by the UsbIOPort ancestor's "@N" suffix.
		// Absent -> the unknown sentinel, so correlation skips an unpaired device.
		let portNumber = usbIOPortName
			.flatMap { portNumberFromUSBIOPortName($0) }
			?? DeviceState.unknownPortNumber
		let state = DeviceState(
			registryID: registryID,
			speedRaw: speedRaw,
			locationID: locationID,
			portNumber: portNumber
		)
		return state
	}

	/// Recover the physical port number from a `UsbIOPort` port name's "@N" suffix.
	///
	/// whatcable parses the `UsbIOPort` registry value down to a port name like
	/// "Port-USB-C@3" (`USBWatcher.portName(fromUSBIOPortPath:)`); the trailing "@N"
	/// is the physical port macOS assigned, the same identity the port controller
	/// reports as `PortNumber`. This parses that number so a device pairs to the
	/// controller for its port.
	///
	/// Args:
	///   name: the port name from the `UsbIOPort` ancestor (e.g. "Port-USB-C@3").
	///
	/// Returns:
	///   The parsed port number, or nil when the name has no "@N" suffix.
	static func portNumberFromUSBIOPortName(_ name: String) -> Int? {
		// The number after the last "@" is the physical port (e.g. "...@3" -> 3).
		guard let atIndex = name.lastIndex(of: "@") else {
			return nil
		}
		let suffix = name[name.index(after: atIndex)...]
		let number = Int(suffix)
		return number
	}
}

//============================================
// MARK: Device-speed -> cable-tier floor map
//============================================

/// Map a negotiated USB "Device Speed" enum value to the conservative cable
/// speed-tier FLOOR it implies, or nil when the device is USB2/below or the speed is
/// absent.
///
/// The mapping is intentionally conservative -- it reports the floor the device
/// PROVES the cable carried, never an optimistic ceiling:
///   speedRaw 3 (Super Speed, 5 Gbps)        -> gen5g  ("At least 5G")
///   speedRaw 4 (Super Speed+, 10 Gbps)      -> gen10g ("At least 10G")
///   speedRaw 5 (Super Speed+ Gen 2x2, 20 G) -> gen20to40g ("At least 20-40G")
///
/// speedRaw 0/1/2 (Low / Full / High, i.e. USB2 and below) and an absent speed yield
/// nil: a USB2 link tells us nothing about whether the cable could go faster, so it
/// is NOT a useful floor (the port stays "Unknown [port active]" rather than being
/// falsely floored at USB2). Mapping note: whatcable exposes a discrete 20G tier
/// (`LinkSpeed.usb20g`); this app's `CableSpeedTier` folds 20 Gbps into the
/// PD-revision-ambiguous `gen20to40g` bucket (USB4 20/40 Gbps), so a 20 Gbps device
/// floors the cable into that combined bucket. 80G has no device-speed source here
/// (no IOUSBHostDevice negotiates 80 Gbps; that is a Thunderbolt/USB4 v2 link), so it
/// is intentionally absent from the device-floor map.
///
/// Adapted from whatcable `USBDevice.speedLabel` / `usb3SpeedLabel` (the "Device
/// Speed" enum values) and the `speedRaw >= 3` USB3+ gate in `rootSuperSpeed`.
/// MIT license, Darryl Morley 2026.
///
/// Args:
///   speedRaw: the IOUSBHostDevice "Device Speed" enum value, or nil when absent.
///
/// Returns:
///   The conservative cable speed-tier floor, or nil for USB2/below or absent.
func deviceSpeedFloorTier(speedRaw: UInt8?) -> CableSpeedTier? {
	guard let raw = speedRaw else {
		return nil
	}
	switch raw {
	case 3:
		// Super Speed, 5 Gbps -> the cable carried at least 5G.
		return .gen5g
	case 4:
		// Super Speed+, 10 Gbps -> at least 10G.
		return .gen10g
	case 5:
		// Super Speed+ Gen 2x2, 20 Gbps -> folds into the 20-40G bucket.
		return .gen20to40g
	default:
		// USB2 and below (0/1/2) or any unknown value: no useful floor.
		return nil
	}
}

//============================================
// MARK: Per-port device floor result
//============================================

/// The device-speed floor for one physical USB-C port, correlated from the attached
/// USB devices whose paired port number matches that port.
///
/// This is the clean per-port decode the `PlugCoordinator` consumes for the M5
/// fallback: when a port has no readable cable e-marker but a USB3+ device paired to
/// it, this carries the conservative floor tier the port renders as
/// "At least <speed> [device]".
public struct DeviceFloor: Equatable {
	/// The physical USB-C port number this floor describes.
	public let portNumber: Int
	/// The conservative cable speed-tier floor from the fastest USB3+ device paired
	/// to this port. Always a speed-bearing tier (gen5g / gen10g / gen20to40g); a
	/// port with no USB3+ device produces no `DeviceFloor` at all.
	public let tier: CableSpeedTier
	/// The raw "Device Speed" enum value of the device that supplied the floor, kept
	/// for the --debug probe and the rendered device-evidence detail line.
	public let speedRaw: UInt8

	public init(portNumber: Int, tier: CableSpeedTier, speedRaw: UInt8) {
		self.portNumber = portNumber
		self.tier = tier
		self.speedRaw = speedRaw
	}
}

//============================================
// MARK: Per-port device correlation (pure)
//============================================

/// Correlate the attached USB devices to one physical port (by its port number) and
/// produce that port's device-speed floor, choosing the FASTEST USB3+ device paired
/// to the port.
///
/// This is the pure, hardware-free core the coordinator calls. Given every detected
/// device and a target port number, it:
///   - keeps only devices paired to that port (matching `portNumber`),
///   - keeps only USB3+ devices (`speedRaw >= 3`), since USB2/below gives no floor,
///   - selects the FASTEST such device (the highest speedRaw), so the floor is the
///     strongest rate proven on that port.
///
/// Choosing the fastest device mirrors whatcable `portMatchedSuperSpeed` (which takes
/// the max `speedRaw` among port-matched USB3+ devices): a hub may enumerate several
/// devices, and the cable demonstrably carried the fastest negotiated link.
///
/// Args:
///   portNumber: the physical USB-C port number to correlate.
///   devices: every detected attached USB device from a snapshot.
///
/// Returns:
///   The port's `DeviceFloor` when a USB3+ device paired to it, or nil when none did
///   (so the coordinator leaves the port as "Unknown [port active]").
public func decodeDeviceFloor(
	forPortNumber portNumber: Int,
	from devices: [DeviceState]
) -> DeviceFloor? {
	// Keep only USB3+ devices paired to this exact port. A device with the unknown
	// port sentinel never matches a real port number, so an unpaired device is
	// skipped rather than floored onto port -1.
	let onPort = devices.filter {
		$0.portNumber == portNumber && $0.isSuperSpeedOrFaster
	}
	// The fastest paired device proves the strongest floor. max(by:) over speedRaw.
	let fastest = onPort.max { lhs, rhs in
		(lhs.speedRaw ?? 0) < (rhs.speedRaw ?? 0)
	}
	guard let device = fastest, let tier = device.speedFloorTier else {
		return nil
	}
	// speedRaw is non-nil here: isSuperSpeedOrFaster only passes a present speed >= 3.
	let floor = DeviceFloor(
		portNumber: portNumber,
		tier: tier,
		speedRaw: device.speedRaw ?? 0
	)
	return floor
}

//============================================
// MARK: USB device watcher (IOKit)
//============================================

/// Enumerates attached USB devices and describes each as a `DeviceState`, pairing it
/// to a physical USB-C port via the IOKit parent chain's `UsbIOPort` value.
///
/// Faithful port of the snapshot half of whatcable `USBWatcher`: it matches
/// `IOUSBHostDevice` (so subclasses like the Billboard device are caught too), reads
/// each device's negotiated speed and locationID per-key, walks the parent chain to
/// the first `UsbIOPort` ancestor for the physical port name and to the XHCI
/// controller for the busIndex fallback, and releases every io_object_t. The SwiftUI
/// `@Published`/notification layer is omitted: the coordinator polls `currentDevices()`
/// on the same cadence it polls the port and SOP sources.
public final class DeviceWatcher {

	/// The IOKit class matched for attached USB devices. A Billboard device
	/// enumerates as a subclass of `IOUSBHostDevice`, so the single match catches it
	/// too. Faithful to whatcable `USBWatcher` (IOServiceMatching("IOUSBHostDevice")).
	public static let deviceClass = "IOUSBHostDevice"

	/// How many parent hops the UsbIOPort/XHCI walk follows before giving up, matching
	/// whatcable `USBWatcher.controllerInfo` (handles devices behind deep hub chains).
	private static let maxParentHops = 20

	public init() {}

	//============================================
	// MARK: Snapshot enumeration (testable shape)
	//============================================

	/// Enumerate every currently-attached USB device and describe each as a
	/// `DeviceState`. Uses IOServiceGetMatchingServices + IOIteratorNext over
	/// `IOUSBHostDevice`, reads each device's keys via per-key
	/// IORegistryEntryCreateCFProperty, walks the parent chain for the UsbIOPort port
	/// name, and releases every io_object_t.
	///
	/// Faithful to whatcable `USBWatcher.handleAdded` + `makeDevice` +
	/// `controllerInfo`, minus the GUI sort, the `@Published` assignment, and the
	/// Billboard descriptor read. Every matched device is described; the USB3+ gate
	/// and the port correlation are applied later by `decodeDeviceFloor`, so the
	/// snapshot stays a faithful view of what IOKit matched.
	///
	/// Returns:
	///   One `DeviceState` per matched device, deduped by registry entry ID.
	public func currentDevices() -> [DeviceState] {
		var devices: [DeviceState] = []
		var seenIDs: Set<UInt64> = []
		var iterator: io_iterator_t = 0
		let matchResult = IOServiceGetMatchingServices(
			kIOMainPortDefault,
			IOServiceMatching(Self.deviceClass),
			&iterator
		)
		guard matchResult == KERN_SUCCESS else {
			return devices
		}
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			let entryID = Self.registryEntryID(service)
			// Dedup by registry entry ID so one device is described once.
			if seenIDs.contains(entryID) {
				continue
			}
			seenIDs.insert(entryID)
			// Walk the parent chain for the physical port name (UsbIOPort ancestor).
			let portName = Self.usbIOPortName(for: service)
			let state = DeviceState.from(
				registryID: entryID,
				usbIOPortName: portName,
				read: Self.makeReader(service)
			)
			devices.append(state)
		}
		IOObjectRelease(iterator)
		return devices
	}

	//============================================
	// MARK: Parent-chain port pairing
	//============================================

	/// Walk the IOKit parent chain from a USB device to the first ancestor that
	/// publishes a `UsbIOPort` value, and parse that value down to the physical port
	/// name (e.g. "Port-USB-C@3").
	///
	/// Faithful to whatcable `USBWatcher.controllerInfo`'s port-name half: it follows
	/// up to `maxParentHops` parent entries in the IOService plane, reads `UsbIOPort`
	/// per-key on each, and stops at the first one that names a port. The XHCI
	/// busIndex fallback whatcable also collects is omitted here -- this app pairs by
	/// the named port (the precise, undocumented-but-stable Apple Silicon mapping),
	/// not the coarse busIndex.
	///
	/// Args:
	///   service: the io_service_t of the USB device.
	///
	/// Returns:
	///   The physical port name (e.g. "Port-USB-C@3"), or nil when no ancestor named
	///   a port within the hop budget.
	private static func usbIOPortName(for service: io_service_t) -> String? {
		var current = service
		IOObjectRetain(current)
		defer { IOObjectRelease(current) }
		for _ in 0..<maxParentHops {
			var parent: io_service_t = 0
			guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
				break
			}
			IOObjectRelease(current)
			current = parent
			// Read UsbIOPort on this ancestor; the first one that names a port wins.
			let raw = IORegistryEntryCreateCFProperty(
				current,
				"UsbIOPort" as CFString,
				kCFAllocatorDefault,
				0
			)?.takeRetainedValue()
			if let value = raw,
				let path = usbIOPortPath(from: value),
				let name = portName(fromUSBIOPortPath: path) {
				return name
			}
		}
		return nil
	}

	//============================================
	// MARK: UsbIOPort value parsing (pure helpers)
	//============================================

	/// Coerce a raw `UsbIOPort` IOKit value into a registry-path string.
	///
	/// Faithful to whatcable `USBWatcher.usbIOPortPath(from:)`: the value is either a
	/// String or UTF-8 Data (the registry path ending in the port's service name).
	///
	/// Args:
	///   value: the bridged `UsbIOPort` value (String or Data).
	///
	/// Returns:
	///   The path string, or nil when the value is neither a string nor UTF-8 data.
	static func usbIOPortPath(from value: Any) -> String? {
		if let string = value as? String {
			return string
		}
		if let data = value as? Data {
			let decoded = String(data: data, encoding: .utf8)?
				.trimmingCharacters(in: .controlCharacters)
			return decoded
		}
		return nil
	}

	/// Parse the physical port name out of a `UsbIOPort` registry path.
	///
	/// Faithful to whatcable `USBWatcher.portName(fromUSBIOPortPath:)`: the last path
	/// component is the port's service name, kept only when it looks like a port
	/// ("Port-..." e.g. "Port-USB-C@3").
	///
	/// Args:
	///   path: the `UsbIOPort` registry path (e.g. ".../Port-USB-C@3").
	///
	/// Returns:
	///   The "Port-..." last component, or nil when the path does not end in one.
	static func portName(fromUSBIOPortPath path: String) -> String? {
		guard let last = path.split(separator: "/").last else {
			return nil
		}
		let name = String(last)
		let looksLikePort = name.hasPrefix("Port-")
		return looksLikePort ? name : nil
	}

	//============================================
	// MARK: IOKit reading helpers
	//============================================

	/// Build a per-key property-read closure backed by a live IOKit device service.
	/// Each call reads ONE key via IORegistryEntryCreateCFProperty, matching the
	/// crash-safe per-key path the rest of this app uses.
	private static func makeReader(_ service: io_service_t) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			let property = IORegistryEntryCreateCFProperty(
				service,
				key as CFString,
				kCFAllocatorDefault,
				0
			)
			let value = property?.takeRetainedValue()
			return value
		}
		return read
	}

	/// Stable identity for a device across repeated callbacks: the registry entry ID.
	private static func registryEntryID(_ service: io_service_t) -> UInt64 {
		var entryID: UInt64 = 0
		IORegistryEntryGetRegistryEntryID(service, &entryID)
		return entryID
	}
}

//============================================
// MARK: Device property coercion helpers
//============================================
//
// Adapted from whatcable USBWatcher.makeDevice's per-key NSNumber coercions
// ((dict["Device Speed"] as? NSNumber)?.uint8Value, (dict["locationID"] as?
// NSNumber)?.uint32Value). IOKit bridges integer properties to NSNumber; synthetic
// test snapshots may carry a plain Int. An absent key yields nil/0 without masking a
// real value, so the floor decision can tell "speed absent" from a real speed.

/// Coerce an IOKit Any? value into the negotiated "Device Speed" enum (UInt8).
///
/// Absent or non-numeric yields nil, NOT 0, so the floor decision distinguishes "no
/// speed reported" from a real Low-Speed (0) value -- both yield no floor, but the
/// nil keeps the snapshot honest for the --debug probe.
///
/// Args:
///   value: the bridged NSNumber / Int "Device Speed" value, or nil.
///
/// Returns:
///   The speed enum value, or nil when absent or non-coercible.
func coerceDeviceSpeedRaw(_ value: Any?) -> UInt8? {
	if let number = value as? NSNumber {
		return number.uint8Value
	}
	if let intValue = value as? Int {
		return UInt8(truncatingIfNeeded: intValue)
	}
	return nil
}

/// Coerce an IOKit Any? value into a `locationID` (UInt32). Absent or non-numeric
/// yields 0, the documented "no location" sentinel that simply does not pair a
/// device by busIndex; it does not mask a real location, because a real device
/// always publishes a numeric locationID.
///
/// Args:
///   value: the bridged NSNumber / Int locationID value, or nil.
///
/// Returns:
///   The 32-bit location word, or 0 when absent or non-coercible.
func coerceLocationID(_ value: Any?) -> UInt32 {
	if let number = value as? NSNumber {
		return number.uint32Value
	}
	if let intValue = value as? Int {
		return UInt32(truncatingIfNeeded: intValue)
	}
	return 0
}
