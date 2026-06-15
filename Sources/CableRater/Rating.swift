// Rating.swift -- merge a decoded CableInfo (and optional raw DB keys) into a
// single user-facing Verdict following the plan's precedence:
//
//   live e-marker decode  ->  DB refinement (zeroed/sparse only)  ->  UNKNOWN
//
// A normal e-marked cable with a clear speed tier MUST rate correctly with NO DB
// hit: the catalog is a refinement-only layer used only when a real SOP' e-marker
// is present but its VDO fields are zeroed or sparse.
//
// User-facing contract rows implemented here:
//   | readable e-marker, unambiguous   | 5G/10G/80G/USB2 | emarker
//   | e-marker value 3 (split unproven)| 20-40G          | emarkerAmbiguous
//   | SOP' zeroed/sparse, DB hit        | DB speed        | knownDB
//   | SOP' zeroed/sparse, no DB hit     | UNKNOWN*        | emarkerUnrecognized
//   | no SOP' service / nothing decoded | UNKNOWN         | noEmarker
//
// The full verdict signature accepts the raw cableVDO and productID separately
// so explicit callers (tests, or a future device-floor milestone) can pass keys
// the e-marker decode did not produce. The live IOKit path no longer needs that:
// CableInfo now carries `rawCableVDO` (the VDO[3] word) and `productID` (from
// IOKit Metadata PID), so the convenience `verdict(for:catalog:)` reads both off
// the cable and the live path reaches the known-cable DB for a zeroed/sparse
// real cable. The clear-tier short-circuit still wins before any DB lookup, so a
// normally e-marked cable rates by e-marker with the catalog untouched. The
// device-floor path is always active (no opt-in flag).

import Foundation

//============================================
// MARK: Verdict basis
//============================================

/// How a Verdict's bucket was determined. Plain-English mapping lives in Render.
///
/// Cases are ordered by the plan's precedence narrative, not by priority value.
public enum VerdictBasis: String, Codable, Equatable {
	/// A clear, unambiguous speed tier came straight from the cable e-marker.
	case emarker
	/// The e-marker speed field was value 3 (USB4 Gen 3): 20 Gbps in PD 3.0 or
	/// 40 Gbps in PD 3.1. PD revision is unavailable, so the bucket is 20-40G.
	case emarkerAmbiguous
	/// A real SOP' e-marker was present but zeroed/sparse; the known-cable DB
	/// supplied the speed by exact Cable VDO or VID/PID match.
	case knownDB
	/// A real SOP' e-marker was present but zeroed/sparse and the DB had no match.
	/// This is the distinct "worth investigating" pile (UNKNOWN*).
	case emarkerUnrecognized
	/// No readable cable e-marker, but a USB3+ device on the far end negotiated a
	/// link speed that is a conservative FLOOR for the cable. The bucket is the
	/// device-negotiated minimum and the headline reads "At least <speed>". This is
	/// the M5 device-speed fallback; the e-marker bases above always take precedence
	/// over it when a readable e-marker exists. The cable's true rating may be
	/// higher -- this is a lower bound proven by the device, not the cable's own
	/// e-marker.
	case deviceFloor
	/// No SOP' service / nothing decodable -- almost certainly a plain USB2 cable.
	case noEmarker
}

//============================================
// MARK: Port-active basis (detected, no e-marker)
//============================================

/// The basis for a port that is physically detected (occupied) but exposes no
/// readable cable e-marker -- the "detected, no e-marker (port active)" case.
///
/// This is a PORT-level basis, distinct from the cable-level `VerdictBasis`: the
/// underlying `Verdict` for such a port is still the honest UNKNOWN/`noEmarker`
/// value (so its JSON `basis` token stays `noEmarker` and the machine schema is
/// untouched). This describes WHY the port has a verdict at all -- the port
/// controller reported a CC attach -- so the port-led headline can show a clean
/// `[port active]` tag next to the calm `Unknown` label instead of the cable-level
/// `[no e-marker]` tag, which would wrongly imply a decoded-but-empty e-marker.
///
/// The renderer reads `tag` for the headline's bracketed basis; keeping the wording
/// here puts the named basis in the rating layer (per the plan's component map)
/// while the render layer owns only its presentation.
public enum PortActiveBasis {
	/// The bracketed tag the port-led headline shows for a detected, no-e-marker
	/// (port active) port.
	public static let tag = "[port active]"
}

//============================================
// MARK: Device-floor basis (M5 far-end device fallback)
//============================================

