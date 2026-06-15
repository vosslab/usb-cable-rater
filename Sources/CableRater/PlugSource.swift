// PlugSource.swift -- the PlugCoordinator: the port-centered merge layer that
// reconciles the two M1 backend detection avenues into ONE verdict per physical
// USB-C port.
//
// The two avenues, ported in earlier work packages, are:
//   - port state (PortWatch.swift): the PRIMARY plug signal. PortLiveness decides
//     occupied/idle from the port controller's own ConnectionActive bit (plus the
//     M1 IOPort guard: a candidate must map to a real USB-C PortNumber).
//   - PD identity (Probe.swift): the cable e-marker decode, correlated to a port by
//     the whatcable "type/number" portKey (ParentPortType/ParentPortNumber).
//
// This file is the custom frontend coordinator the port-fidelity gate calls out:
// the two backends are faithful whatcable ports (PortWatch, Probe), and the merge
// decision here is the project's own glue. The occupied/idle decision mirrors
// whatcable's PortLiveness ordering for the M1 required-now floor:
//   (2) PD identities non-empty -> live;
//   (3) non-MagSafe AND connectionActive -> live.
// (Priority (1) attached USB devices is the device-speed fallback; priority (4)
// power source is future-diagnostic. Neither participates on this M1 hardware.)
// MIT attribution for the ported backend logic lives in PortWatch.swift and
// Probe.swift (Darryl Morley 2026); this coordinator is original glue.
//
// One verdict per OCCUPIED port; an idle/invisible port produces no verdict, so a
// port with nothing plugged in stays silent. A decoded e-marker yields the rated
// CableInfo verdict; an occupied port with no readable e-marker yields the clean
// "Unknown [port active]" verdict. Each verdict records which backend source
// produced it so a rendered line counts only when its backend source is shown
// (the plan's "frontend success cannot hide backend failure" rule).

import Foundation

//============================================
// MARK: Backend source attribution
//============================================

/// Which backend detection avenue produced a port verdict. Recorded on every
/// `PortVerdict` so the rendered line can name its source -- the plan's backend
/// proof requirement that a verdict counts only when its backend source is shown.
public enum PortBackendSource: String, Equatable {
	/// The port-state watcher's live interest-notification / refresh path produced
	/// the occupancy (the primary plug signal on a property-only ConnectionActive
	/// flip). Used for live transitions through `ingest`.
	case portInterest
	/// The port-state snapshot/poll path produced the occupancy. Used by the
	/// initial-scan path (`currentVerdicts`) that mirrors `--once`.
	case portPoll
	/// An SOP / SOP' / SOP'' PD-identity node supplied a readable cable e-marker
	/// that decoded into the headline rating for this port.
	case sopIdentity
	/// An attached USB3+ device on the far end (M5 fallback) supplied a negotiated
	/// link speed that floors the cable's rating. Produced only when the cable has no
	/// readable e-marker but a USB3+ device paired to the port, yielding the
	/// "At least <speed> [device]" headline. The e-marker (SOP') source above always
	/// takes precedence over this device floor when both exist.
	case usbDevice
}

//============================================
// MARK: One verdict per physical port
//============================================

/// The merged verdict for one occupied physical USB-C port: the rated cable plus
/// the port number, the backend source that produced it, and the occupancy signal.
///
/// This is the single unit the watch frontend consumes. The
/// coordinator emits one of these per occupied port and nothing for an idle or
/// invisible port. `verdict` is the existing pure `Verdict` value (so the Render
/// and JSON layers work unchanged); the port-specific fields surround it.
public struct PortVerdict: Equatable {
	/// The physical USB-C port number this verdict is for (the rendered "Port N:").
	public let portNumber: Int
	/// The whatcable-style "type/number" join key the port-state and PD-identity
	/// sources were correlated on.
	public let portKey: String
	/// The rated cable. For a decoded e-marker this carries the speed bucket and
	/// basis; for an occupied-but-no-readable-e-marker port it is the honest
	/// UNKNOWN/noEmarker verdict (the "[port active]" wording is added by
	/// `headline` and by the renderer, not by mutating the stable Verdict).
	public let verdict: Verdict
	/// Which backend avenue produced this verdict (port poll/interest vs SOP
	/// identity vs M5 device). The plan's per-line backend-source record.
	public let backendSource: PortBackendSource
	/// The port-controller property that carried the occupancy decision
	/// (ConnectionActive etc.). The primary-signal half of the backend proof.
	public let occupancySource: PortSignalSource
	/// True when an SOP / SOP' / SOP'' node was present for this port even with no
	/// readable e-marker. Separates "occupied, SOP node present, empty Metadata"
	/// from "occupied by ConnectionActive with no SOP node at all"; both render
	/// "Unknown [port active]" but the field keeps the distinction for diagnostics.
	public let sopServicePresent: Bool

