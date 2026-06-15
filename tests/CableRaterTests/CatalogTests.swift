import XCTest
@testable import CableRater

/// XCTest coverage for Catalog: bundled DB load, CableVDO lookup, VID/PID lookup,
/// zeroed-VID cableVDO record, absent key, and speed-string -> CableSpeedTier mapping.
///
/// All test keys are grounded in real entries from known_cables.json.
final class CatalogTests: XCTestCase {

	// MARK: Load

	/// Catalog.shared must load without crashing (packaging sanity gate).
	func test_catalog_loads_without_crash() {
		// Access the shared singleton; a packaging defect causes preconditionFailure.
		let catalog = Catalog.shared
		// At least one record must be present after a successful load.
		XCTAssertGreaterThan(catalog.records.count, 0, "catalog must contain at least one record")
	}

	// MARK: CableVDO lookup -- known entries

	/// cableVDO 0x110A2644 is the Apple Thunderbolt 5 cable 1 m; speed tier must be gen80g.
	func test_lookup_byCableVDO_apple_tb5_returns_gen80g() {
		// Apple Thunderbolt 5 cable 1 m: cableVDO 0x110A2644, speed "USB4 Gen 4 (80 Gbps)".
		let result = Catalog.shared.lookup(byCableVDO: 0x110A2644)
		XCTAssertNotNil(result, "cableVDO 0x110A2644 must match at least one DB record")
		XCTAssertEqual(result?.speedTier, .gen80g)
	}

	/// cableVDO 0x11082043 is the UGREEN Revodok Max 213 dock cable; speed tier must be gen20to40g.
	func test_lookup_byCableVDO_ugreen_revodok_returns_gen20to40g() {
		// UGREEN Revodok Max 213: cableVDO 0x11082043, speed "USB4 Gen 3 (20 / 40 Gbps)".
		let result = Catalog.shared.lookup(byCableVDO: 0x11082043)
		XCTAssertNotNil(result, "cableVDO 0x11082043 must match at least one DB record")
		XCTAssertEqual(result?.speedTier, .gen20to40g)
	}

	/// cableVDO 0x00084841 is a zeroed-VID 5 Gbps cable (UGreen Revodok hub cable).
	func test_lookup_byCableVDO_zeroed_vid_5g_returns_gen5g() {
		// UGreen Revodok 9-in-1 hub cable: cableVDO 0x00084841, speed "USB 3.2 Gen 1 (5 Gbps)".
		// vid is "0x0000"; can only be found by cableVDO, not by VID/PID.
		let result = Catalog.shared.lookup(byCableVDO: 0x00084841)
		XCTAssertNotNil(result, "cableVDO 0x00084841 must match at least one DB record")
		XCTAssertEqual(result?.speedTier, .gen5g)
	}

	/// cableVDO 0x00082040 is a zeroed-VID USB 2.0 cable (UGreen retractable 100W).
	func test_lookup_byCableVDO_zeroed_vid_usb2_returns_usb2() {
		// UGreen retractable 100W: cableVDO 0x00082040, speed "USB 2.0 (480 Mbps)".
		// vid is "0x0000"; can only be found by cableVDO.
		let result = Catalog.shared.lookup(byCableVDO: 0x00082040)
		XCTAssertNotNil(result, "cableVDO 0x00082040 must match at least one DB record")
		XCTAssertEqual(result?.speedTier, .usb2)
	}

	/// An absent cableVDO (0xDEADBEEF) must return nil, not crash.
	func test_lookup_byCableVDO_absent_returns_nil() {
		// 0xDEADBEEF is not in the DB; nil is the correct result.
		let result = Catalog.shared.lookup(byCableVDO: 0xDEADBEEF)
		XCTAssertNil(result, "unknown cableVDO must return nil")
	}

	// MARK: VID/PID lookup -- known entries

	/// vid=0x05AC pid=0x720A is the Apple Thunderbolt 5 cable 1 m; tier must be gen80g.
	func test_lookup_byVIDPID_apple_tb5_returns_gen80g() {
		// Apple Thunderbolt 5 cable 1 m: vid 0x05AC, pid 0x720A.
		let result = Catalog.shared.lookup(byVendorID: 0x05AC, productID: 0x720A)
		XCTAssertNotNil(result, "vid=0x05AC pid=0x720A must match the Apple TB5 cable record")
		XCTAssertEqual(result?.speedTier, .gen80g)
	}

	/// vid=0x2B1D pid=0x1533 is the Cable Matters TB5 cable; tier must be gen80g.
	func test_lookup_byVIDPID_cable_matters_tb5_returns_gen80g() {
		// Cable Matters Thunderbolt 5 cable 1 m: vid 0x2B1D, pid 0x1533.
		let result = Catalog.shared.lookup(byVendorID: 0x2B1D, productID: 0x1533)
		XCTAssertNotNil(result, "vid=0x2B1D pid=0x1533 must match the Cable Matters TB5 record")
		XCTAssertEqual(result?.speedTier, .gen80g)
	}