/// The basis for a port whose rating is FLOORED by a far-end USB3+ device's
/// negotiated link speed -- the M5 "At least <speed>" fallback.
///
/// Like `PortActiveBasis`, this is a PORT-level presentation basis layered over a
/// `Verdict`. The underlying `Verdict.basis` is `.deviceFloor` and its `bucketLabel`
/// is a normal tier bucket (5G / 10G / 20-40G), so the stable JSON `bucket`/`basis`
/// schema carries the floor without a new bucket token. This describes WHY the port
/// has a speed at all -- a USB3+ device enumerated on the far end -- so the headline
/// can show a clean `[device]` tag next to the calm `At least <speed>` label,
/// distinct from the cable-level `[e-marker]` tag (which would wrongly imply the
/// cable's own e-marker was read).
public enum DeviceFloorBasis {
	/// The bracketed tag the port-led headline shows for a device-floored port.
	public static let tag = "[device]"
}

//============================================
// MARK: Verdict value type
//============================================

/// The final user-facing rating for one cable.
///
/// Pure value type: Codable for --json output, Equatable for deterministic tests.
/// Carries the typed tier plus the source CableInfo and any matched KnownCable so
/// the Render layer (and future milestones) can show provenance without re-deciding.
public struct Verdict: Codable, Equatable {
	/// Short bucket label shown to the user: USB2 / 5G / 10G / 20-40G / 80G /
	/// UNKNOWN / UNKNOWN*. Drawn from CableSpeedTier.bucketLabel, with the
	/// trailing "*" added for the emarkerUnrecognized pile.
	public let bucketLabel: String
	/// Typed speed tier behind the bucket. .unknown for both UNKNOWN and UNKNOWN*.
	public let tier: CableSpeedTier
	/// How the bucket was determined.
	public let basis: VerdictBasis
	/// The decoded cable e-marker, when one was present. nil for the no-SOP' case.
	public let cable: CableInfo?
	/// The matched known-cable DB record, when the DB refined the result. nil
	/// otherwise.
	public let knownCable: KnownCable?

	public init(
		bucketLabel: String,
		tier: CableSpeedTier,
		basis: VerdictBasis,
		cable: CableInfo?,
		knownCable: KnownCable?
	) {
		self.bucketLabel = bucketLabel
		self.tier = tier
		self.basis = basis
		self.cable = cable
		self.knownCable = knownCable
	}
}

//============================================
// MARK: KnownCable Equatable conformance
//============================================
//
// KnownCable (Catalog.swift, a frozen file) is Codable but not declared Equatable.
// Verdict needs Equatable for deterministic tests, so conform KnownCable here in a
// retroactive extension. All stored fields are compared; derived computed
// properties follow from them.

extension KnownCable: Equatable {
	public static func == (lhs: KnownCable, rhs: KnownCable) -> Bool {
		// Compare every stored field; derived fields are functions of these.
		let same = lhs.brand == rhs.brand
			&& lhs.cableVDO == rhs.cableVDO
			&& lhs.vid == rhs.vid
			&& lhs.pid == rhs.pid
			&& lhs.vendor == rhs.vendor
			&& lhs.speed == rhs.speed
			&& lhs.type == rhs.type
			&& lhs.power == rhs.power
		return same
	}
}

//============================================
// MARK: Rating entry points
//============================================

/// Rate a cable into a single Verdict (convenience form for callers that hold a
/// decoded CableInfo).
///
/// CableInfo now carries the DB lookup keys directly: `rawCableVDO` (the raw
/// VDO[3] word, preserved by EMarker.decode) and `productID` (read from IOKit
/// Metadata by the Probe layer). This form reads both off the cable and forwards
/// them to the full verdict, so the LIVE path reaches the known-cable database:
/// a zeroed/sparse real cable whose VDO or VID/PID is in the DB is refined to its
/// DB speed (basis knownDB) instead of always rating UNKNOWN*. The clear-tier
/// short-circuit in the full form still wins first, so a normally e-marked cable
/// rates by e-marker with the DB untouched.
///
/// When the cable is nil (no SOP' service) the keys are nil; the full form
/// returns the honest UNKNOWN/noEmarker result.
///
/// Args:
///   cable: the decoded e-marker, or nil when no SOP' service was found.
///   catalog: the known-cable database used for the zeroed/sparse refine path.
///
/// Returns:
///   The user-facing Verdict.
public func verdict(for cable: CableInfo?, catalog: Catalog) -> Verdict {
	// Pull the DB lookup keys off the decoded cable so the live path can refine
	// a zeroed/sparse cable. A nil cable has no keys (the full form short-circuits
	// to UNKNOWN/noEmarker before any lookup). rawCableVDO/productID of 0 are the
	// "absent" sentinels, which simply miss the DB lookups.
	let result = verdict(
		for: cable,
		cableVDO: cable?.rawCableVDO,
		productID: cable?.productID,
		catalog: catalog
	)
	return result
}

