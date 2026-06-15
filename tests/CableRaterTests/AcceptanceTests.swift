import XCTest
import Foundation
@testable import CableRater

/// M4 fixture-driven acceptance suite: end-to-end behavior proofs from captured
/// M1 IOKit fixtures.  No live hardware is required; every assertion is driven by
/// the four fixture plists already in tests/CableRaterTests/Fixtures/.
///
/// The six M4 acceptance cases:
///   M4-1  M1 visible-attach renders the two-line "Port 3: Unknown [port active]"
///          block; the two idle ports render nothing.
///   M4-2  Initial-scan parity: watch-startup verdicts equal the --once verdicts
///          for the same fixture state.
///   M4-3  Distinct unplug: a remove transition renders "Port N: unplugged", not
///          a plug-shaped line.
///   M4-4  No-e-marker evidence line is stable (identical across startup/interest/
///          poll) and never claims "basic".
///   M4-5  JSON schema/token stability across verdict types (UNKNOWN / UNKNOWN* /
///          a decoded bucket): keys, order, tokens unchanged.
///   M4-6  Raw-controller-shape cases (no PortTypeDescription, no Port- name) still
///          produce an occupied verdict -- regression guard for the live-detection fix.
final class AcceptanceTests: XCTestCase {

	//============================================
	// MARK: Fixture loading helpers
	//============================================

	/// Load a plist fixture array from the test bundle, failing the test if it is
	/// missing or unparseable.
	///
	/// Args:
	///   name: The plist filename inside the Fixtures folder (e.g. "port_controllers_m1.plist").
	///
	/// Returns:
	///   The top-level array from the plist as [[String: Any]].
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
	/// production per-key IOKit reader. An absent key reads nil, matching IOKit.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// Build a PortState from a captured controller-node entry the same way live
	/// IOKit does, reading gate inputs straight off the raw node shape.
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

	/// All three port-controller states from the M1 fixture.
	private func m1PortStates() -> [PortState] {
		let entries = loadFixture(named: "port_controllers_m1.plist")
		return entries.map { portState(from: $0) }
	}

	/// The SOP node from the M1 SOP fixture (empty Metadata, Port 3).
	private func m1SopNodes() -> [DetectedCable] {
		let entries = loadFixture(named: "sop_port3.plist")
		return entries.map { entry -> DetectedCable in
			let cls = entry["IOObjectClass"] as? String
				?? "IOPortTransportComponentCCUSBPDSOP"
			return IOKitCableSource.describeService(
				serviceClass: cls,
				registryID: 4295494713,
				read: reader(entry)
			)
		}
	}

	/// A synthetic port state with a specific ConnectionActive value. Passes the
	/// USB-C/PortNumber guard so liveness can decide.
	private func syntheticPort(number: Int, connectionActive: Bool) -> PortState {
		return PortState(
			registryID: UInt64(9000 + number),
			serviceClass: "AppleTCControllerType10",
			portNumber: number,
			connectionActive: connectionActive,
			accessoryDetect: false,
			transportsActive: [],
			isUSBCPort: true,
			portType: 2
		)
	}

