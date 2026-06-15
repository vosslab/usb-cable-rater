import XCTest
import Foundation
@testable import CableRater

/// End-to-end pipeline coverage for a populated SOP' Cable VDO: decode -> rate ->
/// render, driven entirely from the populated prime fixtures, no live IOKit.
///
/// On the M1 MacBook Pro every observed SOP node carries an EMPTY Metadata dict
/// (the e-marker is only queried once a PD partner negotiates on the far end), so
/// the rating path has only ever been exercised on the `unknown`/no-e-marker case.
/// These tests prove the SAME production pipeline yields a real speed bucket and a
/// correct two-line block when a real SOP' with a populated Cable VDO appears.
///
/// The fixtures (Fixtures/sop_prime_{10g,40g,80g}_port3.plist) carry real Cable
/// VDO words cross-checked against whatcable Tests/WhatCableCoreTests/PDVDOTests.swift:
///   - 40G word 0x2053 == whatcable "Thunderbolt cable 5A 40Gbps"
///     (0b011 | (1<<4) | (2<<5) | (1<<13)); decodes speed bits 2..0 == 3, 5A.
///   - 80G word 0x2644 == whatcable "EPR cable 50V 5A"
///     (0b100 | (2<<5) | (3<<9) | (1<<13)); decodes speed bits 2..0 == 4, 5A.
///   - 10G word 0x2022 (speed bits 2..0 == 2, 3A), the unambiguous Gen2 bucket.
///
/// Each test drives the exact production path:
///   describeService (PD-identity describe) -> decodePort (per-port correlation)
///   -> verdict(for:catalog:) (rating, same call mergeSnapshot uses) -> PortVerdict
///   -> renderPortBlockStyled(styled: false) (two-line default block).
/// `styled: false` keeps the block free of ANSI escapes so the exact text is
/// asserted, matching how a pipe/file/--json capture renders.
final class EMarkerPipelineTests: XCTestCase {

	//============================================
	// MARK: Fixture loading
	//============================================

	/// Load a prime-fixture plist array from the test bundle (same pattern as
	/// FixtureLoadTests / PlugCoordinatorTests), failing the test if missing or
	/// unparseable.
	private func loadFixture(named name: String) -> [[String: Any]] {
		let url = Bundle.module.url(forResource: name, withExtension: nil,
		                            subdirectory: "Fixtures")
			?? Bundle.module.url(forResource: name, withExtension: nil)
		guard let resolved = url else {
			XCTFail("fixture not found in test bundle: \(name)")
			return []
		}
		guard let data = try? Data(contentsOf: resolved) else {
			XCTFail("could not read fixture: \(name)")
			return []
		}
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard let parsed = try? PropertyListSerialization.propertyList(
			from: data, options: [], format: &format
		) as? [[String: Any]] else {
			XCTFail("could not parse fixture array: \(name)")
			return []
		}
		return parsed
	}

	/// Build a read closure over a property dictionary, mirroring the production
	/// per-key IOKit reader. An absent key reads nil, exactly like IOKit.
	private func reader(_ properties: [String: Any]) -> (String) -> Any? {
		func read(_ key: String) -> Any? {
			return properties[key]
		}
		return read
	}

	/// Turn the single entry of a prime fixture into a `DetectedCable` via the
	/// production describe path, reading the IOObjectClass and registry ID straight
	/// off the captured node shape.
	private func detectedCable(fromFixture name: String) -> DetectedCable {
		let entries = loadFixture(named: name)
		XCTAssertEqual(entries.count, 1, "prime fixture \(name) must hold one node")
		let entry = entries.first ?? [:]
		let cls = entry["IOObjectClass"] as? String
			?? "IOPortTransportComponentCCUSBPDSOPp"
		let registryID = UInt64((entry["IORegistryEntryID"] as? Int) ?? 0)
		let detected = IOKitCableSource.describeService(
			serviceClass: cls,
			registryID: registryID,
			read: reader(entry)
		)
		return detected
	}