	public init(
		portNumber: Int,
		portKey: String,
		verdict: Verdict,
		backendSource: PortBackendSource,
		occupancySource: PortSignalSource,
		sopServicePresent: Bool
	) {
		self.portNumber = portNumber
		self.portKey = portKey
		self.verdict = verdict
		self.backendSource = backendSource
		self.occupancySource = occupancySource
		self.sopServicePresent = sopServicePresent
	}

	/// True when this port has a readable cable e-marker (a decoded CableInfo),
	/// i.e. it rates by e-marker / known-db rather than "[port active]".
	public var hasReadableEMarker: Bool {
		return verdict.cable != nil
	}

	/// The one-line port headline, e.g. "Port 3: 10G [e-marker]" for a decoded
	/// cable or "Port 3: Unknown [port active]" for an occupied port with no
	/// readable e-marker.
	///
	/// This is the M1 acceptance wording and the single source of truth for the
	/// port-led text: it delegates to the renderer's plain (unstyled) form so
	/// the coordinator gate text and the terminal output never diverge in wording.
	/// The renderer owns the final terminal styling (the colored bucket token on a
	/// TTY); this plain string lets the coordinator and its tests assert the exact
	/// gate text without ANSI escape codes. The calm title-case labels (Unknown,
	/// Potentially fast?) come from the renderer; the stable Verdict/JSON schema is
	/// untouched.
	public var headline: String {
		let line = renderPortHeadlineStyled(self, styled: false)
		return line
	}
}

//============================================
// MARK: Plug coordinator
//============================================

/// Merges the ported port-state watcher and PD-identity decode into one verdict
/// per occupied physical USB-C port.
///
/// The coordinator is pure with respect to its inputs: the merge core
/// (`mergeSnapshot`) takes a port-state snapshot and an SOP-node snapshot and
/// returns the verdicts, so tests drive the full M1 gate from the captured
/// fixtures with no live IOKit. The live entry points (`currentVerdicts`,
/// `watch`) wrap that core with real `PortWatcher` / `IOKitCableSource`
/// enumeration.
///
/// One verdict per OCCUPIED port; an idle or invisible port produces no verdict.
public final class PlugCoordinator {

	/// The known-cable database, forwarded to the rating layer so a zeroed/sparse
	/// e-marker can be refined to its DB speed.
	private let catalog: Catalog

	/// The port-state watcher (primary plug signal). Used by the live paths.
	private let portWatcher: PortWatcher

	/// The PD-identity source (cable e-marker decode + per-port correlation).
	private let cableSource: IOKitCableSource

	/// The attached-USB-device source (M5 device-speed floor fallback). Used by the
	/// live paths to pair a USB3+ far-end device to a port and floor a no-e-marker
	/// cable's rating.
	private let deviceWatcher: DeviceWatcher

	/// Pure occupancy diff shared with the live watch path so a synthetic or live
	/// snapshot stream yields one plug/unplug verdict per transition.
	private let tracker = PortTransitionTracker()

