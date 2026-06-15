import XCTest
import Foundation
@testable import CableRater

/// XCTest coverage for the PD-identity per-port correlation extended onto
/// IOKitCableSource (the WP-M1c PD-identity watcher port).
///
/// These tests drive the pure correlation core (`describeService`,
/// `parentPortIdentity`, `decodePort(forPortNumber:from:)`) with synthetic
/// service property dictionaries shaped like the captured SOP node at
/// /tmp/sop_node.plist (ParentPortNumber / ParentBuiltInPortNumber == 3, type 2
/// USB-C, empty Metadata). No hardware is required: the IOKit enumeration and
/// notification paths are exercised only on real services and are out of scope.
final class PdIdentityTests: XCTestCase {

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

	/// Build a read closure over a synthetic service property dictionary, mirroring
	/// the production closure that reads IOKit properties by key. Any key not in
	/// the dictionary reads as nil, exactly like an absent IOKit property.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// A populated SOP' service for `port`: ID Header (passive, VID 0x05AC) plus a
	/// 10G Cable VDO, with the parent-port keys shaped like the captured node.
	private func sopPrime10GProperties(port: Int) -> [String: Any] {
		// ID Header (VDO[0]): UFP == 3 (passive), VID == 0x05AC.
		let idHeader: UInt32 = 0x180005AC
		// Cable VDO (VDO[3]): speed bits == 2 (10G), current bits 6..5 == 0b01 (3A).
		let cableVDO: UInt32 = 0x00000022
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
		let properties: [String: Any] = [
			"Metadata": metadata,
			"ParentBuiltInPortNumber": port,
			"ParentBuiltInPortType": 2,
			"ParentPortNumber": port,
			"ParentPortType": 2,
		]
		return properties
	}

	/// The captured-shape SOP partner node for `port`: empty Metadata, both
	/// parent-port keys present (mirrors /tmp/sop_node.plist exactly).
	private func sopEmptyMetadataProperties(port: Int) -> [String: Any] {
		let properties: [String: Any] = [
			"Metadata": [String: Any](),
			"ParentBuiltInPortNumber": port,
			"ParentBuiltInPortType": 2,
			"ParentPortNumber": port,
			"ParentPortType": 2,
		]
		return properties
	}

	//============================================
	// MARK: Reads ParentPortNumber from a SOP node
	//============================================

