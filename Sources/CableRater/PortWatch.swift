// PortWatch.swift -- USB-C port-controller state watcher: the PRIMARY plug
// signal. It watches the port-controller services (AppleTCControllerType10 and
// the portable HPM/TC class set) and reports a cable attach/detach from the
// port's own ConnectionActive bit, NOT from a cable e-marker service.
//
// Why this exists: the e-marker probe in Probe.swift watches only SOP' e-marker
// services, so a non-e-marked cable (the common bare cable) publishes no SOP'
// service and the tool stays silent. The port controller, by contrast, reports
// ConnectionActive = true whenever a cable terminates CC (configuration channel),
// e-marked or not. That makes ConnectionActive the reliable primary plug signal.
//
// Adapted from whatcable
//   Sources/WhatCableDarwinBackend/Watchers/AppleHPMInterfaceWatcher.swift:
//     candidateClasses (matched port-controller class set + IOPort catch-all),
//     start / stop (IONotificationPortCreate, IOServiceAddMatchingNotification on
//       kIOMatchedNotification per class, drain-to-arm),
//     refresh (IOServiceGetMatchingServices + IOIteratorNext registry re-walk),
//     registerInterest (per-service IOServiceAddInterestNotification with
//       kIOGeneralInterest so property-only changes -- a cable plug that does not
//       create or remove a service -- still trigger a refresh),
//     interest-notification pruning across plug/unplug cycles,
//     makePort (per-key IORegistryEntryCreateCFProperty reads, NOT the bulk
//       IORegistryEntryCreateCFProperties fetch, to stay safe during teardown),
//     busIndex / registry-name parsing helpers.
// and from Sources/WhatCableCore/Port/AppleHPMInterface.swift:
//   AppleHPMInterface.from (pure factory reading operational keys one at a time),
//   the real-port gate (PortTypeDescription == "USB-C" and a "Port-" name),
//   stringArrayProperty / boolean coercion helpers.
// MIT license, Darryl Morley 2026.
//
// This file strips whatcable's SwiftUI/ObservableObject coupling (the @MainActor
// @Published ports array, the GUI sort, the UUID/SMC join key, the device-pairing
// helpers) down to the CLI's need: per-port ConnectionActive transitions emitted
// as plain plug/unplug events. The pure PortState factory and the PortLiveness
// decision are hardware-free so PortWatchTests can drive them from injected
// in-memory snapshots with the same keys real IOKit delivers.

import Foundation
import IOKit

//============================================
// MARK: Detected port-controller source
//============================================

/// Which IOKit property produced a port event. Recorded so the --debug probe can
/// print exactly what backend source decided a port was occupied -- the plan's
/// requirement that "frontend success cannot hide backend failure".
public enum PortSignalSource: String, Equatable {
	/// ConnectionActive flipped true. The primary CC-attach signal.
	case connectionActive
	/// A correlated PD identity (SOP / SOP' / SOP'') node was present for the port
	/// even when ConnectionActive was false/nil. This is whatcable isPortLive
	/// priority 2 (PortLiveness.swift:27): a non-empty PD identity makes a port
	/// live on its own, so a port presenting a decodable cable e-marker is occupied
	/// even with no port-controller attach bit set. The coordinator (PlugSource)
	/// supplies this source; PortLiveness itself sees only port-controller state.
	case pdIdentity
	/// IOAccessoryDetect flipped true (corroboration; used when ConnectionActive
	/// was absent but the port still reports an accessory attach).
	case accessoryDetect
	/// TransportsActive began carrying "CC" (active-transport liveness).
	case transportsActiveCC
}

/// One matched port-controller service, decoded into the keys this app reads.
///
/// This is the unit the port watch and snapshot layers emit. It is the
/// port-state analogue of `DetectedCable` (which carries an e-marker): a
/// `PortState` carries the port's own occupancy signal, independent of any
/// cable e-marker. The two combine downstream into one verdict per port.
public struct PortState: Equatable {
	/// IOKit registry entry ID of the port-controller service. Stable per service
	/// within a session; used to dedup and to key interest notifications.
	public let registryID: UInt64
	/// The service's IOKit class name (e.g. "AppleTCControllerType10"). Reported in
	/// the --debug probe as the matched backend source.
	public let serviceClass: String
	/// The physical port number (PortNumber key). The correlation key that ties a
	/// port event to a PD-identity e-marker and to the rendered "Port <N>:" line.
	/// nil when the service does not publish a PortNumber.
	public let portNumber: Int?
	/// The physical port type (PortType key), the type half of the "type/number"
	/// portKey the PlugCoordinator joins on. nil when the service does not publish a
	/// numeric PortType; the coordinator then defaults to the USB-C type. Read from
	/// the controller's own `PortType`, the required-now correlation key in the
	/// plan's data-sources table alongside PortNumber.
	public let portType: Int?
	/// ConnectionActive: the PRIMARY plug signal. true while a cable terminates CC.
	/// nil when the key is absent (a service that is not a real USB-C port).
	public let connectionActive: Bool?
	/// IOAccessoryDetect: corroborating attach signal. nil when absent.
	public let accessoryDetect: Bool?
	/// TransportsActive entries (e.g. ["CC"]). Empty when absent. A port that is
	/// occupied at the CC level lists "CC" here even before any data transport.
	public let transportsActive: [String]
	/// True when this service looks like a real physical USB-C port. There are two
	/// ways to qualify, mirroring whatcable's intent (trust the named port-controller
	/// classes; filter only the broad catch-all):
	///   - a KNOWN port-controller class (AppleTCControllerType10/11,
	///     AppleHPMInterfaceType10/11/12/18) that resolves a PortNumber. For these
	///     classes PortTypeDescription == "USB-C" and a "Port-" name are CONFIRMING
	///     evidence, not a hard requirement, so a controller whose description string
	///     differs (a MagSafe-described port, a TC/HPM generation that labels the
	///     port differently) is still recognized as a real port.
	///   - the broad IOPort catch-all, which must STILL satisfy the hard
	///     PortTypeDescription == "USB-C" (or MagSafe) plus "Port-" name filter,
	///     because that catch-all matches many non-port services and would otherwise
	///     emit from anything. This keeps the IOPort guard's "discovery-only" rule.
	/// A bare IOPort catch-all match that is NOT a real USB-C port is false here,
	/// which is what the IOPort guard keys off of (such a candidate never emits).
	public let isUSBCPort: Bool

