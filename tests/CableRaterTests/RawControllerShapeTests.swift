import XCTest
import Foundation
@testable import CableRater

/// Backend acceptance tests driven by the RAW captured controller-node shape.
///
/// The make-or-break case: an Apple cable into an F-F USB hub presents a real
/// occupied USB-C port (the live capture showed AppleTCControllerType10 Port 3 with
/// ConnectionActive = true and an SOP node with empty Metadata), and the backend
/// must detect it. These tests prove the real-port gate and the coordinator accept
/// the controller node as a real USB-C port even when the friendly description/name
/// keys differ, while the broad IOPort catch-all still never emits alone.
///
/// Every port-controller input here comes from a fixture plist captured from live
/// IOKit (`tests/CableRaterTests/Fixtures/`), read through the same per-key path the
/// production reader uses. No gate input is injected: the fixtures are the faithful
/// node shape, including the without-PortTypeDescription and without-"Port-"-name
/// hardware-reality variants.
final class RawControllerShapeTests: XCTestCase {

	//============================================
	// MARK: Fixture loading
	//============================================

	/// Load a plist fixture array from the test bundle, failing the test if it is
	/// missing or unparseable. Same resolution pattern as the other fixture tests.
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

	/// Build a per-key read closure over a property dictionary, mirroring the
	/// production per-key IOKit reader. An absent key reads nil, exactly like
	/// IORegistryEntryCreateCFProperty on a missing property.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// Build a `PortState` from a captured controller-node entry the way live IOKit
	/// would, reading the gate inputs straight off the RAW node shape (registry name,
	/// location, and every property). No gate input is injected.
	private func portState(from entry: [String: Any]) -> PortState {
		let serviceName = entry["IORegistryEntryName"] as? String ?? ""
		let serviceLocation = entry["IORegistryEntryLocation"] as? String ?? ""
		let number = entry["PortNumber"] as? Int ?? -1
		let state = PortState.from(
			registryID: UInt64(4295000000 + number),
			serviceClass: entry["IOObjectClass"] as? String ?? "AppleTCControllerType10",
			serviceName: serviceName,
			serviceLocation: serviceLocation,
			read: reader(entry)
		)
		return state
	}

	/// The single captured controller node from a one-entry fixture.
	private func singleController(named name: String) -> PortState {
		let entries = loadFixture(named: name)
		guard let first = entries.first else {
			XCTFail("\(name) must contain at least one controller node")
			// Return a sentinel so the caller can fail its own assertions.
			return portState(from: [:])
		}
		return portState(from: first)
	}

	//============================================
	// MARK: Raw controller without PortTypeDescription
	//============================================

	/// The without-PortTypeDescription fixture genuinely omits the PortTypeDescription
	/// key, so the test exercises the gate against real absence rather than a node
	/// that still carries the friendly key. Proves the fixture is the intended shape.
	func test_raw_controller_without_porttypedescription_omits_the_key() {
		let entries = loadFixture(named: "controller_no_porttypedescription.plist")
		guard let first = entries.first else {
			XCTFail("fixture must contain at least one controller node")
			return
		}
		XCTAssertNil(first["PortTypeDescription"],
		             "the fixture must omit PortTypeDescription to test the known-class path")
	}

	/// A raw AppleTCControllerType10 node WITHOUT a PortTypeDescription key is a real
	/// USB-C port (known class + PortNumber) and is judged occupied.
	func test_raw_controller_without_porttypedescription_occupied() {
		let state = singleController(named: "controller_no_porttypedescription.plist")
		XCTAssertEqual(state.serviceClass, "AppleTCControllerType10")
		XCTAssertEqual(state.portNumber, 3, "PortNumber resolves from the node")
		XCTAssertTrue(state.isUSBCPort,
		              "a known port-controller class with a PortNumber is a real port " +
		              "even without PortTypeDescription")
		XCTAssertTrue(PortLiveness.passesPortGuard(state),
		              "the real-port gate clears without PortTypeDescription")
		XCTAssertTrue(PortLiveness.isOccupied(state),
		              "ConnectionActive = true makes the port occupied")
		XCTAssertEqual(PortLiveness.occupancySource(state), .connectionActive)
	}

	//============================================
	// MARK: Raw controller without a "Port-" name
	//============================================

	/// A raw AppleTCControllerType10 node WITHOUT a "Port-" registry name is still
	/// recognized as a real USB-C port (known class + PortNumber), with the "Port-"
	/// name reserved as a hard filter only for the broad IOPort catch-all.
	func test_raw_controller_without_port_name_is_real_usbc_port() {
		let state = singleController(named: "controller_no_port_name.plist")
		XCTAssertEqual(state.serviceClass, "AppleTCControllerType10")
		XCTAssertEqual(state.portNumber, 3, "PortNumber resolves from the node")
		XCTAssertTrue(state.isUSBCPort,
		              "a known port-controller class with a PortNumber is a real port " +
		              "even when the registry name does not start with Port-")
		XCTAssertTrue(PortLiveness.passesPortGuard(state),
		              "the real-port gate clears without a Port- name")
	}

