import XCTest
@testable import CableRater

/// XCTest coverage for the verdict() rating merge. Each User-facing contract row
/// is exercised with a synthetic CableInfo (and the real bundled Catalog), and
/// both the bucket label and the basis are asserted.
///
/// Contract rows:
///   readable e-marker, unambiguous   -> 5G/10G/80G/USB2, basis emarker
///   e-marker value 3 (ambiguous)     -> 20-40G,          basis emarkerAmbiguous
///   SOP' zeroed/sparse, DB hit        -> DB speed,        basis knownDB
///   SOP' zeroed/sparse, no DB hit     -> UNKNOWN*,        basis emarkerUnrecognized
///   no SOP' service / nothing decoded -> UNKNOWN,         basis noEmarker
final class RatingTests: XCTestCase {

	//============================================
	// MARK: Helpers
	//============================================

	/// Build a CableInfo with explicit fields for a test scenario.
	private func makeCable(
		speed: CableSpeedTier,
		product: CableProductType = .passive,
		current: CableCurrent = .threeAmp,
		vendor: UInt16 = 0x1234
	) -> CableInfo {
		let cable = CableInfo(
			speedTier: speed,
			productType: product,
			current: current,
			vendorID: vendor
		)
		return cable
	}

	/// The all-zero "zeroed/sparse" shape produced by a present-but-zeroed SOP'.
	private func makeZeroedCable() -> CableInfo {
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		return cable
	}

