// Probe.swift -- IOKit source layer that produces CableInfo from real
// USB-PD SOP' cable e-marker services, plus live plug/unplug watching and
// per-port PD-identity correlation by SOP ParentPortNumber.
//
// Adapted from whatcable Sources/WhatCableDarwinBackend/Watchers/VDMIdentityWatcher.swift:
//   VDMIdentityWatcher.start / stop (IOServiceAddMatchingNotification, matched +
//     terminated notification ports attached to a dispatch queue)
//   VDMIdentityWatcher.refresh (IOServiceGetMatchingServices + IOIteratorNext snapshot)
//   VDMIdentityWatcher.makeUpdate / parseUpdate (Metadata dict -> VDOs array of Data)
//   VDMIdentityWatcher.endpoint(for:) (IOObjectGetClass class discrimination)
// and from whatcable Sources/WhatCableDarwinBackend/Watchers/USBPDSOPWatcher.swift:
//   USBPDSOPWatcher.matchedClasses (SOP / SOP' / SOP'' class set)
//   USBPDSOPWatcher.endpoint(read:className:) (class-name -> SOP endpoint)
//   USBPDSOPWatcher.parentPortIdentity(read:) (ParentBuiltInPortNumber priority)
//   USBPDSOP.Endpoint (sop / sopPrime / sopDoublePrime classification)
//   USBPDSOP.cableVDO (SOP'/SOP'' carry the Cable VDO; SOP partner is not the
//     cable e-marker source for the headline rating)
// and the property-read closure helpers from
//   Sources/WhatCableDarwinBackend/Support/IOKitHelpers.swift:
//   wcDictionary, wcArray, wcData (Any? coercion for IOKit CFType values)
// MIT license, Darryl Morley 2026.
//
// This file narrows whatcable's general SOP/SOP' identity watcher down to the
// cable e-marker case: it cares about the SOP' Cable VDO (VDO[3]) and the
// ID Header VDO (VDO[0]), emits the pure CableInfo value type decoded by
// EMarker, and exposes each matched service's SOP endpoint and ParentPortNumber
// so PD identity can be correlated to a physical USB-C port. The DB/catalog,
// rating, render, and CLI layers are intentionally not touched here.

import Foundation
import IOKit

//============================================
// MARK: SOP endpoint classification
//============================================

/// Which USB-PD endpoint a matched service speaks for.
///
/// macOS exposes SOP, SOP', and SOP'' as three separate IOKit classes, so the
/// endpoint is derived from the live class name. Adapted from whatcable
/// Sources/WhatCableCore/USB/USBPDSOP.swift `USBPDSOP.Endpoint` and
/// Sources/WhatCableDarwinBackend/Watchers/USBPDSOPWatcher.swift
/// `endpoint(read:className:)`. MIT license, Darryl Morley 2026.
///
/// Rating note (mirrors whatcable `USBPDSOP.cableVDO`): the cable's headline
/// rating comes from the near-end cable e-marker SOP'. SOP'' is the far-end
/// e-marker and must not overwrite the headline identity; SOP is the port
/// partner (the connected device/charger), not the cable itself.
public enum SOPEndpoint: String, Equatable {
	/// Port partner: the connected device or charger, not the cable e-marker.
	case sop = "SOP"
	/// Near-end cable e-marker (SOP'). The source of the cable headline rating.
	case sopPrime = "SOP'"
	/// Far-end cable e-marker (SOP''). Enrichment only; never the headline.
	case sopDoublePrime = "SOP''"
	/// Class name did not match any known SOP endpoint class.
	case unknown

	/// Classify an IOKit class name into an SOP endpoint.
	///
	/// Mirrors whatcable's class-name switch in `endpoint(read:className:)`.
	///
	/// Args:
	///   className: the IOKit class name of the matched service, or nil.
	///
	/// Returns:
	///   The matching SOPEndpoint; `.unknown` when the class is unrecognized.
	public static func fromClassName(_ className: String?) -> SOPEndpoint {
		switch className {
		case "IOPortTransportComponentCCUSBPDSOP":
			return .sop
		case "IOPortTransportComponentCCUSBPDSOPp":
			return .sopPrime
		case "IOPortTransportComponentCCUSBPDSOPpp":
			return .sopDoublePrime
		default:
			return .unknown
		}
	}
}

//============================================
// MARK: Detected service value type
//============================================