/// Rate a cable into a single Verdict, with optional raw DB lookup keys.
///
/// Precedence (each step only runs when the previous did not produce a bucket):
///   1. cable == nil               -> UNKNOWN, basis noEmarker.
///   2. clear tier (USB2/5G/10G/80G) -> that bucket, basis emarker. DB NOT used.
///   3. tier == gen20to40g          -> 20-40G, basis emarkerAmbiguous.
///   4. zeroed/sparse cable: DB refine by cableVDO then VID/PID.
///        DB hit -> DB tier+bucket, basis knownDB.
///        no hit -> UNKNOWN*, basis emarkerUnrecognized.
///
/// Args:
///   cable: the decoded e-marker, or nil when no SOP' service was found.
///   cableVDO: the raw 32-bit Cable VDO for DB lookup, when the caller has it.
///   productID: the raw 16-bit USB product ID for VID/PID lookup, when available.
///   catalog: the known-cable database used for the zeroed/sparse refine path.
///
/// Returns:
///   The user-facing Verdict.
public func verdict(
	for cable: CableInfo?,
	cableVDO: UInt32?,
	productID: UInt16?,
	catalog: Catalog
) -> Verdict {
	// Step 1: no decodable e-marker at all (no SOP' service). Honest UNKNOWN.
	guard let cable = cable else {
		let result = Verdict(
			bucketLabel: CableSpeedTier.unknown.bucketLabel,
			tier: .unknown,
			basis: .noEmarker,
			cable: nil,
			knownCable: nil
		)
		return result
	}

	// Step 4 trigger check first: a zeroed/sparse e-marker is the only case that
	// reaches the DB. A cable with a clear or value-3 tier never needs the DB.
	// This check intentionally runs BEFORE the clear-tier and value-3 returns below
	// so a zeroed cable (usb2+usbDefault+unknown+vid0) can never bypass DB refinement
	// via the Step 2 or Step 3 short-circuits. The all-zero shape is ambiguous at
	// the bit level (could be a genuine USB2 cable or a zeroed e-marker), so it
	// always goes to the DB first; only a miss produces UNKNOWN*.
	if isZeroedOrSparse(cable) {
		let refined = refineZeroedOrSparse(
			cable: cable,
			cableVDO: cableVDO,
			productID: productID,
			catalog: catalog
		)
		return refined
	}

	// Step 3: the value-3 ambiguous bucket (20 vs 40 Gbps unproven).
	if cable.speedTier == .gen20to40g {
		let result = Verdict(
			bucketLabel: CableSpeedTier.gen20to40g.bucketLabel,
			tier: .gen20to40g,
			basis: .emarkerAmbiguous,
			cable: cable,
			knownCable: nil
		)
		return result
	}

	// Step 2: a clear, unambiguous speed tier straight from the e-marker.
	// USB2 / 5G / 10G / 80G. The DB is intentionally NOT consulted here so the
	// tool is never DB-dependent for a normally e-marked cable.
	let result = Verdict(
		bucketLabel: cable.speedTier.bucketLabel,
		tier: cable.speedTier,
		basis: .emarker,
		cable: cable,
		knownCable: nil
	)
	return result
}

//============================================
// MARK: Device-speed floor verdict (M5 fallback)
//============================================

/// Build the device-speed FLOOR verdict for a port: an honest "At least <speed>"
/// rating derived from a USB3+ device's negotiated link speed when the cable has no
/// readable e-marker.
///
/// This is the M5 fallback rating. It is NOT an e-marker read of the cable: it is a
/// lower bound proven by a device that enumerated on the far end, so the cable
/// carried AT LEAST this rate. The caller (the coordinator) reaches this only after
/// the e-marker path produced nothing, so e-marker bases always win over this floor.
///
/// The returned Verdict carries the floor tier and the `.deviceFloor` basis. Its
/// `cable` is nil (no e-marker decoded) and its `knownCable` is nil (the DB is not
/// consulted for a device floor -- the floor stands on the device's negotiated
/// speed alone). The render layer turns `.deviceFloor` + tier into the
/// "At least <speed> [device]" headline; the stable JSON `bucket` is the tier's
/// normal bucket label so the machine schema needs no new bucket token.
///
/// Args:
///   tier: the conservative cable speed-tier floor (a speed-bearing tier:
///     gen5g / gen10g / gen20to40g; never .unknown).
///
/// Returns:
///   A `.deviceFloor` Verdict at the given floor tier.
public func verdictForDeviceFloor(tier: CableSpeedTier) -> Verdict {
	// The bucket label is the tier's normal bucket (5G / 10G / 20-40G); the
	// "At least" wording is render-only, so the stable JSON bucket stays a known
	// tier token rather than a new one.
	let result = Verdict(
		bucketLabel: tier.bucketLabel,
		tier: tier,
		basis: .deviceFloor,
		cable: nil,
		knownCable: nil
	)
	return result
}