	/// Build a coordinator over the known-cable catalog and the two backend
	/// sources. Defaults construct fresh sources for the live path; tests inject
	/// their own (or ignore them and call the pure `mergeSnapshot` directly).
	///
	/// Args:
	///   catalog: the known-cable database for rating refinement.
	///   portWatcher: the port-state watcher; defaults to a fresh instance.
	///   cableSource: the PD-identity source; defaults to a fresh instance.
	///   deviceWatcher: the attached-USB-device source for the M5 device-speed floor;
	///     defaults to a fresh instance.
	public init(
		catalog: Catalog,
		portWatcher: PortWatcher = PortWatcher(),
		cableSource: IOKitCableSource = IOKitCableSource(),
		deviceWatcher: DeviceWatcher = DeviceWatcher()
	) {
		self.catalog = catalog
		self.portWatcher = portWatcher
		self.cableSource = cableSource
		self.deviceWatcher = deviceWatcher
	}

	//============================================
	// MARK: Pure merge core (testable, no hardware)
	//============================================

	/// Merge one port-state snapshot with one SOP-node snapshot into the verdicts
	/// for every occupied port. The pure core the M1 gate tests drive from fixtures.
	///
	/// For each port-controller state (behind the USB-C/PortNumber guard):
	///   - Skip it unless it is occupied by EITHER a port-controller signal
	///     (`PortLiveness.isOccupied`: ConnectionActive primary, plus IOAccessoryDetect
	///     and TransportsActive-"CC" corroboration) OR a correlated PD identity
	///     (whatcable isPortLive priority 2: a non-empty SOP / SOP' / SOP'' node makes
	///     the port live even with ConnectionActive false/nil). An idle, invisible
	///     port (no attach bit AND no PD identity) produces no verdict, so it stays
	///     silent.
	///   - Correlate the SOP nodes for that port by the "type/number" portKey
	///     (`PortType`/`PortNumber` on the controller joined to
	///     `ParentPortType`/`ParentPortNumber` on the SOP node).
	///   - If a readable e-marker decoded, rate it (basis e-marker/known-db/...),
	///     attributing the verdict to the SOP identity source.
	///   - Otherwise, if a USB3+ device on the far end paired to the port, floor the
	///     rating at the device-negotiated speed ("At least <speed>", basis
	///     deviceFloor), attributing the verdict to the USB device source. The
	///     e-marker path above always takes precedence over this device floor.
	///   - Otherwise produce the "Unknown [port active]" verdict, attributing it to
	///     the supplied port backend source (poll for the snapshot path).
	///
	/// Note on liveness priority: an occupied decision can come from
	/// ConnectionActive (whatcable priority 3, plus the IOAccessoryDetect /
	/// TransportsActive-"CC" corroborating avenues) OR, per whatcable PortLiveness
	/// priority 2, from a non-empty correlated PD identity even when ConnectionActive
	/// was false/nil. Both reduce to "this port has a cable", so a port presenting a
	/// decodable SOP' e-marker is included and rated rather than dropped.
	///
	/// Args:
	///   ports: the port-controller states (from a poll/refresh or a fixture).
	///   sopNodes: every detected SOP / SOP' / SOP'' node in the same snapshot.
	///   devices: every attached USB device in the same snapshot (the M5 device-speed
	///     floor source). A USB3+ device paired to a port floors a no-e-marker
	///     cable's rating. Defaults to empty so callers that do not supply devices
	///     keep the pre-M5 behavior.
	///   backendSource: the port-state backend that produced the occupancy
	///     (`.portPoll` for snapshots, `.portInterest` for the live diff path).
	///     A port whose rating comes from an SOP e-marker overrides this with
	///     `.sopIdentity`; a port floored by a far-end device overrides it with
	///     `.usbDevice`.
	///
	/// Returns:
	///   One `PortVerdict` per occupied port, in ascending PortNumber order for
	///   stable, reproducible output. Empty when no port is occupied.
	public func mergeSnapshot(
		ports: [PortState],
		sopNodes: [DetectedCable],
		devices: [DeviceState] = [],
		backendSource: PortBackendSource = .portPoll
	) -> [PortVerdict] {
		// Keep one occupied port per PortNumber. A physical port can appear under
		// more than one matched class (named controller + IOPort catch-all); the
		// liveness guard drops the IOPort-only candidate, and the first occupied
		// state per number wins so a port is rated once.
		var occupiedByNumber: [Int: PortState] = [:]
		for state in ports {
			// The candidate must clear the IOPort guard first (a real USB-C port
			// with a PortNumber). An IOPort-only catch-all match never emits, even
			// through the PD-identity avenue below.
			guard PortLiveness.passesPortGuard(state), let number = state.portNumber else {
				continue
			}
			// Occupied/idle decision reconciling every avenue whatcable's isPortLive
			// uses, behind the USB-C/PortNumber guard:
			//   - PortLiveness.isOccupied: ConnectionActive (primary, whatcable
			//     priority 3) plus the IOAccessoryDetect and TransportsActive-"CC"
			//     corroborating avenues.
			//   - PD identity present (whatcable isPortLive priority 2,
			//     PortLiveness.swift:27): a port presenting a correlated SOP /
			//     SOP' / SOP'' node is live even when ConnectionActive is false/nil,
			//     so a decodable e-marker is rated rather than dropped.
			// Idle/invisible ports (no attach bit AND no PD identity) never enter the
			// map, so they produce no verdict (stay silent).
			let occupiedByPort = PortLiveness.isOccupied(state)
			let occupiedByPD = portHasCorrelatedIdentity(state: state, sopNodes: sopNodes)
			guard occupiedByPort || occupiedByPD else {
				continue
			}
			if occupiedByNumber[number] == nil {
				occupiedByNumber[number] = state
			}
		}

		var verdicts: [PortVerdict] = []
		for number in occupiedByNumber.keys.sorted() {
			let state = occupiedByNumber[number]!
			let portVerdict = mergePort(
				state: state,
				sopNodes: sopNodes,
				devices: devices,
				portBackendSource: backendSource
			)
			verdicts.append(portVerdict)
		}
		return verdicts
	}