/// One matched IOKit cable e-marker service, whether or not it decoded into a
/// full `CableInfo`.
///
/// This is the unit the watch and snapshot layers now emit. The original design
/// only surfaced services that `parseCableInfo` decoded successfully, which
/// dropped real plug events for cables whose SOP service answers with an empty
/// or absent `Metadata` dictionary (the common non-e-marked cable on this Mac).
/// `DetectedCable` keeps the matched service visible: `info` is nil when the
/// e-marker could not be decoded, but `serviceClass` and `registryID` always
/// identify the service so the caller can still render a numbered UNKNOWN line
/// and the debug path can report exactly what IOKit delivered.
public struct DetectedCable: Equatable {
	/// The decoded e-marker, or nil when this matched service had no usable
	/// Metadata/VDOs. A nil `info` rates as UNKNOWN/no-emarker downstream.
	public let info: CableInfo?
	/// The IOKit class name of the matched service (e.g.
	/// `IOPortTransportComponentCCUSBPDSOP`). Always present; used for diagnostics.
	public let serviceClass: String
	/// The IOKit registry entry ID, stable per service. Used for dedup across
	/// SOP/SOP' duplicates and repeated callbacks, and printed in debug output.
	public let registryID: UInt64
	/// Number of VDO Data blobs the service exposed in its Metadata. 0 when the
	/// Metadata was empty or absent. Diagnostic only.
	public let vdoCount: Int
	/// Number of keys present in the service's Metadata dictionary. 0 when the
	/// Metadata was empty or absent. Diagnostic only -- an empty-Metadata service
	/// is exactly the silent-plug case this surfaces.
	public let metadataKeyCount: Int
	/// Which USB-PD endpoint this service speaks for, derived from its IOKit class
	/// name. SOP' is the near-end cable e-marker (the headline rating source);
	/// SOP'' is the far-end e-marker; SOP is the port partner. Used to keep SOP''
	/// from overwriting the SOP' headline during per-port correlation.
	public let endpoint: SOPEndpoint
	/// The physical USB-C port number this SOP node hangs off, read from the
	/// service's `ParentBuiltInPortNumber` (preferred) or `ParentPortNumber`. This
	/// is the join key that correlates PD identity to a port controller's
	/// `PortNumber`. `Self.unknownPortNumber` (-1) when neither key was present.
	public let parentPortNumber: Int
	/// The physical USB-C port type for this SOP node, from
	/// `ParentBuiltInPortType` (preferred) or `ParentPortType`. 0 when absent.
	/// Carried alongside the number for parity with whatcable's portKey; not used
	/// for correlation here, which keys on the port number alone.
	public let parentPortType: Int

	/// Sentinel for "no ParentPortNumber was readable on this service". A real SOP
	/// node always carries a port number; this value marks a synthetic or absent
	/// one so correlation can skip it instead of matching port 0 by accident.
	public static let unknownPortNumber = -1

	/// The whatcable-style port join key "<parentPortType>/<parentPortNumber>".
	///
	/// This is the active correlation key on M1 hardware (no HPM controller UUID
	/// is exposed there). Adapted from whatcable
	/// Sources/WhatCableCore/USB/USBPDSOP.swift `USBPDSOP.portKey`
	/// (`"\(parentPortType)/\(parentPortNumber)"`). The coordinator joins SOP
	/// identity to a port controller by matching this against the controller's own
	/// type/number portKey, so PD identity and port-state resolve to one physical
	/// port. MIT license, Darryl Morley 2026.
	public var portKey: String {
		let key = "\(parentPortType)/\(parentPortNumber)"
		return key
	}

	public init(
		info: CableInfo?,
		serviceClass: String,
		registryID: UInt64,
		vdoCount: Int,
		metadataKeyCount: Int,
		endpoint: SOPEndpoint = .unknown,
		parentPortNumber: Int = DetectedCable.unknownPortNumber,
		parentPortType: Int = 0
	) {
		self.info = info
		self.serviceClass = serviceClass
		self.registryID = registryID
		self.vdoCount = vdoCount
		self.metadataKeyCount = metadataKeyCount
		self.endpoint = endpoint
		self.parentPortNumber = parentPortNumber
		self.parentPortType = parentPortType
	}
}

//============================================
// MARK: Per-port PD identity result
//============================================

/// The PD-identity outcome for one physical USB-C port, correlated from the SOP
/// services whose `ParentPortNumber` matches that port.
///
/// This is the clean per-port decode the `PlugCoordinator` (a later work
/// package) consumes: it merges this PD identity with the port-state detection
/// into one verdict per port. Distinguishing "no SOP node at all for this port"
/// from "an SOP node is present but its e-marker is unreadable (empty Metadata)"
/// matters: the latter is the visible-but-no-e-marker cable that rates
/// `Unknown [port active]` rather than vanishing.
public struct PortPDIdentity: Equatable {
	/// The whatcable-style port join key "<parentPortType>/<parentPortNumber>"
	/// this identity was correlated on. The coordinator matches this against the
	/// port controller's own type/number portKey.
	public let portKey: String
	/// The physical USB-C port number this identity describes (the number half of
	/// the portKey). Convenience for callers that key on the number alone.
	public let portNumber: Int
	/// The decoded near-end (SOP') cable e-marker for this port, or nil when no
	/// readable e-marker was present. nil rates as UNKNOWN/no-emarker downstream.
	public let info: CableInfo?
	/// True when at least one SOP / SOP' / SOP'' service was found for this port,
	/// even one with empty Metadata. Separates "port has an SOP node but no
	/// readable e-marker" (`true`, `info == nil`) from "no SOP node for this port"
	/// (`false`, `info == nil`).
	public let sopServicePresent: Bool

	/// True when an SOP node exists for this port but no readable e-marker decoded.
	/// This is the "detected, no readable e-marker" signal the coordinator turns
	/// into `Unknown [port active]`. Computed from the two stored fields so it
	/// cannot drift from them.
	public var hasReadableEMarker: Bool {
		return info != nil
	}

	public init(
		portKey: String,
		portNumber: Int,
		info: CableInfo?,
		sopServicePresent: Bool
	) {
		self.portKey = portKey
		self.portNumber = portNumber
		self.info = info
		self.sopServicePresent = sopServicePresent
	}
}

//============================================
// MARK: IOKit cable source
//============================================

/// Reads plugged-in USB-C cable e-markers over IOKit and reports each as a
/// pure `CableInfo`. A bare cable's only software-readable speed is its USB-PD
/// SOP' e-marker, exposed via the IOKit class `IOPortTransportComponentCCUSBPDSOPp`.
///
/// The decode itself is a pure static function (`parseCableInfo(read:)`) so it
/// is fully unit-testable without hardware. The instance methods wrap that pure
/// function with real IOKit enumeration and notification plumbing.
public final class IOKitCableSource {

