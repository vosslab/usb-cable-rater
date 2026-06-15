import XCTest
import Foundation
@testable import CableRater

/// XCTest coverage for the pure IOKitCableSource.parseCableInfo function.
///
/// These tests drive the parser with synthetic Metadata dictionaries (a dict
/// with a VDOs array of little-endian 4-byte Data blobs) so no hardware is
/// required. The IOKit enumeration and notification paths are exercised only on
/// real services and are out of scope for unit tests.
final class ProbeTests: XCTestCase {

	//============================================
	// MARK: Helpers
	//============================================

	/// Pack a UInt32 VDO into a 4-byte little-endian Data, the way IOKit stores
	/// each VDO in the Metadata "VDOs" array.
	private func vdoData(_ value: UInt32) -> Data {
		var little = value.littleEndian
		let data = withUnsafeBytes(of: &little) { Data($0) }
		return data
	}

	/// Build a read closure over a synthetic Metadata dictionary, mirroring the
	/// production closure that reads IOKit properties by key.
	private func reader(metadata: [String: Any]?) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			if key == "Metadata" {
				return metadata
			}
			return nil
		}
		return read
	}

	//============================================
	// MARK: Speed-tier decode from a Cable VDO
	//============================================

	/// A 40G-class cable: Cable VDO speed bits 2..0 == 3 -> gen20to40g.
	func test_parse_40g_class_cable_vdo() {
		// ID Header (VDO[0]): UFP == 3 (passive), VID == 0x05AC.
		let idHeader: UInt32 = 0x180005AC
		// Cert Stat (VDO[1]) and Product VDO (VDO[2]) are present but unused.
		// Cable VDO (VDO[3]): speed bits == 3, current bits 6..5 == 0b10 (5A).
		// 0b10_00011 = 0x43.
		let cableVDO: UInt32 = 0x00000043
		let metadata: [String: Any] = [
			"VID": 0x05AC,
			"PID": 0x0001,
			"Product Type": 3,
			"VDOs": [
				vdoData(idHeader),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(cableVDO),
			],
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNotNil(info)
		XCTAssertEqual(info?.speedTier, .gen20to40g)
		XCTAssertEqual(info?.speedTier.bucketLabel, "20-40G")
		XCTAssertEqual(info?.current, .fiveAmp)
		XCTAssertEqual(info?.productType, .passive)
		XCTAssertEqual(info?.vendorID, 0x05AC)
		// rawCableVDO must equal the Cable VDO word fed in (VDO[3]).
		XCTAssertEqual(info?.rawCableVDO, cableVDO)
		// productID must equal the PID from the Metadata dictionary.
		XCTAssertEqual(info?.productID, 0x0001)
	}

	/// A 10G cable: Cable VDO speed bits 2..0 == 2 -> gen10g.
	func test_parse_10g_cable_vdo() {
		// ID Header: UFP == 4 (active), VID == 0x1234.
		let idHeader: UInt32 = 0x20001234
		// Cable VDO: speed bits == 2 (10G), current bits 6..5 == 0b01 (3A).
		// 0b01_00010 = 0x22.
		let cableVDO: UInt32 = 0x00000022
		let metadata: [String: Any] = [
			"VID": 0x1234,
			"PID": 0x5678,
			"Product Type": 4,
			"VDOs": [
				vdoData(idHeader),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(cableVDO),
			],
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNotNil(info)
		XCTAssertEqual(info?.speedTier, .gen10g)
		XCTAssertEqual(info?.speedTier.bucketLabel, "10G")
		XCTAssertEqual(info?.current, .threeAmp)
		XCTAssertEqual(info?.productType, .active)
		XCTAssertEqual(info?.vendorID, 0x1234)
		// rawCableVDO must equal the Cable VDO word fed in (VDO[3]).
		XCTAssertEqual(info?.rawCableVDO, cableVDO)
		// productID must equal the PID from the Metadata dictionary (0x5678).
		XCTAssertEqual(info?.productID, 0x5678)
	}

	//============================================
	// MARK: Sparse and zeroed VDO arrays
	//============================================

	/// A sparse e-marker with only the ID Header VDO present (no Cable VDO at
	/// index 3). The missing Cable VDO is treated as all-zero, decoding to the
	/// usb2 / usbDefault buckets rather than failing.
	func test_parse_sparse_vdos_only_id_header() {
		// ID Header: UFP == 3 (passive), VID == 0x0BDA.
		let idHeader: UInt32 = 0x18000BDA
		let metadata: [String: Any] = [
			"VID": 0x0BDA,
			"PID": 0x0000,
			"Product Type": 3,
			"VDOs": [
				vdoData(idHeader),
			],
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNotNil(info)
		// No Cable VDO -> all-zero -> usb2 / usbDefault.
		XCTAssertEqual(info?.speedTier, .usb2)
		XCTAssertEqual(info?.speedTier.bucketLabel, "USB2")
		XCTAssertEqual(info?.current, .usbDefault)
		XCTAssertEqual(info?.productType, .passive)
		XCTAssertEqual(info?.vendorID, 0x0BDA)
	}

	/// A fully zeroed VDO set: ID Header and Cable VDO both zero. Decodes to
	/// usb2 / usbDefault / unknown product type / vendor 0 without trapping.
	func test_parse_zeroed_vdos() {
		let metadata: [String: Any] = [
			"VID": 0x0000,
			"PID": 0x0000,
			"Product Type": 0,
			"VDOs": [
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(0x00000000),
			],
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNotNil(info)
		XCTAssertEqual(info?.speedTier, .usb2)
		XCTAssertEqual(info?.current, .usbDefault)
		XCTAssertEqual(info?.productType, .unknown)
		XCTAssertEqual(info?.vendorID, 0x0000)
	}

	//============================================
	// MARK: Missing-data nil cases
	//============================================

	/// No Metadata property at all -> nil (not a decodable e-marker service).
	func test_parse_missing_metadata_returns_nil() {
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: nil))
		XCTAssertNil(info)
	}

	/// Metadata present but with no VDOs array -> nil (no ID Header VDO).
	func test_parse_metadata_without_vdos_returns_nil() {
		let metadata: [String: Any] = [
			"VID": 0x05AC,
			"PID": 0x0001,
			"Product Type": 3,
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNil(info)
	}

	/// Metadata with an empty VDOs array -> nil (no ID Header VDO at index 0).
	func test_parse_empty_vdos_array_returns_nil() {
		let metadata: [String: Any] = [
			"VDOs": [Data](),
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNil(info)
	}

	/// An ID Header VDO blob shorter than 4 bytes cannot be decoded -> nil.
	func test_parse_truncated_id_header_returns_nil() {
		let metadata: [String: Any] = [
			"VDOs": [
				Data([0x01, 0x02]),
			],
		]
		let info = IOKitCableSource.parseCableInfo(read: reader(metadata: metadata))
		XCTAssertNil(info)
	}

	//============================================
	// MARK: describeService -- DetectedCable wrapper
	//============================================

	/// A service whose Metadata is absent describes as a DetectedCable with
	/// info == nil and zero diagnostic counts (the silent-plug signature). The
	/// service is NOT dropped; it carries its class and registry ID.
	func test_describe_empty_metadata_service_keeps_nil_info() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 0x100080C39,
			read: reader(metadata: nil)
		)
		XCTAssertNil(detected.info, "no Metadata must decode to nil info, not drop")
		XCTAssertEqual(detected.serviceClass, "IOPortTransportComponentCCUSBPDSOP")
		XCTAssertEqual(detected.registryID, 0x100080C39)
		XCTAssertEqual(detected.metadataKeyCount, 0, "absent Metadata -> 0 keys")
		XCTAssertEqual(detected.vdoCount, 0, "absent Metadata -> 0 VDOs")
	}

	/// A service with an empty Metadata dictionary (the real non-e-marked cable
	/// case observed on this Mac) also describes as info == nil with zero counts.
	func test_describe_empty_dict_metadata_keeps_nil_info() {
		let metadata: [String: Any] = [:]
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 0xABCD,
			read: reader(metadata: metadata)
		)
		XCTAssertNil(detected.info, "empty Metadata must decode to nil info")
		XCTAssertEqual(detected.metadataKeyCount, 0)
		XCTAssertEqual(detected.vdoCount, 0)
	}

	/// A decodable service describes with a populated info and correct counts.
	func test_describe_decodable_service_populates_info_and_counts() {
		let idHeader: UInt32 = 0x180005AC
		let cableVDO: UInt32 = 0x00000043
		let metadata: [String: Any] = [
			"VID": 0x05AC,
			"PID": 0x0001,
			"VDOs": [
				vdoData(idHeader),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(cableVDO),
			],
		]
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 0x42,
			read: reader(metadata: metadata)
		)
		XCTAssertNotNil(detected.info, "a decodable service must carry info")
		XCTAssertEqual(detected.info?.speedTier, .gen20to40g)
		XCTAssertEqual(detected.vdoCount, 4, "four VDO blobs were present")
		XCTAssertEqual(detected.metadataKeyCount, 3, "three Metadata keys present")
	}

	//============================================
	// MARK: nil-info DetectedCable rendering path
	//============================================

	/// A DetectedCable with info == nil rates and renders as the UNKNOWN /
	/// no-emarker numbered line, proving a non-e-marked plug now produces output
	/// instead of being silently dropped.
	func test_nil_info_detected_renders_unknown_line() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 0x7,
			read: reader(metadata: nil)
		)
		// The CLI rates a detected service via its (possibly nil) info.
		let cableVerdict = verdict(for: detected.info, catalog: Catalog.shared)
		let text = renderCableTextStyled(cableVerdict, prefix: "cable 1: ", styled: false)
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(String(lines[0]), "cable 1: UNKNOWN", "nil info -> UNKNOWN label")
		XCTAssertTrue(String(lines[1]).contains("[no e-marker]"), "no-e-marker tag: \(text)")
	}
}