	/// True when a SOP / SOP' / SOP'' PD-identity node correlates to this port by
	/// the "type/number" portKey. This is the PD-identity occupancy avenue
	/// (whatcable isPortLive priority 2, PortLiveness.swift:27): a port presenting a
	/// correlated PD identity is occupied even when ConnectionActive is false/nil.
	///
	/// The portKey is built from the controller's own PortType + PortNumber the same
	/// way `mergePort` builds it, so the occupancy decision and the later rating
	/// correlate on the identical key.
	///
	/// Args:
	///   state: a port-controller state that has already cleared the USB-C guard.
	///   sopNodes: every detected SOP node in the snapshot.
	///
	/// Returns:
	///   true when at least one SOP node correlates to this port.
	private func portHasCorrelatedIdentity(
		state: PortState,
		sopNodes: [DetectedCable]
	) -> Bool {
		// The caller's passesPortGuard + `let number = state.portNumber` guarantees
		// this is non-nil, so force-unwrap rather than substitute a wrong portKey.
		let number = state.portNumber!
		let portType = state.portType ?? Self.usbCPortType
		let identity = IOKitCableSource.decodePort(
			forPortType: portType,
			portNumber: number,
			from: sopNodes
		)
		// sopServicePresent is true when any SOP node matched the portKey, even one
		// with empty Metadata. Either is a non-empty PD identity for liveness.
		return identity.sopServicePresent
	}

