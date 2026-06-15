import XCTest
import Foundation
@testable import CableRater

/// M5 gate tests for DeviceWatch -- the attached-USB-device-to-port pairing and the
/// negotiated-speed FLOOR fallback, driven from a synthetic XHCI/UsbIOPort
/// device-attach fixture and constructed values (no live IOKit).
///
/// They prove the pieces the coordinator relies on for the device-floor path:
///   - the "Device Speed" enum maps to the conservative cable speed-tier floor,
///   - the UsbIOPort registry path parses down to the physical port name and number,
///   - the pure DeviceState factory pairs a device to its port from the UsbIOPort
///     ancestor name,
///   - decodeDeviceFloor correlates the fastest USB3+ device on a port to its floor,
///     skips USB2/below (no floor), and skips devices paired to a different port.
final class DeviceWatchTests: XCTestCase {

	//============================================
	// MARK: Fixture loading
	//============================================

	/// Load a plist fixture array from the test bundle (same pattern as the other
	/// fixture-driven suites), failing the test if it is missing or unparseable.
	private func loadFixture(named name: String) -> [[String: Any]] {
		let url = Bundle.module.url(forResource: name, withExtension: nil,
		                            subdirectory: "Fixtures")
			?? Bundle.module.url(forResource: name, withExtension: nil)
		guard let resolved = url else {
			XCTFail("fixture not found in test bundle: \(name)")
			return []
		}
		guard let data = try? Data(contentsOf: resolved) else {
			XCTFail("could not read fixture: \(name)")
			return []
		}
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard let parsed = try? PropertyListSerialization.propertyList(
			from: data, options: [], format: &format
		) as? [[String: Any]] else {
			XCTFail("could not parse fixture array: \(name)")
			return []
		}
		return parsed
	}

	/// Build a read closure over a property dictionary, mirroring the production
	/// per-key IOKit reader. An absent key reads nil, exactly like IOKit.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// Turn a device fixture entry into a `DeviceState` the way live IOKit would: read
	/// the per-key device properties straight off the captured node, and pair to a
	/// port by parsing the UsbIOPort registry-path value the same way the live
	/// parent-chain walk does (path -> port name -> "@N").
	private func deviceState(from entry: [String: Any]) -> DeviceState {
		// Parse the UsbIOPort path -> port name, exactly as the live walk does.
		let portName = (entry["UsbIOPort"] as? String)
			.flatMap { DeviceWatcher.usbIOPortPath(from: $0) }
			.flatMap { DeviceWatcher.portName(fromUSBIOPortPath: $0) }
		let registryID = UInt64((entry["idProduct"] as? Int) ?? 0)
		let state = DeviceState.from(
			registryID: registryID,
			usbIOPortName: portName,
			read: reader(entry)
		)
		return state
	}

	/// Every device state from the synthetic Port 3 device-attach fixture.
	private func port3Devices() -> [DeviceState] {
		let entries = loadFixture(named: "devices_port3.plist")
		let states = entries.map { deviceState(from: $0) }
		return states
	}

	//============================================
	// MARK: Speed -> tier floor map
	//============================================

	/// The "Device Speed" enum maps to the conservative cable speed-tier floor: USB3+
	/// speeds 3/4/5 -> 5G/10G/20-40G, and USB2/below (or absent) -> no floor.
	func test_device_speed_floor_tier_map() {
		XCTAssertEqual(deviceSpeedFloorTier(speedRaw: 3), .gen5g, "5 Gbps floors at 5G")
		XCTAssertEqual(deviceSpeedFloorTier(speedRaw: 4), .gen10g, "10 Gbps floors at 10G")
		XCTAssertEqual(deviceSpeedFloorTier(speedRaw: 5), .gen20to40g,
		               "20 Gbps folds into the 20-40G bucket")
		// USB2 and below give no useful floor.
		XCTAssertNil(deviceSpeedFloorTier(speedRaw: 2), "High Speed (USB2) is no floor")
		XCTAssertNil(deviceSpeedFloorTier(speedRaw: 1), "Full Speed is no floor")
		XCTAssertNil(deviceSpeedFloorTier(speedRaw: 0), "Low Speed is no floor")
		XCTAssertNil(deviceSpeedFloorTier(speedRaw: nil), "absent speed is no floor")
	}

	//============================================
	// MARK: UsbIOPort path parsing
	//============================================

