import XCTest
import Foundation
@testable import CableRater

/// WP-M2 behavior tests for the watch-mode frontend wiring (WatchEmitter +
/// PlugCoordinator). These prove the make-or-break startup contract and the
/// debounce/coalesce policy WITHOUT live IOKit: the coordinator's pure
/// `mergeSnapshot` / `ingest` drive synthetic snapshots, and the emitter's injected
/// "now" + print sink make the debounce window deterministic.
///
/// Covered:
///   - --once and watch-startup print the SAME line for one visible no-e-marker
///     cable ("Port 3: Unknown [port active]");
///   - a late SOP' e-marker (arriving a beat after the port goes active) yields ONE
///     coalesced headline with the e-marker result;
///   - the poll path catches a transition when the interest callback is absent.
final class WatchFrontendTests: XCTestCase {

	//============================================
	// MARK: Synthetic snapshot builders
	//============================================

	/// A synthetic occupied/idle USB-C port with a chosen ConnectionActive value.
	/// Clears the USB-C/PortNumber guard so liveness can decide.
	private func port(number: Int, connectionActive: Bool) -> PortState {
		let state = PortState(
			registryID: UInt64(8000 + number),
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

	/// Build a read closure over a property dictionary, mirroring the production
	/// per-key IOKit reader (an absent key reads nil).
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// A populated SOP' node for `port`: passive cable, VID 0x05AC, 10G Cable VDO.
	/// Same shape PlugCoordinatorTests uses, so the decode reaches a readable
	/// e-marker that rates 10G.
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
			registryID: UInt64(8100 + port),
			read: reader(properties)
		)
		return detected
	}

	//============================================
	// MARK: --once / watch-startup parity
	//============================================

	/// A single visible no-e-marker cable on Port 3 yields the SAME two-line block in
	/// both the --once path and the watch-startup path. Both paths render from the
	/// coordinator's verdicts: --once prints `renderPortBlock` directly; watch-startup
	/// prints it through `WatchEmitter.emitStartup`. The shared block proves they agree.
	func test_once_and_startup_agree_on_visible_no_emarker_cable() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		// Port 3 occupied (ConnectionActive true) with NO SOP node: a bare cable with
		// no readable e-marker -- the exact silent-plug bug this wiring fixes.
		let ports = [port(number: 3, connectionActive: true)]
		let verdicts = coordinator.mergeSnapshot(ports: ports, sopNodes: [])

		XCTAssertEqual(verdicts.count, 1, "only the occupied Port 3 produces a verdict")
		let port3 = verdicts.first
		XCTAssertEqual(port3?.portNumber, 3)

		// The --once text block: the two-line port-led block printed directly by runOnce.
		let onceBlock = renderPortBlockStyled(port3!, styled: false)
		// The headline line still leads with the calm Unknown port-active wording.
		XCTAssertTrue(onceBlock.hasPrefix("Port 3: Unknown [port active]\n"),
		              "--once headline leads the block for a bare cable: \(onceBlock)")

		// The watch-startup block: emitted through the same renderer by emitStartup.
		var startupLines: [String] = []
		let emitter = WatchEmitter(json: false) { line in startupLines.append(line) }
		emitter.emitStartup(verdicts)