	/// describeService reads the captured node's ParentPortNumber and port type,
	/// and classifies its SOP endpoint from the IOKit class name.
	func test_describe_reads_parent_port_number_and_endpoint() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 4295494713,
			read: reader(sopEmptyMetadataProperties(port: 3))
		)
		// The port number is read from the captured-shape parent keys (== 3).
		XCTAssertEqual(detected.parentPortNumber, 3, "ParentPortNumber must read 3")
		XCTAssertEqual(detected.parentPortType, 2, "USB-C port type == 2")
		// The SOP partner class classifies as the SOP endpoint.
		XCTAssertEqual(detected.endpoint, .sop)
	}

	/// The BuiltIn parent key wins over the plain key, matching whatcable's
	/// priority, so PD identity and port-state resolve to the same physical port.
	func test_parent_port_builtin_key_takes_priority() {
		let properties: [String: Any] = [
			"Metadata": [String: Any](),
			"ParentBuiltInPortNumber": 3,
			"ParentPortNumber": 9,
		]
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 1,
			read: reader(properties)
		)
		XCTAssertEqual(detected.parentPortNumber, 3, "BuiltIn key must win over plain")
	}

	/// A node with neither parent-port key reads the unknown-port sentinel, so
	/// correlation skips it rather than matching port 0 by accident.
	func test_parent_port_absent_reads_unknown_sentinel() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 1,
			read: reader(["Metadata": [String: Any]()])
		)
		XCTAssertEqual(detected.parentPortNumber, DetectedCable.unknownPortNumber)
	}

	//============================================
	// MARK: Empty Metadata -> no readable e-marker (clean)
	//============================================

	/// The captured Port 3 case: an SOP node is present with empty Metadata. The
	/// per-port identity reports the SOP node is present but carries no readable
	/// e-marker -- a clean result (info nil, no crash, no error).
	func test_empty_metadata_is_no_readable_emarker_clean() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 4295494713,
			read: reader(sopEmptyMetadataProperties(port: 3))
		)
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: [detected]
		)
		// Clean "detected, no readable e-marker": present but undecoded.
		XCTAssertTrue(identity.sopServicePresent, "SOP node present for the port")
		XCTAssertNil(identity.info, "empty Metadata -> no decoded e-marker")
		XCTAssertFalse(identity.hasReadableEMarker, "no readable e-marker for port 3")
		XCTAssertEqual(identity.portNumber, 3)
		XCTAssertEqual(identity.portKey, "2/3", "type/number join key")
	}

	/// A port with no SOP node at all is distinct from an empty-Metadata node:
	/// sopServicePresent is false, so the coordinator can keep an invisible port
	/// silent instead of rating it "port active".
	func test_no_sop_node_for_port_is_not_present() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 1,
			read: reader(sopEmptyMetadataProperties(port: 3))
		)
		// Ask about port 1, which has no SOP node in this snapshot.
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 1, from: [detected]
		)
		XCTAssertFalse(identity.sopServicePresent, "no SOP node for port 1")
		XCTAssertNil(identity.info)
		XCTAssertFalse(identity.hasReadableEMarker)
		// The number half is still recovered from the requested key.
		XCTAssertEqual(identity.portNumber, 1)
	}

	//============================================
	// MARK: Correlate SOP'-with-VDO to the matching port
	//============================================

	/// An SOP' node carrying a real Cable VDO correlates to its ParentPortNumber
	/// and decodes the e-marker as that port's headline rating.
	func test_correlate_sop_prime_with_vdo_to_port() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 42,
			read: reader(sopPrime10GProperties(port: 3))
		)
		// The SOP' endpoint and port number are read off the service.
		XCTAssertEqual(detected.endpoint, .sopPrime)
		XCTAssertEqual(detected.parentPortNumber, 3)
		// Correlate to port 3 (portKey "2/3"): the e-marker decodes as headline.
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: [detected]
		)
		XCTAssertTrue(identity.sopServicePresent)
		XCTAssertTrue(identity.hasReadableEMarker, "SOP' VDO must decode")
		XCTAssertEqual(identity.info?.speedTier, .gen10g)
		XCTAssertEqual(identity.info?.speedTier.bucketLabel, "10G")
		XCTAssertEqual(identity.info?.vendorID, 0x05AC)
		XCTAssertEqual(identity.portKey, "2/3")
	}

	/// The portKey is the active join key on this M1 hardware: a node read off the
	/// captured-shape keys exposes "<type>/<number>" matching the controller.
	func test_detected_node_exposes_type_number_port_key() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 42,
			read: reader(sopPrime10GProperties(port: 3))
		)
		XCTAssertEqual(detected.portKey, "2/3", "type 2, number 3")
	}

	/// The same SOP' node does not bleed into a different port number.
	func test_sop_prime_does_not_correlate_to_other_port() {
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 42,
			read: reader(sopPrime10GProperties(port: 3))
		)
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 1, from: [detected]
		)
		XCTAssertFalse(identity.sopServicePresent, "node is on port 3, not port 1")
		XCTAssertNil(identity.info)
	}

	//============================================
	// MARK: SOP' is the headline; SOP'' never overwrites it
	//============================================

	/// SOP'' (far-end) is discovered and matched, but when an SOP' (near-end)
	/// e-marker is present for the same port, SOP' supplies the headline rating
	/// and SOP'' does not overwrite it (mirrors whatcable's SOP'-first handling).
	func test_sop_double_prime_does_not_overwrite_sop_prime_headline() {
		// SOP' on port 3: 10G near-end e-marker (the intended headline).
		let sopPrime = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 42,
			read: reader(sopPrime10GProperties(port: 3))
		)
		// SOP'' on port 3: a different (80G) far-end e-marker that must NOT win.
		// Cable VDO speed bits == 4 -> gen80g.
		let farMetadata: [String: Any] = [
			"VDOs": [
				vdoData(0x180005AC),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(0x00000004),
			],
		]
		let farProperties: [String: Any] = [
			"Metadata": farMetadata,
			"ParentBuiltInPortNumber": 3,
			"ParentBuiltInPortType": 2,
			"ParentPortNumber": 3,
			"ParentPortType": 2,
		]
		let sopDoublePrime = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPpp",
			registryID: 43,
			read: reader(farProperties)
		)
		XCTAssertEqual(sopDoublePrime.endpoint, .sopDoublePrime)
		// Both nodes for the same port; SOP' must supply the headline.
		let identity = IOKitCableSource.decodePort(
			forPortType: 2,
			portNumber: 3,
			from: [sopDoublePrime, sopPrime]
		)
		XCTAssertEqual(identity.info?.speedTier, .gen10g, "SOP' headline, not SOP'' 80G")
	}

	/// When no SOP' is present but an SOP'' e-marker is, SOP'' is used as a
	/// fallback so a far-end-only e-marker is not dropped.
	func test_sop_double_prime_used_when_no_sop_prime() {
		// SOP'' on port 3 with a decodable 80G e-marker, no SOP' present.
		let farMetadata: [String: Any] = [
			"VDOs": [
				vdoData(0x180005AC),
				vdoData(0x00000000),
				vdoData(0x00000000),
				vdoData(0x00000004),
			],
		]
		let farProperties: [String: Any] = [
			"Metadata": farMetadata,
			"ParentBuiltInPortNumber": 3,
			"ParentBuiltInPortType": 2,
			"ParentPortNumber": 3,
			"ParentPortType": 2,
		]
		let sopDoublePrime = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPpp",
			registryID: 43,
			read: reader(farProperties)
		)
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: [sopDoublePrime]
		)
		XCTAssertTrue(identity.hasReadableEMarker, "SOP'' fallback decodes")
		XCTAssertEqual(identity.info?.speedTier, .gen80g)
	}

	/// The SOP partner node is not used as the cable e-marker source: a populated
	/// SOP (non-prime) node does not supply the cable headline.
	func test_sop_partner_node_is_not_the_cable_headline() {
		// A populated SOP (non-prime) node on port 3. It is the port partner, not
		// the cable e-marker, so it must not become the headline.
		var partnerProperties = sopPrime10GProperties(port: 3)
		// Reuse the populated metadata but at the SOP (partner) endpoint class.
		let detected = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 7,
			read: reader(partnerProperties)
		)
		XCTAssertEqual(detected.endpoint, .sop)
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: [detected]
		)
		// The SOP node is present (a cable is at the port) but it is not used as
		// the cable e-marker headline, so info is nil.
		XCTAssertTrue(identity.sopServicePresent)
		XCTAssertNil(identity.info, "SOP partner node is not the cable headline")
		// Silence the unused-mutation warning by reading the var once.
		partnerProperties.removeAll()
	}

	//============================================
	// MARK: Captured-shape correlation across ports
	//============================================

	/// A realistic snapshot: port 2 has an SOP' 10G cable, port 3 has only an
	/// empty-Metadata SOP node. Each port correlates to its own identity.
	func test_mixed_snapshot_correlates_each_port_independently() {
		let port2Prime = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 100,
			read: reader(sopPrime10GProperties(port: 2))
		)
		let port3Empty = IOKitCableSource.describeService(
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 4295494713,
			read: reader(sopEmptyMetadataProperties(port: 3))
		)
		let snapshot = [port2Prime, port3Empty]

		let id2 = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 2, from: snapshot
		)
		XCTAssertEqual(id2.info?.speedTier, .gen10g, "port 2 has the SOP' cable")

		let id3 = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: snapshot
		)
		XCTAssertTrue(id3.sopServicePresent, "port 3 has an SOP node")
		XCTAssertNil(id3.info, "port 3 has no readable e-marker")
		XCTAssertFalse(id3.hasReadableEMarker)
	}
}
