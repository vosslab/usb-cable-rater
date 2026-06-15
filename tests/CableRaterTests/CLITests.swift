import XCTest
@testable import CableRater

/// XCTest coverage for the CLI argument parsing, usage text, and the raw IOKit
/// debug diagnostic line. The live IOKit watch loop is hardware-bound and out of
/// scope for unit tests; these cover only the pure, deterministic surface.
final class CLITests: XCTestCase {

	//============================================
	// MARK: Argument parsing -- --debug / -d
	//============================================

	/// --debug sets the debug flag and leaves the other flags off.
	func test_parse_long_debug_flag() {
		let result = parseCLI(["--debug"])
		guard case let .options(options) = result else {
			XCTFail("expected options, got \(result)")
			return
		}
		XCTAssertTrue(options.debug, "--debug must set debug")
		XCTAssertFalse(options.once)
		XCTAssertFalse(options.json)
	}

	/// -d is the short form of --debug.
	func test_parse_short_debug_flag() {
		let result = parseCLI(["-d"])
		guard case let .options(options) = result else {
			XCTFail("expected options, got \(result)")
			return
		}
		XCTAssertTrue(options.debug, "-d must set debug")
	}

	/// --debug composes with other flags in any order.
	func test_parse_debug_with_json_and_once() {
		let result = parseCLI(["--json", "-d", "--once"])
		guard case let .options(options) = result else {
			XCTFail("expected options, got \(result)")
			return
		}
		XCTAssertTrue(options.debug)
		XCTAssertTrue(options.json)
		XCTAssertTrue(options.once)
	}

	/// An unknown flag still fails loud (debug did not loosen parsing).
	func test_parse_unknown_flag_errors() {
		let result = parseCLI(["--nope"])
		guard case let .error(message) = result else {
			XCTFail("expected error, got \(result)")
			return
		}
		XCTAssertTrue(message.contains("--nope"), "error names the bad flag: \(message)")
	}

	//============================================
	// MARK: Usage text documents --debug
	//============================================

	/// The help text documents both the long and short debug flags.
	func test_usage_documents_debug_flag() {
		let text = usageText()
		XCTAssertTrue(text.contains("--debug"), "usage must mention --debug: \(text)")
		XCTAssertTrue(text.contains("-d"), "usage must mention -d: \(text)")
	}

	//============================================
	// MARK: Debug diagnostic line
	//============================================

	/// A matched event with a fully decoded e-marker reports the class, hex id,
	/// nonzero counts, and the decoded speed tier raw value.
	func test_debug_line_matched_decoded() {
		let info = CableInfo(
			speedTier: .gen10g,
			productType: .passive,
			current: .threeAmp,
			vendorID: 0x05AC,
			rawCableVDO: 0x22,
			productID: 0x0001
		)
		let detected = DetectedCable(
			info: info,
			serviceClass: "IOPortTransportComponentCCUSBPDSOPp",
			registryID: 0x100080C39,
			vdoCount: 4,
			metadataKeyCount: 3,
			endpoint: .sopPrime,
			parentPortNumber: DetectedCable.unknownPortNumber,
			parentPortType: 0
		)
		let line = debugLine(for: detected, matched: true)
		XCTAssertTrue(line.hasPrefix("[debug] matched"), "matched prefix: \(line)")
		XCTAssertTrue(line.contains("class=IOPortTransportComponentCCUSBPDSOPp"))
		XCTAssertTrue(line.contains("id=0x100080c39"), "hex registry id: \(line)")
		XCTAssertTrue(line.contains("metadataKeys=3"))
		XCTAssertTrue(line.contains("vdos=4"))
		XCTAssertTrue(line.contains("decoded=gen10g"))
	}

	/// The silent-plug signature: a matched non-e-marked service reports zero
	/// counts and decoded=nil. This is exactly what --debug surfaces for the
	/// previously-dropped events.
	func test_debug_line_matched_nil_decode() {
		let detected = DetectedCable(
			info: nil,
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 0x100080C39,
			vdoCount: 0,
			metadataKeyCount: 0,
			endpoint: .sop,
			parentPortNumber: DetectedCable.unknownPortNumber,
			parentPortType: 0
		)
		let line = debugLine(for: detected, matched: true)
		XCTAssertTrue(line.hasPrefix("[debug] matched"), "silent-plug must use matched prefix: \(line)")
		XCTAssertTrue(line.contains("class=IOPortTransportComponentCCUSBPDSOP"),
		              "silent-plug line contains service class: \(line)")
		XCTAssertTrue(line.contains("metadataKeys=0"), "zero metadataKeys for no-VDO node: \(line)")
		XCTAssertTrue(line.contains("vdos=0"), "zero vdos for no-VDO node: \(line)")
		XCTAssertTrue(line.contains("decoded=nil"), "nil decode for a non-emarked SOP: \(line)")
	}