	/// IOKit class for the SOP' (cable plug) e-marker. This is the cable's own
	/// e-marker chip and the canonical source of cable speed/current.
	static let sopPrimeClass = "IOPortTransportComponentCCUSBPDSOPp"

	/// IOKit class for the non-prime SOP (partner) endpoint. A cable plugged in
	/// on its own can answer at SOP instead of SOP', declaring its cable
	/// identity there, so it is matched too and filtered by ID Header product
	/// type during decode. SOP is also where the port-side node (empty Metadata,
	/// no e-marker) appears for a visible cable with no readable e-marker.
	static let sopClass = "IOPortTransportComponentCCUSBPDSOP"

	/// IOKit class for the SOP'' (far-end cable plug) e-marker. Some hardware
	/// exposes a third class for the far-side e-marker. It is matched so the
	/// per-port correlation sees every SOP node, but it never overwrites the
	/// SOP' headline rating (mirrors whatcable `USBPDSOP.cableVDO`, which reads
	/// SOP'/SOP'' but keeps SOP' as the near-end source).
	static let sopDoublePrimeClass = "IOPortTransportComponentCCUSBPDSOPpp"

	/// Every class the watcher matches. Mirrors whatcable
	/// `USBPDSOPWatcher.matchedClasses` (SOP, SOP', SOP''). SOP' is listed first
	/// because it is the primary cable e-marker path for the headline rating.
	static let matchedClasses = [sopPrimeClass, sopClass, sopDoublePrimeClass]

	/// Notification port for live matched/terminated callbacks. nil until
	/// `watch` is called and back to nil after `stop`.
	private var notifyPort: IONotificationPortRef?

	/// Every io_iterator_t handed back by IOServiceAddMatchingNotification.
	/// Held so `stop` can release each one (IOObjectRelease).
	private var iterators: [io_iterator_t] = []

	/// Registry entry IDs already reported as inserted, used to collapse the
	/// duplicate matched callbacks one physical plug produces (the initial
	/// drain plus the live notification). Cleared on terminate so a replug of
	/// the same service reports again.
	private var seenServiceIDs: Set<UInt64> = []

	/// Registry entry IDs that already existed when `watch` armed. These are the
	/// host-side ports/cables present at startup; emitting them would print a
	/// phantom "cable" line with nothing newly plugged in (a persistent host-port
	/// SOP service is always present on this Mac). They are recorded during the
	/// initial arming drain and suppressed from `onInsert`, so only services that
	/// appear AFTER arming are reported. Pre-existing cables are covered by
	/// `--once`, which snapshots without a baseline.
	private var baselineServiceIDs: Set<UInt64> = []

	/// True only while the initial arming drain runs (inside `watch`). During
	/// this window a matched service is recorded in `baselineServiceIDs` and NOT
	/// emitted to `onInsert`; afterward, matched services are real plug events.
	private var arming: Bool = false

	/// Insert callback supplied to `watch`. Retained so the IOKit callback
	/// trampoline can reach it. Emits for EVERY new matched service (info may be
	/// nil), not only successfully-decoded ones.
	private var insertHandler: ((DetectedCable) -> Void)?

	/// Remove callback supplied to `watch`. Emits for any previously-emitted
	/// service that terminates.
	private var removeHandler: ((DetectedCable) -> Void)?

	/// Debug callback supplied to `watch`. When set, it is called for EVERY IOKit
	/// event the watch sees -- including baseline/pre-existing matched services
	/// and every terminate -- so the user can confirm on real hardware whether a
	/// non-e-marked plug fires any matched callback at all. The Bool argument is
	/// true for matched events and false for terminated events.
	private var debugHandler: ((DetectedCable, Bool) -> Void)?

	public init() {}

	//============================================
	// MARK: Pure parse (testable, no hardware)
	//============================================

