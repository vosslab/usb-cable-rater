import XCTest
import Foundation
@testable import CableRater

/// M1 gate tests for the PlugCoordinator (WP-M1d).
///
/// These prove the coordinator merges the ported port-state watcher and the
/// PD-identity decode into ONE verdict per physical USB-C port, driven entirely
/// from the captured M1 fixtures and synthetic ConnectionActive transitions -- no
/// live IOKit. They are the decisive M1 gate:
///   - initial scan of the M1 fixture yields the same Port 3 verdict as `--once`,
///   - a synthetic ConnectionActive false->true emits a plug; true->false an unplug,
///   - SOP correlation by the "type/number" portKey joins the SOP node to Port 3,
///   - SOP present with empty Metadata -> "Unknown [port active]" (clean verdict),
///   - a visible no-e-marker port -> Unknown; an invisible/idle port -> silent,
///   - each verdict records its backend source.
///
/// Fixture seed (authoritative): Port 3 active (ConnectionActive = true, an SOP
/// node present with empty Metadata, ParentPortNumber/Type = 3/2); Ports 1-2
/// inactive with no SOP node.
final class PlugCoordinatorTests: XCTestCase {

	//============================================
	// MARK: Fixture loading
	//============================================

	/// Load a plist fixture array from the test bundle (same pattern as
	/// FixtureLoadTests), failing the test if it is missing or unparseable.
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

	/// Turn a port-controller fixture entry into a `PortState` the way live IOKit
	/// would, reading the gate inputs straight off the captured RAW node shape.
	///
	/// The fixture is the faithful captured controller node: it carries the real
	/// keys the live service publishes -- PortNumber, PortType (2 == USB-C),
	/// PortTypeDescription ("USB-C"), the IORegistryEntryName ("Port-USB-C"), and the
	/// IORegistryEntryLocation ("@N" suffix). No gate input is injected here; the test
	/// reads the same keys the production per-key reader pulls from real IOKit, so the
	/// fixture exercises the real-port gate against hardware reality rather than a
	/// hand-supplied shape.
	private func portState(from entry: [String: Any]) -> PortState {
		// Registry name and location come from the captured node itself (the "@N"
		// identity), not a synthesized string.
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

	/// Every port-controller state from the M1 fixture.
	private func m1PortStates() -> [PortState] {
		let entries = loadFixture(named: "port_controllers_m1.plist")
		let states = entries.map { portState(from: $0) }
		return states
	}

	/// Turn the SOP fixture entry into a `DetectedCable` via describeService (the
	/// production PD-identity describe path), so the coordinator correlates a real
	/// detected node.
	private func m1SopNodes() -> [DetectedCable] {
		let entries = loadFixture(named: "sop_port3.plist")
		let nodes = entries.map { entry -> DetectedCable in
			let cls = entry["IOObjectClass"] as? String
				?? "IOPortTransportComponentCCUSBPDSOP"
			let detected = IOKitCableSource.describeService(
				serviceClass: cls,
				registryID: 4295494713,
				read: reader(entry)
			)
			return detected
		}
		return nodes
	}

	//============================================
	// MARK: Synthetic port snapshots (transitions)
	//============================================

	/// A synthetic occupied/idle USB-C port state for a port number, with a chosen
	/// ConnectionActive value. Passes the USB-C gate so liveness can decide.
	private func syntheticPort(number: Int, connectionActive: Bool) -> PortState {
		let state = PortState(
			registryID: UInt64(5000 + number),
			serviceClass: "AppleTCControllerType10",
			portNumber: number,
			connectionActive: connectionActive,
			accessoryDetect: false,
			transportsActive: [],
			isUSBCPort: true,
			portType: 2
		)
		return state
	}

	/// A synthetic USB-C port with no port-controller attach signal at all:
	/// ConnectionActive nil, IOAccessoryDetect nil, TransportsActive empty. It still
	/// passes the USB-C guard (real port + PortNumber), so the only thing that can
	/// make it occupied is a correlated PD identity (whatcable isPortLive priority 2).
	private func portNoAttachSignal(number: Int) -> PortState {
		let state = PortState(
			registryID: UInt64(6000 + number),
			serviceClass: "AppleTCControllerType10",
			portNumber: number,
			connectionActive: nil,
			accessoryDetect: nil,
			transportsActive: [],
			isUSBCPort: true,
			portType: 2
		)
		return state
	}

	/// A synthetic USB-C port occupied ONLY via IOAccessoryDetect: ConnectionActive
	/// false/nil, IOAccessoryDetect true, no CC transport. Behind the USB-C guard.
	private func portAccessoryDetectOnly(number: Int) -> PortState {
		let state = PortState(
			registryID: UInt64(6100 + number),
			serviceClass: "AppleTCControllerType10",
			portNumber: number,
			connectionActive: nil,
			accessoryDetect: true,
			transportsActive: [],
			isUSBCPort: true,
			portType: 2
		)
		return state
	}

	/// A synthetic USB-C port occupied ONLY via TransportsActive containing "CC":
	/// ConnectionActive false/nil, no IOAccessoryDetect. Behind the USB-C guard.
	private func portTransportsCCOnly(number: Int) -> PortState {
		let state = PortState(
			registryID: UInt64(6200 + number),
			serviceClass: "AppleTCControllerType10",
			portNumber: number,
			connectionActive: false,
			accessoryDetect: false,
			transportsActive: ["CC"],
			isUSBCPort: true,
			portType: 2
		)
		return state
	}

	/// A populated SOP' node for `port`: passive cable, VID 0x05AC, 10G Cable VDO.
	private func sopPrime10G(port: Int) -> DetectedCable {
		// ID Header (VDO[0]): UFP == 3 passive, VID 0x05AC.
		let idHeader: UInt32 = 0x180005AC
		// Cable VDO (VDO[3]): speed bits == 2 -> 10G.
		let cableVDO: UInt32 = 0x00000022
		func packed(_ value: UInt32) -> Data {
			var little = value.littleEndian
			return withUnsafeBytes(of: &little) { Data($0) }
		}
		let metadata: [String: Any] = [
			"PID": 0x0001,
			"VDOs": [packed(idHeader), packed(0), packed(0), packed(cableVDO)],
		]
		let properties: [String: Any] = [
			"Metadata": metadata,
			"ParentBuiltInPortNumber": port,
			"ParentBuiltInPortType": 2,
			"ParentPortNumber": port,
			"ParentPortType": 2,
		]
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: UInt64(7000 + port),
			read: reader(properties)
		)
		return detected
	}