	public init(
		registryID: UInt64,
		serviceClass: String,
		portNumber: Int?,
		connectionActive: Bool?,
		accessoryDetect: Bool?,
		transportsActive: [String],
		isUSBCPort: Bool,
		portType: Int? = nil
	) {
		self.registryID = registryID
		self.serviceClass = serviceClass
		self.portNumber = portNumber
		self.connectionActive = connectionActive
		self.accessoryDetect = accessoryDetect
		self.transportsActive = transportsActive
		self.isUSBCPort = isUSBCPort
		self.portType = portType
	}

	/// True when TransportsActive carries the CC entry, i.e. the port reports an
	/// active configuration-channel transport. This is one of the corroborating
	/// liveness signals from the plan's data-sources table.
	public var transportsActiveHasCC: Bool {
		let hasCC = transportsActive.contains("CC")
		return hasCC
	}

	/// Build a `PortState` from a property-read closure, reading each operational
	/// key one at a time.
	///
	/// Faithful to whatcable `AppleHPMInterface.from`: keys are read individually
	/// via the supplied closure rather than via a bulk property-dictionary fetch.
	/// whatcable hardened this because the bulk fetch
	/// (`IORegistryEntryCreateCFProperties`) can abort the process from inside
	/// `IOCFUnserializeBinary` when the kernel returns a malformed serialized blob
	/// during service teardown; the per-key path has no such failure mode. Each
	/// boolean key is coerced from NSNumber (the IOKit bridge) or a plain Bool/Int
	/// (synthetic test snapshots), so this factory runs unchanged on real hardware
	/// and on injected dictionaries.
	///
	/// The real-port gate mirrors whatcable's `isRealPort` INTENT rather than its
	/// exact string test. whatcable trusts the named port-controller classes (the
	/// broad IOPort catch-all is the only matched class that can pull in non-port
	/// services) and uses the `PortTypeDescription`/`Port-` filter to drop the
	/// catch-all's noise. So here:
	///   - a KNOWN port-controller class with a resolvable PortNumber is a real port;
	///     PortTypeDescription/"Port-" only CONFIRM it.
	///   - the broad IOPort catch-all must still pass the hard
	///     PortTypeDescription == "USB-C"/MagSafe + "Port-" name filter.
	/// The gate's result is recorded on `isUSBCPort` (not used to drop the service)
	/// because the IOPort guard needs to SEE a non-USB-C candidate to suppress it.
	///
	/// When the controller does not publish a `PortNumber`, the port number is
	/// recovered from the registry name's "@N" location suffix (mirroring whatcable's
	/// IORegistryEntryGetLocationInPlane identity), so a real port with an absent
	/// PortNumber key still resolves a number and clears the guard.
	///
	/// Args:
	///   registryID: the IOKit registry entry ID of the service.
	///   serviceClass: the IOKit class name of the service.
	///   serviceName: the registry entry name (e.g. "Port-USB-C@1"); used by the
	///     real-port gate. Empty when unavailable.
	///   serviceLocation: the registry entry location in the plane (e.g. "1"); the
	///     "@N" suffix whatcable uses for port identity. Empty when unavailable.
	///   read: closure mapping an IOKit property key to its value, or nil.
	///
	/// Returns:
	///   A `PortState` describing the service's occupancy keys.
	public static func from(
		registryID: UInt64,
		serviceClass: String,
		serviceName: String,
		serviceLocation: String = "",
		read: (String) -> Any?
	) -> PortState {
		// PortNumber correlates this port to a PD e-marker and to the rendered
		// line. Read it on its own; absent -> nil (not a defaulted 0, which would
		// falsely correlate to a real port 0).
		let portNumberKey = coercePortInt(read("PortNumber"))
		// Fallback: when the controller does not publish PortNumber, recover it from
		// the registry name/location "@N" suffix (whatcable's location-based port
		// identity). A real port with an absent PortNumber key still resolves here.
		let portNumber = portNumberKey
			?? portNumberFromLocation(name: serviceName, location: serviceLocation)
		// PortType is the type half of the "type/number" portKey the coordinator
		// joins on. Read individually; absent -> nil so the coordinator can default
		// to the USB-C type rather than a falsely-correlating 0. Named distinctly
		// from the string PortTypeDescription used by the real-port gate below.
		let portTypeNumber = coercePortInt(read("PortType"))
		// ConnectionActive is the primary plug signal; read individually.
		let connectionActive = coercePortBool(read("ConnectionActive"))
		// IOAccessoryDetect corroborates the attach; read individually.
		let accessoryDetect = coercePortBool(read("IOAccessoryDetect"))
		// TransportsActive lists active transports ("CC" at the CC level); read
		// individually and coerced to a string array.
		let transportsActive = coercePortStringArray(read("TransportsActive"))
		// Real-port gate. A real port has PortTypeDescription == "USB-C" (or a
		// MagSafe variant) and a name "Port-*". whatcable AppleHPMInterface.from
		// applies this to every matched service; we keep it as the HARD requirement
		// for the broad IOPort catch-all only, and treat it as CONFIRMING evidence
		// for the known port-controller classes (which we trust by class identity
		// plus a resolvable PortNumber).
		let portTypeDescription = read("PortTypeDescription") as? String
		let descriptionLooksLikePort =
			(portTypeDescription == "USB-C" || portTypeDescription?.hasPrefix("MagSafe") == true)
			&& serviceName.hasPrefix("Port-")
		let knownPortClass = isKnownPortControllerClass(serviceClass)
		let isUSBCPort: Bool
		if knownPortClass {
			// Trust the named class: a known port controller with a resolved
			// PortNumber is a real port even if its description string differs.
			// The description/"Port-" name still counts as confirming evidence.
			isUSBCPort = (portNumber != nil) || descriptionLooksLikePort
		} else {
			// Broad IOPort catch-all (or any other class): keep the hard filter so
			// the discovery catch-all never qualifies a non-port service.
			isUSBCPort = descriptionLooksLikePort
		}
		let state = PortState(
			registryID: registryID,
			serviceClass: serviceClass,
			portNumber: portNumber,
			connectionActive: connectionActive,
			accessoryDetect: accessoryDetect,
			transportsActive: transportsActive,
			isUSBCPort: isUSBCPort,
			portType: portTypeNumber
		)
		return state
	}