	/// A zeroed/sparse shape that still carries a real raw Cable VDO word, the way
	/// the live Probe layer now surfaces it (rawCableVDO from VDO[3]). This is the
	/// shape that lets the convenience verdict reach the known-cable DB.
	private func makeZeroedCable(rawCableVDO: UInt32) -> CableInfo {
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0,
			rawCableVDO: rawCableVDO
		)
		return cable
	}

	//============================================
	// MARK: Row -- nothing decoded (no SOP' service)
	//============================================

	/// cable == nil -> UNKNOWN bucket, basis noEmarker.
	func test_nil_cable_is_unknown_noEmarker() {
		let result = verdict(for: nil, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "UNKNOWN")
		XCTAssertEqual(result.basis, .noEmarker)
		XCTAssertEqual(result.tier, .unknown)
		XCTAssertNil(result.cable)
		XCTAssertNil(result.knownCable)
	}

	//============================================
	// MARK: Row -- readable e-marker, unambiguous (no DB dependency)
	//============================================

	/// A clear 5G cable rates 5G via the e-marker with NO DB hit.
	func test_clear_5g_is_emarker_no_db() {
		// vendor 0xABCD / 5G is deliberately not in the DB; must still rate 5G.
		let cable = makeCable(speed: .gen5g, vendor: 0xABCD)
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "5G")
		XCTAssertEqual(result.basis, .emarker)
		XCTAssertEqual(result.tier, .gen5g)
		// Proves not DB-dependent: no known-cable record was attached.
		XCTAssertNil(result.knownCable)
	}

	/// A clear 10G cable rates 10G via the e-marker.
	func test_clear_10g_is_emarker() {
		let cable = makeCable(speed: .gen10g)
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "10G")
		XCTAssertEqual(result.basis, .emarker)
		XCTAssertEqual(result.tier, .gen10g)
	}

	/// A clear 80G cable rates 80G via the e-marker.
	func test_clear_80g_is_emarker() {
		let cable = makeCable(speed: .gen80g)
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "80G")
		XCTAssertEqual(result.basis, .emarker)
		XCTAssertEqual(result.tier, .gen80g)
	}

	/// A clear USB2 cable that still carries a nonzero VID/product is a real
	/// e-marked USB2 cable, not the zeroed shape, so basis is emarker.
	func test_clear_usb2_emarked_is_emarker() {
		// Nonzero vendor + passive product => not the all-zero sparse shape.
		let cable = makeCable(speed: .usb2, product: .passive, current: .threeAmp, vendor: 0x1A2B)
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "USB2")
		XCTAssertEqual(result.basis, .emarker)
		XCTAssertEqual(result.tier, .usb2)
	}

	//============================================
	// MARK: Row -- value 3 ambiguous
	//============================================

	/// gen20to40g -> 20-40G bucket, basis emarkerAmbiguous.
	func test_value3_is_20to40g_ambiguous() {
		let cable = makeCable(speed: .gen20to40g)
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "20-40G")
		XCTAssertEqual(result.basis, .emarkerAmbiguous)
		XCTAssertEqual(result.tier, .gen20to40g)
	}

	//============================================
	// MARK: Row -- zeroed/sparse, DB hit (by cableVDO)
	//============================================

	/// A zeroed cable refined by raw cableVDO 0x00084841 hits the DB as 5G.
	func test_zeroed_cable_db_hit_byCableVDO_is_knownDB() {
		// UGreen Revodok 9-in-1 hub cable: cableVDO 0x00084841, zeroed VID, 5 Gbps.
		let cable = makeZeroedCable()
		let result = verdict(
			for: cable,
			cableVDO: 0x00084841,
			productID: nil,
			catalog: Catalog.shared
		)
		XCTAssertEqual(result.bucketLabel, "5G")
		XCTAssertEqual(result.basis, .knownDB)
		XCTAssertEqual(result.tier, .gen5g)
		XCTAssertNotNil(result.knownCable, "a DB record must be attached on a knownDB verdict")
	}

	//============================================
	// MARK: Live path -- convenience verdict reaches the DB via rawCableVDO
	//============================================

	/// The LIVE convenience path proof: a zeroed/sparse cable that carries a real
	/// raw Cable VDO on CableInfo (the way the Probe layer now surfaces VDO[3])
	/// must reach the known-cable DB through `verdict(for:catalog:)` -- the same
	/// form CLI.swift calls -- with NO explicit cableVDO/productID passed in.
	/// This is the contract that was previously impossible: the convenience form
	/// used to pass nil keys and could never hit the DB on the live path.
	func test_live_convenience_path_reaches_db_byCableVDO_is_knownDB() {
		// UGreen Revodok hub cable: cableVDO 0x00084841 (zeroed VID), 5 Gbps in the
		// bundled known_cables.json. The cable carries rawCableVDO itself; the
		// convenience verdict reads it off the cable, not from an explicit argument.
		let cable = makeZeroedCable(rawCableVDO: 0x00084841)
		// Convenience form only: no cableVDO/productID arguments -- this is exactly
		// what CLI.swift's runOnce/runWatch call on a live snapshot.
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "5G")
		XCTAssertEqual(result.basis, .knownDB)
		XCTAssertEqual(result.tier, .gen5g)
		XCTAssertNotNil(result.knownCable, "the live convenience path must attach a DB record")
	}

	//============================================
	// MARK: Row -- zeroed/sparse, DB hit (by VID/PID)
	//============================================

	/// A sparse cable (unknown speed) with a real VID refined by raw productID
	/// hits the DB by VID/PID (Apple TB5) as 80G.
	func test_sparse_cable_db_hit_byVIDPID_is_knownDB() {
		// Apple Thunderbolt 5 cable 1 m: vid 0x05AC, pid 0x720A, 80 Gbps.
		// speedTier .unknown makes the cable sparse; vendorID carries the VID.
		let cable = makeCable(speed: .unknown, product: .active, current: .fiveAmp, vendor: 0x05AC)
		let result = verdict(
			for: cable,
			cableVDO: nil,
			productID: 0x720A,
			catalog: Catalog.shared
		)
		XCTAssertEqual(result.bucketLabel, "80G")
		XCTAssertEqual(result.basis, .knownDB)
		XCTAssertEqual(result.tier, .gen80g)
		XCTAssertNotNil(result.knownCable)
	}

	//============================================
	// MARK: Row -- zeroed/sparse, no DB hit (UNKNOWN*)
	//============================================

	/// A zeroed cable with no raw keys cannot reach the DB -> UNKNOWN*.
	func test_zeroed_cable_no_keys_is_unknown_star() {
		let cable = makeZeroedCable()
		let result = verdict(for: cable, catalog: Catalog.shared)
		XCTAssertEqual(result.bucketLabel, "UNKNOWN*")
		XCTAssertEqual(result.basis, .emarkerUnrecognized)
		XCTAssertEqual(result.tier, .unknown)
		XCTAssertNil(result.knownCable)
	}

	/// A sparse cable (unknown speed) whose raw cableVDO misses the DB -> UNKNOWN*.
	func test_sparse_cable_db_miss_is_unknown_star() {
		// speedTier .unknown is sparse; 0xDEADBEEF is not in the DB.
		let cable = makeCable(speed: .unknown, vendor: 0x9999)
		let result = verdict(
			for: cable,
			cableVDO: 0xDEADBEEF,
			productID: 0x9999,
			catalog: Catalog.shared
		)
		XCTAssertEqual(result.bucketLabel, "UNKNOWN*")
		XCTAssertEqual(result.basis, .emarkerUnrecognized)
		XCTAssertEqual(result.tier, .unknown)
	}

	//============================================
	// MARK: Precedence -- clear tier never consults the DB
	//============================================

	/// Even when a clear-tier cable's vendor matches a DB record, the e-marker
	/// tier wins and no DB record is attached (live decode beats DB refine).
	func test_clear_tier_beats_db_refine() {
		// Apple VID 0x05AC, but a clear 10G e-marker tier must short-circuit the DB.
		let cable = makeCable(speed: .gen10g, product: .passive, current: .threeAmp, vendor: 0x05AC)
		let result = verdict(
			for: cable,
			cableVDO: 0x110A2644,
			productID: 0x720A,
			catalog: Catalog.shared
		)
		XCTAssertEqual(result.bucketLabel, "10G")
		XCTAssertEqual(result.basis, .emarker)
		XCTAssertNil(result.knownCable, "clear-tier verdicts must not attach a DB record")
	}
}
