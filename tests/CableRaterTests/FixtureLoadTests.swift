import XCTest
import Foundation
@testable import CableRater

/// Fixture-load tests for the captured M1 IOKit snapshot files.
///
/// These tests prove that the fixture plist files are bundled correctly,
/// are readable, and contain the exact port-controller and SOP properties
/// from the M1 capture seed. No live hardware or IOKit access is required.
///
/// Fixture seed (authoritative):
///   Port 3: ConnectionActive = Yes, IOAccessoryDetect = Yes,
///           TransportsActive = ("CC"), SOP present with empty Metadata,
///           ParentPortNumber = 3.
///   Ports 1 and 2: ConnectionActive = No, IOAccessoryDetect = No,
///           TransportsActive = empty, no SOP service.
final class FixtureLoadTests: XCTestCase {

	//============================================
	// MARK: Helpers
	//============================================

	/// Load a plist fixture from the test bundle and return the parsed array.
	///
	/// Fails the test immediately if the resource is missing or unparseable.
	///
	/// Args:
	///   name: The plist filename (without path prefix) inside the Fixtures folder.
	///
	/// Returns:
	///   The top-level array from the plist as [[String: Any]].
	private func loadFixture(named name: String) -> [[String: Any]] {
		// Bundle.module resolves the test-bundle resource directory.
		guard let url = Bundle.module.url(forResource: name, withExtension: nil,
		                                  subdirectory: "Fixtures") else {
			// Fall back: try without subdirectory (SwiftPM may flatten resources).
			guard let url2 = Bundle.module.url(forResource: name, withExtension: nil) else {
				XCTFail("fixture not found in test bundle: \(name)")
				return []
			}
			return parseArrayPlist(at: url2, name: name)
		}
		return parseArrayPlist(at: url, name: name)
	}