	/// An absent VID/PID pair (0xFFFF, 0xFFFF) must return nil, not crash.
	func test_lookup_byVIDPID_absent_returns_nil() {
		// (0xFFFF, 0xFFFF) is not a real USB-IF pair; nil is the correct result.
		let result = Catalog.shared.lookup(byVendorID: 0xFFFF, productID: 0xFFFF)
		XCTAssertNil(result, "unknown VID/PID must return nil")
	}

	// MARK: Zeroed-VID record found by cableVDO

	/// Zeroed-VID records (vid == "0x0000") must be findable by cableVDO lookup.
	///
	/// cableVDO 0x00082042 appears for Dockcase 100W 10G (and others) with vid 0x0000.
	/// lookup(byCableVDO:) must find it; lookup(byVendorID:productID:) with 0/0 is
	/// ambiguous and tested separately.
	func test_zeroed_vid_record_found_by_cableVDO() {
		// Dockcase 100W 10G: cableVDO 0x00082042, vid "0x0000", speed 10 Gbps.
		let result = Catalog.shared.lookup(byCableVDO: 0x00082042)
		XCTAssertNotNil(result, "zeroed-VID record with cableVDO 0x00082042 must be found")
		// The first hit for this VDO is Dockcase 100W 10G -> gen10g.
		XCTAssertEqual(result?.speedTier, .gen10g)
	}

	// MARK: Speed-string mapping

	/// "USB 2.0 (480 Mbps)" -> .usb2
	func test_speedTierFromString_usb20_mbps() {
		XCTAssertEqual(Catalog.speedTierFromString("USB 2.0 (480 Mbps)"), .usb2)
	}

	/// "USB 2.0 (480 Mbit/s)" alternate notation -> .usb2
	func test_speedTierFromString_usb20_mbitps() {
		XCTAssertEqual(Catalog.speedTierFromString("USB 2.0 (480 Mbit/s)"), .usb2)
	}

	/// "USB 3.2 Gen 1 (5 Gbps)" -> .gen5g
	func test_speedTierFromString_gen1_5g() {
		XCTAssertEqual(Catalog.speedTierFromString("USB 3.2 Gen 1 (5 Gbps)"), .gen5g)
	}

	/// "USB 3.2 Gen 2 (10 Gbps)" -> .gen10g
	func test_speedTierFromString_gen2_10g() {
		XCTAssertEqual(Catalog.speedTierFromString("USB 3.2 Gen 2 (10 Gbps)"), .gen10g)
	}

	/// "USB 3.2 Gen 2 (10 Gbit/s)" alternate notation -> .gen10g
	func test_speedTierFromString_gen2_10gbit() {
		XCTAssertEqual(Catalog.speedTierFromString("USB 3.2 Gen 2 (10 Gbit/s)"), .gen10g)
	}

	/// "USB4 Gen 3 (40 Gbps, Thunderbolt 4 class)" -> .gen20to40g
	func test_speedTierFromString_usb4gen3_40g_tb4() {
		XCTAssertEqual(Catalog.speedTierFromString("USB4 Gen 3 (40 Gbps, Thunderbolt 4 class)"), .gen20to40g)
	}

	/// "USB4 Gen 3 (20 / 40 Gbps)" ambiguous range notation -> .gen20to40g
	func test_speedTierFromString_usb4gen3_20_40g() {
		XCTAssertEqual(Catalog.speedTierFromString("USB4 Gen 3 (20 / 40 Gbps)"), .gen20to40g)
	}

	/// "USB4 Gen 4 (80 Gbps)" -> .gen80g
	func test_speedTierFromString_usb4gen4_80g() {
		XCTAssertEqual(Catalog.speedTierFromString("USB4 Gen 4 (80 Gbps)"), .gen80g)
	}

	/// "USB4 Gen 4 (80 Gbps, Thunderbolt 5 class)" -> .gen80g
	func test_speedTierFromString_usb4gen4_80g_tb5() {
		XCTAssertEqual(Catalog.speedTierFromString("USB4 Gen 4 (80 Gbps, Thunderbolt 5 class)"), .gen80g)
	}

	/// An empty string -> .unknown (never crash).
	func test_speedTierFromString_empty_is_unknown() {
		XCTAssertEqual(Catalog.speedTierFromString(""), .unknown)
	}

	/// An unrecognized string -> .unknown (never crash).
	func test_speedTierFromString_garbage_is_unknown() {
		XCTAssertEqual(Catalog.speedTierFromString("Thunderbolt 99 (999 Gbps)"), .unknown)
	}
}