	/// The known USB-C port-controller IOKit classes -- the named entries in
	/// `PortWatcher.candidateClasses`, excluding the broad `IOPort` catch-all. A
	/// service of one of these classes is a real port controller by class identity,
	/// so it is trusted with only a resolvable PortNumber; the description string is
	/// confirming evidence, not a hard requirement. Faithful to whatcable's intent:
	/// the named classes are real ports, and only the `IOPort` catch-all needs the
	/// `PortTypeDescription`/"Port-" filter to drop non-port noise.
	static let knownPortControllerClasses: Set<String> = [
		"AppleHPMInterfaceType10",
		"AppleHPMInterfaceType11",
		"AppleHPMInterfaceType12",
		"AppleHPMInterfaceType18",
		"AppleTCControllerType10",
		"AppleTCControllerType11",
	]

	/// True when the class is one of the known port-controller classes (not the
	/// broad IOPort catch-all).
	///
	/// Args:
	///   serviceClass: the IOKit class name of the matched service.
	///
	/// Returns:
	///   true for a known port-controller class; false for IOPort or anything else.
	static func isKnownPortControllerClass(_ serviceClass: String) -> Bool {
		let isKnown = knownPortControllerClasses.contains(serviceClass)
		return isKnown
	}

	/// Recover the physical port number from the registry name/location "@N" suffix
	/// when the controller does not publish a `PortNumber` key.
	///
	/// macOS names the port controllers `Port-USB-C@1`, `Port-USB-C@2`, ... and sets
	/// the registry-entry location in the plane to the same "1"/"2"/... string (the
	/// "@N" suffix). whatcable derives port identity from
	/// IORegistryEntryGetLocationInPlane for this reason. This parses the number from
	/// the explicit location first (the most reliable source), then from any "@N"
	/// suffix in the name as a secondary path.
	///
	/// Args:
	///   name: the registry entry name (e.g. "Port-USB-C" or "Port-USB-C@1").
	///   location: the registry entry location in the plane (e.g. "1"). Empty when
	///     unavailable.
	///
	/// Returns:
	///   The parsed port number, or nil when neither source yields one.
	static func portNumberFromLocation(name: String, location: String) -> Int? {
		// The location string is the "@N" value macOS assigns the port; prefer it.
		if let fromLocation = Int(location) {
			return fromLocation
		}
		// Secondary: an "@N" suffix embedded in the name (e.g. "Port-USB-C@3").
		if let atIndex = name.lastIndex(of: "@") {
			let suffix = name[name.index(after: atIndex)...]
			if let fromName = Int(suffix) {
				return fromName
			}
		}
		return nil
	}
}

//============================================
// MARK: Port-liveness decision (occupied vs idle)
//============================================

/// Decide whether a port-controller state means a cable is attached, and report
/// which property carried the signal.
///
/// Adapted from the role of whatcable's port-liveness logic: ConnectionActive is
/// the primary occupied signal, with IOAccessoryDetect and an active CC transport
/// as corroboration. The plan's IOPort guard is enforced here: a candidate that
/// is not a real USB-C port (`isUSBCPort == false`) or that has no PortNumber is
/// never occupied, so a broad IOPort catch-all match -- which has neither -- can
/// never emit an insertion on its own. Class discovery still SEES such a service
/// (the watcher matches IOPort), but liveness refuses it until it maps to a real
/// USB-C PortNumber.
public enum PortLiveness {