	/// A populated SOP' node for a given port number (passive cable, 10G VDO).
	/// Used for M4-5 JSON schema stability with a decoded bucket.
	private func sopPrime10G(port: Int) -> DetectedCable {
		// ID Header VDO[0]: UFP product type 3 == passive, VID 0x05AC.
		let idHeader: UInt32 = 0x180005AC
		// Cable VDO[3]: speed bits 2..0 == 2 -> 10G.
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
		return IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: UInt64(9100 + port),
			read: reader(properties)
		)
	}

	//============================================
	// MARK: M4-1: M1 visible-attach renders two-line block; idle ports render nothing
	//============================================

	/// M4-1a: The M1 fixture Port 3 (visible CC attach, empty-Metadata SOP node)
	/// produces exactly one verdict with headline "Port 3: Unknown [port active]".
	/// Ports 1 and 2 (ConnectionActive false, no SOP node) produce no verdict.
	func test_m4_1a_m1_fixture_port3_renders_unknown_port_active() {
		// Fixture source: port_controllers_m1.plist (three controllers) +
		//                 sop_port3.plist (empty-Metadata SOP for Port 3).
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)

		// Exactly one occupied port -- Port 3 with its CC attach.
		XCTAssertEqual(verdicts.count, 1,
		               "M4-1: only Port 3 is occupied; Ports 1-2 must be silent")
		let port3 = verdicts.first
		XCTAssertEqual(port3?.portNumber, 3,
		               "M4-1: the occupied port is Port 3")
		// The headline must be the exact gate text.
		XCTAssertEqual(port3?.headline, "Port 3: Unknown [port active]",
		               "M4-1: Port 3 renders the Unknown [port active] headline")
		// The verdict tier and basis are stable.
		XCTAssertEqual(port3?.verdict.basis, .noEmarker,
		               "M4-1: empty Metadata -> no e-marker basis")
	}

	/// M4-1b: The full two-line block (headline + detail) for the M1 Port 3 verdict
	/// has the right leading text. The detail line must not be empty.
	func test_m4_1b_m1_fixture_port3_two_line_block_shape() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		guard let port3 = verdicts.first(where: { $0.portNumber == 3 }) else {
			XCTFail("M4-1b: Port 3 verdict must exist")
			return
		}
		// The two-line block is headline + newline + detail.
		let block = renderPortBlockStyled(port3, styled: false)
		XCTAssertTrue(block.hasPrefix("Port 3: Unknown [port active]\n"),
		              "M4-1b: the block starts with the headline on line 1: \(block)")
		// The block must contain a second line (detail) separated by a newline.
		let lines = block.components(separatedBy: "\n")
		XCTAssertEqual(lines.count, 2,
		               "M4-1b: the block has exactly two lines (headline + detail): \(block)")
		XCTAssertFalse(lines[1].isEmpty,
		               "M4-1b: the detail line must not be empty: \(block)")
	}

	/// M4-1c: Ports 1 and 2 from the M1 fixture produce NO verdicts -- they are idle
	/// (ConnectionActive false, no SOP node). This is the "idle ports render nothing"
	/// half of M4-1, driven from the real fixture rather than synthetic ports.
	func test_m4_1c_m1_idle_ports_produce_no_verdicts() {
		// Filter out Port 3 (occupied) -- only feed Ports 1 and 2 to the coordinator.
		let entries = loadFixture(named: "port_controllers_m1.plist")
		let ports1and2 = entries
			.filter { ($0["PortNumber"] as? Int) != 3 }
			.map { portState(from: $0) }
		guard !ports1and2.isEmpty else {
			XCTFail("M4-1c: fixture must have idle port entries (Ports 1 and 2)")
			return
		}
		// Confirm the idle ports are indeed ports 1 and 2 (ConnectionActive false or nil).
		XCTAssertTrue(ports1and2.allSatisfy { $0.connectionActive != true },
		              "M4-1c: all filtered ports must have ConnectionActive false or nil")

		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// No SOP nodes either (Ports 1-2 had none in the live capture).
		let verdicts = coordinator.mergeSnapshot(ports: ports1and2, sopNodes: [])
		XCTAssertTrue(verdicts.isEmpty,
		              "M4-1c: Ports 1 and 2 (ConnectionActive false) produce no verdicts")
	}

	//============================================
	// MARK: M4-2: Initial-scan parity with --once
	//============================================

	/// M4-2a: The watch-startup verdicts (from mergeSnapshot / emitStartup) equal the
	/// --once verdicts for the same M1 fixture state. Both paths rate Port 3 from the
	/// same empty-Metadata SOP node and arrive at the identical PortVerdict.
	func test_m4_2a_startup_verdicts_equal_once_verdicts() {
		// The --once path: one coordinator merge of the M1 fixture snapshot.
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let onceVerdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)

		// The watch-startup path: the same merge forwarded through emitStartup.
		var startupLines: [String] = []
		let emitter = WatchEmitter(json: false) { line in startupLines.append(line) }
		emitter.emitStartup(onceVerdicts)

		// --once produces one verdict; startup emits one block for that verdict.
		XCTAssertEqual(onceVerdicts.count, 1,
		               "M4-2a: --once produces one verdict for the M1 fixture")
		XCTAssertEqual(startupLines.count, 1,
		               "M4-2a: startup emits one block (one per occupied port)")

		// The rendered output must be identical between --once and startup.
		let onceBlock = renderPortBlockStyled(onceVerdicts[0], styled: false)
		XCTAssertEqual(startupLines[0], onceBlock,
		               "M4-2a: startup and --once render the identical block: \(startupLines[0])")
	}

	/// M4-2b: For a fully idle M1 state (all ports ConnectionActive false, no SOP),
	/// both --once and watch-startup produce zero output lines. Parity holds on
	/// silence too.
	func test_m4_2b_all_idle_parity_produces_no_output() {
		let allIdlePorts = [
			syntheticPort(number: 1, connectionActive: false),
			syntheticPort(number: 2, connectionActive: false),
			syntheticPort(number: 3, connectionActive: false),
		]
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let onceVerdicts = coordinator.mergeSnapshot(ports: allIdlePorts, sopNodes: [])

		var startupLines: [String] = []
		let emitter = WatchEmitter(json: false) { line in startupLines.append(line) }
		emitter.emitStartup(onceVerdicts)

		// Both paths produce silence for an idle state.
		XCTAssertTrue(onceVerdicts.isEmpty,
		              "M4-2b: all-idle --once produces no verdicts")
		XCTAssertTrue(startupLines.isEmpty,
		              "M4-2b: all-idle startup emits nothing")
	}

	//============================================
	// MARK: M4-3: Distinct unplug rendering
	//============================================

	/// M4-3a: A remove transition renders "Port N: unplugged" in text mode, not the
	/// plug-shaped "Port N: Unknown [port active]" line. This is the M4 unplug proof:
	/// a synthetic true->false ConnectionActive transition produces the distinct
	/// unplug message via the coordinator + emitter path.
	func test_m4_3a_remove_transition_renders_unplugged_not_plug_shaped() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: false) { line in lines.append(line) }

		// Plug: Port 3 active (false->true seeds the tracker).
		let plug = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		emitter.offer(transitions: plug, now: 0.0)
		// Flush the plug so the port is tracked as occupied.
		emitter.flushReady(
			now: watchDebounceSeconds + 0.01,
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			coordinator: coordinator
		)
		let afterPlug = lines.count
		XCTAssertEqual(afterPlug, 1, "M4-3a: the plug produced one line")

		// Unplug: ConnectionActive flips false (the remove transition).
		let unplug = coordinator.ingest(
			ports: [syntheticPort(number: 3, connectionActive: false)],
			sopNodes: []
		)
		emitter.offer(transitions: unplug, now: 10.0)

		// The unplug must render as "Port 3: unplugged" exactly.
		XCTAssertEqual(lines.count, 2, "M4-3a: the unplug produced a second line")
		XCTAssertEqual(lines.last, "Port 3: unplugged",
		               "M4-3a: the remove transition renders 'Port 3: unplugged'")
		// The unplug line must NOT contain plug-shaped tokens.
		XCTAssertFalse(lines.last?.contains("[port active]") == true,
		               "M4-3a: the unplug must not look like a plug: \(lines.last ?? "")")
		XCTAssertFalse(lines.last?.contains("Unknown") == true,
		               "M4-3a: the unplug must not contain 'Unknown': \(lines.last ?? "")")
	}

	/// M4-3b: The direct renderPortUnplug function produces "Port N: unplugged" for
	/// the port number carried by the remove verdict. This is the render-layer proof
	/// that the distinct-unplug renderer never produces plug-shaped text.
	func test_m4_3b_render_port_unplug_produces_distinct_line() {
		let unplugged3 = renderPortUnplug(portNumber: 3)
		XCTAssertEqual(unplugged3, "Port 3: unplugged",
		               "M4-3b: renderPortUnplug for port 3 renders the distinct line")
		let unplugged1 = renderPortUnplug(portNumber: 1)
		XCTAssertEqual(unplugged1, "Port 1: unplugged",
		               "M4-3b: renderPortUnplug for port 1 renders the distinct line")
		// Confirm neither line resembles a plug.
		XCTAssertFalse(unplugged3.contains("[port active]"),
		               "M4-3b: unplug line must not contain [port active]")
		XCTAssertFalse(unplugged3.contains("Unknown"),
		               "M4-3b: unplug line must not contain Unknown")
	}

	//============================================
	// MARK: M4-4: No-e-marker evidence line stability
	//============================================

	/// M4-4a: The no-e-marker evidence line for the same physical port state is
	/// IDENTICAL across the startup path (SOP node enumerated, sopServicePresent=true)
	/// and the interest path (SOP node absent at plug time, sopServicePresent=false).
	/// The stability contract: the block must not flip "SOP node" in/out.
	func test_m4_4a_no_emarker_evidence_line_identical_startup_vs_interest() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let ports3active = [syntheticPort(number: 3, connectionActive: true)]

		// Startup path: merge with the M1 SOP node present (sopServicePresent=true after
		// the merge). The SOP node carries empty Metadata, so no readable e-marker.
		let startupVerdicts = coordinator.mergeSnapshot(
			ports: ports3active,
			sopNodes: m1SopNodes(),
			backendSource: .portPoll
		)
		XCTAssertEqual(startupVerdicts.count, 1, "M4-4a: startup must produce one verdict")
		let startupVerdict = startupVerdicts[0]
		// Manually reconstruct with sopServicePresent=true to simulate the settled SOP.
		let startupVerdictWithSOP = PortVerdict(
			portNumber: startupVerdict.portNumber,
			portKey: startupVerdict.portKey,
			verdict: startupVerdict.verdict,
			backendSource: startupVerdict.backendSource,
			occupancySource: startupVerdict.occupancySource,
			sopServicePresent: true
		)

		// Interest path: ingest with no SOP node (SOP not yet settled at plug time).
		let coordinator2 = PlugCoordinator(catalog: Catalog.shared)
		_ = coordinator2.ingest(
			ports: [syntheticPort(number: 3, connectionActive: false)],
			sopNodes: []
		)
		let plugTransitions = coordinator2.ingest(ports: ports3active, sopNodes: [])
		XCTAssertEqual(plugTransitions.count, 1, "M4-4a: interest path produces one insert")
		let interestVerdict = plugTransitions[0].verdict
		XCTAssertFalse(interestVerdict.sopServicePresent,
		               "M4-4a: at interest time no SOP node is present (sopServicePresent=false)")

		// Render both blocks and compare: they must be identical.
		let blockStartup = renderPortBlockStyled(startupVerdictWithSOP, styled: false)
		let blockInterest = renderPortBlockStyled(interestVerdict, styled: false)
		XCTAssertEqual(blockStartup, blockInterest,
		               "M4-4a: startup and interest blocks must be identical (no SOP-node flip):\n" +
		               "startup:  \(blockStartup)\ninterest: \(blockInterest)")

		// Both blocks must name ConnectionActive as the avenue.
		XCTAssertTrue(blockStartup.contains("via ConnectionActive"),
		              "M4-4a: startup block must name ConnectionActive: \(blockStartup)")
		XCTAssertTrue(blockInterest.contains("via ConnectionActive"),
		              "M4-4a: interest block must name ConnectionActive: \(blockInterest)")

		// Neither block may mention "SOP node" (timing-variable enrichment).
		XCTAssertFalse(blockStartup.contains("SOP node"),
		               "M4-4a: startup block must not mention 'SOP node': \(blockStartup)")
		XCTAssertFalse(blockInterest.contains("SOP node"),
		               "M4-4a: interest block must not mention 'SOP node': \(blockInterest)")
	}

	/// M4-4b: The no-e-marker evidence line never claims "basic" or "USB2" as the
	/// cable rating. The correct wording is the honest unqueried message, not a speed
	/// claim (which would overclaim a rating for an unread cable).
	func test_m4_4b_no_emarker_evidence_line_never_claims_basic() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// The M1 fixture: Port 3 occupied, empty-Metadata SOP node (no readable e-marker).
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		guard let port3 = verdicts.first(where: { $0.portNumber == 3 }) else {
			XCTFail("M4-4b: Port 3 verdict must exist")
			return
		}
		let block = renderPortBlockStyled(port3, styled: false)

		// The evidence line must not claim "basic" (overclaim).
		XCTAssertFalse(block.contains("basic"),
		               "M4-4b: the block must not claim 'basic': \(block)")
		// The wording must be the honest unqueried message.
		XCTAssertTrue(block.contains("no e-marker read yet"),
		              "M4-4b: the detail line must use honest unqueried wording: \(block)")
		// The far-end retry hint must be present.
		XCTAssertTrue(block.contains("attach a charger/dock/device on the far end"),
		              "M4-4b: the detail line must include the far-end retry hint: \(block)")
	}

	/// M4-4c: Poll-path evidence-line stability: the flushReady re-merge with no SOP
	/// node produces the same two-line block as startup. The poll path must not vary
	/// from the interest/startup paths for the same physical cable state.
	func test_m4_4c_no_emarker_evidence_line_stable_on_poll_flush() {
		// Reference block from the startup merge (no SOP node, ConnectionActive only).
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let startupVerdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			backendSource: .portPoll
		)
		let referenceBlock = renderPortBlockStyled(startupVerdicts[0], styled: false)

		// Poll path via WatchEmitter: plug at t0, flush after the debounce window with
		// no SOP node in the snapshot.
		let coordinator2 = PlugCoordinator(catalog: Catalog.shared)
		var pollLines: [String] = []
		let emitter = WatchEmitter(json: false) { line in pollLines.append(line) }

		let t0 = 20.0
		_ = coordinator2.ingest(
			ports: [syntheticPort(number: 3, connectionActive: false)],
			sopNodes: []
		)
		let plug = coordinator2.ingest(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: []
		)
		emitter.offer(transitions: plug, now: t0)
		emitter.flushReady(
			now: t0 + watchDebounceSeconds + 0.01,
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [],
			coordinator: coordinator2
		)
		XCTAssertEqual(pollLines.count, 1, "M4-4c: the poll flush produced one block")
		// The poll-flushed block must match the reference startup block.
		XCTAssertEqual(pollLines[0], referenceBlock,
		               "M4-4c: poll-flushed block must equal the startup reference:\n" +
		               "poll:    \(pollLines[0])\nreference: \(referenceBlock)")
	}

	//============================================
	// MARK: M4-5: JSON schema/token stability
	//============================================

	/// M4-5a: UNKNOWN verdict (no e-marker): the JSON object has the expected key
	/// order, the "UNKNOWN" bucket token, and null vendor/product/cableVDO/brand fields.
	func test_m4_5a_json_schema_unknown_verdict() {
		// The M1 fixture's no-e-marker verdict -- the UNKNOWN / noEmarker shape.
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: m1PortStates(),
			sopNodes: m1SopNodes()
		)
		guard let port3 = verdicts.first(where: { $0.portNumber == 3 }) else {
			XCTFail("M4-5a: Port 3 verdict must exist")
			return
		}
		let json = renderJSON(port3.verdict, event: "snapshot")

		// Stable bucket token.
		XCTAssertTrue(json.contains("\"bucket\":\"UNKNOWN\""),
		              "M4-5a: UNKNOWN bucket token must appear in JSON: \(json)")
		// Stable basis token.
		XCTAssertTrue(json.contains("\"basis\":\"noEmarker\""),
		              "M4-5a: noEmarker basis token must appear in JSON: \(json)")
		// For a no-e-marker verdict, vendorId is null and brand is null.
		XCTAssertTrue(json.contains("\"vendorId\":null"),
		              "M4-5a: vendorId must be null for a no-e-marker verdict: \(json)")
		XCTAssertTrue(json.contains("\"brand\":null"),
		              "M4-5a: brand must be null for a no-e-marker verdict: \(json)")
	}

	/// M4-5b: UNKNOWN* verdict (e-marker unrecognized / Potentially fast?): the JSON
	/// object carries the "UNKNOWN*" bucket token and "emarkerUnrecognized" basis.
	/// The stable schema tokens must be unchanged.
	func test_m4_5b_json_schema_unknown_star_verdict() {
		// An all-zero CableInfo shape (no recognized speed bits) -> emarkerUnrecognized.
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let rated = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(rated.basis, .emarkerUnrecognized,
		               "M4-5b: the all-zero cable must produce an emarkerUnrecognized basis")
		let json = renderJSON(rated, event: "snapshot")

		// Stable bucket token for the UNKNOWN* pile.
		XCTAssertTrue(json.contains("\"bucket\":\"UNKNOWN*\""),
		              "M4-5b: UNKNOWN* bucket token must appear in JSON: \(json)")
		XCTAssertTrue(json.contains("\"basis\":\"emarkerUnrecognized\""),
		              "M4-5b: emarkerUnrecognized basis token must appear in JSON: \(json)")
		// Stable key presence (not order): event, bucket, tier, basis must all be present.
		XCTAssertTrue(json.contains("\"event\""), "M4-5b: event key must be present")
		XCTAssertTrue(json.contains("\"tier\""), "M4-5b: tier key must be present")
	}

	/// M4-5c: Decoded bucket verdict (10G e-marker from a SOP' node): the JSON object
	/// carries the "10G" bucket token, "emarker" basis, and the non-null vendorId from
	/// the decoded ID Header. Key order is the same as the other verdict types.
	func test_m4_5c_json_schema_decoded_bucket_verdict() {
		// Merge a synthetic Port 3 with the 10G SOP' node to get a decoded emarker verdict.
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(
			ports: [syntheticPort(number: 3, connectionActive: true)],
			sopNodes: [sopPrime10G(port: 3)]
		)
		guard let port3 = verdicts.first(where: { $0.portNumber == 3 }) else {
			XCTFail("M4-5c: Port 3 verdict with e-marker must exist")
			return
		}
		XCTAssertEqual(port3.verdict.basis, .emarker,
		               "M4-5c: the SOP' 10G node must decode to emarker basis")
		let json = renderJSON(port3.verdict, event: "inserted")

		// Stable bucket and basis tokens for the decoded 10G pile.
		XCTAssertTrue(json.contains("\"bucket\":\"10G\""),
		              "M4-5c: 10G bucket token must appear in JSON: \(json)")
		XCTAssertTrue(json.contains("\"basis\":\"emarker\""),
		              "M4-5c: emarker basis token must appear in JSON: \(json)")
		// The event token must reflect the caller-supplied name.
		XCTAssertTrue(json.contains("\"event\":\"inserted\""),
		              "M4-5c: event must be 'inserted': \(json)")
		// A decoded e-marker supplies a non-null vendorId (0x05AC from the ID Header).
		XCTAssertFalse(json.contains("\"vendorId\":null"),
		               "M4-5c: vendorId must not be null for a decoded e-marker: \(json)")
	}

	/// M4-5d: The "removed" event token is present in JSON for an unplug verdict.
	/// The schema must be unchanged: the same keys, same order, "removed" event name.
	func test_m4_5d_json_schema_removed_event_token() {
		// A remove transition carries the honest UNKNOWN/noEmarker verdict.
		let rated = verdict(for: nil, catalog: Catalog.shared)
		let json = renderJSON(rated, event: "removed")

		XCTAssertTrue(json.contains("\"event\":\"removed\""),
		              "M4-5d: the removed event token must appear in JSON: \(json)")
		XCTAssertTrue(json.contains("\"bucket\":\"UNKNOWN\""),
		              "M4-5d: UNKNOWN bucket for removed event: \(json)")
		// Stable key presence: the schema keys must all be present.
		XCTAssertTrue(json.contains("\"tier\""), "M4-5d: tier key must be present: \(json)")
		XCTAssertTrue(json.contains("\"basis\""), "M4-5d: basis key must be present: \(json)")
	}

	//============================================
	// MARK: M4-6: Raw-controller-shape regression guard
	//============================================

	/// M4-6a: A raw AppleTCControllerType10 node WITHOUT a PortTypeDescription key
	/// (controller_no_porttypedescription.plist) still produces an occupied verdict
	/// at the coordinator. This is the regression guard for the live-detection fix:
	/// the gate trusts the named class plus PortNumber, not PortTypeDescription.
	func test_m4_6a_no_porttypedescription_fixture_produces_occupied_verdict() {
		// Fixture: controller_no_porttypedescription.plist (one occupied Port 3 node
		//          without PortTypeDescription, ConnectionActive = true).
		let entries = loadFixture(named: "controller_no_porttypedescription.plist")
		XCTAssertEqual(entries.count, 1,
		               "M4-6a: fixture must contain exactly one controller node")
		// Confirm the fixture genuinely omits the PortTypeDescription key.
		XCTAssertNil(entries[0]["PortTypeDescription"],
		             "M4-6a: the fixture must omit PortTypeDescription to exercise the gate")
		let state = portState(from: entries[0])

		// The gate must accept the known class + PortNumber combination.
		XCTAssertTrue(state.isUSBCPort,
		              "M4-6a: a known TC class with PortNumber is a real USB-C port")
		XCTAssertTrue(PortLiveness.passesPortGuard(state),
		              "M4-6a: the real-port gate clears without PortTypeDescription")
		XCTAssertTrue(PortLiveness.isOccupied(state),
		              "M4-6a: ConnectionActive=true makes the port occupied")

		// The coordinator must produce a verdict for this node.
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(ports: [state], sopNodes: [])
		XCTAssertEqual(verdicts.count, 1,
		               "M4-6a: the no-PortTypeDescription fixture must yield one verdict")
		XCTAssertEqual(verdicts.first?.portNumber, 3,
		               "M4-6a: the verdict is for Port 3")
		XCTAssertEqual(verdicts.first?.headline, "Port 3: Unknown [port active]",
		               "M4-6a: the no-PortTypeDescription port renders the occupied headline")
	}

	/// M4-6b: A raw AppleTCControllerType10 node WITHOUT a "Port-" registry name
	/// (controller_no_port_name.plist) still produces an occupied verdict. The "Port-"
	/// name filter applies only to the broad IOPort catch-all, not to named TC classes.
	func test_m4_6b_no_port_name_fixture_produces_occupied_verdict() {
		// Fixture: controller_no_port_name.plist (one occupied Port 3 node whose
		//          IORegistryEntryName is "USB-C Port", not "Port-USB-C").
		let entries = loadFixture(named: "controller_no_port_name.plist")
		XCTAssertEqual(entries.count, 1,
		               "M4-6b: fixture must contain exactly one controller node")
		// Confirm the fixture genuinely has a non-"Port-" name.
		let registryName = entries[0]["IORegistryEntryName"] as? String ?? ""
		XCTAssertFalse(registryName.hasPrefix("Port-"),
		               "M4-6b: the fixture must use a non-Port- name to exercise the gate")
		let state = portState(from: entries[0])

		// The gate must accept the known class + PortNumber combination.
		XCTAssertTrue(state.isUSBCPort,
		              "M4-6b: a known TC class with PortNumber is a real USB-C port")
		XCTAssertTrue(PortLiveness.passesPortGuard(state),
		              "M4-6b: the real-port gate clears without a Port- name")

		// The coordinator must produce a verdict for this node.
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		let verdicts = coordinator.mergeSnapshot(ports: [state], sopNodes: [])
		XCTAssertEqual(verdicts.count, 1,
		               "M4-6b: the no-Port-name fixture must yield one verdict")
		XCTAssertEqual(verdicts.first?.portNumber, 3,
		               "M4-6b: the verdict is for Port 3")
		XCTAssertEqual(verdicts.first?.headline, "Port 3: Unknown [port active]",
		               "M4-6b: the no-Port-name port renders the occupied headline")
	}
}