	/// Run one prime fixture through the full pipeline and return the PortVerdict,
	/// the way `PlugCoordinator.verdictFor` does for a decoded e-marker: correlate
	/// the SOP node to its port, rate the decoded CableInfo, and merge into a
	/// PortVerdict attributed to the SOP identity backend.
	///
	/// Args:
	///   name: the prime fixture filename.
	///
	/// Returns:
	///   The per-port verdict for the decoded SOP' e-marker on Port 3.
	private func portVerdict(fromFixture name: String) -> PortVerdict {
		let detected = detectedCable(fromFixture: name)
		// Per-port correlation by the captured "type/number" key (2/3 == USB-C port 3).
		let identity = IOKitCableSource.decodePort(
			forPortType: 2, portNumber: 3, from: [detected]
		)
		// The real bundled catalog (the production default): a clear or value-3
		// e-marker tier short-circuits in verdict() BEFORE any DB lookup, so the
		// refinement-only catalog stays untouched for all three speeds here. Using
		// Catalog.shared matches the rating-layer tests and the live path.
		let rated = verdict(for: identity.info, catalog: Catalog.shared)
		// Mirror the production merge for a decoded e-marker (PlugSource.verdictFor):
		// SOP-identity backend, ConnectionActive occupancy (Port 3 is the active M1
		// port), and the correlated portKey/number.
		let portVerdict = PortVerdict(
			portNumber: identity.portNumber,
			portKey: identity.portKey,
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .connectionActive,
			sopServicePresent: identity.sopServicePresent
		)
		return portVerdict
	}

	//============================================
	// MARK: 10G (gen10g) -- unambiguous Gen2 bucket
	//============================================

	/// A populated 10G SOP' Cable VDO decodes to gen10g, rates the 10G bucket by
	/// e-marker, and renders the two-line block with the spec detail line.
	func test_pipeline_10g_decodes_rates_and_renders() {
		let detected = detectedCable(fromFixture: "sop_prime_10g_port3.plist")
		// Decode: the SOP' node carries a readable e-marker for the gen10g tier.
		XCTAssertEqual(detected.endpoint, .sopPrime, "10G fixture is the near-end SOP'")
		XCTAssertEqual(detected.info?.speedTier, .gen10g, "speed bits 2..0 == 2 -> gen10g")
		XCTAssertEqual(detected.info?.rawCableVDO, 0x00002022, "10G Cable VDO word")
		// Rate: a clear tier rates the 10G bucket by e-marker, no DB hit.
		let portVerdict = portVerdict(fromFixture: "sop_prime_10g_port3.plist")
		XCTAssertEqual(portVerdict.verdict.tier, .gen10g)
		XCTAssertEqual(portVerdict.verdict.bucketLabel, "10G", "bucket token is 10G")
		XCTAssertEqual(portVerdict.verdict.basis, .emarker, "clear tier rates by e-marker")
		XCTAssertNil(portVerdict.verdict.knownCable, "no DB refinement for a clear tier")
		// Render: the two-line block, headline + spec detail line.
		let block = renderPortBlockStyled(portVerdict, styled: false)
		XCTAssertTrue(block.hasPrefix("Port 3: 10G [e-marker]"),
		              "10G block headline must start with bucket and basis tag")
		XCTAssertTrue(block.contains("10G [e-marker]"), "block contains bucket and basis tag")
		XCTAssertTrue(block.contains("10 Gbps"), "block contains speed phrase")
		XCTAssertTrue(block.contains("3A"), "block contains current rating")
		XCTAssertTrue(block.contains("0x05AC"), "block contains Apple VID")
	}

	//============================================
	// MARK: 20-40G (gen20to40g) -- value-3 ambiguous bucket
	//============================================

	/// A populated 40G SOP' Cable VDO (whatcable Thunderbolt 5A 40Gbps cross-check)
	/// decodes to gen20to40g, rates the 20-40G bucket as e-marker-ambiguous, and
	/// renders the two-line block with the spec detail line.
	func test_pipeline_20to40g_decodes_rates_and_renders() {
		let detected = detectedCable(fromFixture: "sop_prime_40g_port3.plist")
		XCTAssertEqual(detected.endpoint, .sopPrime, "40G fixture is the near-end SOP'")
		XCTAssertEqual(detected.info?.speedTier, .gen20to40g, "speed bits 2..0 == 3 -> gen20to40g")
		XCTAssertEqual(detected.info?.rawCableVDO, 0x00002053,
		               "40G word == whatcable Thunderbolt 5A 40Gbps cross-check")
		let portVerdict = portVerdict(fromFixture: "sop_prime_40g_port3.plist")
		XCTAssertEqual(portVerdict.verdict.tier, .gen20to40g)
		XCTAssertEqual(portVerdict.verdict.bucketLabel, "20-40G", "bucket token is 20-40G")
		XCTAssertEqual(portVerdict.verdict.basis, .emarkerAmbiguous,
		               "value-3 tier rates as e-marker ambiguous (PD revision unknown)")
		XCTAssertNil(portVerdict.verdict.knownCable, "no DB refinement for the value-3 tier")
		let block = renderPortBlockStyled(portVerdict, styled: false)
		XCTAssertTrue(block.hasPrefix("Port 3: 20-40G [e-marker ambiguous]"),
		              "20-40G block headline must start with bucket and ambiguous basis tag")
		XCTAssertTrue(block.contains("20-40G [e-marker ambiguous]"), "block contains bucket and basis tag")
		XCTAssertTrue(block.contains("20-40 Gbps"), "block contains speed phrase")
		XCTAssertTrue(block.contains("5A"), "block contains current rating")
		XCTAssertTrue(block.contains("0x05AC"), "block contains Apple VID")
	}