	/// True when the candidate clears the IOPort guard: it is a real USB-C port
	/// (`isUSBCPort`) AND it publishes a `PortNumber`. This is the gate every
	/// occupancy avenue must pass before it can emit, so a broad IOPort catch-all
	/// match (no PortNumber, not a USB-C port) can never emit alone -- including the
	/// PD-identity avenue the coordinator adds on top of `isOccupied`.
	///
	/// Args:
	///   state: the port-controller state to gate.
	///
	/// Returns:
	///   true when the candidate maps to a real USB-C PortNumber; false otherwise.
	public static func passesPortGuard(_ state: PortState) -> Bool {
		let passes = state.isUSBCPort && state.portNumber != nil
		return passes
	}

	/// True when the port reports a cable attach by any read signal, AND the port
	/// is a real USB-C port with a PortNumber.
	///
	/// The USB-C/PortNumber gate runs FIRST so an IOPort-only candidate (no
	/// PortNumber, not a USB-C port) returns false even if some unrelated boolean
	/// happened to be true. Only after the candidate is confirmed as a USB-C port
	/// with a PortNumber do the occupancy signals decide.
	///
	/// Args:
	///   state: the port-controller state to judge.
	///
	/// Returns:
	///   true when the port is occupied (a cable is attached); false otherwise.
	public static func isOccupied(_ state: PortState) -> Bool {
		// IOPort guard: discovery-only candidates (no USB-C identity, no
		// PortNumber) never count as occupied, regardless of any boolean. This is
		// the plan's "emit only after it maps to a USB-C PortNumber" rule.
		guard passesPortGuard(state) else {
			return false
		}
		// Primary: ConnectionActive true means a cable terminates CC.
		if state.connectionActive == true {
			return true
		}
		// Corroboration: the port reports an accessory attach.
		if state.accessoryDetect == true {
			return true
		}
		// Corroboration: an active CC transport is present.
		if state.transportsActiveHasCC {
			return true
		}
		return false
	}

	/// The property that carried the occupancy signal, used by the --debug probe.
	///
	/// Returns the highest-priority source that is currently asserting occupancy
	/// (ConnectionActive first, then IOAccessoryDetect, then the CC transport), or
	/// nil when the port is not occupied. Mirrors the priority order of
	/// `isOccupied` so the reported source always matches the decision.
	///
	/// Args:
	///   state: the port-controller state to inspect.
	///
	/// Returns:
	///   The contributing `PortSignalSource`, or nil when idle.
	public static func occupancySource(_ state: PortState) -> PortSignalSource? {
		// Same gate and priority order as isOccupied so the source is consistent
		// with the decision.
		guard isOccupied(state) else {
			return nil
		}
		if state.connectionActive == true {
			return .connectionActive
		}
		if state.accessoryDetect == true {
			return .accessoryDetect
		}
		if state.transportsActiveHasCC {
			return .transportsActiveCC
		}
		return nil
	}
}

//============================================
// MARK: Detected-insertion event type
//============================================

/// A port plug or unplug event. This is the detected-insertion event the plan
/// asks for: distinct from the e-marker `DetectedCable`, it carries the
/// port-state occupancy decision (insert on false->true, remove on true->false)
/// and the backend source that produced it.
public struct PortEvent: Equatable {
	/// insert (port became occupied) or remove (port became idle).
	public enum Kind: String, Equatable {
		case inserted
		case removed
	}

	/// Whether the port became occupied (inserted) or idle (removed).
	public let kind: Kind
	/// The full port state at the moment of the transition.
	public let state: PortState
	/// The property that produced the event. For an insert this is the occupancy
	/// source (ConnectionActive etc.); for a remove it is the source that had been
	/// asserting occupancy before it cleared.
	public let source: PortSignalSource

	public init(kind: Kind, state: PortState, source: PortSignalSource) {
		self.kind = kind
		self.state = state
		self.source = source
	}
}

//============================================
// MARK: Transition tracker (pure, testable)
//============================================

/// Tracks per-port occupancy across snapshots and yields plug/unplug events on
/// the false->true and true->false transitions.
///
/// This is the pure, hardware-free core of the watcher's diff: feed it a fresh
/// list of `PortState`s (from an interest-notification rebuild, a poll, or an
/// injected test snapshot) and it returns only the ports whose occupancy
/// changed since the last call. It mirrors how whatcable's `refresh()` rebuilds
/// the live list and compares; the difference is this returns explicit
/// transition events instead of mutating a `@Published` array.
///
/// Keyed by PortNumber so the same physical port tracked across SOP/IOPort
/// duplicates or repeated callbacks counts once. A candidate that fails the
/// IOPort guard (no PortNumber, not USB-C) is never occupied, so it never
/// produces an event and never enters the tracked set.
public final class PortTransitionTracker {

	/// PortNumber -> the occupancy source that fired the last insert for that
	/// port. Presence means the port is currently considered occupied; the value
	/// is the source to attribute the eventual remove to.
	private var occupiedSources: [Int: PortSignalSource] = [:]

	public init() {}