	/// A terminated event uses the "terminated" label with the same fields.
	func test_debug_line_terminated() {
		let detected = DetectedCable(
			info: nil,
			serviceClass: "IOPortTransportComponentCCUSBPDSOP",
			registryID: 0xABCD,
			vdoCount: 0,
			metadataKeyCount: 0,
			endpoint: .sop,
			parentPortNumber: DetectedCable.unknownPortNumber,
			parentPortType: 0
		)
		let line = debugLine(for: detected, matched: false)
		XCTAssertTrue(line.hasPrefix("[debug] terminated"), "terminated prefix: \(line)")
		XCTAssertTrue(line.contains("id=0xabcd"))
		XCTAssertTrue(line.contains("decoded=nil"))
	}

	//============================================
	// MARK: --debug raw per-port fields (portVerdictDebugLine)
	//============================================

	/// A rated e-marker port's --debug line shows the raw fields an advanced user
	/// needs: the matched backend source, the occupancy avenue, the portKey, the
	/// SOP-present flag, and the raw rawCableVDO / productID / vendorID hex plus the
	/// decoded speed tier.
	func test_port_verdict_debug_line_emarker_raw_fields() {
		// A decoded 10G cable: VID 0x05AC, PID 0x720A, raw Cable VDO 0x110A2644.
		let cable = CableInfo(
			speedTier: .gen10g,
			productType: .passive,
			current: .threeAmp,
			vendorID: 0x05AC,
			rawCableVDO: 0x110A2644,
			productID: 0x720A
		)
		let rated = verdict(for: cable, catalog: Catalog.shared)
		let pv = PortVerdict(
			portNumber: 3,
			portKey: "2/3",
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .connectionActive,
			sopServicePresent: true
		)
		let line = portVerdictDebugLine(for: pv)
		XCTAssertTrue(line.hasPrefix("[debug] port 3"), "port-led debug prefix: \(line)")
		XCTAssertTrue(line.contains("source=sopIdentity"), "matched backend source: \(line)")
		XCTAssertTrue(line.contains("occupancy=connectionActive"), "occupancy avenue: \(line)")
		XCTAssertTrue(line.contains("portKey=2/3"), "the correlation portKey: \(line)")
		XCTAssertTrue(line.contains("sopPresent=true"), "SOP node present flag: \(line)")
		XCTAssertTrue(line.contains("cableVDO=0x110A2644"), "raw Cable VDO hex: \(line)")
		XCTAssertTrue(line.contains("productID=0x720A"), "raw product ID hex: \(line)")
		XCTAssertTrue(line.contains("vendorID=0x05AC"), "raw vendor ID hex: \(line)")
		XCTAssertTrue(line.contains("endpoint=SOP'"), "SOP endpoint named: \(line)")
		XCTAssertTrue(line.contains("decoded=gen10g"), "decoded speed tier: \(line)")
	}

	/// An occupied port with no readable e-marker prints the occupancy fields and
	/// the honest decoded=nil signature, with no raw hex fields.
	func test_port_verdict_debug_line_no_emarker_is_nil() {
		let rated = verdict(for: nil, catalog: Catalog.shared)
		let pv = PortVerdict(
			portNumber: 3,
			portKey: "2/3",
			verdict: rated,
			backendSource: .portPoll,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		let line = portVerdictDebugLine(for: pv)
		XCTAssertTrue(line.contains("source=portPoll"), "poll backend source: \(line)")
		XCTAssertTrue(line.contains("sopPresent=false"), "no SOP node: \(line)")
		XCTAssertTrue(line.contains("decoded=nil"), "no readable e-marker: \(line)")
		XCTAssertFalse(line.contains("cableVDO=0x"), "no raw VDO when no e-marker: \(line)")
		XCTAssertFalse(line.contains("vendorID=0x"), "no raw vendor when no e-marker: \(line)")
	}

	/// The SOP endpoint is surfaced for a port whose e-marker came from an SOP'
	/// node (the near-end cable e-marker headline source). The debug line's
	/// occupancy/source fields name the PD-identity avenue.
	func test_port_verdict_debug_line_sop_identity_source() {
		let cable = CableInfo(
			speedTier: .gen5g,
			productType: .passive,
			current: .threeAmp,
			vendorID: 0x1234,
			rawCableVDO: 0x21,
			productID: 0x0009
		)
		let rated = verdict(for: cable, catalog: Catalog.shared)
		// A port admitted by the PD-identity avenue (ConnectionActive false/nil):
		// occupancySource is pdIdentity, backendSource is sopIdentity.
		let pv = PortVerdict(
			portNumber: 1,
			portKey: "2/1",
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .pdIdentity,
			sopServicePresent: true
		)
		let line = portVerdictDebugLine(for: pv)
		XCTAssertTrue(line.contains("source=sopIdentity"), "SOP identity backend: \(line)")
		XCTAssertTrue(line.contains("occupancy=pdIdentity"), "PD-identity avenue: \(line)")
		XCTAssertTrue(line.contains("decoded=gen5g"))
	}
}
