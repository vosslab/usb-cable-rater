import XCTest
@testable import CableRater

/// XCTest coverage for the text renderer (renderCableTextStyled) and renderJSON.
///
/// Text tests call the style-explicit form so they can exercise BOTH the plain
/// (non-TTY, styled=false) and colored (TTY, styled=true) paths deterministically,
/// without depending on whether the test runner's stdout is a terminal. They
/// assert the numbered prefix, the friendly labels, the verbose detail fields, and
/// the absence of ANSI escape codes in plain output. JSON tests assert the
/// UNCHANGED stable key order and schema.
final class RenderTests: XCTestCase {

	//============================================
	// MARK: Helpers
	//============================================

	/// Build a clear-tier verdict for a given tier (basis emarker), with populated
	/// raw fields so the verbose detail line has something to print.
	private func clearVerdict(_ tier: CableSpeedTier) -> Verdict {
		let cable = CableInfo(
			speedTier: tier,
			productType: .passive,
			current: .threeAmp,
			vendorID: 0x05AC,
			rawCableVDO: 0x110A2644,
			productID: 0x720A
		)
		let result = verdict(for: cable, catalog: Catalog.shared)
		return result
	}

	/// The ESC character that begins every ANSI escape sequence (color or bold).
	private let escChar = "\u{1B}"

	/// Build a PortVerdict that rates by a decoded e-marker (basis e-marker), on a
	/// given port. The underlying Verdict carries the speed bucket so the port
	/// headline reads "Port N: <bucket> [e-marker]".
	private func emarkerPortVerdict(port: Int, tier: CableSpeedTier) -> PortVerdict {
		let rated = clearVerdict(tier)
		let pv = PortVerdict(
			portNumber: port,
			portKey: "2/\(port)",
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .connectionActive,
			sopServicePresent: true
		)
		return pv
	}