	/// Parse a plist file at the given URL and return it as [[String: Any]].
	///
	/// The fixture plists all have an array at the top level.
	private func parseArrayPlist(at url: URL, name: String) -> [[String: Any]] {
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			XCTFail("could not read fixture \(name): \(error)")
			return []
		}
		var format = PropertyListSerialization.PropertyListFormat.xml
		let parsed: Any
		do {
			parsed = try PropertyListSerialization.propertyList(from: data, options: [],
			                                                    format: &format)
		} catch {
			XCTFail("could not parse plist \(name): \(error)")
			return []
		}
		guard let array = parsed as? [[String: Any]] else {
			XCTFail("fixture \(name) top-level is not an array of dicts")
			return []
		}
		return array
	}

	//============================================
	// MARK: Port-controller fixture
	//============================================

	/// The port-controller fixture must load without error and contain Port 3 as an
	/// occupied entry (ConnectionActive = true), which is the M1 fixture's key behavior.
	func test_port_controllers_fixture_loads() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		guard !ports.isEmpty else {
			XCTFail("fixture must contain port-controller entries")
			return
		}
		// Port 3 (ConnectionActive true) must be present as the occupied port.
		let port3 = ports.first(where: { ($0["PortNumber"] as? Int) == 3 })
		XCTAssertNotNil(port3, "fixture must contain a Port 3 entry (the occupied M1 port)")
		XCTAssertEqual(port3?["ConnectionActive"] as? Bool, true,
		               "Port 3 must have ConnectionActive = true in the fixture")
	}

	/// Every entry in the port-controller fixture carries IOObjectClass
	/// == "AppleTCControllerType10".
	func test_port_controllers_fixture_class_is_AppleTCControllerType10() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		for (idx, port) in ports.enumerated() {
			let cls = port["IOObjectClass"] as? String
			XCTAssertEqual(cls, "AppleTCControllerType10",
			               "port entry \(idx) must carry the correct IOObjectClass")
		}
	}

	/// Port 1 must have ConnectionActive = false (no CC attach).
	func test_port1_connection_inactive() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		// Port 1 is the first entry (PortNumber == 1).
		let port1 = ports.first(where: { ($0["PortNumber"] as? Int) == 1 })
		XCTAssertNotNil(port1, "fixture must contain a Port 1 entry")
		let active = port1?["ConnectionActive"] as? Bool
		XCTAssertEqual(active, false, "Port 1 must have ConnectionActive = false")
	}

	/// Port 2 must have ConnectionActive = false (no CC attach).
	func test_port2_connection_inactive() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		let port2 = ports.first(where: { ($0["PortNumber"] as? Int) == 2 })
		XCTAssertNotNil(port2, "fixture must contain a Port 2 entry")
		let active = port2?["ConnectionActive"] as? Bool
		XCTAssertEqual(active, false, "Port 2 must have ConnectionActive = false")
	}

	/// Port 3 must have ConnectionActive = true (CC attach present).
	func test_port3_connection_active() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		let port3 = ports.first(where: { ($0["PortNumber"] as? Int) == 3 })
		XCTAssertNotNil(port3, "fixture must contain a Port 3 entry")
		let active = port3?["ConnectionActive"] as? Bool
		XCTAssertEqual(active, true, "Port 3 must have ConnectionActive = true")
	}

	/// Port 3 must have IOAccessoryDetect = true (corroborates CC attach).
	func test_port3_accessory_detect_true() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		let port3 = ports.first(where: { ($0["PortNumber"] as? Int) == 3 })
		XCTAssertNotNil(port3, "fixture must contain a Port 3 entry")
		let detect = port3?["IOAccessoryDetect"] as? Bool
		XCTAssertEqual(detect, true, "Port 3 must have IOAccessoryDetect = true")
	}

	/// Port 3's TransportsActive must contain "CC" (active CC transport).
	func test_port3_transports_active_contains_cc() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		let port3 = ports.first(where: { ($0["PortNumber"] as? Int) == 3 })
		XCTAssertNotNil(port3, "fixture must contain a Port 3 entry")
		let transports = port3?["TransportsActive"] as? [String]
		XCTAssertNotNil(transports, "Port 3 TransportsActive must be a string array")
		XCTAssertTrue(transports?.contains("CC") == true,
		              "Port 3 TransportsActive must contain CC")
	}

	/// Ports 1 and 2 must have empty TransportsActive arrays.
	func test_ports1and2_transports_active_empty() {
		let ports = loadFixture(named: "port_controllers_m1.plist")
		for portNum in [1, 2] {
			let entry = ports.first(where: { ($0["PortNumber"] as? Int) == portNum })
			XCTAssertNotNil(entry, "fixture must contain a Port \(portNum) entry")
			let transports = entry?["TransportsActive"] as? [String]
			XCTAssertNotNil(transports, "Port \(portNum) TransportsActive must be a string array")
			XCTAssertTrue(transports?.isEmpty == true,
			              "Port \(portNum) TransportsActive must be empty")
		}
	}

	//============================================
	// MARK: SOP fixture
	//============================================

	/// The SOP fixture must load without error and carry the SOP IOObjectClass.
	func test_sop_fixture_loads() {
		let nodes = loadFixture(named: "sop_port3.plist")
		guard let first = nodes.first else {
			XCTFail("SOP fixture must contain at least one entry")
			return
		}
		// The first entry must carry the SOP component class.
		XCTAssertNotNil(first["IOObjectClass"],
		                "SOP fixture entry must carry IOObjectClass")
	}

	/// The SOP node must carry IOObjectClass == "IOPortTransportComponentCCUSBPDSOP".
	func test_sop_fixture_class_is_CCUSBPDSOP() {
		let nodes = loadFixture(named: "sop_port3.plist")
		let cls = nodes.first?["IOObjectClass"] as? String
		XCTAssertEqual(cls, "IOPortTransportComponentCCUSBPDSOP",
		               "SOP node must carry the correct IOObjectClass")
	}

	/// The SOP node must have ParentPortNumber = 3 (correlates to Port 3 controller).
	func test_sop_fixture_parent_port_number_is_3() {
		let nodes = loadFixture(named: "sop_port3.plist")
		let parentPort = nodes.first?["ParentPortNumber"] as? Int
		XCTAssertEqual(parentPort, 3, "SOP node must have ParentPortNumber = 3")
	}

	/// The SOP node Metadata must be an empty dict (no readable e-marker).
	func test_sop_fixture_metadata_is_empty_dict() {
		let nodes = loadFixture(named: "sop_port3.plist")
		let metadata = nodes.first?["Metadata"] as? [String: Any]
		XCTAssertNotNil(metadata, "Metadata must be present as a dictionary")
		XCTAssertTrue(metadata?.isEmpty == true,
		              "Metadata must be empty (non-e-marked cable, no VDO data)")
	}

	/// The SOP node ComponentName must be "SOP" (not SOP' or SOP'').
	func test_sop_fixture_component_name_is_SOP() {
		let nodes = loadFixture(named: "sop_port3.plist")
		let componentName = nodes.first?["ComponentName"] as? String
		XCTAssertEqual(componentName, "SOP",
		               "SOP node ComponentName must be SOP")
	}
}