	/// A synthetic USB3+ device paired to a port at a chosen "Device Speed" enum, for
	/// the M5 device-floor merge tests. speedRaw 4 == 10 Gbps (USB3+).
	private func device(port: Int, speedRaw: UInt8) -> DeviceState {
		let state = DeviceState(
			registryID: UInt64(8000 + port),
			speedRaw: speedRaw,
			locationID: UInt32(0x14200000 + port),
			portNumber: port
		)
		return state
	}

	//============================================
	// MARK: Initial-scan parity with --once
	//============================================

	/// The initial scan of the M1 fixture yields the same Port 3 verdict the
	/// `--once` path produces. `--once` rates the captured SOP node (empty Metadata)
	/// via verdict(for: nil) -> UNKNOWN/noEmarker; the coordinator must reach the
	/// SAME Verdict for the occupied Port 3, and produce nothing for the idle ports.
	func test_initial_scan_matches_once_port3_verdict() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		// Exactly one verdict: the single occupied port (Port 3).
		XCTAssertEqual(verdicts.count, 1, "only Port 3 is occupied in the M1 fixture")
		let port3 = verdicts.first
		XCTAssertEqual(port3?.portNumber, 3)

		// The --once path for the captured empty-Metadata node rates UNKNOWN/noEmarker.
		let onceVerdict = verdict(for: nil, catalog: Catalog.shared)
		XCTAssertEqual(port3?.verdict, onceVerdict,
		               "coordinator Port 3 verdict matches the --once verdict")
		XCTAssertEqual(port3?.verdict.basis, .noEmarker)
	}

	//============================================
	// MARK: Synthetic plug / unplug transitions
	//============================================

	/// A synthetic ConnectionActive false->true emits a plug (inserted) verdict.
	func test_connection_false_to_true_emits_plug() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Baseline: Port 3 idle (ConnectionActive false) -> no events, seeds tracker.
		let baseline = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: false)],
			sopNodes: []
		)
		XCTAssertTrue(baseline.isEmpty, "an idle baseline produces no transition")

		// Transition: Port 3 ConnectionActive flips true -> a plug.
		let plugged = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		XCTAssertEqual(plugged.count, 1, "false->true emits exactly one plug")
		XCTAssertEqual(plugged.first?.kind, .inserted)
		XCTAssertEqual(plugged.first?.portNumber, 3)
		// No SOP node -> occupied with no readable e-marker -> Unknown [port active].
		XCTAssertEqual(plugged.first?.verdict.headline, "Port 3: Unknown [port active]")
	}

	/// A synthetic ConnectionActive true->false emits an unplug (removed) verdict.
	func test_connection_true_to_false_emits_unplug() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Plug first so the port is tracked occupied.
		_ = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		// Then drop ConnectionActive: an unplug.
		let unplugged = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: false)],
			sopNodes: []
		)
		XCTAssertEqual(unplugged.count, 1, "true->false emits exactly one unplug")
		XCTAssertEqual(unplugged.first?.kind, .removed)
		XCTAssertEqual(unplugged.first?.portNumber, 3)
	}

	/// A steady occupied port (no transition) emits nothing on a repeated snapshot.
	func test_steady_port_emits_no_duplicate() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		_ = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		let again = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		XCTAssertTrue(again.isEmpty, "a steady occupied port yields no duplicate plug")
	}

	//============================================
	// MARK: portKey correlation (type/number join)
	//============================================

	/// SOP correlation by the "type/number" portKey joins the SOP node to Port 3:
	/// the coordinator merges the Port 3 controller with the SOP node carrying
	/// ParentPortType/Number 2/3, and the merged verdict's portKey is "2/3".
	func test_sop_correlates_to_port3_by_type_number_key() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertNotNil(port3, "Port 3 must be merged")
		XCTAssertEqual(port3?.portKey, "2/3", "joined on the type/number portKey")
		XCTAssertTrue(port3?.sopServicePresent == true,
		              "the SOP node correlated to Port 3")
	}

	/// A decoded SOP' e-marker on Port 3 rates by the cable (10G, basis e-marker)
	/// and the verdict is attributed to the SOP-identity backend source.
	func test_sop_prime_emarker_rates_cable_and_records_source() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [sopPrime10G(port: 3)]
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertEqual(port3?.verdict.tier, .gen10g, "SOP' e-marker rates 10G")
		XCTAssertEqual(port3?.verdict.basis, .emarker)
		XCTAssertEqual(port3?.backendSource, .sopIdentity,
		               "an e-marker rating is attributed to the SOP identity source")
		XCTAssertEqual(port3?.headline, "Port 3: 10G [e-marker]")
		XCTAssertTrue(port3?.hasReadableEMarker == true)
	}

	//============================================
	// MARK: Empty Metadata -> Unknown [port active]
	//============================================

	/// SOP present with empty Metadata -> "Unknown [port active]" as a clean verdict
	/// (the captured M1 Port 3 case): the port is occupied, an SOP node is present,
	/// but it carries no readable e-marker. No crash, no error.
	func test_empty_metadata_is_unknown_port_active_clean() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertNotNil(port3)
		XCTAssertFalse(port3?.hasReadableEMarker == true,
		               "empty Metadata -> no readable e-marker")
		XCTAssertTrue(port3?.sopServicePresent == true,
		              "an SOP node is present even with empty Metadata")
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]")
		XCTAssertEqual(port3?.verdict.basis, .noEmarker)
	}

	//============================================
	// MARK: Visible no-e-marker -> Unknown; invisible -> silent
	//============================================

	/// A visible no-e-marker port (occupied by ConnectionActive, no SOP node)
	/// renders Unknown [port active]; an invisible/idle port produces NO verdict.
	func test_visible_no_emarker_unknown_invisible_silent() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Port 3 occupied with no SOP node; Ports 1 and 2 idle.
		let ports = [
			syntheticPort(number: 1, connectionActive: false),
			syntheticPort(number: 2, connectionActive: false),
			syntheticPort(number: 3, connectionActive: true),
		]
		let verdicts = coordinator.mergeSnapshot(ports: ports, sopNodes: [])
		// Only the occupied port produces a verdict; the idle ports stay silent.
		XCTAssertEqual(verdicts.count, 1, "only the occupied port produces a verdict")
		XCTAssertEqual(verdicts.first?.portNumber, 3)
		XCTAssertEqual(verdicts.first?.headline, "Port 3: Unknown [port active]")
	}

	/// An entirely idle snapshot (every port ConnectionActive false) produces no
	/// verdicts at all -- the silent invisible-port case.
	func test_all_idle_ports_produce_no_verdicts() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let ports = [
			syntheticPort(number: 1, connectionActive: false),
			syntheticPort(number: 2, connectionActive: false),
			syntheticPort(number: 3, connectionActive: false),
		]
		let verdicts = coordinator.mergeSnapshot(ports: ports, sopNodes: [])
		XCTAssertTrue(verdicts.isEmpty, "no occupied port -> no verdicts (silent)")
	}

	/// The IOPort guard holds at the coordinator boundary: an IOPort-only candidate
	/// (no PortNumber, not a USB-C port) is never occupied, so it never produces a
	/// verdict even if it carries a true ConnectionActive.
	func test_ioport_only_candidate_produces_no_verdict() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let ioPortOnly = PortState(
			registryID: 9999,
			serviceClass: "IOPort",
			portNumber: nil,
			connectionActive: true,
			accessoryDetect: false,
			transportsActive: ["CC"],
			isUSBCPort: false,
			portType: nil
		)
		let verdicts = coordinator.mergeSnapshot(ports: [ioPortOnly], sopNodes: [])
		XCTAssertTrue(verdicts.isEmpty,
		              "an IOPort-only candidate never emits a verdict")
	}

	//============================================
	// MARK: Backend source recorded per verdict
	//============================================

	/// Each verdict records its backend source: an empty-Metadata occupied port is
	/// attributed to the port backend (poll), a decoded e-marker to SOP identity.
	func test_each_verdict_records_backend_source() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Empty-Metadata occupied port -> port poll backend, ConnectionActive source.
		let noEmarker = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		).first(where: { $0.portNumber == 3 })
		XCTAssertEqual(noEmarker?.backendSource, .portPoll,
		               "an occupied no-e-marker port is attributed to the port backend")
		XCTAssertEqual(noEmarker?.occupancySource, .connectionActive,
		               "ConnectionActive carried the occupancy decision")

		// Decoded e-marker -> SOP identity backend.
		let decoded = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [sopPrime10G(port: 3)]
		).first(where: { $0.portNumber == 3 })
		XCTAssertEqual(decoded?.backendSource, .sopIdentity,
		               "a decoded e-marker is attributed to the SOP identity backend")
	}

	//============================================
	// MARK: PD-identity occupancy avenue (whatcable isPortLive priority 2)
	//============================================

	/// Headline case: a port presenting a decodable SOP' e-marker with no
	/// port-controller attach signal (ConnectionActive false/nil, no accessory, no
	/// CC transport) is OCCUPIED and rated from the e-marker -- not dropped, not
	/// Unknown. This is whatcable isPortLive priority 2 (PortLiveness.swift:27): a
	/// non-empty PD identity makes a port live on its own. Before this avenue the
	/// coordinator dropped such a port because occupancy was ConnectionActive-driven.
	func test_pd_identity_present_with_connection_false_is_occupied_and_rated() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Port 2 has NO port-controller attach bit, but a 10G SOP' e-marker
		// correlates to it by the "2/2" portKey.
		let verdicts = coordinator.mergeSnapshot(
			ports: [portNoAttachSignal(number: 2)],
			sopNodes: [sopPrime10G(port: 2)]
		)
		XCTAssertEqual(verdicts.count, 1,
		               "a PD-identity-only port is occupied, not dropped")
		let port2 = verdicts.first
		XCTAssertEqual(port2?.portNumber, 2)
		// Rated from the e-marker, not Unknown.
		XCTAssertTrue(port2?.hasReadableEMarker == true,
		              "the SOP' e-marker is rated, not Unknown")
		XCTAssertEqual(port2?.verdict.tier, .gen10g, "SOP' e-marker rates 10G")
		XCTAssertEqual(port2?.verdict.basis, .emarker)
		XCTAssertEqual(port2?.headline, "Port 2: 10G [e-marker]")
		// The rating is attributed to the SOP identity backend, and the occupancy
		// avenue is recorded as the PD identity (no port-controller signal fired).
		XCTAssertEqual(port2?.backendSource, .sopIdentity)
		XCTAssertEqual(port2?.occupancySource, .pdIdentity,
		               "occupancy came from the PD identity, not ConnectionActive")
	}

	/// A port presenting an SOP node with EMPTY Metadata and no port-controller
	/// attach signal is still occupied via the PD-identity avenue, rendering
	/// "Unknown [port active]" (the SOP node is present but carries no readable
	/// e-marker). The occupancy source is recorded as the PD identity.
	func test_pd_identity_empty_metadata_no_connection_is_unknown_port_active() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Reuse the captured M1 SOP node (empty Metadata, port 3) but pair it with a
		// port-3 controller that has NO attach signal.
		let verdicts = coordinator.mergeSnapshot(
			ports: [portNoAttachSignal(number: 3)],
			sopNodes: m1SopNodes()
		)
		XCTAssertEqual(verdicts.count, 1,
		               "an empty-Metadata SOP node still makes the port occupied")
		let port3 = verdicts.first
		XCTAssertEqual(port3?.portNumber, 3)
		XCTAssertFalse(port3?.hasReadableEMarker == true,
		               "empty Metadata -> no readable e-marker")
		XCTAssertTrue(port3?.sopServicePresent == true)
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]")
		XCTAssertEqual(port3?.occupancySource, .pdIdentity)
	}

	//============================================
	// MARK: Corroborating occupancy avenues (accessory / CC transport)
	//============================================

	/// Corroborating avenue: a port with ConnectionActive false/nil but
	/// IOAccessoryDetect true is occupied at the coordinator (still behind the
	/// USB-C/PortNumber guard) and renders Unknown [port active], with the accessory
	/// avenue recorded as the occupancy source.
	func test_accessory_detect_only_is_occupied_at_coordinator() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [portAccessoryDetectOnly(number: 2)],
			sopNodes: []
		)
		XCTAssertEqual(verdicts.count, 1,
		               "IOAccessoryDetect alone makes the port occupied")
		let port2 = verdicts.first
		XCTAssertEqual(port2?.portNumber, 2)
		XCTAssertEqual(port2?.headline, "Port 2: Unknown [port active]")
		XCTAssertEqual(port2?.occupancySource, .accessoryDetect,
		               "IOAccessoryDetect carried the occupancy decision")
	}

	/// Corroborating avenue: a port with ConnectionActive false and TransportsActive
	/// containing "CC" is occupied at the coordinator (behind the guard) and renders
	/// Unknown [port active], with the CC-transport avenue recorded as the source.
	func test_transports_cc_only_is_occupied_at_coordinator() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [portTransportsCCOnly(number: 2)],
			sopNodes: []
		)
		XCTAssertEqual(verdicts.count, 1,
		               "TransportsActive 'CC' alone makes the port occupied")
		let port2 = verdicts.first
		XCTAssertEqual(port2?.portNumber, 2)
		XCTAssertEqual(port2?.headline, "Port 2: Unknown [port active]")
		XCTAssertEqual(port2?.occupancySource, .transportsActiveCC,
		               "TransportsActive 'CC' carried the occupancy decision")
	}

	/// An idle port with NO attach signal AND no correlated PD identity stays silent
	/// even though the new PD-identity avenue exists: an unrelated SOP node for a
	/// different port must not make this port occupied.
	func test_idle_port_with_no_signal_and_no_identity_stays_silent() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Port 1 has no attach signal; the only SOP node is for port 3, so it does
		// not correlate to port 1.
		let verdicts = coordinator.mergeSnapshot(
			ports: [portNoAttachSignal(number: 1)],
			sopNodes: [sopPrime10G(port: 3)]
		)
		XCTAssertTrue(verdicts.isEmpty,
		              "no attach signal and no correlated identity -> silent")
	}

	//============================================
	// MARK: M5 device-speed floor fallback
	//============================================

	/// A no-e-marker cable with a USB3+ device on the far end is FLOORED at the
	/// device-negotiated speed: an occupied Port 3 with no SOP e-marker but a 10G
	/// device paired to it renders "Port 3: At least 10G [device]", attributed to the
	/// USB device backend.
	func test_device_floor_renders_at_least_speed_when_no_emarker() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			devices: [device(port: 3, speedRaw: 4)]
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertNotNil(port3, "the occupied port produces a verdict")
		XCTAssertFalse(port3?.hasReadableEMarker == true,
		               "the device floor is not a cable e-marker read")
		XCTAssertEqual(port3?.verdict.basis, .deviceFloor)
		XCTAssertEqual(port3?.verdict.tier, .gen10g, "floored at the 10G device speed")
		XCTAssertEqual(port3?.backendSource, .usbDevice,
		               "a device-floored verdict is attributed to the USB device source")
		XCTAssertEqual(port3?.headline, "Port 3: At least 10G [device]")
	}

	/// E-marker precedence: when a readable SOP' e-marker AND a far-end device both
	/// exist for a port, the cable's own e-marker wins -- the verdict rates by the
	/// e-marker, not the device floor. Here the e-marker reads 10G and the device
	/// negotiated 5G; the headline is the e-marker 10G, never "At least 5G".
	func test_emarker_wins_over_device_floor() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [sopPrime10G(port: 3)],
			devices: [device(port: 3, speedRaw: 3)]
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertTrue(port3?.hasReadableEMarker == true,
		              "the e-marker is read, not the device floor")
		XCTAssertEqual(port3?.verdict.basis, .emarker,
		               "the cable e-marker basis wins over the device floor")
		XCTAssertEqual(port3?.verdict.tier, .gen10g, "rated by the e-marker (10G)")
		XCTAssertEqual(port3?.backendSource, .sopIdentity,
		               "an e-marked cable is attributed to the SOP identity source")
		XCTAssertEqual(port3?.headline, "Port 3: 10G [e-marker]")
	}

	/// Neither e-marker nor device floor: an occupied port with no SOP e-marker and no
	/// USB3+ device on the far end stays "Unknown [port active]". A USB2 device gives
	/// no floor, so it does not change the Unknown result.
	func test_no_emarker_and_no_useful_device_stays_unknown() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// A USB2 device (speedRaw 2) on the port provides no floor.
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			devices: [device(port: 3, speedRaw: 2)]
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertEqual(port3?.verdict.basis, .noEmarker,
		               "no e-marker and no USB3+ device -> Unknown")
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]")
	}

	/// A device on a DIFFERENT port does not floor this port: a 10G device paired to
	/// Port 2 must not floor the occupied Port 3, which stays Unknown.
	func test_device_on_other_port_does_not_floor_this_port() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			devices: [device(port: 2, speedRaw: 4)]
		)
		let port3 = verdicts.first(where: { $0.portNumber == 3 })
		XCTAssertEqual(port3?.verdict.basis, .noEmarker,
		               "a device on Port 2 does not floor Port 3")
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]")
	}
}
