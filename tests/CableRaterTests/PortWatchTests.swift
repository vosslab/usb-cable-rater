import XCTest
import Foundation
@testable import CableRater

/// XCTest coverage for the pure port-state backend in PortWatch.swift.
///
/// These tests drive the hardware-free core -- the `PortState.from` factory, the
/// `PortLiveness` decision (including the IOPort guard), and the
/// `PortTransitionTracker` diff -- with injected in-memory snapshots whose keys
/// match what real IOKit delivers: ConnectionActive, IOAccessoryDetect,
/// TransportsActive, PortNumber, PortTypeDescription. No M1 ioreg fixture file is
/// required; if one lands later under tests/CableRaterTests/Fixtures/ in the same
/// key format, these same factory/decision/tracker calls drive it unchanged.
///
/// The IOServiceGetMatchingServices / IOServiceAddMatchingNotification /
/// IOServiceAddInterestNotification plumbing runs only against real services and
/// is out of scope for unit tests; it is exercised on hardware via the --debug
/// probe.
final class PortWatchTests: XCTestCase {

	//============================================
	// MARK: Helpers
	//============================================

	/// Build a per-key read closure over a synthetic port-property dictionary,
	/// mirroring the production closure that reads IOKit properties by key. Absent
	/// keys return nil, exactly like IORegistryEntryCreateCFProperty on a missing
	/// property.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// A realistic occupied USB-C port (the M1 Port 3 seed: ConnectionActive Yes,
	/// IOAccessoryDetect Yes, TransportsActive ("CC"), PortNumber 3).
	private func occupiedPort3Properties() -> [String: Any] {
		let properties: [String: Any] = [
			"PortTypeDescription": "USB-C",
			"PortNumber": 3,
			"ConnectionActive": true,
			"IOAccessoryDetect": true,
			"TransportsActive": ["CC"],
		]
		return properties
	}

	/// A realistic idle USB-C port (Ports 1-2 seed: ConnectionActive No, no attach).
	private func idlePortProperties(portNumber: Int) -> [String: Any] {
		let properties: [String: Any] = [
			"PortTypeDescription": "USB-C",
			"PortNumber": portNumber,
			"ConnectionActive": false,
			"IOAccessoryDetect": false,
			"TransportsActive": [String](),
		]
		return properties
	}

	//============================================
	// MARK: Class discovery + key reads
	//============================================

	/// Discovers the AppleTCControllerType10 class: it is in the matched candidate
	/// set the watcher queries, alongside the portable HPM/TC set and the IOPort
	/// discovery catch-all. This is the M1 USB-C port-controller class.
	func test_candidate_classes_include_apple_tc_controller_type10() {
		let classes = PortWatcher.candidateClasses
		XCTAssertTrue(classes.contains("AppleTCControllerType10"))
		// The portable HPM/TC set is matched too, for other chip generations.
		XCTAssertTrue(classes.contains("AppleHPMInterfaceType10"))
		XCTAssertTrue(classes.contains("AppleTCControllerType11"))
		// IOPort is present strictly for class discovery (guarded by PortLiveness).
		XCTAssertTrue(classes.contains("IOPort"))
	}

	/// Reads PortNumber: the per-key factory pulls the PortNumber correlation key
	/// off an AppleTCControllerType10 snapshot.
	func test_reads_port_number_from_apple_tc_controller_type10() {
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		XCTAssertEqual(state.serviceClass, "AppleTCControllerType10")
		XCTAssertEqual(state.portNumber, 3)
	}

	/// Reads ConnectionActive: the primary plug signal is pulled off the snapshot
	/// as a true boolean (not a defaulted value), and the corroborating signals
	/// (IOAccessoryDetect, TransportsActive contains "CC") are read too.
	func test_reads_connection_active_and_corroborating_signals() {
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		XCTAssertEqual(state.connectionActive, true)
		XCTAssertEqual(state.accessoryDetect, true)
		XCTAssertTrue(state.transportsActiveHasCC)
		XCTAssertTrue(state.isUSBCPort)
	}

