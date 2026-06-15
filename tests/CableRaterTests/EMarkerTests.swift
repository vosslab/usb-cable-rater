import XCTest
@testable import CableRater

/// XCTest coverage for EMarker decode functions and Model types.
///
/// Each speed value 0-4 gets a test, plus out-of-range, product type,
/// current, and the value-3 -> gen20to40g bucket contract.
final class EMarkerTests: XCTestCase {

	// MARK: Speed tier -- each VDO bit pattern

	/// Speed bits 0 (USB 2.0) -> .usb2 and bucket label "USB2".
	func test_speed_bits0_decodes_to_usb2() {
		// Cable VDO with bits 2..0 == 0b000
		let vdo: UInt32 = 0x00000000
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .usb2)
		XCTAssertEqual(tier.bucketLabel, "USB2")
	}

	/// Speed bits 1 (5 Gbps) -> .gen5g and bucket label "5G".
	func test_speed_bits1_decodes_to_5g() {
		// Cable VDO with bits 2..0 == 0b001
		let vdo: UInt32 = 0x00000001
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .gen5g)
		XCTAssertEqual(tier.bucketLabel, "5G")
	}

	/// Speed bits 2 (10 Gbps) -> .gen10g and bucket label "10G".
	func test_speed_bits2_decodes_to_10g() {
		// Cable VDO with bits 2..0 == 0b010
		let vdo: UInt32 = 0x00000002
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .gen10g)
		XCTAssertEqual(tier.bucketLabel, "10G")
	}

	/// Speed bits 3 MUST default to .gen20to40g (value-3 ambiguity contract).
	/// PD revision is unknown at this layer; the combined bucket is correct.
	func test_speed_bits3_defaults_to_20to40g() {
		// Cable VDO with bits 2..0 == 0b011
		let vdo: UInt32 = 0x00000003
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .gen20to40g,
			"value 3 must default to gen20to40g until step-3 spike proves PD-revision split")
		XCTAssertEqual(tier.bucketLabel, "20-40G")
	}

	/// Speed bits 4 (80 Gbps) -> .gen80g and bucket label "80G".
	func test_speed_bits4_decodes_to_80g() {
		// Cable VDO with bits 2..0 == 0b100
		let vdo: UInt32 = 0x00000004
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .gen80g)
		XCTAssertEqual(tier.bucketLabel, "80G")
	}

	/// Speed bits 5 is out-of-range -> .unknown (never trap).
	func test_speed_bits5_is_unknown() {
		// Cable VDO with bits 2..0 == 0b101 (reserved by PD spec)
		let vdo: UInt32 = 0x00000005
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .unknown)
	}

	/// Speed bits 7 (all high) is also unknown; confirms upper range is guarded.
	func test_speed_bits7_is_unknown() {
		// Cable VDO with bits 2..0 == 0b111 (out of range)
		let vdo: UInt32 = 0x00000007
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .unknown)
	}

	/// High bits in the VDO do not affect the low-3-bit speed decode.
	func test_speed_decode_ignores_high_bits() {
		// Upper bits set, speed bits == 0b010 (10G)
		let vdo: UInt32 = 0xFFFFFF02
		let tier = EMarker.decodeSpeed(cableVDO: vdo)
		XCTAssertEqual(tier, .gen10g)
	}

	// MARK: Current rating decode

	/// Current bits 0 -> .usbDefault.
	func test_current_bits0_is_usb_default() {
		// bits 6..5 == 0b00
		let vdo: UInt32 = 0x00000000
		let current = EMarker.decodeCurrent(cableVDO: vdo)
		XCTAssertEqual(current, .usbDefault)
	}

	/// Current bits 1 -> .threeAmp.
	func test_current_bits1_is_three_amp() {
		// bits 6..5 == 0b01, i.e. bit 5 set
		let vdo: UInt32 = 0x00000020
		let current = EMarker.decodeCurrent(cableVDO: vdo)
		XCTAssertEqual(current, .threeAmp)
	}

	/// Current bits 2 -> .fiveAmp.
	func test_current_bits2_is_five_amp() {
		// bits 6..5 == 0b10, i.e. bit 6 set
		let vdo: UInt32 = 0x00000040
		let current = EMarker.decodeCurrent(cableVDO: vdo)
		XCTAssertEqual(current, .fiveAmp)
	}

	/// Current bits 3 (reserved) -> .unknown; never trap.
	func test_current_bits3_is_unknown() {
		// bits 6..5 == 0b11, i.e. bits 6 and 5 both set
		let vdo: UInt32 = 0x00000060
		let current = EMarker.decodeCurrent(cableVDO: vdo)
		XCTAssertEqual(current, .unknown)
	}

	// MARK: Product type decode from ID Header VDO

	/// UFP bits == 3 -> passive cable.
	func test_product_type_bits3_is_passive() {
		// UFP field bits 29..27 == 0b011 -> passiveCable
		// 3 << 27 = 0x18000000
		let idHeader: UInt32 = 0x18000000
		let productType = EMarker.decodeProductType(idHeaderVDO: idHeader)
		XCTAssertEqual(productType, .passive)
	}

	/// UFP bits == 4 -> active cable.
	func test_product_type_bits4_is_active() {
		// UFP field bits 29..27 == 0b100 -> activeCable
		// 4 << 27 = 0x20000000
		let idHeader: UInt32 = 0x20000000
		let productType = EMarker.decodeProductType(idHeaderVDO: idHeader)
		XCTAssertEqual(productType, .active)
	}

	/// UFP bits == 0 (undefined) -> .unknown.
	func test_product_type_bits0_is_unknown() {
		let idHeader: UInt32 = 0x00000000
		let productType = EMarker.decodeProductType(idHeaderVDO: idHeader)
		XCTAssertEqual(productType, .unknown)
	}

	// MARK: Vendor ID decode

	/// Low 16 bits of ID Header VDO are the vendor ID.
	func test_vendor_id_decoded_from_low_16_bits() {
		// VID = 0x05AC (Apple), in the low 16 bits
		let idHeader: UInt32 = 0x000005AC
		let vid = EMarker.decodeVendorID(idHeaderVDO: idHeader)
		XCTAssertEqual(vid, 0x05AC)
	}

	/// High bits do not bleed into the vendor ID.
	func test_vendor_id_ignores_high_bits() {
		// All upper bits set, VID = 0x1234
		let idHeader: UInt32 = 0xFFFF1234
		let vid = EMarker.decodeVendorID(idHeaderVDO: idHeader)
		XCTAssertEqual(vid, 0x1234)
	}

	// MARK: Convenience full decode

	/// Convenience decode produces correct CableInfo from both VDOs.
	func test_full_decode_produces_correct_cable_info() {
		// Speed bits == 2 (10G), current bits 6..5 == 0b01 (3A)
		// Combined: 0b01_000010 = 0x22
		let cableVDO: UInt32 = 0x00000022
		// UFP == 3 (passive), VID == 0x05AC
		let idHeader: UInt32 = 0x180005AC
		let info = EMarker.decode(cableVDO: cableVDO, idHeaderVDO: idHeader)
		XCTAssertEqual(info.speedTier, .gen10g)
		XCTAssertEqual(info.productType, .passive)
		XCTAssertEqual(info.current, .threeAmp)
		XCTAssertEqual(info.vendorID, 0x05AC)
	}

	// MARK: CableSpeedTier bucket labels

	/// All defined tiers have the expected bucket label strings.
	func test_all_speed_tier_bucket_labels() {
		XCTAssertEqual(CableSpeedTier.usb2.bucketLabel, "USB2")
		XCTAssertEqual(CableSpeedTier.gen5g.bucketLabel, "5G")
		XCTAssertEqual(CableSpeedTier.gen10g.bucketLabel, "10G")
		XCTAssertEqual(CableSpeedTier.gen20to40g.bucketLabel, "20-40G")
		XCTAssertEqual(CableSpeedTier.gen80g.bucketLabel, "80G")
		XCTAssertEqual(CableSpeedTier.unknown.bucketLabel, "UNKNOWN")
	}
}