	/// Merge one occupied port-controller state with the SOP nodes correlated to it
	/// into that port's single verdict.
	///
	/// The portKey is built from the controller's own PortType + PortNumber (the
	/// type half is read from the state's `portType` when present; on this M1 the
	/// SOP nodes carry type 2, so the controller is correlated on the same key).
	/// The PD identity is decoded by the existing pure `decodePort` correlation.
	///
	/// Args:
	///   state: an occupied port-controller state (already admitted by the merge
	///     occupancy decision -- a port-controller signal or a correlated PD identity).
	///   sopNodes: every detected SOP node in the snapshot.
	///   devices: every attached USB device in the snapshot (the device-floor source).
	///   portBackendSource: the backend that produced the occupancy when no e-marker
	///     decoded.
	///
	/// Returns:
	///   The port's `PortVerdict`.
	private func mergePort(
		state: PortState,
		sopNodes: [DetectedCable],
		devices: [DeviceState],
		portBackendSource: PortBackendSource
	) -> PortVerdict {
		// The caller's guard (passesPortGuard / `let number = event.state.portNumber`)
		// guarantees this is non-nil, so force-unwrap rather than substitute -1.
		let number = state.portNumber!
		// Correlate the SOP nodes for this port by the "type/number" portKey. The
		// type comes from the controller's PortType when present; the captured M1
		// SOP nodes use type 2 (USB-C), so the coordinator correlates on that key.
		let portType = state.portType ?? Self.usbCPortType
		let identity = IOKitCableSource.decodePort(
			forPortType: portType,
			portNumber: number,
			from: sopNodes
		)
		// The occupancy source records which avenue decided "occupied":
		//   - a port-controller signal (ConnectionActive / IOAccessoryDetect /
		//     TransportsActive-"CC") when PortLiveness.isOccupied accepted the port,
		//   - otherwise the PD-identity avenue (whatcable isPortLive priority 2):
		//     the port was admitted only because a correlated SOP node is present
		//     while ConnectionActive was false/nil.
		let occSource = PortLiveness.occupancySource(state)
			?? (identity.sopServicePresent ? .pdIdentity : .connectionActive)

		// A readable e-marker -> rate by the cable; attribute to the SOP identity
		// backend. The existing verdict() reads the DB keys off the CableInfo, so a
		// zeroed/sparse cable still reaches the known-cable DB.
		if identity.hasReadableEMarker {
			let rated = verdict(for: identity.info, catalog: catalog)
			let portVerdict = PortVerdict(
				portNumber: number,
				portKey: identity.portKey,
				verdict: rated,
				backendSource: .sopIdentity,
				occupancySource: occSource,
				sopServicePresent: identity.sopServicePresent
			)
			return portVerdict
		}

		// No readable e-marker: M5 fallback. If a USB3+ device on the far end paired
		// to this port, its negotiated link speed is a conservative FLOOR for the
		// cable -- the cable carried at least that rate -- so rate the port
		// "At least <speed>" (basis deviceFloor) instead of Unknown. The e-marker
		// branch above always wins first, so a readable e-marker is never overridden
		// by the device floor; this only fires when the e-marker produced nothing.
		if let floor = decodeDeviceFloor(forPortNumber: number, from: devices) {
			let rated = verdictForDeviceFloor(tier: floor.tier)
			let portVerdict = PortVerdict(
				portNumber: number,
				portKey: identity.portKey,
				verdict: rated,
				backendSource: .usbDevice,
				occupancySource: occSource,
				sopServicePresent: identity.sopServicePresent
			)
			return portVerdict
		}

		// Occupied port, no readable e-marker and no device floor: the clean
		// "Unknown [port active]" verdict. verdict(for: nil, ...) returns the honest
		// UNKNOWN/noEmarker Verdict; the "[port active]" wording is supplied by
		// PortVerdict.headline (and the renderer), keeping the stable
		// Verdict/JSON schema untouched.
		let rated = verdict(for: nil, catalog: catalog)
		let portVerdict = PortVerdict(
			portNumber: number,
			portKey: identity.portKey,
			verdict: rated,
			backendSource: portBackendSource,
			occupancySource: occSource,
			sopServicePresent: identity.sopServicePresent
		)
		return portVerdict
	}

	//============================================
	// MARK: Initial-scan path (parity with --once)
	//============================================

	/// Take one live snapshot of port state + SOP nodes and return the verdict for
	/// every currently-occupied port. The startup parity path: the watch frontend
	/// prints these before listening for transitions, matching `--once`.
	///
	/// This enumerates real IOKit (via the injected `PortWatcher` /
	/// `IOKitCableSource`), so it is not used by the pure tests; tests call
	/// `mergeSnapshot` with fixture snapshots instead.
	///
	/// Returns:
	///   One `PortVerdict` per occupied port, ascending by PortNumber.
	public func currentVerdicts() -> [PortVerdict] {
		let ports = portWatcher.currentPorts()
		let sopNodes = cableSource.currentCables()
		let devices = deviceWatcher.currentDevices()
		let verdicts = mergeSnapshot(
			ports: ports,
			sopNodes: sopNodes,
			devices: devices,
			backendSource: .portPoll
		)
		return verdicts
	}