	/// Diff a fresh snapshot against the tracked occupancy and return the
	/// resulting plug/unplug events.
	///
	/// For each port that is occupied now but was not -> an `.inserted` event with
	/// its occupancy source. For each port that was occupied but is absent or idle
	/// now -> a `.removed` event attributed to the source that had been asserting
	/// it. A port that stays occupied (or stays idle) yields nothing, which is what
	/// keeps the live output to one line per physical plug.
	///
	/// Args:
	///   snapshot: the current set of port-controller states.
	///
	/// Returns:
	///   The plug/unplug events implied by the change since the previous call,
	///   inserts before removes, each in ascending PortNumber order for stable,
	///   reproducible test output.
	public func ingest(_ snapshot: [PortState]) -> [PortEvent] {
		// Occupied ports in this snapshot, keyed by PortNumber. A port that fails
		// the IOPort guard is not occupied, so it never appears here -- the guard's
		// emit-only-after-mapping rule holds at the event boundary too.
		var nowOccupied: [Int: PortState] = [:]
		for state in snapshot {
			guard PortLiveness.isOccupied(state), let number = state.portNumber else {
				continue
			}
			// One physical port can be represented by more than one service in a
			// snapshot; keep the first occupied one per PortNumber.
			if nowOccupied[number] == nil {
				nowOccupied[number] = state
			}
		}

		var inserts: [PortEvent] = []
		var removes: [PortEvent] = []

		// Inserts: occupied now, not tracked before.
		for (number, state) in nowOccupied where occupiedSources[number] == nil {
			// occupancySource is non-nil because the port is occupied.
			let source = PortLiveness.occupancySource(state) ?? .connectionActive
			occupiedSources[number] = source
			let event = PortEvent(kind: .inserted, state: state, source: source)
			inserts.append(event)
		}

		// Removes: tracked before, not occupied now.
		for (number, source) in occupiedSources where nowOccupied[number] == nil {
			occupiedSources.removeValue(forKey: number)
			// Synthesize an idle state for the removed port so the event still
			// carries the PortNumber for the rendered line.
			let idleState = PortState(
				registryID: 0,
				serviceClass: "(removed)",
				portNumber: number,
				connectionActive: false,
				accessoryDetect: false,
				transportsActive: [],
				isUSBCPort: true
			)
			let event = PortEvent(kind: .removed, state: idleState, source: source)
			removes.append(event)
		}

		// Stable order: inserts (ascending port) then removes (ascending port).
		inserts.sort { lhs, rhs in (lhs.state.portNumber ?? 0) < (rhs.state.portNumber ?? 0) }
		removes.sort { lhs, rhs in (lhs.state.portNumber ?? 0) < (rhs.state.portNumber ?? 0) }
		let events = inserts + removes
		return events
	}

	/// Forget all tracked occupancy. Used by `stop()` so a fresh watch starts with
	/// no baseline.
	public func reset() {
		occupiedSources.removeAll()
	}
}

//============================================
// MARK: Port-controller watcher (IOKit)
//============================================

/// Watches USB-C port-controller services and emits plug/unplug events from the
/// port's own ConnectionActive bit. The primary, e-marker-independent plug
/// signal.
///
/// Faithful port of whatcable `AppleHPMInterfaceWatcher`: it matches the same
/// port-controller class set plus the IOPort catch-all, drains the initial
/// iterators to arm the match notifications, registers a per-service interest
/// notification (`kIOGeneralInterest`) so a property-only change (a cable plug
/// that flips ConnectionActive without creating or removing a service) still
/// triggers a `refresh()`, prunes stale interest notifications across plug/unplug
/// cycles, and reads each operational key one at a time. The SwiftUI
/// `@Published`/sort layer is replaced by a `PortTransitionTracker` that turns
/// each rebuild into explicit plug/unplug events.
public final class PortWatcher {

	/// Port-controller classes to match. AppleTCControllerType10 is the USB-C port
	/// controller on this M1; the rest are the portable HPM/TC set whatcable
	/// matches across chip generations. IOPort is the shared superclass catch-all,
	/// kept ONLY for class discovery on untested hardware -- the port-liveness
	/// decision refuses to emit from an IOPort candidate that does not map to a
	/// real USB-C PortNumber, per the plan's IOPort guard. Faithful to whatcable
	/// AppleHPMInterfaceWatcher.candidateClasses.
	public static let candidateClasses = [
		"AppleHPMInterfaceType10",
		"AppleHPMInterfaceType11",
		"AppleHPMInterfaceType12",
		"AppleHPMInterfaceType18",
		"AppleTCControllerType10",
		"AppleTCControllerType11",
		"IOPort",
	]

	/// Notification port for matched + interest callbacks. nil until `start`.
	private var notifyPort: IONotificationPortRef?

	/// Every io_iterator_t from IOServiceAddMatchingNotification, held so `stop`
	/// can release each one.
	private var iterators: [io_iterator_t] = []

	/// Per-service interest notifications, keyed by registry entry ID so a port
	/// rediscovered during a refresh is not double-registered. Each value is a
	/// Mach port reference released on prune or `stop`. Faithful to whatcable
	/// AppleHPMInterfaceWatcher.interestNotifications.
	private var interestNotifications: [UInt64: io_object_t] = [:]

	/// Pure occupancy diff. Turns each registry rebuild into plug/unplug events.
	private let tracker = PortTransitionTracker()

	/// Insert callback supplied to `watch`. Retained so the IOKit trampoline can
	/// reach it.
	private var insertHandler: ((PortEvent) -> Void)?

	/// Remove callback supplied to `watch`.
	private var removeHandler: ((PortEvent) -> Void)?

	/// Debug callback supplied to `watch`. When set it is called for EVERY matched
	/// or interest rebuild with the full current snapshot, so the --debug probe can
	/// print the matched backend source (class + the property that produced an
	/// event) even for ports that did not transition.
	private var debugHandler: (([PortState]) -> Void)?

	public init() {}

	//============================================
	// MARK: Snapshot enumeration (testable shape)
	//============================================