	//============================================
	// MARK: 80G (gen80g) -- unambiguous Gen4 bucket
	//============================================

	/// A populated 80G SOP' Cable VDO (whatcable EPR cable 50V 5A cross-check)
	/// decodes to gen80g, rates the 80G bucket by e-marker, and renders the two-line
	/// block with the spec detail line. This is the active-cable fixture, so the
	/// detail line shows "active" rather than "passive".
	func test_pipeline_80g_decodes_rates_and_renders() {
		let detected = detectedCable(fromFixture: "sop_prime_80g_port3.plist")
		XCTAssertEqual(detected.endpoint, .sopPrime, "80G fixture is the near-end SOP'")
		XCTAssertEqual(detected.info?.speedTier, .gen80g, "speed bits 2..0 == 4 -> gen80g")
		XCTAssertEqual(detected.info?.rawCableVDO, 0x00002644,
		               "80G word == whatcable EPR cable 50V 5A cross-check")
		XCTAssertEqual(detected.info?.productType, .active, "ID Header UFP == 4 -> active cable")
		let portVerdict = portVerdict(fromFixture: "sop_prime_80g_port3.plist")
		XCTAssertEqual(portVerdict.verdict.tier, .gen80g)
		XCTAssertEqual(portVerdict.verdict.bucketLabel, "80G", "bucket token is 80G")
		XCTAssertEqual(portVerdict.verdict.basis, .emarker, "clear tier rates by e-marker")
		XCTAssertNil(portVerdict.verdict.knownCable, "no DB refinement for a clear tier")
		let block = renderPortBlockStyled(portVerdict, styled: false)
		XCTAssertTrue(block.hasPrefix("Port 3: 80G [e-marker]"),
		              "80G block headline must start with bucket and basis tag")
		XCTAssertTrue(block.contains("80G [e-marker]"), "block contains bucket and basis tag")
		XCTAssertTrue(block.contains("80 Gbps"), "block contains speed phrase")
		XCTAssertTrue(block.contains("5A"), "block contains current rating")
		XCTAssertTrue(block.contains("0x05AC"), "block contains Apple VID")
	}

	//============================================
	// MARK: Shared shape: every speed reports a readable e-marker on Port 3
	//============================================

	/// Every populated prime fixture must correlate to Port 3, expose a readable
	/// e-marker (so the headline is NOT the no-e-marker "[port active]" case), and
	/// carry the Apple VID / fixture PID through to render. This locks in that the
	/// populated-Metadata path is distinct from the empty-Metadata M1 reality.
	func test_pipeline_all_speeds_have_readable_emarker_on_port3() {
		let fixtures = [
			"sop_prime_10g_port3.plist",
			"sop_prime_40g_port3.plist",
			"sop_prime_80g_port3.plist",
		]
		for name in fixtures {
			let portVerdict = portVerdict(fromFixture: name)
			XCTAssertTrue(portVerdict.hasReadableEMarker,
			              "\(name): populated Metadata -> readable e-marker")
			XCTAssertTrue(portVerdict.sopServicePresent,
			              "\(name): an SOP node is present for the port")
			XCTAssertEqual(portVerdict.portNumber, 3, "\(name): correlates to Port 3")
			XCTAssertEqual(portVerdict.portKey, "2/3", "\(name): USB-C type/number key")
			XCTAssertEqual(portVerdict.verdict.cable?.vendorID, 0x05AC,
			               "\(name): Apple VID carried through")
			XCTAssertEqual(portVerdict.verdict.cable?.productID, 0x720A,
			               "\(name): fixture PID carried through from Metadata")
			// The headline carries a real speed bucket + e-marker basis, never the
			// no-e-marker "[port active]" tag the empty-Metadata M1 case produces.
			XCTAssertFalse(portVerdict.headline.contains("[port active]"),
			               "\(name): a decoded e-marker is never the no-e-marker case")
		}
	}
}