	//============================================
	// MARK: Transition diff (synthetic + live)
	//============================================

	/// A plug or unplug verdict from a port-occupancy transition.
	public struct PortTransition: Equatable {
		/// inserted (port became occupied) or removed (port became idle).
		public let kind: PortEvent.Kind
		/// The port number that transitioned.
		public let portNumber: Int
		/// The merged verdict for the port. For an insert this carries the rated
		/// cable / "[port active]" verdict; for a remove it is the honest
		/// UNKNOWN/noEmarker verdict (the cable is gone) with the port number.
		public let verdict: PortVerdict

		public init(kind: PortEvent.Kind, portNumber: Int, verdict: PortVerdict) {
			self.kind = kind
			self.portNumber = portNumber
			self.verdict = verdict
		}
	}

	/// Diff a fresh port-state snapshot against the tracked occupancy and return the
	/// plug/unplug verdicts, merging each inserted port with the SOP nodes from the
	/// same snapshot. The synthetic-transition entry point the M1 gate drives with
	/// false->true and true->false ConnectionActive snapshots.
	///
	/// Inserts merge with the SOP nodes (so a freshly plugged port with a readable
	/// e-marker rates by the cable, and one without rates "[port active]"). Removes
	/// carry the now-idle port number with the honest UNKNOWN/noEmarker verdict.
	/// Insert verdicts are attributed to `.portInterest` unless an SOP e-marker
	/// supplied the rating (then `.sopIdentity`).
	///
	/// Args:
	///   ports: the current port-controller states.
	///   sopNodes: the SOP nodes in the same snapshot (used for insert merges).
	///   devices: the attached USB devices in the same snapshot (used for the M5
	///     device-speed floor on insert merges). Defaults to empty so pre-M5 callers
	///     keep their behavior.
	///
	/// Returns:
	///   The plug/unplug verdicts implied by the change since the previous call,
	///   inserts before removes, each ascending by PortNumber.
	public func ingest(
		ports: [PortState],
		sopNodes: [DetectedCable],
		devices: [DeviceState] = []
	) -> [PortTransition] {
		// Reuse the pure port-state transition tracker for the occupancy diff. It
		// already enforces the IOPort guard and emits one event per false->true /
		// true->false transition, deduped per PortNumber.
		let events = tracker.ingest(ports)
		var transitions: [PortTransition] = []
		for event in events {
			guard let number = event.state.portNumber else {
				continue
			}
			switch event.kind {
			case .inserted:
				// Merge the freshly-occupied port with the SOP nodes (and any far-end
				// device floor) for its rating.
				let portVerdict = mergePort(
					state: event.state,
					sopNodes: sopNodes,
					devices: devices,
					portBackendSource: .portInterest
				)
				let transition = PortTransition(
					kind: .inserted,
					portNumber: number,
					verdict: portVerdict
				)
				transitions.append(transition)
			case .removed:
				// The cable is gone: honest UNKNOWN/noEmarker verdict for the port.
				let rated = verdict(for: nil, catalog: catalog)
				let portKey = IOKitCableSource.portKey(
					forPortType: event.state.portType ?? Self.usbCPortType,
					portNumber: number
				)
				let portVerdict = PortVerdict(
					portNumber: number,
					portKey: portKey,
					verdict: rated,
					backendSource: .portInterest,
					occupancySource: event.source,
					sopServicePresent: false
				)
				let transition = PortTransition(
					kind: .removed,
					portNumber: number,
					verdict: portVerdict
				)
				transitions.append(transition)
			}
		}
		return transitions
	}

	/// Forget all tracked occupancy. Used so a fresh watch starts with no baseline.
	public func reset() {
		tracker.reset()
	}

	//============================================
	// MARK: Constants
	//============================================

	/// The USB-C port type value on this hardware (the SOP nodes and the port
	/// controller both report type 2 for USB-C). Used to build the "type/number"
	/// portKey when a port-controller state does not itself carry a port type.
	static let usbCPortType = 2
}