	/// Enumerate every currently-attached port-controller service and describe each
	/// as a `PortState`. Uses IOServiceGetMatchingServices + IOIteratorNext over the
	/// candidate classes, reads each service's keys via per-key
	/// IORegistryEntryCreateCFProperty, and releases every io_object_t.
	///
	/// Faithful to whatcable `AppleHPMInterfaceWatcher.refresh`'s registry re-walk,
	/// minus the GUI sort and the `@Published` assignment. Every matched service is
	/// described (including an IOPort catch-all match); the IOPort guard is applied
	/// later by PortLiveness, so the snapshot stays a faithful view of what IOKit
	/// matched.
	///
	/// Returns:
	///   One `PortState` per matched service, deduped by registry entry ID.
	public func currentPorts() -> [PortState] {
		var ports: [PortState] = []
		var seenIDs: Set<UInt64> = []
		for className in Self.candidateClasses {
			var iterator: io_iterator_t = 0
			let matchResult = IOServiceGetMatchingServices(
				kIOMainPortDefault,
				IOServiceMatching(className),
				&iterator
			)
			guard matchResult == KERN_SUCCESS else {
				continue
			}
			while case let service = IOIteratorNext(iterator), service != 0 {
				defer { IOObjectRelease(service) }
				let entryID = Self.registryEntryID(service)
				// IOPort and the named classes can both return the same service;
				// dedup by registry entry ID so one port is described once.
				if seenIDs.contains(entryID) {
					continue
				}
				seenIDs.insert(entryID)
				let liveClass = Self.serviceClassName(service) ?? className
				let serviceName = Self.serviceRegistryName(service)
				let serviceLocation = Self.serviceRegistryLocation(service)
				let state = PortState.from(
					registryID: entryID,
					serviceClass: liveClass,
					serviceName: serviceName,
					serviceLocation: serviceLocation,
					read: Self.makeReader(service)
				)
				ports.append(state)
			}
			IOObjectRelease(iterator)
		}
		return ports
	}

	//============================================
	// MARK: Live watch
	//============================================

	/// Begin watching for port plug (ConnectionActive false->true) and unplug
	/// (true->false) events.
	///
	/// Faithful to whatcable `AppleHPMInterfaceWatcher.start` + `registerInterest`:
	/// a notification port is created on the main queue, a matched notification is
	/// registered per candidate class and its iterator drained to arm it, and a
	/// per-service interest notification (`kIOGeneralInterest`) is registered for
	/// every discovered port so a property-only change still triggers a refresh.
	/// Each refresh rebuilds the snapshot and the tracker emits only the ports that
	/// transitioned -- so a persistent port object whose ConnectionActive flips
	/// (the common case on this Mac, where no service is created or destroyed on
	/// plug) still produces a plug event.
	///
	/// The initial drain establishes the baseline occupancy (ports already
	/// occupied at start), so those do not fire `onInsert`; only later transitions
	/// do. `onDebug`, when supplied, sees every rebuild's full snapshot.
	///
	/// Args:
	///   onInsert: called once per port that becomes occupied after the baseline.
	///   onRemove: called once per port that becomes idle.
	///   onDebug: optional full-snapshot sink for diagnostics; nil to disable.
	public func watch(
		onInsert: @escaping (PortEvent) -> Void,
		onRemove: @escaping (PortEvent) -> Void,
		onDebug: (([PortState]) -> Void)? = nil
	) {
		guard notifyPort == nil else {
			return
		}
		insertHandler = onInsert
		removeHandler = onRemove
		debugHandler = onDebug

		// IONotificationPortCreate returns nil under Mach-port exhaustion. Passing a
		// nil port onward to IONotificationPortSetDispatchQueue is undefined behavior,
		// so fail cleanly: log to stderr and return without arming the watcher.
		guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
			let message = "PortWatcher.watch: IONotificationPortCreate failed (Mach-port exhaustion?); not watching"
			FileHandle.standardError.write(Data((message + "\n").utf8))
			return
		}
		IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
		notifyPort = port

		let selfPtr = Unmanaged.passUnretained(self).toOpaque()

		// Matched callback: a service appeared. Drain (to keep the iterator armed)
		// and then refresh, since the new service may already be occupied.
		let matchedCallback: IOServiceMatchingCallback = { refcon, iterator in
			guard let refcon else { return }
			let watcher = Unmanaged<PortWatcher>.fromOpaque(refcon).takeUnretainedValue()
			watcher.drainMatched(iterator)
		}