	/// Decode a `CableInfo` from a property-read closure.
	///
	/// The closure shape mirrors whatcable's `VDMIdentityWatcher.parseUpdate(read:)`:
	/// callers pass a function that returns the IOKit property for a given key,
	/// so tests can drive the parser with synthetic dictionaries and production
	/// code can pass a closure backed by `IORegistryEntryCreateCFProperty`.
	///
	/// The `Metadata` dictionary carries a `VDOs` array of 4-byte little-endian
	/// `Data` blobs. VDO[0] is the ID Header VDO (product type, vendor ID) and
	/// VDO[3] is the Cable VDO (speed bits 2..0, current bits 6..5). Both are fed
	/// to the existing `EMarker.decode`, which preserves the raw Cable VDO word on
	/// the returned `CableInfo` as `rawCableVDO` (the catalog's primary DB key).
	///
	/// The USB Product ID is not a VDO field; it lives in the Metadata `PID` key.
	/// It is read here (coerced to UInt16, 0 when absent) and set on the returned
	/// `CableInfo` so the rating layer can use VID/PID as the catalog's secondary
	/// DB key. Both keys make the live path reach the known-cable database for a
	/// zeroed/sparse real cable instead of always rating UNKNOWN*.
	///
	/// Args:
	///   read: closure mapping an IOKit property key to its value, or nil.
	///
	/// Returns:
	///   A decoded `CableInfo`, or nil when no `Metadata`/`VDOs` are present or
	///   the ID Header VDO (VDO[0]) cannot be read. A present-but-zeroed Cable
	///   VDO decodes to the usb2 / usbDefault buckets rather than failing.
	public static func parseCableInfo(read: (String) -> Any?) -> CableInfo? {
		// Metadata must be a dictionary; absence means this is not a decodable
		// e-marker service, so return nil (fail loud at the call site, not a
		// silent default cable).
		guard let metadataRaw = read("Metadata") else {
			return nil
		}
		let metadata = coerceDictionary(metadataRaw)
		// The VDOs array holds the e-marker response objects as Data blobs.
		let vdoDataList = coerceArray(metadata["VDOs"]).compactMap(coerceData)
		// The ID Header VDO (index 0) is mandatory: without it there is no
		// vendor ID or product type, so this is not a usable cable record.
		guard vdoDataList.count > 0,
			let idHeaderVDO = vdoUInt32(vdoDataList[0]) else {
			return nil
		}
		// The Cable VDO (index 3) carries speed and current. A sparse e-marker
		// may stop short of index 3; treat a missing Cable VDO as all-zero,
		// which decodes to the usb2 / usbDefault buckets via EMarker.
		var cableVDO: UInt32 = 0
		if vdoDataList.count > 3,
			let decoded = vdoUInt32(vdoDataList[3]) {
			cableVDO = decoded
		}
		// EMarker.decode preserves the raw Cable VDO word on the CableInfo as
		// rawCableVDO; productID is left 0 there because it is not a VDO field.
		let decoded = EMarker.decode(cableVDO: cableVDO, idHeaderVDO: idHeaderVDO)
		// PID comes only from IOKit Metadata, not the VDOs. Coerce it to UInt16
		// (0 when absent), the same way whatcable reads the PID metadata value.
		let productID = coerceUInt16(metadata["PID"])
		// Rebuild the CableInfo with the Metadata-sourced product ID attached so
		// the live VID/PID DB key is reachable. All EMarker-decoded fields and
		// the raw Cable VDO word are carried through unchanged.
		let info = CableInfo(
			speedTier: decoded.speedTier,
			productType: decoded.productType,
			current: decoded.current,
			vendorID: decoded.vendorID,
			rawCableVDO: decoded.rawCableVDO,
			productID: productID
		)
		return info
	}

	/// Describe one matched service as a `DetectedCable`, decoding its e-marker
	/// when possible and always recording the diagnostic counts.
	///
	/// This is the pure, hardware-free core shared by the snapshot and watch
	/// paths: it runs `parseCableInfo` (which yields nil for an empty/absent
	/// Metadata service) and, independently, counts the Metadata keys and VDO
	/// blobs so the debug path can show that a silent plug delivered, for example,
	/// `metadataKeys=0 vdos=0 decoded=nil`. A service that fails to decode is NOT
	/// dropped -- it becomes a `DetectedCable` with `info = nil`, which rates as
	/// UNKNOWN/no-emarker downstream.
	///
	/// Args:
	///   serviceClass: the IOKit class name of the matched service.
	///   registryID: the service's IOKit registry entry ID.
	///   read: closure mapping an IOKit property key to its value, or nil.
	///
	/// Returns:
	///   A `DetectedCable` for the service (info may be nil).
	static func describeService(
		serviceClass: String,
		registryID: UInt64,
		read: (String) -> Any?
	) -> DetectedCable {
		// Decode the e-marker; nil when Metadata/VDOs are absent or unusable.
		let info = parseCableInfo(read: read)
		// Independently count the raw shape for diagnostics. An absent Metadata
		// dictionary yields zero keys and zero VDOs -- the silent-plug signature.
		let metadata = coerceDictionary(read("Metadata"))
		let metadataKeyCount = metadata.count
		let vdoCount = coerceArray(metadata["VDOs"]).compactMap(coerceData).count
		// Classify the SOP endpoint from the live class name so SOP'' never takes
		// the SOP' headline during per-port correlation.
		let endpoint = SOPEndpoint.fromClassName(serviceClass)
		// Read the physical port this SOP node hangs off so identity correlates to
		// a port controller's PortNumber.
		let parent = parentPortIdentity(read: read)
		let detected = DetectedCable(
			info: info,
			serviceClass: serviceClass,
			registryID: registryID,
			vdoCount: vdoCount,
			metadataKeyCount: metadataKeyCount,
			endpoint: endpoint,
			parentPortNumber: parent.number,
			parentPortType: parent.type
		)
		return detected
	}

	//============================================
	// MARK: Parent port correlation read
	//============================================