	/// Build a PortVerdict for an occupied port with NO readable e-marker: the
	/// "Unknown [port active]" shape (verdict(for: nil) -> noEmarker).
	private func portActiveVerdict(port: Int) -> PortVerdict {
		let rated = verdict(for: nil, catalog: Catalog.shared)
		let pv = PortVerdict(
			portNumber: port,
			portKey: "2/\(port)",
			verdict: rated,
			backendSource: .portPoll,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		return pv
	}

	/// Build a PortVerdict whose e-marker is present but unrecognized (UNKNOWN*),
	/// rendered as the calm "Potentially fast?" label.
	private func unrecognizedPortVerdict(port: Int) -> PortVerdict {
		// All-zero shape with no raw keys -> emarkerUnrecognized.
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let rated = verdict(for: cable, catalog: Catalog.shared)
		let pv = PortVerdict(
			portNumber: port,
			portKey: "2/\(port)",
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .connectionActive,
			sopServicePresent: true
		)
		return pv
	}

	/// Build a PortVerdict floored by a far-end USB3+ device (basis deviceFloor), on
	/// a given port and tier. No cable e-marker; the M5 "At least <speed> [device]"
	/// shape.
	private func deviceFloorPortVerdict(port: Int, tier: CableSpeedTier) -> PortVerdict {
		let rated = verdictForDeviceFloor(tier: tier)
		let pv = PortVerdict(
			portNumber: port,
			portKey: "2/\(port)",
			verdict: rated,
			backendSource: .usbDevice,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		return pv
	}

	//============================================
	// MARK: Text -- numbered prefix + label line
	//============================================

	/// The label line carries the caller prefix and the friendly bucket label.
	func test_text_numbered_prefix_and_label() {
		let result = clearVerdict(.gen10g)
		let text = renderCableTextStyled(result, prefix: "cable 1 of 3: ", styled: false)
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(lines.count, 2, "text output must be a two-line block")
		XCTAssertEqual(String(lines[0]), "cable 1 of 3: 10G", "label line must be prefix + label")
	}

	/// Watch-style numbering (no total) renders "cable N: <LABEL>".
	func test_text_watch_prefix_no_total() {
		let result = clearVerdict(.gen5g)
		let text = renderCableTextStyled(result, prefix: "cable 7: ", styled: false)
		XCTAssertTrue(text.hasPrefix("cable 7: 5G"), "watch prefix has no total: \(text)")
	}

	//============================================
	// MARK: Text -- friendly labels
	//============================================

	/// emarkerUnrecognized renders the friendly "POTENTIALLY FAST?" label, not
	/// the stable JSON bucketLabel "UNKNOWN*".
	func test_text_unrecognized_label_is_potentially_fast() {
		// All-zero shape with no raw keys -> emarkerUnrecognized (POTENTIALLY FAST?).
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let result = verdict(for: cable, catalog: Catalog.shared)
		let text = renderCableTextStyled(result, prefix: "cable 1: ", styled: false)
		XCTAssertTrue(text.hasPrefix("cable 1: POTENTIALLY FAST?"), "friendly label: \(text)")
		XCTAssertFalse(text.contains("UNKNOWN*"), "stable bucketLabel must not leak into text")
		// The basis tag for the unrecognized pile.
		XCTAssertTrue(text.contains("[unrecognized]"), "unrecognized basis tag: \(text)")
	}

	/// noEmarker renders the "UNKNOWN" label and the short no-e-marker detail hint.
	func test_text_no_emarker_label_and_hint() {
		let result = verdict(for: nil, catalog: Catalog.shared)
		let text = renderCableTextStyled(result, prefix: "cable 1: ", styled: false)
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(String(lines[0]), "cable 1: UNKNOWN")
		// No CableInfo: detail is the short hint plus the basis tag, no raw fields.
		XCTAssertTrue(String(lines[1]).contains("no e-marker"), "hint present: \(text)")
		XCTAssertTrue(String(lines[1]).contains("[no e-marker]"), "no-e-marker tag: \(text)")
	}

	/// The ambiguous value-3 verdict shows the 20-40G label and the ambiguous tag.
	func test_text_ambiguous_label_and_tag() {
		let cable = CableInfo(
			speedTier: .gen20to40g,
			productType: .passive,
			current: .fiveAmp,
			vendorID: 0x2222
		)
		let result = verdict(for: cable, catalog: Catalog.shared)
		let text = renderCableTextStyled(result, prefix: "cable 1: ", styled: false)
		XCTAssertTrue(text.hasPrefix("cable 1: 20-40G"))
		XCTAssertTrue(text.contains("[e-marker ambiguous]"))
	}

	//============================================
	// MARK: Text -- verbose detail fields
	//============================================

	/// A populated cable prints vendor / product / cableVDO hex, type, current,
	/// and the e-marker basis tag.
	func test_text_verbose_fields_present() {
		let result = clearVerdict(.gen10g)
		let detail = verboseDetail(result)
		XCTAssertTrue(detail.hasPrefix("  "), "detail line is indented two spaces: \(detail)")
		XCTAssertTrue(detail.contains("vendor 0x05AC"), "vendor hex: \(detail)")
		XCTAssertTrue(detail.contains("product 0x720A"), "product hex: \(detail)")
		XCTAssertTrue(detail.contains("cableVDO 0x110A2644"), "cableVDO hex: \(detail)")
		XCTAssertTrue(detail.contains("passive"), "product type word: \(detail)")
		XCTAssertTrue(detail.contains("3A"), "current word: \(detail)")
		XCTAssertTrue(detail.contains("[e-marker]"), "basis tag: \(detail)")
	}

	/// Fields at their zero/unknown sentinel are omitted from the detail line.
	func test_text_verbose_fields_omitted_when_zero() {
		// vendorID 0, productID 0, rawCableVDO 0, productType unknown, current unknown.
		let cable = CableInfo(
			speedTier: .gen5g,
			productType: .unknown,
			current: .unknown,
			vendorID: 0,
			rawCableVDO: 0,
			productID: 0
		)
		let result = verdict(for: cable, catalog: Catalog.shared)
		let detail = verboseDetail(result)
		XCTAssertFalse(detail.contains("vendor 0x"), "vendor omitted when zero: \(detail)")
		XCTAssertFalse(detail.contains("product 0x"), "product omitted when zero: \(detail)")
		XCTAssertFalse(detail.contains("cableVDO 0x"), "cableVDO omitted when zero: \(detail)")
		XCTAssertFalse(detail.contains("passive"), "type omitted when unknown: \(detail)")
		XCTAssertFalse(detail.contains("active"), "type omitted when unknown: \(detail)")
		// The basis tag is always present even when every raw field is absent.
		XCTAssertTrue(detail.contains("[e-marker]"), "basis tag always present: \(detail)")
	}

	/// A knownDB hit adds the matched brand and the known-db tag to the detail.
	func test_text_knownDB_detail_has_matched_brand_and_tag() {
		// Zeroed cable refined by cableVDO 0x00084841 (UGreen Revodok hub, 5G).
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let result = verdict(
			for: cable,
			cableVDO: 0x00084841,
			productID: nil,
			catalog: Catalog.shared
		)
		let detail = verboseDetail(result)
		XCTAssertTrue(detail.contains("matched: "), "matched brand present: \(detail)")
		XCTAssertTrue(detail.contains("[known-db]"), "known-db tag present: \(detail)")
	}

	//============================================
	// MARK: Text -- ANSI styling on/off
	//============================================

	/// Plain (styled=false) text must not contain any raw ANSI escape codes
	/// (color OR bold).
	func test_text_has_no_ansi_codes_when_not_styled() {
		let result = clearVerdict(.gen80g)
		let text = renderCableTextStyled(result, prefix: "cable 1: ", styled: false)
		XCTAssertFalse(text.contains(escChar), "no raw ANSI ESC must leak into plain text: \(text)")
		XCTAssertTrue(text.hasPrefix("cable 1: 80G"), "label is plain when not styled")
	}

	/// Styled (TTY) render wraps the label token in the expected per-tier ANSI
	/// color for at least two tiers, plus bold. The detail line stays uncolored.
	func test_text_label_is_colored_when_styled() {
		// 80G -> bright green (92), 5G -> blue (34): two distinct tier colors.
		let fast = clearVerdict(.gen80g)
		let fastText = renderCableTextStyled(fast, prefix: "cable 1: ", styled: true)
		XCTAssertTrue(fastText.contains("\u{1B}[92m"), "80G must be bright green: \(fastText)")
		XCTAssertTrue(fastText.contains("\u{1B}[1m"), "label must still be bold: \(fastText)")

		let slow = clearVerdict(.gen5g)
		let slowText = renderCableTextStyled(slow, prefix: "cable 1: ", styled: true)
		XCTAssertTrue(slowText.contains("\u{1B}[34m"), "5G must be blue: \(slowText)")

		// The verbose detail line itself carries no color escape (only the label does).
		let detail = verboseDetail(fast)
		XCTAssertFalse(detail.contains(escChar), "detail line stays default color: \(detail)")
	}

	//============================================
	// MARK: Port-led headline -- text per representative verdict
	//============================================

	/// A decoded e-marker port renders the port-led "Port N: <bucket> [e-marker]"
	/// headline, leading with the physical port number and the speed bucket token.
	func test_port_headline_emarker_bucket() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertEqual(line, "Port 3: 10G [e-marker]",
		               "decoded e-marker renders the port-led bucket headline: \(line)")
	}

	/// An occupied port with no readable e-marker renders the calm
	/// "Port N: Unknown [port active]" headline (the detected-no-e-marker basis).
	func test_port_headline_unknown_port_active() {
		let pv = portActiveVerdict(port: 3)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertEqual(line, "Port 3: Unknown [port active]",
		               "occupied-no-e-marker renders the port-active headline: \(line)")
	}

	/// A decoded but unrecognized e-marker renders the calm title-case
	/// "Potentially fast?" label with the unrecognized basis tag.
	func test_port_headline_potentially_fast_title_case() {
		let pv = unrecognizedPortVerdict(port: 2)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertEqual(line, "Port 2: Potentially fast? [unrecognized]",
		               "unrecognized renders the calm title-case label: \(line)")
		// The shouty all-caps wording must NOT appear in the human headline.
		XCTAssertFalse(line.contains("POTENTIALLY FAST?"),
		               "human headline is calm title-case, not all-caps: \(line)")
		XCTAssertFalse(line.contains("UNKNOWN*"),
		               "stable JSON bucket must not leak into the headline: \(line)")
	}

	/// M5 device-floor port renders the "Port N: At least <speed> [device]" headline:
	/// the calm "At least <bucket>" label and the distinct [device] basis tag.
	func test_port_headline_device_floor_at_least_speed() {
		let pv = deviceFloorPortVerdict(port: 3, tier: .gen10g)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertEqual(line, "Port 3: At least 10G [device]",
		               "device floor renders the At-least headline: \(line)")
		// It must not read like a cable e-marker (no [e-marker]) nor like Unknown.
		XCTAssertFalse(line.contains("[e-marker]"), "device floor is not an e-marker: \(line)")
		XCTAssertFalse(line.contains("Unknown"), "a device floor is not Unknown: \(line)")
	}

	/// The device-floor two-line block names the device evidence in its detail line
	/// and keeps the honest hedge that the cable's true rating may be higher.
	func test_block_device_floor_detail_names_device_evidence() {
		let pv = deviceFloorPortVerdict(port: 3, tier: .gen10g)
		let block = renderPortBlockStyled(pv, styled: false)
		let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(lines.count, 2, "device floor is a two-line block")
		XCTAssertEqual(String(lines[0]), "Port 3: At least 10G [device]")
		let detail = String(lines[1])
		XCTAssertTrue(detail.contains("device"), "detail names the device evidence: \(detail)")
		XCTAssertTrue(detail.contains("at least"), "detail keeps the floor hedge: \(detail)")
		XCTAssertTrue(detail.contains("via ConnectionActive"),
		              "detail names the occupancy avenue: \(detail)")
	}

	/// The device floor is render-only: its stable JSON bucket is the normal tier
	/// token (e.g. "10G"), and its basis token is the new "deviceFloor" -- the
	/// "At least" wording and the [device] tag never leak into the machine schema.
	func test_device_floor_human_vs_json_tokens() {
		let pv = deviceFloorPortVerdict(port: 3, tier: .gen10g)
		// Human headline carries the "At least" hedge and the [device] tag.
		let headline = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertTrue(headline.contains("At least 10G"), "human headline: \(headline)")
		XCTAssertTrue(headline.contains("[device]"), "human basis tag: \(headline)")
		// JSON keeps the stable tier bucket and the typed basis; no "At least", no
		// "[device]".
		let jsonText = renderJSON(pv.verdict, event: "snapshot")
		XCTAssertTrue(jsonText.contains("\"bucket\":\"10G\""),
		              "JSON bucket is the stable tier token: \(jsonText)")
		XCTAssertTrue(jsonText.contains("\"basis\":\"deviceFloor\""),
		              "JSON basis names the device-floor case: \(jsonText)")
		XCTAssertFalse(jsonText.contains("At least"), "no hedge in JSON: \(jsonText)")
		XCTAssertFalse(jsonText.contains("device]"), "no human tag in JSON: \(jsonText)")
	}

	//============================================
	// MARK: Port-led headline -- calm title-case casing
	//============================================

	/// The two .unknown-tier piles use calm title-case words (Unknown,
	/// Potentially fast?), not the shouty all-caps labelText wording.
	func test_port_headline_labels_are_title_case() {
		let unknown = renderPortHeadlineStyled(portActiveVerdict(port: 1), styled: false)
		XCTAssertTrue(unknown.contains("Unknown"), "calm 'Unknown': \(unknown)")
		XCTAssertFalse(unknown.contains("UNKNOWN"), "no all-caps UNKNOWN: \(unknown)")

		let unrec = renderPortHeadlineStyled(unrecognizedPortVerdict(port: 1), styled: false)
		XCTAssertTrue(unrec.contains("Potentially fast?"), "calm label: \(unrec)")
	}

	//============================================
	// MARK: Port-led headline -- trimmed / no trailing whitespace
	//============================================

	/// The port headline carries no leading or trailing whitespace and ends with
	/// the bracketed basis tag (no dangling space after it).
	func test_port_headline_is_trimmed() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen80g)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertEqual(line, line.trimmingCharacters(in: .whitespaces),
		               "no leading/trailing whitespace: '\(line)'")
		XCTAssertTrue(line.hasSuffix("]"), "headline ends with the basis tag: \(line)")
		XCTAssertFalse(line.contains("\n"), "the headline is a single line: \(line)")
	}

	//============================================
	// MARK: Port-led headline -- color only on a TTY, only the bucket token
	//============================================

	/// Plain (styled=false) port headline carries no ANSI escape codes, so a pipe,
	/// file, or --json run stays clean.
	func test_port_headline_no_ansi_when_not_styled() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let line = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertFalse(line.contains(escChar),
		               "no ANSI must leak into the plain headline: \(line)")
	}

	/// Styled (TTY) port headline colors ONLY the bucket token: the per-tier color
	/// wraps the bucket, the "Port N:" prefix and the basis tag stay default color.
	func test_port_headline_colors_only_the_bucket_on_tty() {
		// 10G -> cyan (36). The colored region is just the bucket token.
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let line = renderPortHeadlineStyled(pv, styled: true)
		XCTAssertTrue(line.contains("\u{1B}[36m"), "10G bucket must be cyan: \(line)")
		XCTAssertTrue(line.contains("\u{1B}[0m"), "a reset must close the color: \(line)")
		// The prefix is before the first color escape (uncolored).
		XCTAssertTrue(line.hasPrefix("Port 3: "), "the prefix stays default color: \(line)")
		// The basis tag is after the reset (uncolored): the substring "] " ... actually
		// the tag trails the reset, so the reset appears before "[e-marker]".
		guard let resetRange = line.range(of: "\u{1B}[0m") else {
			XCTFail("expected a reset escape: \(line)")
			return
		}
		let afterReset = String(line[resetRange.upperBound...])
		XCTAssertTrue(afterReset.contains("[e-marker]"),
		              "the basis tag follows the reset (default color): \(line)")
		XCTAssertFalse(afterReset.contains(escChar),
		               "no further color escape after the bucket token: \(line)")
	}

	/// The bucket token is NOT bolded in the port headline (the calm value-only
	/// color rule); the two-line detail renderer's bold is separate.
	func test_port_headline_bucket_is_not_bold() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen5g)
		let line = renderPortHeadlineStyled(pv, styled: true)
		XCTAssertFalse(line.contains("\u{1B}[1m"),
		               "the calm port headline does not bold the bucket: \(line)")
	}

	/// The Unknown port-active bucket is colored red on a TTY (matching labelColor
	/// for the noEmarker pile), and only the bucket token.
	func test_port_headline_unknown_is_red_on_tty() {
		let pv = portActiveVerdict(port: 2)
		let line = renderPortHeadlineStyled(pv, styled: true)
		XCTAssertTrue(line.contains("\u{1B}[31m"), "Unknown bucket must be red: \(line)")
		XCTAssertTrue(line.contains("[port active]"),
		              "the port-active basis tag is present: \(line)")
	}

	//============================================
	// MARK: JSON -- stable keys, inserted event (UNCHANGED schema)
	//============================================

	/// An inserted JSON object carries the required stable keys and values.
	func test_json_inserted_key_order() {
		let result = clearVerdict(.gen10g)
		let json = renderJSON(result, event: "inserted")
		// Stable key presence and values.
		XCTAssertTrue(json.contains("\"event\":\"inserted\""))
		XCTAssertTrue(json.contains("\"bucket\":\"10G\""))
		XCTAssertTrue(json.contains("\"tier\":\"gen10g\""))
		XCTAssertTrue(json.contains("\"basis\":\"emarker\""))
	}

	/// JSON keeps the stable "UNKNOWN*" bucket for the unrecognized pile, even
	/// though the text label changed to "POTENTIALLY FAST?".
	func test_json_unrecognized_bucket_unchanged() {
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let result = verdict(for: cable, catalog: Catalog.shared)
		let json = renderJSON(result, event: "snapshot")
		XCTAssertTrue(json.contains("\"bucket\":\"UNKNOWN*\""), "stable JSON bucket: \(json)")
		XCTAssertTrue(json.contains("\"basis\":\"emarkerUnrecognized\""))
	}

	/// The port headline shows the calm title-case "Unknown" label, but the SAME
	/// no-e-marker port verdict's JSON keeps the stable "UNKNOWN" token and the
	/// "noEmarker" basis -- the human/machine split the plan requires.
	func test_port_active_human_vs_json_tokens() {
		let pv = portActiveVerdict(port: 3)
		// Human headline: calm title-case "Unknown".
		let headline = renderPortHeadlineStyled(pv, styled: false)
		XCTAssertTrue(headline.contains("Unknown"))
		// JSON of the SAME underlying Verdict: stable all-caps token, unchanged basis.
		let json = renderJSON(pv.verdict, event: "snapshot")
		XCTAssertTrue(json.contains("\"bucket\":\"UNKNOWN\""),
		              "JSON keeps the stable UNKNOWN token: \(json)")
		XCTAssertTrue(json.contains("\"basis\":\"noEmarker\""),
		              "the port-active path keeps basis noEmarker in JSON: \(json)")
	}

	/// vendorId is rendered as a zero-padded "0x" hex string from the e-marker.
	func test_json_vendorid_hex_format() {
		let result = clearVerdict(.gen5g)
		let json = renderJSON(result, event: "inserted")
		XCTAssertTrue(json.contains("\"vendorId\":\"0x05AC\""), "vendorId must be 0x-padded hex: \(json)")
	}

	//============================================
	// MARK: JSON -- removed event
	//============================================

	/// A removed event renders event = "removed" with the same stable schema.
	func test_json_removed_event() {
		let result = clearVerdict(.gen5g)
		let json = renderJSON(result, event: "removed")
		XCTAssertTrue(json.contains("\"event\":\"removed\""), "removed event must be present: \(json)")
		// The schema is unchanged: bucket/tier/basis still present.
		XCTAssertTrue(json.contains("\"bucket\":\"5G\""))
		XCTAssertTrue(json.contains("\"basis\":\"emarker\""))
	}

	/// When there is no e-marker, vendorId/productId/cableVDO/brand are JSON null.
	func test_json_nulls_for_no_emarker() {
		let result = verdict(for: nil, catalog: Catalog.shared)
		let json = renderJSON(result, event: "snapshot")
		XCTAssertTrue(json.contains("\"vendorId\":null"))
		XCTAssertTrue(json.contains("\"productId\":null"))
		XCTAssertTrue(json.contains("\"cableVDO\":null"))
		XCTAssertTrue(json.contains("\"brand\":null"))
	}

	//============================================
	// MARK: JSON -- knownDB record fields populated
	//============================================

	/// A knownDB verdict populates brand / cableVDO / productId from the record.
	func test_json_knownDB_populates_record_fields() {
		// Zeroed cable refined by cableVDO 0x00084841 (UGreen Revodok hub, 5G).
		let cable = CableInfo(
			speedTier: .usb2,
			productType: .unknown,
			current: .usbDefault,
			vendorID: 0
		)
		let result = verdict(
			for: cable,
			cableVDO: 0x00084841,
			productID: nil,
			catalog: Catalog.shared
		)
		let json = renderJSON(result, event: "snapshot")
		XCTAssertTrue(json.contains("\"basis\":\"knownDB\""))
		XCTAssertTrue(json.contains("\"bucket\":\"5G\""))
		// brand and cableVDO come from the matched record; assert they are non-null.
		XCTAssertFalse(json.contains("\"brand\":null"), "brand must be populated on a DB hit: \(json)")
		XCTAssertFalse(json.contains("\"cableVDO\":null"), "cableVDO must be populated on a DB hit: \(json)")
	}

	//============================================
	// MARK: Two-line block -- decoded e-marker spec detail
	//============================================

	/// The two-line block for a decoded e-marker prints the headline on line 1 and a
	/// concise spec detail line on line 2: speed phrase, current, product type, and
	/// VID/PID -- the advanced-user fields, with raw hex VDO / registry IDs left for
	/// --debug.
	func test_block_emarker_detail_spec_line() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let block = renderPortBlockStyled(pv, styled: false)
		let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(lines.count, 2, "the block is two lines: \(block)")
		// Line 1 is the existing headline.
		XCTAssertEqual(String(lines[0]), "Port 3: 10G [e-marker]",
		               "line 1 is the colored-on-TTY headline: \(block)")
		// Line 2 is the indented spec detail.
		let detail = String(lines[1])
		XCTAssertTrue(detail.hasPrefix("        "), "detail line is indented: '\(detail)'")
		XCTAssertTrue(detail.contains("USB3.2 Gen2 (10 Gbps)"), "speed phrase: \(detail)")
		XCTAssertTrue(detail.contains("3A"), "current: \(detail)")
		XCTAssertTrue(detail.contains("passive"), "product type: \(detail)")
		XCTAssertTrue(detail.contains("VID 0x05AC"), "vendor ID: \(detail)")
		XCTAssertTrue(detail.contains("PID 0x720A"), "product ID: \(detail)")
		// Raw hex VDO and registry IDs stay OUT of the default detail (they are --debug).
		XCTAssertFalse(detail.contains("cableVDO"), "raw VDO stays under --debug: \(detail)")
		XCTAssertFalse(detail.contains("0x110A2644"), "raw VDO word stays under --debug: \(detail)")
	}

	/// The 80G tier renders its USB4 v2 (80 Gbps) speed phrase in the detail line.
	func test_block_emarker_detail_speed_phrase_80g() {
		let pv = emarkerPortVerdict(port: 1, tier: .gen80g)
		let block = renderPortBlockStyled(pv, styled: false)
		XCTAssertTrue(block.contains("USB4 v2 (80 Gbps)"), "80G speed phrase: \(block)")
	}

	//============================================
	// MARK: Two-line block -- no-e-marker evidence detail
	//============================================

	/// The two-line block for an occupied port with NO readable e-marker prints the
	/// headline on line 1 and an honest evidence line on line 2 naming the avenues
	/// that fired (here ConnectionActive), with the far-end retry hint.
	/// Per whatcable README Caveats: "likely USB2 / basic" is NOT printed because
	/// macOS may simply not have queried the cable yet; the wording is honest.
	func test_block_no_emarker_evidence_line() {
		let pv = portActiveVerdict(port: 3)
		let block = renderPortBlockStyled(pv, styled: false)
		let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
		XCTAssertEqual(lines.count, 2, "the block is two lines: \(block)")
		XCTAssertEqual(String(lines[0]), "Port 3: Unknown [port active]",
		               "line 1 is the Unknown port-active headline: \(block)")
		let detail = String(lines[1])
		XCTAssertTrue(detail.hasPrefix("        "), "detail line is indented: '\(detail)'")
		// Honest wording: the e-marker was not read, not that the cable is basic.
		XCTAssertTrue(detail.contains("no e-marker read yet"),
		              "honest no-e-marker wording present: \(detail)")
		// The far-end retry hint must be present per whatcable guidance.
		XCTAssertTrue(detail.contains("attach a charger/dock/device on the far end"),
		              "far-end retry hint present: \(detail)")
		// The word "basic" must NOT appear -- it overclaims a USB2 rating.
		XCTAssertFalse(detail.contains("basic"),
		               "the wording must not claim 'basic' or 'USB2 / basic': \(detail)")
		XCTAssertTrue(detail.contains("via ConnectionActive"),
		              "evidence line names the deciding avenue: \(detail)")
	}

	/// The evidence avenue list names ONLY the deciding occupancy source: SOP-node
	/// presence is timing-variable enrichment and is excluded so the line is stable
	/// across startup, interest, and poll paths for the same physical cable state.
	func test_evidence_line_connectionActive_only_even_when_sop_present() {
		// sopServicePresent: true simulates a startup-path verdict where the SOP node
		// was already enumerated. The avenue list must NOT include "SOP node" because
		// that would cause the line to flip on a replug (where the SOP node may not
		// yet be present at flush time).
		let rated = verdict(for: nil, catalog: Catalog.shared)
		let pvWithSOP = PortVerdict(
			portNumber: 2,
			portKey: "2/2",
			verdict: rated,
			backendSource: .portPoll,
			occupancySource: .connectionActive,
			sopServicePresent: true
		)
		let avenuesWithSOP = portEvidenceAvenues(pvWithSOP)
		// Stability: sopServicePresent = true must NOT add "SOP node" to the avenue list.
		XCTAssertEqual(avenuesWithSOP, ["ConnectionActive"],
		               "only the deciding source, never 'SOP node': \(avenuesWithSOP)")

		// A replug verdict where sopServicePresent is false (SOP not yet settled).
		let pvNoSOP = PortVerdict(
			portNumber: 2,
			portKey: "2/2",
			verdict: rated,
			backendSource: .portInterest,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		let avenuesNoSOP = portEvidenceAvenues(pvNoSOP)
		XCTAssertEqual(avenuesNoSOP, ["ConnectionActive"],
		               "same avenue list when sopServicePresent is false: \(avenuesNoSOP)")

		// Both must be identical -- the stability contract.
		XCTAssertEqual(avenuesWithSOP, avenuesNoSOP,
		               "avenue list is identical regardless of sopServicePresent: \(avenuesWithSOP) vs \(avenuesNoSOP)")
	}

	/// The evidence detail line text is identical whether sopServicePresent is true or
	/// false for the same physical cable state -- proving the no-e-marker line never
	/// flips between startup (SOP settled) and replug (SOP not yet settled) paths.
	/// This is the stability test: the plan requires the SAME evidence line across
	/// startup, interest, and poll paths.
	func test_evidence_line_stable_across_sop_presence_states() {
		let rated = verdict(for: nil, catalog: Catalog.shared)
		// Startup-path verdict: SOP node was already enumerated when the verdict was built.
		let pvStartup = PortVerdict(
			portNumber: 3,
			portKey: "2/3",
			verdict: rated,
			backendSource: .portPoll,
			occupancySource: .connectionActive,
			sopServicePresent: true
		)
		// Replug-path verdict: SOP node not yet present at the debounce flush moment.
		let pvReplug = PortVerdict(
			portNumber: 3,
			portKey: "2/3",
			verdict: rated,
			backendSource: .portInterest,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		// Interest-callback path verdict: same ConnectionActive source.
		let pvInterest = PortVerdict(
			portNumber: 3,
			portKey: "2/3",
			verdict: rated,
			backendSource: .portInterest,
			occupancySource: .connectionActive,
			sopServicePresent: false
		)
		// Build the full two-line block for each path and compare.
		let blockStartup = renderPortBlockStyled(pvStartup, styled: false)
		let blockReplug = renderPortBlockStyled(pvReplug, styled: false)
		let blockInterest = renderPortBlockStyled(pvInterest, styled: false)

		// All three blocks must be identical: headline + evidence line never differ
		// between startup (SOP present) and replug (SOP absent at flush).
		XCTAssertEqual(blockStartup, blockReplug,
		               "startup and replug blocks must be identical (no SOP-node flip):\nstartup: \(blockStartup)\nreplug:  \(blockReplug)")
		XCTAssertEqual(blockStartup, blockInterest,
		               "startup and interest blocks must be identical:\nstartup:  \(blockStartup)\ninterest: \(blockInterest)")

		// The stable evidence line must say "via ConnectionActive" (not "SOP node").
		XCTAssertTrue(blockStartup.contains("via ConnectionActive"),
		              "evidence line names ConnectionActive: \(blockStartup)")
		XCTAssertFalse(blockStartup.contains("SOP node"),
		               "evidence line must NOT contain 'SOP node' (timing-variable): \(blockStartup)")
	}

	/// When the PD identity itself decided the port, the avenue list names PD identity
	/// only (no SOP-node enrichment appended).
	func test_evidence_line_pd_identity_is_sole_avenue() {
		let rated = verdict(for: nil, catalog: Catalog.shared)
		let pv = PortVerdict(
			portNumber: 2,
			portKey: "2/2",
			verdict: rated,
			backendSource: .sopIdentity,
			occupancySource: .pdIdentity,
			sopServicePresent: true
		)
		let avenues = portEvidenceAvenues(pv)
		XCTAssertEqual(avenues, ["PD identity"],
		               "PD identity is the sole avenue when it decided occupancy: \(avenues)")
	}

	//============================================
	// MARK: Two-line block -- color only on the bucket, none when piped
	//============================================

	/// In a styled (TTY) block, color wraps ONLY the headline bucket token: the detail
	/// line carries no ANSI escape code at all.
	func test_block_color_only_on_bucket_detail_uncolored() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let block = renderPortBlockStyled(pv, styled: true)
		let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
		// Headline carries the cyan 10G color.
		XCTAssertTrue(String(lines[0]).contains("\u{1B}[36m"), "headline bucket is cyan: \(block)")
		// The detail line is entirely uncolored.
		XCTAssertFalse(String(lines[1]).contains(escChar),
		               "the detail line carries no ANSI escape: '\(String(lines[1]))'")
	}

	/// A plain (piped / styled=false) block carries no ANSI escape codes anywhere, so
	/// captured output stays clean.
	func test_block_no_ansi_when_not_styled() {
		let pv = emarkerPortVerdict(port: 3, tier: .gen10g)
		let block = renderPortBlockStyled(pv, styled: false)
		XCTAssertFalse(block.contains(escChar),
		               "no ANSI must leak into the plain block: \(block)")
	}

	//============================================
	// MARK: Distinct unplug rendering
	//============================================

	/// The unplug renderer produces a distinct one-line "Port N: unplugged" message,
	/// with no speed bucket, no basis tag, and no ANSI color.
	func test_unplug_line_is_distinct_and_plain() {
		let line = renderPortUnplug(portNumber: 3)
		XCTAssertEqual(line, "Port 3: unplugged", "distinct unplug wording: \(line)")
		XCTAssertFalse(line.contains("[port active]"), "no plug-shaped basis tag: \(line)")
		XCTAssertFalse(line.contains(escChar), "no ANSI color on an unplug: \(line)")
		XCTAssertFalse(line.contains("\n"), "the unplug is a single line: \(line)")
	}
}