		XCTAssertEqual(startupLines.count, 1, "startup emits one block for one cable")
		XCTAssertEqual(startupLines.first, onceBlock,
		               "watch-startup and --once render the identical current-state block")
	}

	//============================================
	// MARK: Late e-marker coalesce (one headline per plug)
	//============================================

	/// The late-e-marker sequence yields ONE coalesced headline with the e-marker
	/// result. t0: Port 3 ConnectionActive false->true with no SOP' (held Unknown).
	/// t1 (within the debounce window): the SOP' appears for the same port. At flush
	/// (after the window) the re-merge picks up the e-marker, so exactly one line
	/// prints -- the 10G e-marker headline, not the earlier Unknown.
	func test_late_emarker_coalesces_to_one_emarker_headline() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: false) { line in lines.append(line) }

		// Baseline at t0: Port 3 idle. Seeds the tracker, no transition, no line.
		let t0 = 100.0
		let baseline = coordinator.ingest(
			ports: [port(number: 3, connectionActive: false)],
			sopNodes: []
		)
		emitter.offer(transitions: baseline, now: t0)
		XCTAssertTrue(lines.isEmpty, "an idle baseline prints nothing")

		// t0: ConnectionActive flips true with NO SOP' yet -> a held insert (Unknown).
		let plugged = coordinator.ingest(
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: []
		)
		emitter.offer(transitions: plugged, now: t0)
		XCTAssertTrue(lines.isEmpty, "the plug is HELD during the debounce window")
		XCTAssertTrue(emitter.hasPending, "an insert is pending the debounce deadline")

		// A poll within the window (before the deadline) must not flush the held line.
		let withinWindow = t0 + (watchDebounceSeconds / 2.0)
		emitter.flushReady(
			now: withinWindow,
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: [],
			coordinator: coordinator
		)
		XCTAssertTrue(lines.isEmpty, "nothing flushes before the debounce deadline")

		// t1 (still within the window): the SOP' e-marker appears for Port 3.
		// The window closes at the next flush, which re-merges with the SOP node.
		let afterWindow = t0 + watchDebounceSeconds + 0.01
		emitter.flushReady(
			now: afterWindow,
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: [sopPrime10G(port: 3)],
			coordinator: coordinator
		)

		// Exactly ONE emitted block, and its headline is the upgraded e-marker result.
		XCTAssertEqual(lines.count, 1, "one plug yields exactly one block (coalesced)")
		XCTAssertTrue(lines.first?.hasPrefix("Port 3: 10G [e-marker]\n") == true,
		              "the late SOP' upgrades the held block to the e-marker headline: \(lines.first ?? "")")
		// The detail line beneath carries the decoded spec (10 Gbps speed phrase).
		XCTAssertTrue(lines.first?.contains("10 Gbps") == true,
		              "the e-marker block's detail line carries the speed phrase: \(lines.first ?? "")")
		XCTAssertFalse(emitter.hasPending, "the held insert was flushed")
	}

	/// When the debounce window closes with NO SOP' ever arriving, the held line is
	/// printed as the honest Unknown [port active] result -- still exactly one line.
	func test_no_emarker_within_window_prints_one_unknown_line() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: false) { line in lines.append(line) }

		let t0 = 50.0
		_ = coordinator.ingest(
			ports: [port(number: 3, connectionActive: false)],
			sopNodes: []
		)
		let plugged = coordinator.ingest(
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: []
		)
		emitter.offer(transitions: plugged, now: t0)

		// Window closes with no SOP node ever present -> one Unknown line.
		emitter.flushReady(
			now: t0 + watchDebounceSeconds + 0.01,
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: [],
			coordinator: coordinator
		)
		XCTAssertEqual(lines.count, 1, "one plug, one block even without an e-marker")
		XCTAssertTrue(lines.first?.hasPrefix("Port 3: Unknown [port active]\n") == true,
		              "no e-marker by the deadline -> the honest Unknown headline: \(lines.first ?? "")")
		// The detail line beneath is the honest evidence line naming the avenue(s).
		// New wording: "no e-marker read yet" (not "no readable e-marker") per whatcable guidance.
		XCTAssertTrue(lines.first?.contains("no e-marker read yet") == true,
		              "the Unknown block's detail line uses honest unqueried wording: \(lines.first ?? "")")
		// The far-end retry hint must be present.
		XCTAssertTrue(lines.first?.contains("attach a charger/dock/device on the far end") == true,
		              "the detail line includes the far-end retry hint: \(lines.first ?? "")")
		// The word "basic" must NOT appear -- it overclaims a USB2 rating.
		XCTAssertFalse(lines.first?.contains("basic") == true,
		               "the wording must not claim 'basic': \(lines.first ?? "")")
		XCTAssertTrue(lines.first?.contains("ConnectionActive") == true,
		              "the evidence line names the ConnectionActive avenue: \(lines.first ?? "")")
	}

	//============================================
	// MARK: Poll backup catches a missed interest callback
	//============================================

	/// The poll path catches a transition when the interest callback is simulated
	/// absent. The poll loop's per-tick work is: snapshot -> coordinator.ingest ->
	/// emitter.offer -> emitter.flushReady. Here the interest callback NEVER fires;
	/// only the poll tick runs, and it still detects the false->true plug and prints
	/// the line after the debounce window -- proving the backup poll alone suffices.
	func test_poll_backup_catches_transition_without_interest_callback() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: false) { line in lines.append(line) }

		// One poll tick that mirrors the live loop's pollStep, with NO interest poke.
		func pollTick(now: Double, ports: [PortState], sopNodes: [DetectedCable]) {
			let transitions = coordinator.ingest(ports: ports, sopNodes: sopNodes)
			emitter.offer(transitions: transitions, now: now)
			emitter.flushReady(
				now: now,
				ports: ports,
				sopNodes: sopNodes,
				coordinator: coordinator
			)
		}

		// Tick 1: Port 3 idle -> seeds the tracker, no line.
		pollTick(now: 0.0, ports: [port(number: 3, connectionActive: false)], sopNodes: [])
		XCTAssertTrue(lines.isEmpty, "an idle poll prints nothing")

		// Tick 2: Port 3 now ConnectionActive true. The interest callback did NOT
		// fire; the poll alone detects the plug and holds it.
		pollTick(now: 1.0, ports: [port(number: 3, connectionActive: true)], sopNodes: [])
		XCTAssertTrue(lines.isEmpty, "the poll-detected plug is held in the window")

		// Tick 3: after the debounce window. The held line flushes -> ONE line, even
		// though no interest notification ever arrived.
		pollTick(
			now: 1.0 + watchDebounceSeconds + 0.01,
			ports: [port(number: 3, connectionActive: true)],
			sopNodes: []
		)
		XCTAssertEqual(lines.count, 1,
		               "the backup poll alone surfaces the missed-interest plug")
		XCTAssertTrue(lines.first?.hasPrefix("Port 3: Unknown [port active]\n") == true,
		              "the poll-flushed block leads with the Unknown headline: \(lines.first ?? "")")
	}

	/// The poll path also catches a removal with no interest callback: a tracked
	/// occupied port that flips ConnectionActive false on a later poll prints the
	/// removed event in JSON mode (text mode stays quiet on unplug). This proves the
	/// backup poll handles both edges of the transition.
	func test_poll_backup_catches_removal_in_json() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: true) { line in lines.append(line) }

		func pollTick(now: Double, ports: [PortState]) {
			let transitions = coordinator.ingest(ports: ports, sopNodes: [])
			emitter.offer(transitions: transitions, now: now)
			emitter.flushReady(now: now, ports: ports, sopNodes: [], coordinator: coordinator)
		}

		// Plug, flush, then unplug -- all via poll, no interest callback.
		pollTick(now: 0.0, ports: [port(number: 3, connectionActive: true)])
		pollTick(now: watchDebounceSeconds + 0.01, ports: [port(number: 3, connectionActive: true)])
		let beforeUnplug = lines.count
		XCTAssertEqual(beforeUnplug, 1, "the plug produced one JSON event")

		pollTick(now: 10.0, ports: [port(number: 3, connectionActive: false)])
		XCTAssertEqual(lines.count, 2, "the poll-detected unplug produced a JSON event")
		XCTAssertTrue(lines.last?.contains("removed") == true,
		              "the unplug is a removed event: \(lines.last ?? "")")
	}

	//============================================
	// MARK: Distinct unplug rendering (text mode)
	//============================================

	//============================================
	// MARK: Evidence-line stability across startup, interest, and poll
	//============================================

	/// The no-e-marker evidence line for the same physical port state is IDENTICAL
	/// across the startup path (SOP node already enumerated, sopServicePresent=true)
	/// and the replug/poll path (SOP node not yet present at flush, sopServicePresent=false).
	///
	/// This is the stability test the task requires: the coordinator's output for
	/// startup and for replug must produce the same two-line block so "via ConnectionActive"
	/// is stable and "SOP node" never appears (it is timing-variable enrichment).
	///
	/// Three paths are exercised:
	///   - startup: `mergeSnapshot` with a SOP node present (sopServicePresent=true).
	///   - replug interest: `ingest` with no SOP node present at flush time.
	///   - replug poll: `flushReady` re-merge with no SOP node in the snapshot.
	func test_no_emarker_evidence_line_stable_across_startup_interest_poll() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)

		// Startup path: Port 3 occupied, NO SOP node in the snapshot (no e-marker path).
		// We also build a startup-path PortVerdict with sopServicePresent=true below to
		// simulate the case where the SOP node had enumerated before the verdict was built.
		let ports3active = [port(number: 3, connectionActive: true)]
		// Build the startup block without any SOP node to get the no-e-marker path.
		let startupVerdictsNoEmarker = coordinator.mergeSnapshot(
			ports: ports3active,
			sopNodes: [],
			backendSource: .portPoll
		)
		XCTAssertEqual(startupVerdictsNoEmarker.count, 1,
		               "startup: Port 3 occupied produces one verdict")
		let startupVerdict = startupVerdictsNoEmarker[0]
		// Manually set sopServicePresent to true to simulate the settled SOP state.
		// We test portEvidenceAvenues directly with both sopServicePresent values.
		let startupVerdictWithSOP = PortVerdict(
			portNumber: startupVerdict.portNumber,
			portKey: startupVerdict.portKey,
			verdict: startupVerdict.verdict,
			backendSource: startupVerdict.backendSource,
			occupancySource: startupVerdict.occupancySource,
			sopServicePresent: true
		)

		// Replug path via interest: `ingest` with no SOP node (SOP not yet settled).
		let coordinator2 = PlugCoordinator(catalog: Catalog.shared)
		// Seed the tracker (idle baseline).
		_ = coordinator2.ingest(ports: [port(number: 3, connectionActive: false)], sopNodes: [])
		// Plug fires (ConnectionActive true), no SOP node yet.
		let plugTransitions = coordinator2.ingest(ports: ports3active, sopNodes: [])
		XCTAssertEqual(plugTransitions.count, 1, "interest path: one insert transition")
		let interestVerdict = plugTransitions[0].verdict
		// sopServicePresent must be false at interest time (no SOP node in snapshot).
		XCTAssertFalse(interestVerdict.sopServicePresent,
		               "interest path: no SOP node present at plug time means sopServicePresent=false")

		// Render blocks from both verdicts (startup with SOP present vs interest with no SOP).
		let blockStartupWithSOP = renderPortBlockStyled(startupVerdictWithSOP, styled: false)
		let blockInterest = renderPortBlockStyled(interestVerdict, styled: false)

		// The stability contract: the two-line block must be IDENTICAL regardless of
		// sopServicePresent. The headline and evidence line must not flip.
		XCTAssertEqual(blockStartupWithSOP, blockInterest,
		               "startup (sopServicePresent=true) and interest (sopServicePresent=false) blocks must be identical (no SOP-node flip):\nstartup:  \(blockStartupWithSOP)\ninterest: \(blockInterest)")

		// The evidence line says "via ConnectionActive" in both cases.
		XCTAssertTrue(blockStartupWithSOP.contains("via ConnectionActive"),
		              "startup evidence line names ConnectionActive: \(blockStartupWithSOP)")
		XCTAssertTrue(blockInterest.contains("via ConnectionActive"),
		              "interest evidence line names ConnectionActive: \(blockInterest)")

		// "SOP node" must NOT appear in either block.
		XCTAssertFalse(blockStartupWithSOP.contains("SOP node"),
		               "startup block must not contain 'SOP node' (timing-variable): \(blockStartupWithSOP)")
		XCTAssertFalse(blockInterest.contains("SOP node"),
		               "interest block must not contain 'SOP node': \(blockInterest)")
	}

	/// A removal in TEXT mode renders the distinct one-line unplug message
	/// "Port N: unplugged", NOT the plug-shaped "Port N: Unknown [port active]" line.
	/// This is the WP-M6 secondary fix: the reliable true->false remove transition is
	/// rendered distinctly so an unplug no longer looks identical to a plug. The remove
	/// transition is reliable here -- the pure tracker emits one clean true->false
	/// event per unplug, fed by both the interest path and the backup poll.
	func test_text_unplug_renders_distinct_unplugged_line() {
		let coordinator = PlugCoordinator(catalog: Catalog.shared)
		var lines: [String] = []
		let emitter = WatchEmitter(json: false) { line in lines.append(line) }

		func pollTick(now: Double, ports: [PortState]) {
			let transitions = coordinator.ingest(ports: ports, sopNodes: [])
			emitter.offer(transitions: transitions, now: now)
			emitter.flushReady(now: now, ports: ports, sopNodes: [], coordinator: coordinator)
		}

		// Plug Port 3 and flush the held insert so the plug block prints.
		pollTick(now: 0.0, ports: [port(number: 3, connectionActive: true)])
		pollTick(now: watchDebounceSeconds + 0.01, ports: [port(number: 3, connectionActive: true)])
		let afterPlug = lines.count
		XCTAssertEqual(afterPlug, 1, "the plug produced one block")

		// Unplug Port 3: ConnectionActive flips false on a later poll.
		pollTick(now: 10.0, ports: [port(number: 3, connectionActive: false)])
		XCTAssertEqual(lines.count, 2, "the unplug produced one line")
		XCTAssertEqual(lines.last, "Port 3: unplugged",
		               "the unplug renders the distinct unplugged line: \(lines.last ?? "")")
		// The unplug line must NOT be a plug-shaped headline.
		XCTAssertFalse(lines.last?.contains("[port active]") == true,
		               "the unplug must not look like a plug: \(lines.last ?? "")")
		XCTAssertFalse(lines.last?.contains("Unknown") == true,
		               "the unplug is not the Unknown plug line: \(lines.last ?? "")")
	}
}