	/// Read the physical port type and number a SOP node hangs off.
	///
	/// Adapted from whatcable
	/// Sources/WhatCableDarwinBackend/Watchers/USBPDSOPWatcher.swift
	/// `parentPortIdentity(read:)`. The BuiltIn keys take priority so PD identity
	/// and port-state data resolve to the same physical port for a given port.
	/// The captured SOP node (/tmp/sop_node.plist) carries both
	/// `ParentBuiltInPortNumber` and `ParentPortNumber` == 3 with type 2 (USB-C).
	///
	/// Args:
	///   read: closure mapping an IOKit property key to its value, or nil.
	///
	/// Returns:
	///   A (type, number) pair. `number` is `DetectedCable.unknownPortNumber`
	///   (-1) when neither port-number key is present, so correlation skips a
	///   service with no readable port rather than matching port 0 by accident.
	static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
		// Port type: BuiltIn key first, then the plain key, else 0.
		let type = coerceInt(read("ParentBuiltInPortType"))
			?? coerceInt(read("ParentPortType"))
			?? 0
		// Port number: BuiltIn key first, then the plain key. Absent on both ->
		// the unknown sentinel, never a real port number.
		let number = coerceInt(read("ParentBuiltInPortNumber"))
			?? coerceInt(read("ParentPortNumber"))
			?? DetectedCable.unknownPortNumber
		return (type, number)
	}

	//============================================
	// MARK: Per-port PD identity correlation
	//============================================

	/// Build the whatcable-style port join key from a port type and number.
	///
	/// Mirrors whatcable `USBPDSOP.portKey` (`"\(parentPortType)/\(parentPortNumber)"`).
	/// The coordinator uses the same shape for the port controller's PortType +
	/// PortNumber so PD identity and port-state join on one key.
	///
	/// Args:
	///   portType: the physical USB-C port type (2 == USB-C on this hardware).
	///   portNumber: the physical USB-C port number.
	///
	/// Returns:
	///   The "type/number" port key string.
	public static func portKey(forPortType portType: Int, portNumber: Int) -> String {
		let key = "\(portType)/\(portNumber)"
		return key
	}

	/// Correlate a set of detected SOP services to one physical port (by its
	/// whatcable-style "type/number" portKey) and produce that port's PD identity,
	/// choosing the near-end (SOP') e-marker for the headline.
	///
	/// This is the pure, hardware-free core of the per-port decode API the
	/// coordinator will call. Given every detected SOP service and a target
	/// portKey, it:
	///   - keeps only services whose `portKey` matches the target,
	///   - reports whether ANY SOP node was present for that port (so an
	///     empty-Metadata SOP node reads as "detected, no readable e-marker"
	///     rather than "no port"),
	///   - selects the cable headline e-marker with SOP' priority, never letting
	///     SOP'' overwrite an SOP' headline. Confirmed against whatcable
	///     `USBPDSOP.cableVDO` (USBPDSOP.swift:93-99): SOP' (near plug) and SOP''
	///     (far plug) decode the SAME cable VDO -- one cable identity per port --
	///     so SOP' is the headline and SOP'' is a fallback only. The SOP
	///     (non-prime) partner node is the connected device/charger
	///     (USBPDSOP.swift:6-10), distinct from the cable, so it is never the
	///     cable e-marker source.
	///
	/// Args:
	///   portKey: the whatcable-style "type/number" join key for the target port.
	///   detected: every detected SOP service from a snapshot or watch event.
	///
	/// Returns:
	///   A `PortPDIdentity`: `info` is the decoded SOP' (or SOP'' fallback)
	///   e-marker or nil; `sopServicePresent` is true when any SOP node matched
	///   the portKey, even one with empty Metadata.
	public static func decodePort(
		forPortKey portKey: String,
		from detected: [DetectedCable]
	) -> PortPDIdentity {
		// Keep only the SOP nodes whose "type/number" portKey matches the target.
		let forPort = detected.filter { $0.portKey == portKey }
		// Any matching SOP node -- even an empty-Metadata one -- means a cable is
		// present at this port. This is the "detected, no readable e-marker" case.
		let sopServicePresent = !forPort.isEmpty
		// Prefer the near-end SOP' e-marker as the cable headline.
		let sopPrimeInfo = forPort.first {
			$0.endpoint == .sopPrime && $0.info != nil
		}?.info
		// SOP'' is far-end enrichment: SOP' and SOP'' carry the same cable VDO, so
		// SOP'' is used only when no SOP' e-marker decoded and never overwrites the
		// SOP' headline identity.
		let sopDoublePrimeInfo = forPort.first {
			$0.endpoint == .sopDoublePrime && $0.info != nil
		}?.info
		// Headline rating source: SOP' first, then SOP'' fallback. The SOP partner
		// node is intentionally not used as the cable e-marker source.
		let headlineInfo = sopPrimeInfo ?? sopDoublePrimeInfo
		// Recover the port number from any matched node (they share the portKey);
		// fall back to parsing the key's number half when no node matched.
		let portNumber = forPort.first?.parentPortNumber
			?? portNumberFromKey(portKey)
		let identity = PortPDIdentity(
			portKey: portKey,
			portNumber: portNumber,
			info: headlineInfo,
			sopServicePresent: sopServicePresent
		)
		return identity
	}

	/// Convenience correlation by port type + number; builds the portKey and
	/// delegates to `decodePort(forPortKey:from:)`.
	///
	/// Args:
	///   portType: the physical USB-C port type (2 == USB-C on this hardware).
	///   portNumber: the physical USB-C port number.
	///   detected: every detected SOP service from a snapshot or watch event.
	///
	/// Returns:
	///   The `PortPDIdentity` for that port.
	public static func decodePort(
		forPortType portType: Int,
		portNumber: Int,
		from detected: [DetectedCable]
	) -> PortPDIdentity {
		let key = portKey(forPortType: portType, portNumber: portNumber)
		let identity = decodePort(forPortKey: key, from: detected)
		return identity
	}

	/// Parse the number half out of a "type/number" portKey, for the no-match
	/// case where no detected node supplied a port number directly.
	///
	/// Args:
	///   portKey: a "type/number" key string.
	///
	/// Returns:
	///   The number after the slash, or `DetectedCable.unknownPortNumber` when the
	///   key has no parseable number half.
	static func portNumberFromKey(_ portKey: String) -> Int {
		let parts = portKey.split(separator: "/", maxSplits: 1)
		guard parts.count == 2, let number = Int(parts[1]) else {
			return DetectedCable.unknownPortNumber
		}
		return number
	}

	//============================================
	// MARK: Snapshot enumeration
	//============================================

	/// Enumerate every currently-attached cable e-marker service and describe each
	/// as a `DetectedCable`. Uses `IOServiceGetMatchingServices` + `IOIteratorNext`,
	/// reading each service's properties via `IORegistryEntryCreateCFProperty`,
	/// and releases every io_object_t (each service plus each iterator).
	///
	/// Unlike the old design, a service whose e-marker cannot be decoded is still
	/// included with `info = nil` instead of being dropped, so a plugged-in
	/// non-e-marked cable shows up as an UNKNOWN entry rather than silently
	/// vanishing.
	///
	/// Returns:
	///   One `DetectedCable` per matched service (info may be nil). May be empty
	///   only when no matching service exists at all.
	public func currentCables() -> [DetectedCable] {
		var cables: [DetectedCable] = []
		var seenIDs: Set<UInt64> = []
		for className in Self.matchedClasses {
			var iterator: io_iterator_t = 0
			let matchResult = IOServiceGetMatchingServices(
				kIOMainPortDefault,
				IOServiceMatching(className),
				&iterator
			)
			// A failed match leaves nothing to release for this class.
			guard matchResult == KERN_SUCCESS else {
				continue
			}
			// Drain the iterator; IOIteratorNext returns 0 when exhausted.
			while case let service = IOIteratorNext(iterator), service != 0 {
				// Always release the service, even if decode fails or is a dup.
				defer { IOObjectRelease(service) }
				let entryID = Self.registryEntryID(service)
				// A cable can answer at both SOP and SOP'; dedup by registry
				// entry ID so one physical service is reported once.
				if seenIDs.contains(entryID) {
					continue
				}
				seenIDs.insert(entryID)
				// Use the live IOKit class string for accuracy (an SOP' service
				// can be matched by either class query); fall back to the query
				// class name only if the live read is empty.
				let liveClass = Self.serviceClassName(service) ?? className
				let detected = Self.describeService(
					serviceClass: liveClass,
					registryID: entryID,
					read: Self.makeReader(service)
				)
				cables.append(detected)
			}
			// Release the iterator itself once drained.
			IOObjectRelease(iterator)
		}
		return cables
	}

	//============================================
	// MARK: Live watch
	//============================================

	/// Begin watching for cable plug (insert) and unplug (remove) events.
	///
	/// Mirrors whatcable's `VDMIdentityWatcher.start`: a notification port is
	/// created, attached to the main dispatch queue, and matched + terminated
	/// notifications are registered for each cable e-marker class. The initial
	/// matched iterator MUST be drained immediately to arm the notification, but
	/// the services it returns are the host-side ports/cables already present at
	/// startup. Those form a BASELINE that is recorded and NOT emitted as inserts:
	/// otherwise a persistent host-port SOP service (always present on this Mac)
	/// would print a phantom "cable" line with nothing newly plugged in. Only
	/// services that appear AFTER arming -- whose registry ID is not in the
	/// baseline -- fire `onInsert`. Pre-existing cables are covered by `--once`,
	/// which snapshots without a baseline.
	///
	/// `onInsert` fires for EVERY new matched service, even one whose e-marker
	/// cannot be decoded (`DetectedCable.info == nil`), so a non-e-marked plug is
	/// reported as UNKNOWN rather than dropped. Duplicate matched callbacks for the
	/// same physical service (a cable can answer at both SOP and SOP') are
	/// collapsed by registry entry ID so a single plug yields a single `onInsert`.
	///
	/// When `onDebug` is supplied it is called for EVERY IOKit event the watch
	/// sees -- including baseline/pre-existing matched services and every
	/// terminate -- so the user can confirm whether a non-e-marked plug fires any
	/// matched callback at all. The Bool is true for matched, false for terminated.
	///
	/// Args:
	///   onInsert: called once per newly-attached service (info may be nil).
	///   onRemove: called when a previously-emitted service is detached.
	///   onDebug: optional raw event sink for diagnostics; nil to disable.
	public func watch(
		onInsert: @escaping (DetectedCable) -> Void,
		onRemove: @escaping (DetectedCable) -> Void,
		onDebug: ((DetectedCable, Bool) -> Void)? = nil
	) {
		// Idempotent: a second watch without an intervening stop is a no-op.
		guard notifyPort == nil else {
			return
		}
		insertHandler = onInsert
		removeHandler = onRemove
		debugHandler = onDebug

		// IONotificationPortCreate returns nil under Mach-port exhaustion. Passing a
		// nil port onward to IONotificationPortSetDispatchQueue is undefined behavior,
		// so fail cleanly: log to stderr and return without arming the watch.
		guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
			let message = "IOKitCableSource.watch: IONotificationPortCreate failed (Mach-port exhaustion?); not watching"
			FileHandle.standardError.write(Data((message + "\n").utf8))
			return
		}
		IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
		notifyPort = port

		// Pass an unretained pointer to self through the C callback refcon.
		let selfPtr = Unmanaged.passUnretained(self).toOpaque()

		// Matched: a service appeared. Drain the iterator on the main queue.
		let matchedCallback: IOServiceMatchingCallback = { refcon, iterator in
			guard let refcon else { return }
			let source = Unmanaged<IOKitCableSource>.fromOpaque(refcon).takeUnretainedValue()
			source.handleMatched(iterator)
		}
		// Terminated: a service went away. Drain and report removals.
		let terminatedCallback: IOServiceMatchingCallback = { refcon, iterator in
			guard let refcon else { return }
			let source = Unmanaged<IOKitCableSource>.fromOpaque(refcon).takeUnretainedValue()
			source.handleTerminated(iterator)
		}

		// Mark the arming window: the initial drains below populate the baseline
		// (suppressed from onInsert) instead of reporting phantom plug events.
		arming = true
		for className in Self.matchedClasses {
			// Matched notification. Drain the returned iterator now so existing
			// cables are recorded as baseline, then keep it alive for future
			// callbacks. (Required to arm the notification port.)
			var matchedIter: io_iterator_t = 0
			if IOServiceAddMatchingNotification(
				port,
				kIOMatchedNotification,
				IOServiceMatching(className),
				matchedCallback,
				selfPtr,
				&matchedIter
			) == KERN_SUCCESS {
				handleMatched(matchedIter)
				iterators.append(matchedIter)
			}

			// Terminated notification. Drain once to arm the iterator.
			var terminatedIter: io_iterator_t = 0
			if IOServiceAddMatchingNotification(
				port,
				kIOTerminatedNotification,
				IOServiceMatching(className),
				terminatedCallback,
				selfPtr,
				&terminatedIter
			) == KERN_SUCCESS {
				handleTerminated(terminatedIter)
				iterators.append(terminatedIter)
			}
		}
		// Arming complete: subsequent matched callbacks are real plug events.
		arming = false
	}

	/// Stop watching and release every IOKit resource: all notification
	/// iterators and the notification port. Safe to call when not watching.
	public func stop() {
		for iterator in iterators where iterator != 0 {
			IOObjectRelease(iterator)
		}
		iterators.removeAll()
		if let port = notifyPort {
			IONotificationPortDestroy(port)
			notifyPort = nil
		}
		seenServiceIDs.removeAll()
		baselineServiceIDs.removeAll()
		arming = false
		insertHandler = nil
		removeHandler = nil
		debugHandler = nil
	}

	//============================================
	// MARK: Notification iterator handlers
	//============================================

	/// Drain a matched-notification iterator, describing and reporting each new
	/// service exactly once. Releases every service it pulls.
	///
	/// Every matched service becomes a `DetectedCable` (info may be nil) so a
	/// non-e-marked plug is reported, not dropped. Services drained during the
	/// initial arming window are recorded as baseline and suppressed from
	/// `onInsert`; only services that appear after arming fire it. The debug sink,
	/// when present, sees ALL matched services including the baseline ones.
	private func handleMatched(_ iterator: io_iterator_t) {
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			let entryID = Self.registryEntryID(service)
			let liveClass = Self.serviceClassName(service) ?? "(unknown class)"
			let detected = Self.describeService(
				serviceClass: liveClass,
				registryID: entryID,
				read: Self.makeReader(service)
			)
			// Debug sees every matched event, baseline or not.
			debugHandler?(detected, true)
			// Collapse duplicate add events: a cable can answer at both SOP and
			// SOP', and the same service may be drained by more than one callback.
			if seenServiceIDs.contains(entryID) {
				continue
			}
			seenServiceIDs.insert(entryID)
			// Baseline window: record the pre-existing service and do not emit it
			// as a plug. Otherwise emit the insert (info may be nil -> UNKNOWN).
			if arming {
				baselineServiceIDs.insert(entryID)
				continue
			}
			if baselineServiceIDs.contains(entryID) {
				continue
			}
			insertHandler?(detected)
		}
	}

	/// Drain a terminated-notification iterator, describing and reporting each
	/// removed service. Clears the dedup record so a later replug reports again.
	///
	/// A removal is reported only for a service that was actually emitted as an
	/// insert (not a baseline/pre-existing service). The debug sink sees every
	/// terminate regardless.
	private func handleTerminated(_ iterator: io_iterator_t) {
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			let entryID = Self.registryEntryID(service)
			let liveClass = Self.serviceClassName(service) ?? "(unknown class)"
			let detected = Self.describeService(
				serviceClass: liveClass,
				registryID: entryID,
				read: Self.makeReader(service)
			)
			// Debug sees every terminate event.
			debugHandler?(detected, false)
			// Forget the dedup record so a later replug reports again.
			let wasSeen = seenServiceIDs.remove(entryID) != nil
			// A baseline service going away is not a user-facing removal; clear
			// its baseline record so a replug of the same ID can insert.
			let wasBaseline = baselineServiceIDs.remove(entryID) != nil
			// Report a removal only for a service we actually emitted as an insert.
			if wasSeen && !wasBaseline {
				removeHandler?(detected)
			}
		}
	}

	//============================================
	// MARK: IOKit reading helpers
	//============================================

	/// Build a property-read closure backed by a live IOKit service. The closure
	/// takes ownership of each returned CFType via takeRetainedValue, matching
	/// whatcable's read(_:) in makeUpdate.
	///
	/// Args:
	///   service: the io_service_t to read properties from.
	///
	/// Returns:
	///   A closure mapping a property key to its value, or nil if absent.
	private static func makeReader(_ service: io_service_t) -> (String) -> Any? {
		// Capture the service handle by value for the closure's lifetime, which
		// is bounded by the enclosing drain loop (the service is released after).
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

	/// Stable identity for a service across SOP/SOP' duplicates and repeated
	/// callbacks. The registry entry ID is unique per IOKit object.
	///
	/// Args:
	///   service: the io_service_t to identify.
	///
	/// Returns:
	///   The registry entry ID, or 0 if it could not be read.
	private static func registryEntryID(_ service: io_service_t) -> UInt64 {
		var entryID: UInt64 = 0
		IORegistryEntryGetRegistryEntryID(service, &entryID)
		return entryID
	}

	/// Read the IOKit class name of a service via IOObjectGetClass.
	///
	/// Mirrors whatcable's class discrimination in VDMIdentityWatcher.endpoint(for:).
	/// The live class is preferred over the query class because an SOP' service can
	/// be returned by either class match query.
	///
	/// Args:
	///   service: the io_service_t to identify.
	///
	/// Returns:
	///   The class name string, or nil if it could not be read.
	private static func serviceClassName(_ service: io_service_t) -> String? {
		// IOObjectGetClass fills a C string buffer with the registered class name.
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
}

//============================================
// MARK: Any? coercion helpers
//============================================
//
// Adapted from whatcable Sources/WhatCableDarwinBackend/Support/IOKitHelpers.swift
// (wcDictionary, wcArray, wcData). IOKit returns CFType values bridged to Any,
// so these coerce them into the Swift container types the parser expects without
// masking missing data: a non-matching value yields an empty container or nil,
// which the parser treats as "absent" and fails loud where required.

/// Coerce an IOKit Any? value into a [String: Any] dictionary.
///
/// Args:
///   value: the bridged CFDictionary / NSDictionary, or nil.
///
/// Returns:
///   The dictionary contents, or an empty dictionary when not a dictionary.
func coerceDictionary(_ value: Any?) -> [String: Any] {
	if let dict = value as? [String: Any] {
		return dict
	}
	if let nsDict = value as? NSDictionary {
		var converted: [String: Any] = [:]
		for case let (key, val) as (String, Any) in nsDict {
			converted[key] = val
		}
		return converted
	}
	return [:]
}

/// Coerce an IOKit Any? value into an [Any] array.
///
/// Args:
///   value: the bridged CFArray / NSArray, or nil.
///
/// Returns:
///   The array contents, or an empty array when not an array.
func coerceArray(_ value: Any?) -> [Any] {
	if let array = value as? [Any] {
		return array
	}
	if let nsArray = value as? NSArray {
		return nsArray.map { $0 }
	}
	return []
}

/// Coerce an IOKit Any? value into Data.
///
/// Args:
///   value: the bridged CFData / NSData, or nil.
///
/// Returns:
///   The Data when the value is data, otherwise nil.
func coerceData(_ value: Any?) -> Data? {
	let data = value as? Data
	return data
}

/// Coerce an IOKit Any? Metadata value into a UInt16 (e.g. the PID key).
///
/// IOKit bridges integer metadata values to NSNumber (most common) or a plain
/// Swift Int. The PID is a 16-bit USB product ID, so this masks to the low 16
/// bits. An absent or non-numeric value yields 0, the documented "no PID"
/// sentinel that simply misses the VID/PID DB lookup -- it does not mask a real
/// value, because a real PID is always a present numeric Metadata entry. Mirrors
/// whatcable's metadata["PID"] -> integer -> UInt16 coercion.
///
/// Args:
///   value: the bridged NSNumber / Int Metadata value, or nil.
///
/// Returns:
///   The low 16 bits as a UInt16, or 0 when the value is absent or not numeric.
func coerceUInt16(_ value: Any?) -> UInt16 {
	// NSNumber covers the common CFNumber bridge from IOKit metadata.
	if let number = value as? NSNumber {
		return UInt16(truncatingIfNeeded: number.intValue)
	}
	// A plain Swift Int can arrive for synthetic dictionaries (tests).
	if let intValue = value as? Int {
		return UInt16(truncatingIfNeeded: intValue)
	}
	return 0
}

/// Coerce an IOKit Any? value into an Int (e.g. ParentPortNumber/Type keys).
///
/// IOKit bridges integer registry values to NSNumber; synthetic test
/// dictionaries may carry a plain Swift Int. Returns nil when the value is
/// absent or not numeric, which the parent-port reader treats as "key absent"
/// and falls through to the next key (then the unknown-port sentinel) -- it
/// does not invent a 0 that would falsely match port 0. Mirrors whatcable's
/// `(read(key) as? NSNumber)?.intValue` reads in `parentPortIdentity(read:)`.
///
/// Args:
///   value: the bridged NSNumber / Int registry value, or nil.
///
/// Returns:
///   The integer value, or nil when absent or non-numeric.
func coerceInt(_ value: Any?) -> Int? {
	// NSNumber covers the common CFNumber bridge from IOKit registry values.
	if let number = value as? NSNumber {
		return number.intValue
	}
	// A plain Swift Int can arrive for synthetic dictionaries (tests).
	if let intValue = value as? Int {
		return intValue
	}
	return nil
}

/// Decode a 4-byte little-endian VDO Data blob into a UInt32.
///
/// IOKit stores each VDO as a little-endian 4-byte Data. Adapted from whatcable
/// Sources/WhatCableCore/USB/USBPDVDO.swift PDVDO.vdoFromData.
///
/// Args:
///   data: the VDO bytes; must be at least 4 bytes.
///
/// Returns:
///   The host-order UInt32, or nil when the blob is shorter than 4 bytes.
func vdoUInt32(_ data: Data) -> UInt32? {
	guard data.count >= 4 else {
		return nil
	}
	let value = data.withUnsafeBytes { buffer in
		buffer.loadUnaligned(as: UInt32.self).littleEndian
	}
	return value
}