	/// An absent ConnectionActive key reads as nil, not false, so the liveness
	/// decision can distinguish "key missing" from "present and false".
	func test_absent_connection_active_reads_as_nil() {
		let properties: [String: Any] = [
			"PortTypeDescription": "USB-C",
			"PortNumber": 1,
		]
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(properties)
		)
		XCTAssertNil(state.connectionActive)
		XCTAssertNil(state.accessoryDetect)
		XCTAssertTrue(state.transportsActive.isEmpty)
	}

	//============================================
	// MARK: Port-liveness decision
	//============================================

	/// An occupied real USB-C port is judged occupied, and ConnectionActive is
	/// reported as the contributing source.
	func test_liveness_occupied_real_usbc_port() {
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		XCTAssertTrue(PortLiveness.isOccupied(state))
		XCTAssertEqual(PortLiveness.occupancySource(state), .connectionActive)
	}

	/// An idle real USB-C port is judged not occupied with no source.
	func test_liveness_idle_real_usbc_port() {
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(idlePortProperties(portNumber: 1))
		)
		XCTAssertFalse(PortLiveness.isOccupied(state))
		XCTAssertNil(PortLiveness.occupancySource(state))
	}

	/// Corroboration path: ConnectionActive absent but IOAccessoryDetect true still
	/// counts as occupied, attributed to the accessory-detect source.
	func test_liveness_occupied_via_accessory_detect() {
		let properties: [String: Any] = [
			"PortTypeDescription": "USB-C",
			"PortNumber": 2,
			"IOAccessoryDetect": true,
		]
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(properties)
		)
		XCTAssertTrue(PortLiveness.isOccupied(state))
		XCTAssertEqual(PortLiveness.occupancySource(state), .accessoryDetect)
	}

	/// Corroboration path: only TransportsActive contains "CC" -> occupied via the
	/// CC-transport source.
	func test_liveness_occupied_via_cc_transport() {
		let properties: [String: Any] = [
			"PortTypeDescription": "USB-C",
			"PortNumber": 2,
			"TransportsActive": ["CC"],
		]
		let state = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(properties)
		)
		XCTAssertTrue(PortLiveness.isOccupied(state))
		XCTAssertEqual(PortLiveness.occupancySource(state), .transportsActiveCC)
	}

	//============================================
	// MARK: IOPort guard (discovery-only, never emits alone)
	//============================================

	/// An IOPort-only candidate that does NOT map to a USB-C PortNumber is never
	/// occupied, even if ConnectionActive happens to read true. This is the plan's
	/// IOPort guard: discovery enumerates the class, but liveness refuses to emit
	/// until the candidate maps to a real USB-C PortNumber.
	func test_ioport_candidate_without_port_mapping_is_not_occupied() {
		// An IOPort catch-all match: not a USB-C port (no PortTypeDescription), no
		// PortNumber. Even with a true ConnectionActive it must not be occupied.
		let properties: [String: Any] = [
			"ConnectionActive": true,
		]
		let state = PortState.from(
			registryID: 0x2000,
			serviceClass: "IOPort",
			serviceName: "IOPort",
			read: reader(properties)
		)
		XCTAssertFalse(state.isUSBCPort)
		XCTAssertNil(state.portNumber)
		XCTAssertFalse(PortLiveness.isOccupied(state))
		XCTAssertNil(PortLiveness.occupancySource(state))
	}

	/// The IOPort guard also holds at the event boundary: an IOPort-only candidate
	/// in a snapshot produces NO plug event from the tracker.
	func test_ioport_candidate_emits_no_event() {
		let tracker = PortTransitionTracker()
		let ioPortState = PortState.from(
			registryID: 0x2000,
			serviceClass: "IOPort",
			serviceName: "IOPort",
			read: reader(["ConnectionActive": true])
		)
		let events = tracker.ingest([ioPortState])
		XCTAssertTrue(events.isEmpty)
	}

	/// A USB-C-named real port that has a PortNumber DOES emit (the positive
	/// counterpart to the guard), proving the guard suppresses only the
	/// discovery-only candidates, not real ports.
	func test_real_usbc_port_emits_after_mapping() {
		let tracker = PortTransitionTracker()
		let portState = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		let events = tracker.ingest([portState])
		XCTAssertEqual(events.count, 1)
		XCTAssertEqual(events.first?.kind, .inserted)
		XCTAssertEqual(events.first?.state.portNumber, 3)
	}

	//============================================
	// MARK: Synthetic transitions (insert / remove)
	//============================================

	/// A synthetic ConnectionActive false->true transition emits exactly one
	/// insert event for the port, attributed to ConnectionActive.
	func test_synthetic_false_to_true_emits_insert() {
		let tracker = PortTransitionTracker()
		// t0: Port 3 idle. No event.
		let idle = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(idlePortProperties(portNumber: 3))
		)
		let t0 = tracker.ingest([idle])
		XCTAssertTrue(t0.isEmpty)
		// t1: same port flips ConnectionActive true. One insert event.
		let occupied = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		let t1 = tracker.ingest([occupied])
		XCTAssertEqual(t1.count, 1)
		XCTAssertEqual(t1.first?.kind, .inserted)
		XCTAssertEqual(t1.first?.state.portNumber, 3)
		XCTAssertEqual(t1.first?.source, .connectionActive)
	}

	/// A synthetic ConnectionActive true->false transition emits exactly one remove
	/// event for the port.
	func test_synthetic_true_to_false_emits_remove() {
		let tracker = PortTransitionTracker()
		// Seed occupied.
		let occupied = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		let seed = tracker.ingest([occupied])
		XCTAssertEqual(seed.count, 1)
		XCTAssertEqual(seed.first?.kind, .inserted)
		// Now the same port goes idle. One remove event.
		let idle = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(idlePortProperties(portNumber: 3))
		)
		let removed = tracker.ingest([idle])
		XCTAssertEqual(removed.count, 1)
		XCTAssertEqual(removed.first?.kind, .removed)
		XCTAssertEqual(removed.first?.state.portNumber, 3)
	}

	/// A steady occupied port across two snapshots emits no duplicate event: one
	/// physical plug yields one line.
	func test_steady_occupied_emits_no_duplicate() {
		let tracker = PortTransitionTracker()
		let occupied = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		let first = tracker.ingest([occupied])
		XCTAssertEqual(first.count, 1)
		let second = tracker.ingest([occupied])
		XCTAssertTrue(second.isEmpty)
	}

	/// A port that vanishes entirely from the snapshot (service torn down) while it
	/// was occupied still emits a remove, carrying the PortNumber for the line.
	func test_vanished_occupied_port_emits_remove() {
		let tracker = PortTransitionTracker()
		let occupied = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		_ = tracker.ingest([occupied])
		// Empty snapshot: the port is gone. Remove event for port 3.
		let removed = tracker.ingest([])
		XCTAssertEqual(removed.count, 1)
		XCTAssertEqual(removed.first?.kind, .removed)
		XCTAssertEqual(removed.first?.state.portNumber, 3)
	}

	//============================================
	// MARK: Debug probe line
	//============================================

	/// The --debug probe line names the matched backend source: the IOKit class and
	/// the property that produced the event.
	func test_port_debug_line_names_backend_source() {
		let tracker = PortTransitionTracker()
		let occupied = PortState.from(
			registryID: 0x1000,
			serviceClass: "AppleTCControllerType10",
			serviceName: "Port-USB-C",
			read: reader(occupiedPort3Properties())
		)
		let events = tracker.ingest([occupied])
		XCTAssertEqual(events.count, 1)
		let line = portDebugLine(for: events[0])
		XCTAssertTrue(line.contains("class=AppleTCControllerType10"))
		XCTAssertTrue(line.contains("port=3"))
		XCTAssertTrue(line.contains("source=connectionActive"))
		XCTAssertTrue(line.contains("connectionActive=true"))
		XCTAssertTrue(line.contains("inserted"))
	}
}