		// Arm one matched notification per candidate class. The initial drain
		// registers interest on each existing port and seeds the tracker baseline,
		// suppressing phantom inserts for ports already occupied at start.
		for className in Self.candidateClasses {
			var matchedIter: io_iterator_t = 0
			if IOServiceAddMatchingNotification(
				port,
				kIOMatchedNotification,
				IOServiceMatching(className),
				matchedCallback,
				selfPtr,
				&matchedIter
			) == KERN_SUCCESS {
				drainMatched(matchedIter)
				iterators.append(matchedIter)
			}
		}
		// Seed the tracker baseline so ports already occupied at startup are not
		// reported as inserts; only later transitions fire.
		let baseline = currentPorts()
		_ = tracker.ingest(baseline)
	}

	/// Stop watching and release every IOKit resource: matched iterators, every
	/// per-service interest notification, and the notification port. Resets the
	/// transition tracker. Safe to call when not watching.
	public func stop() {
		for iterator in iterators where iterator != 0 {
			IOObjectRelease(iterator)
		}
		iterators.removeAll()
		for (_, notification) in interestNotifications {
			IOObjectRelease(notification)
		}
		interestNotifications.removeAll()
		if let port = notifyPort {
			IONotificationPortDestroy(port)
			notifyPort = nil
		}
		tracker.reset()
		insertHandler = nil
		removeHandler = nil
		debugHandler = nil
	}

	/// Re-walk the registry, register interest on any new port, prune interest for
	/// vanished ports, diff occupancy, and emit the resulting plug/unplug events.
	///
	/// Faithful to whatcable `AppleHPMInterfaceWatcher.refresh`: build the new list
	/// in a local array, register interest per live port, and prune stale interest
	/// handles for ports no longer present (each handle is a Mach port reference
	/// that must be released, or they leak across plug/unplug cycles). Instead of
	/// assigning a `@Published` array, this feeds the snapshot to the tracker and
	/// dispatches the diff to the insert/remove handlers. Property-only changes
	/// (the common plug on this Mac) reach here via the interest callback.
	public func refresh() {
		let snapshot = rebuildAndRegisterInterest()
		// Debug sees the full snapshot every rebuild, transition or not.
		debugHandler?(snapshot)
		let events = tracker.ingest(snapshot)
		for event in events {
			switch event.kind {
			case .inserted:
				insertHandler?(event)
			case .removed:
				removeHandler?(event)
			}
		}
	}

	//============================================
	// MARK: Notification iterator handlers
	//============================================

	/// Drain a matched-notification iterator (required to keep it armed), then run
	/// a full refresh. A matched service may already be occupied, and registering
	/// its interest notification is what makes the later property-only transition
	/// visible, so a refresh after every drain is the faithful behavior.
	private func drainMatched(_ iterator: io_iterator_t) {
		// Drain and release every service the iterator yields so it stays armed.
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			let entryID = Self.registryEntryID(service)
			registerInterest(for: service, entryID: entryID)
		}
		refresh()
	}

	/// Subscribe to property/state changes on a port-controller service via
	/// IOServiceAddInterestNotification with kIOGeneralInterest.
	///
	/// Faithful to whatcable `AppleHPMInterfaceWatcher.registerInterest`: the
	/// kernel fires a property-change message when a cable is plugged or unplugged,
	/// so this gives a timely refresh trigger that does not depend on a service
	/// being created or destroyed (on this Mac, ConnectionActive flips on a
	/// persistent port object, with no match/terminate event). Keyed by registry
	/// entry ID so a port rediscovered during a refresh is not double-registered.
	private func registerInterest(for service: io_service_t, entryID: UInt64) {
		guard let notifyPort, interestNotifications[entryID] == nil else {
			return
		}
		let selfPtr = Unmanaged.passUnretained(self).toOpaque()
		let callback: IOServiceInterestCallback = { refcon, _, _, _ in
			guard let refcon else { return }
			let watcher = Unmanaged<PortWatcher>.fromOpaque(refcon).takeUnretainedValue()
			watcher.refresh()
		}
		var notification: io_object_t = 0
		let result = IOServiceAddInterestNotification(
			notifyPort,
			service,
			kIOGeneralInterest,
			callback,
			selfPtr,
			&notification
		)
		if result == KERN_SUCCESS {
			interestNotifications[entryID] = notification
		}
	}

	/// Re-walk the candidate classes, describe each live port, register interest on
	/// any newly-seen port, and prune interest handles for ports that are gone.
	/// Returns the fresh snapshot for the tracker.
	private func rebuildAndRegisterInterest() -> [PortState] {
		var rebuilt: [PortState] = []
		var seenIDs: Set<UInt64> = []
		var liveEntryIDs: Set<UInt64> = []
		for className in Self.candidateClasses {
			var iterator: io_iterator_t = 0
			let matchResult = IOServiceGetMatchingServices(
				kIOMainPortDefault,
				IOServiceMatching(className),
				&iterator
			)
			guard matchResult == KERN_SUCCESS else {
				continue
			}
			while case let service = IOIteratorNext(iterator), service != 0 {
				defer { IOObjectRelease(service) }
				let entryID = Self.registryEntryID(service)
				if seenIDs.contains(entryID) {
					continue
				}
				seenIDs.insert(entryID)
				liveEntryIDs.insert(entryID)
				let liveClass = Self.serviceClassName(service) ?? className
				let serviceName = Self.serviceRegistryName(service)
				let serviceLocation = Self.serviceRegistryLocation(service)
				let state = PortState.from(
					registryID: entryID,
					serviceClass: liveClass,
					serviceName: serviceName,
					serviceLocation: serviceLocation,
					read: Self.makeReader(service)
				)
				rebuilt.append(state)
				// Register interest so this port's property-only transitions fire.
				registerInterest(for: service, entryID: entryID)
			}
			IOObjectRelease(iterator)
		}
		// Prune interest for ports no longer in the registry; each handle is a Mach
		// port reference and must be released or it leaks. Faithful to whatcable's
		// prune loop in refresh().
		for entryID in interestNotifications.keys where !liveEntryIDs.contains(entryID) {
			if let notification = interestNotifications.removeValue(forKey: entryID) {
				IOObjectRelease(notification)
			}
		}
		return rebuilt
	}

	//============================================
	// MARK: IOKit reading helpers
	//============================================

	/// Build a per-key property-read closure backed by a live IOKit service. Each
	/// call reads ONE key via IORegistryEntryCreateCFProperty -- the crash-safe
	/// path whatcable uses instead of the bulk property-dictionary fetch.
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

	/// Stable identity for a service across class-match duplicates and repeated
	/// callbacks: the registry entry ID.
	private static func registryEntryID(_ service: io_service_t) -> UInt64 {
		var entryID: UInt64 = 0
		IORegistryEntryGetRegistryEntryID(service, &entryID)
		return entryID
	}

	/// Read the IOKit class name of a service via IOObjectGetClass.
	private static func serviceClassName(_ service: io_service_t) -> String? {
		let nameRef = UnsafeMutablePointer<io_name_t>.allocate(capacity: 1)
		defer { nameRef.deallocate() }
		let result = nameRef.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<io_name_t>.size) {
			buffer -> kern_return_t in
			return IOObjectGetClass(service, buffer)
		}
		guard result == KERN_SUCCESS else {
			return nil
		}
		let name = nameRef.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<io_name_t>.size) {
			buffer -> String in
			return String(cString: buffer)
		}
		return name
	}

	/// Read the registry entry NAME (e.g. "Port-USB-C") via IORegistryEntryGetName,
	/// used by the real-port gate. The "@N" location suffix is read separately by
	/// `serviceRegistryLocation` and supplied to the PortNumber fallback.
	private static func serviceRegistryName(_ service: io_service_t) -> String {
		var nameBuf = [CChar](repeating: 0, count: 128)
		guard IORegistryEntryGetName(service, &nameBuf) == KERN_SUCCESS else {
			return ""
		}
		let name = String(cString: nameBuf)
		return name
	}

	/// Read the registry entry LOCATION in the IOService plane (e.g. "1") via
	/// IORegistryEntryGetLocationInPlane -- the "@N" suffix macOS assigns the port
	/// controller. Mirrors whatcable's location-based port identity; supplied to the
	/// PortNumber fallback so a controller with no `PortNumber` key still resolves a
	/// number. Empty when the service has no location in the plane.
	private static func serviceRegistryLocation(_ service: io_service_t) -> String {
		var locationBuf = [CChar](repeating: 0, count: 128)
		let result = locationBuf.withUnsafeMutableBufferPointer {
			buffer -> kern_return_t in
			// baseAddress is nil only for an empty buffer; locationBuf is fixed at 128
			// bytes, so this is defensive. Fail cleanly with the function's empty-string
			// convention rather than force-unwrapping and crashing.
			guard let ptr = buffer.baseAddress else {
				return KERN_FAILURE
			}
			return IORegistryEntryGetLocationInPlane(service, kIOServicePlane, ptr)
		}
		guard result == KERN_SUCCESS else {
			return ""
		}
		let location = String(cString: locationBuf)
		return location
	}
}