	//============================================
	// MARK: PortNumber + ConnectionActive -> occupied verdict
	//============================================

	/// A captured controller node with PortNumber + ConnectionActive yields an
	/// occupied verdict from the coordinator: the make-or-break Apple-cable-into-hub
	/// case. The captured Port 3 node (RAW shape) is occupied and renders the clean
	/// "Unknown [port active]" verdict (no readable e-marker, but a real plug).
	func test_port_number_plus_connection_active_produces_occupied_verdict() {
		let entries = loadFixture(named: "port_controllers_m1.plist")
		let states = entries.map { portState(from: $0) }
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// No SOP node: occupancy must come from the port controller's own keys.
		let verdicts = coordinator.mergeSnapshot(ports: states, sopNodes: [])
		XCTAssertEqual(verdicts.count, 1, "only the occupied Port 3 produces a verdict")
		let port3 = verdicts.first
		XCTAssertEqual(port3?.portNumber, 3)
		XCTAssertEqual(port3?.occupancySource, .connectionActive,
		               "ConnectionActive carried the occupancy decision")
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]")
		XCTAssertEqual(port3?.verdict.basis, .noEmarker)
	}

	//============================================
	// MARK: SOP child correlates by the portKey
	//============================================

	/// A captured SOP child still correlates to its port by the
	/// ParentPortType/ParentPortNumber portKey: the SOP node (ParentPortType 2,
	/// ParentPortNumber 3) joins the Port 3 controller on the "2/3" key, marking the
	/// port's PD identity present even with empty Metadata.
	func test_sop_child_correlates_by_parent_port_key() {
		let portEntries = loadFixture(named: "port_controllers_m1.plist")
		let states = portEntries.map { portState(from: $0) }
		let sopEntries = loadFixture(named: "sop_port3.plist")
		let sopNodes = sopEntries.map { entry -> DetectedCable in
			let cls = entry["IOObjectClass"] as? String
				?? "IOPortTransportComponentCCUSBPDSOP"
			return IOKitCableSource.describeService(
				serviceClass: cls,
				registryID: 4295494713,
				read: reader(entry)
			)
		}
		// The SOP node carries the parent port join key 2/3.
		XCTAssertEqual(sopNodes.first?.portKey, "2/3",
		               "the SOP child's ParentPortType/Number form the 2/3 portKey")
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(ports: states, sopNodes: sopNodes)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertNotNil(port3, "Port 3 must be merged")
		XCTAssertEqual(port3?.portKey, "2/3",
		               "the controller correlated to the SOP child on the 2/3 portKey")
		XCTAssertTrue(port3?.sopServicePresent == true,
		              "the SOP child correlated to Port 3 by its portKey")
	}

	//============================================
	// MARK: Broad IOPort catch-all never emits alone
	//============================================

	/// A broad IOPort candidate still does NOT emit alone: an IOPort catch-all match
	/// with no PortTypeDescription and no PortNumber is not a real USB-C port and is
	/// never occupied, so it produces no verdict even with a true ConnectionActive.
	/// This keeps the IOPort guard's discovery-only rule intact while the known
	/// classes are trusted by class identity.
	func test_broad_ioport_candidate_does_not_emit_alone() {
		// A bare IOPort catch-all match: not a known port-controller class, no
		// PortTypeDescription, no PortNumber, no "Port-" name. Read through the same
		// per-key path; even a true ConnectionActive must not qualify it.
		let properties: [String: Any] = [
			"ConnectionActive": true,
			"TransportsActive": ["CC"],
		]
		let state = PortState.from(
			registryID: 0x4000,
			serviceClass: "IOPort",
			serviceName: "IOPort",
			read: reader(properties)
		)
		XCTAssertFalse(state.isUSBCPort,
		               "a broad IOPort catch-all is not a real USB-C port")
		XCTAssertNil(state.portNumber, "the IOPort catch-all resolves no PortNumber")
		XCTAssertFalse(PortLiveness.passesPortGuard(state),
		               "the IOPort catch-all never clears the real-port gate")
		XCTAssertFalse(PortLiveness.isOccupied(state),
		               "the IOPort catch-all is never occupied, even with ConnectionActive")
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(ports: [state], sopNodes: [])
		XCTAssertTrue(verdicts.isEmpty,
		              "a broad IOPort candidate never produces a verdict alone")
	}
}