	/// The UsbIOPort registry path parses down to the physical port name, and that
	/// name's "@N" suffix yields the paired port number.
	func test_usbioport_path_parses_to_port_name_and_number() {
		let path = "IOService:/AppleARMPE/usb-drd0@/AppleT8103USBXHCI/usb-drd0-port-ss@/Port-USB-C@3"
		let name = DeviceWatcher.portName(fromUSBIOPortPath: path)
		XCTAssertEqual(name, "Port-USB-C@3", "last path component is the port name")
		XCTAssertEqual(DeviceState.portNumberFromUSBIOPortName("Port-USB-C@3"), 3,
		               "the @N suffix is the physical port number")
	}

	/// A UsbIOPort value carried as UTF-8 Data (the other IOKit shape) coerces to the
	/// same path string a plain String value would.
	func test_usbioport_value_from_data() {
		let path = "IOService:/.../Port-USB-C@2"
		let data = Data(path.utf8)
		XCTAssertEqual(DeviceWatcher.usbIOPortPath(from: data), path,
		               "UTF-8 Data coerces to the same path string")
		XCTAssertEqual(DeviceWatcher.usbIOPortPath(from: path), path,
		               "a String value passes through unchanged")
	}

	/// A path whose last component is not a "Port-" name yields no port name (so an
	/// ancestor that is not a physical port does not falsely pair a device).
	func test_non_port_path_yields_no_name() {
		let path = "IOService:/AppleARMPE/usb-drd0@/AppleT8103USBXHCI"
		XCTAssertNil(DeviceWatcher.portName(fromUSBIOPortPath: path),
		             "a non-Port- last component is not a port name")
	}

	//============================================
	// MARK: Pure factory pairs a device to its port
	//============================================

	/// The pure DeviceState factory reads the negotiated speed off the fixture and
	/// pairs the device to Port 3 from its UsbIOPort ancestor name. This proves a
	/// USB3+ device pairs to the right port.
	func test_factory_pairs_device_to_port3() {
		let devices = port3Devices()
		guard !devices.isEmpty else {
			XCTFail("fixture must have at least one device paired to Port 3")
			return
		}
		// Every device in the fixture paired to physical Port 3.
		for device in devices {
			XCTAssertEqual(device.portNumber, 3, "device paired to Port 3 via UsbIOPort")
		}
		// The 10 Gbps device negotiated Super Speed+ (speedRaw 4), USB3+.
		let fast = devices.first { $0.speedRaw == 4 }
		XCTAssertNotNil(fast, "the 10 Gbps device is present")
		XCTAssertTrue(fast?.isSuperSpeedOrFaster == true, "speedRaw 4 is USB3+")
		XCTAssertEqual(fast?.speedFloorTier, .gen10g, "10 Gbps floors at 10G")
	}

	//============================================
	// MARK: decodeDeviceFloor correlation
	//============================================

	/// The fastest USB3+ device paired to a port sets that port's floor: with a 10G
	/// and a 5G device on Port 3, the floor is 10G (the stronger proven rate).
	func test_fastest_device_sets_floor() {
		let floor = decodeDeviceFloor(forPortNumber: 3, from: port3Devices())
		XCTAssertNotNil(floor, "a USB3+ device on Port 3 yields a floor")
		XCTAssertEqual(floor?.portNumber, 3)
		XCTAssertEqual(floor?.tier, .gen10g, "the fastest (10G) device sets the floor")
		XCTAssertEqual(floor?.speedRaw, 4, "the floor records the 10G device's speed enum")
	}

	/// A device paired to a different port does not floor this port.
	func test_device_on_other_port_does_not_floor() {
		// All fixture devices are on Port 3; Port 1 must get no floor.
		let floor = decodeDeviceFloor(forPortNumber: 1, from: port3Devices())
		XCTAssertNil(floor, "no device paired to Port 1 -> no floor")
	}

	/// A USB2 (or slower) device gives no floor even when paired to the port.
	func test_usb2_device_gives_no_floor() {
		let usb2 = DeviceState(
			registryID: 1,
			speedRaw: 2,
			locationID: 0,
			portNumber: 2
		)
		let floor = decodeDeviceFloor(forPortNumber: 2, from: [usb2])
		XCTAssertNil(floor, "a USB2 device proves no useful floor")
	}

	/// An unpaired device (no UsbIOPort ancestor -> unknown port sentinel) never
	/// floors a real port, even when it negotiated a fast link.
	func test_unpaired_device_never_floors() {
		let unpaired = DeviceState(
			registryID: 1,
			speedRaw: 4,
			locationID: 0,
			portNumber: DeviceState.unknownPortNumber
		)
		// Probe a couple of real port numbers; neither must pick up the unpaired one.
		XCTAssertNil(decodeDeviceFloor(forPortNumber: 1, from: [unpaired]))
		XCTAssertNil(decodeDeviceFloor(forPortNumber: 3, from: [unpaired]))
	}
}