//============================================
// MARK: Zeroed/sparse detection and DB refine
//============================================

/// Decide whether a decoded cable is "zeroed or sparse" -- a real SOP' e-marker
/// whose VDO fields carry no usable speed information of their own.
///
/// Two shapes qualify:
///   - speedTier == .unknown: reserved/out-of-range speed bits (5-7); the
///     e-marker answered but the speed field is meaningless.
///   - the all-zero shape: a missing/zeroed Cable VDO decodes (via EMarker) to
///     usb2 + usbDefault, and a zeroed ID Header gives productType .unknown and
///     vendorID 0. That combination is indistinguishable from a genuine plain
///     USB2 cable at the bit level, so it is treated as zeroed/sparse and offered
///     to the DB before falling back. A genuine USB2 cable simply misses the DB
///     and lands in UNKNOWN* only if the caller had no raw keys; with a real raw
///     cableVDO the DB can still confirm it as USB2.
///
/// Args:
///   cable: the decoded CableInfo to classify.
///
/// Returns:
///   true when the cable should be routed through the DB-refine branch.
func isZeroedOrSparse(_ cable: CableInfo) -> Bool {
	// Reserved/undecodeable speed bits: always treat as sparse.
	if cable.speedTier == .unknown {
		return true
	}
	// All-zero shape: usb2 + usbDefault + unknown product type + zero vendor ID.
	// This is the "SOP' present, zeroed Cable VDO and ID Header" case.
	let allZeroShape = cable.speedTier == .usb2
		&& cable.current == .usbDefault
		&& cable.productType == .unknown
		&& cable.vendorID == 0
	return allZeroShape
}

/// Refine a zeroed/sparse cable through the known-cable DB.
///
/// Tries the exact Cable VDO key first (the catalog's primary key, the only key
/// that can match zeroed-VID records), then VID/PID. A hit yields the DB speed
/// tier and basis knownDB; a miss yields UNKNOWN* and basis emarkerUnrecognized.
///
/// Args:
///   cable: the zeroed/sparse decoded cable (carried into the Verdict).
///   cableVDO: the raw Cable VDO for the primary DB key, or nil.
///   productID: the raw product ID for the VID/PID key, or nil.
///   catalog: the known-cable database.
///
/// Returns:
///   A knownDB Verdict on a hit, otherwise an emarkerUnrecognized (UNKNOWN*) one.
func refineZeroedOrSparse(
	cable: CableInfo,
	cableVDO: UInt32?,
	productID: UInt16?,
	catalog: Catalog
) -> Verdict {
	// Primary key: exact Cable VDO. Matches zeroed-VID records too.
	var hit: KnownCable? = nil
	if let cableVDO = cableVDO {
		hit = catalog.lookup(byCableVDO: cableVDO)
	}
	// Secondary key: VID (from the e-marker) + PID (raw, caller-supplied).
	// A zero vendor ID never matches a real registered cable, so only attempt
	// this when both halves are present and the vendor ID is nonzero.
	if hit == nil, let productID = productID, cable.vendorID != 0 {
		hit = catalog.lookup(byVendorID: cable.vendorID, productID: productID)
	}

	// DB hit: refine to the DB speed tier and bucket, basis knownDB.
	if let known = hit {
		let dbTier = known.speedTier
		let result = Verdict(
			bucketLabel: dbTier.bucketLabel,
			tier: dbTier,
			basis: .knownDB,
			cable: cable,
			knownCable: known
		)
		return result
	}

	// No DB hit: the distinct "worth investigating" pile, UNKNOWN*.
	let result = Verdict(
		bucketLabel: CableSpeedTier.unknown.bucketLabel + "*",
		tier: .unknown,
		basis: .emarkerUnrecognized,
		cable: cable,
		knownCable: nil
	)
	return result
}