//============================================
// MARK: Port property coercion helpers
//============================================
//
// Adapted from whatcable AppleHPMInterface.from boolean/array coercions
// ((read(key) as? NSNumber)?.boolValue, stringArrayProperty). IOKit bridges
// integer/boolean properties to NSNumber and arrays to NSArray; these coerce
// without masking absent data: an absent key yields nil (boolean/int) or an empty
// array, which the liveness decision treats as "not occupied" rather than a
// silent default true.

/// Coerce an IOKit Any? value into a Bool. NSNumber is the IOKit bridge; a plain
/// Bool/Int can arrive in synthetic test snapshots. Absent or non-numeric yields
/// nil, NOT false, so the liveness decision can tell "key absent" from
/// "key present and false".
///
/// Args:
///   value: the bridged NSNumber / Bool / Int property value, or nil.
///
/// Returns:
///   The boolean value, or nil when absent or non-coercible.
func coercePortBool(_ value: Any?) -> Bool? {
	// NSNumber covers the common CFBoolean/CFNumber bridge from IOKit.
	if let number = value as? NSNumber {
		return number.boolValue
	}
	// A plain Swift Bool can arrive from synthetic test dictionaries.
	if let boolValue = value as? Bool {
		return boolValue
	}
	// A plain Int (0/1) can also arrive in test dictionaries.
	if let intValue = value as? Int {
		return intValue != 0
	}
	return nil
}

/// Coerce an IOKit Any? value into an Int (e.g. PortNumber). Absent or
/// non-numeric yields nil so a missing PortNumber stays nil (the IOPort guard
/// keys off that), not a falsely-correlating 0.
///
/// Args:
///   value: the bridged NSNumber / Int property value, or nil.
///
/// Returns:
///   The integer value, or nil when absent or non-coercible.
func coercePortInt(_ value: Any?) -> Int? {
	if let number = value as? NSNumber {
		return number.intValue
	}
	if let intValue = value as? Int {
		return intValue
	}
	return nil
}

/// Coerce an IOKit Any? value into a [String] (e.g. TransportsActive). Faithful
/// to whatcable stringArrayProperty: a non-array or absent value yields an empty
/// array, which reads as "no active transports".
///
/// Args:
///   value: the bridged CFArray / NSArray of strings, or nil.
///
/// Returns:
///   The string entries, or an empty array when absent or not an array.
func coercePortStringArray(_ value: Any?) -> [String] {
	if let array = value as? [Any] {
		let strings = array.compactMap { $0 as? String }
		return strings
	}
	if let nsArray = value as? NSArray {
		let strings = nsArray.compactMap { $0 as? String }
		return strings
	}
	return []
}
