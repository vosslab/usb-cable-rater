// Render.swift -- turn a Verdict into human text or machine JSON.
//
// Text mode: a numbered "cable N: <LABEL>" line followed by an indented verbose
// detail line that prints the raw e-marker fields that are available plus a basis
// tag. The <LABEL> token is bold and colored only when stdout is a real TTY, so
// piped output and --json stay free of raw escape codes.
//
// JSON mode: one object per event with a stable, deterministic key order. Unplug
// events are rendered here too (event = "removed"). The JSON schema is the stable
// machine interface and is intentionally unchanged by the text-UX work.

import Foundation

//============================================
// MARK: ANSI helpers
//============================================

/// ANSI SGR bold-on / reset sequences. Used only when stdout is a TTY.
private let ansiBold = "\u{1B}[1m"
private let ansiReset = "\u{1B}[0m"

/// Whether standard output is connected to an interactive terminal.
///
/// Used to decide if ANSI bold/color is safe to emit. When stdout is a pipe or
/// file, isatty returns 0 and the renderer keeps the label plain so no escape
/// codes leak into captured output.
///
/// Returns:
///   true when fileno(stdout) is a terminal, false otherwise.
func stdoutIsTTY() -> Bool {
	// isatty returns nonzero for a terminal-backed descriptor.
	let result = isatty(fileno(stdout)) != 0
	return result
}

/// ANSI foreground color for a Verdict's label, mapped fastest -> slowest.
///
/// Centralizes the tier/basis -> color choice so the palette lives in one place.
/// The returned string is a bare SGR color-set sequence (no reset); the caller
/// pairs it with ansiReset. Color is applied only on a TTY (see styledLabel).
///
/// Palette:
///   80G                -> bright green (fastest)
///   20-40G             -> green
///   10G                -> cyan
///   5G                 -> blue
///   USB2               -> yellow
///   POTENTIALLY FAST?  -> magenta (emarkerUnrecognized, worth investigating)
///   UNKNOWN            -> red (no e-marker)
///
/// Args:
///   verdict: the rated cable.
///
/// Returns:
///   An ANSI SGR foreground-color escape string for this verdict's label.
func labelColor(_ verdict: Verdict) -> String {
	// emarkerUnrecognized has tier .unknown but its own magenta color, so branch
	// on the basis first for the two .unknown-tier piles.
	switch verdict.basis {
	case .emarkerUnrecognized:
		// "POTENTIALLY FAST?" -- a chip is present but unrecognized.
		return "\u{1B}[35m"
	case .noEmarker:
		// "UNKNOWN" -- nothing answered; least promising.
		return "\u{1B}[31m"
	default:
		break
	}
	// Speed-bearing tiers map by tier, fastest to slowest.
	switch verdict.tier {
	case .gen80g:
		return "\u{1B}[92m"
	case .gen20to40g:
		return "\u{1B}[32m"
	case .gen10g:
		return "\u{1B}[36m"
	case .gen5g:
		return "\u{1B}[34m"
	case .usb2:
		return "\u{1B}[33m"
	case .unknown:
		// Any remaining .unknown (defensive) gets the same red as no e-marker.
		return "\u{1B}[31m"
	}
}

//============================================
// MARK: Label token
//============================================

/// The short <LABEL> token printed after the "cable N:" prefix.
///
/// This is the friendly, power-user-readable verdict word:
///   clear e-marker tiers : USB2 / 5G / 10G / 80G
///   ambiguous (value 3)  : 20-40G
///   known-db hit         : the DB tier bucket (e.g. 5G)
///   emarkerUnrecognized  : POTENTIALLY FAST?   (was UNKNOWN*)
///   noEmarker            : UNKNOWN
///
/// The label is derived from basis + tier rather than the raw bucketLabel so the
/// stable JSON bucketLabel ("UNKNOWN*") is untouched while the text gets the
/// friendlier wording.
///
/// Args:
///   verdict: the rated cable.
///
/// Returns:
///   The plain label string (no styling, no prefix).
func labelText(_ verdict: Verdict) -> String {
	switch verdict.basis {
	case .emarkerUnrecognized:
		// Friendlier than the old "UNKNOWN*": a chip is present, speed unproven.
		return "POTENTIALLY FAST?"
	case .noEmarker:
		// No SOP' service answered at all.
		return "UNKNOWN"
	default:
		// emarker / emarkerAmbiguous / knownDB all carry a real speed bucket.
		return verdict.bucketLabel
	}
}

/// The <LABEL> token, optionally wrapped in bold + tier color.
///
/// When `styled` is true the label is wrapped as color + bold + text + reset so a
/// terminal shows a bold, tier-colored verdict word. When `styled` is false the
/// raw label is returned with no escape codes, keeping piped/captured output and
/// --json clean. The live path passes styled = stdoutIsTTY(); tests force either
/// value for deterministic coverage.
///
/// Args:
///   verdict: the rated cable.
///   styled: whether to apply ANSI bold + color (TTY only).
///
/// Returns:
///   The label, styled or plain.
func styledLabel(_ verdict: Verdict, styled: Bool) -> String {
	let label = labelText(verdict)
	if !styled {
		return label
	}
	// Color first, then bold, so the whole word is both colored and bold; a single
	// reset at the end clears both attributes.
	let color = labelColor(verdict)
	let wrapped = color + ansiBold + label + ansiReset
	return wrapped
}

//============================================
// MARK: Calm title-case label (port-led headline)
//============================================

/// The calm, title-case verdict word for the port-led headline.
///
/// This is the human-output bucket token used in "Port N: <Bucket> [basis]". The
/// user asked for calm title-case labels (Unknown, Potentially fast?) rather than
/// the shouty all-caps `labelText` wording, so the two .unknown-tier piles get
/// sentence-case words here while the speed buckets keep their natural casing
/// (USB2 / 5G / 10G / 20-40G / 80G -- already calm and unambiguous).
///
/// The stable JSON `bucket` token (UNKNOWN / UNKNOWN*) is untouched: this is a
/// render-only label, derived from basis + tier the same way `labelText` is, so
/// the machine schema stays stable while the terminal text reads calmly.
///
/// Args:
///   verdict: the rated cable.
///
/// Returns:
///   The plain calm label string (no styling, no prefix).
func humanLabel(_ verdict: Verdict) -> String {
	switch verdict.basis {
	case .emarkerUnrecognized:
		// Calm title-case for the "chip present, speed unproven" pile.
		return "Potentially fast?"
	case .noEmarker:
		// Calm title-case for the no-readable-e-marker pile.
		return "Unknown"
	case .deviceFloor:
		// M5 device-speed floor: the bucket is a conservative lower bound proven by a
		// far-end USB3+ device, so the headline reads "At least <bucket>" (e.g.
		// "At least 10G"). The "At least" prefix is the honest hedge that this is a
		// floor, not the cable's own e-marker rating.
		return "At least " + verdict.bucketLabel
	default:
		// emarker / emarkerAmbiguous / knownDB carry a real speed bucket whose
		// natural casing (10G, USB2, 20-40G, ...) is already calm.
		return verdict.bucketLabel
	}
}

/// The calm bucket token for a port-led headline, optionally colored on a TTY.
///
/// Only this speed/bucket token is colored (mirroring the Python `rich` approach
/// the user described); the rest of the headline -- the "Port N:" prefix and the
/// bracketed basis tag -- stays the default terminal color. When `styled` is false
/// the bare token is returned with no escape codes, so a pipe, file, or --json run
/// stays free of ANSI sequences.
///
/// The color is the same per-tier palette `labelColor` already defines (bright
/// green 80G ... red Unknown), so the headline token matches the two-line detail
/// renderer's coloring. The token is NOT bolded here: the port headline keeps a
/// calm single-attribute color on the value, per the user's "color the value while
/// details stay normal" preference.
///
/// Args:
///   verdict: the rated cable (drives both the label text and its color).
///   styled: whether to apply the ANSI color (TTY only).
///
/// Returns:
///   The calm bucket token, colored or plain.
func styledHumanLabel(_ verdict: Verdict, styled: Bool) -> String {
	let label = humanLabel(verdict)
	if !styled {
		return label
	}
	// Color only the bucket token; a single reset clears it so the basis tag that
	// follows prints in the default color.
	let color = labelColor(verdict)
	let wrapped = color + label + ansiReset
	return wrapped
}

//============================================
// MARK: Verbose detail line
//============================================

/// Human name for a product type word, when it is a real cable type.
///
/// Args:
///   productType: the decoded UFP product type.
///
/// Returns:
///   "passive" / "active", or nil for .unknown (so the field is skipped).
private func productTypeWord(_ productType: CableProductType) -> String? {
	switch productType {
	case .passive:
		return "passive"
	case .active:
		return "active"
	case .unknown:
		return nil
	}
}

/// Human name for a current rating, when it is known.
///
/// Args:
///   current: the decoded current rating.
///
/// Returns:
///   "5A" / "3A" / "USB-default", or nil for .unknown (so the field is skipped).
private func currentWord(_ current: CableCurrent) -> String? {
	switch current {
	case .fiveAmp:
		return "5A"
	case .threeAmp:
		return "3A"
	case .usbDefault:
		return "USB-default"
	case .unknown:
		return nil
	}
}

/// The basis tag printed in brackets at the end of every verbose detail line.
///
/// Args:
///   verdict: the rated cable.
///
/// Returns:
///   A bracketed tag, e.g. "[e-marker]".
func basisTag(_ verdict: Verdict) -> String {
	switch verdict.basis {
	case .emarker:
		return "[e-marker]"
	case .emarkerAmbiguous:
		return "[e-marker ambiguous]"
	case .knownDB:
		return "[known-db]"
	case .emarkerUnrecognized:
		return "[unrecognized]"
	case .deviceFloor:
		// The M5 device-speed floor: the rating came from a far-end USB3+ device, not
		// the cable's own e-marker. portBasisTag short-circuits to DeviceFloorBasis.tag
		// for the port headline; this keeps basisTag exhaustive and consistent for any
		// cable-level detail caller.
		return DeviceFloorBasis.tag
	case .noEmarker:
		return "[no e-marker]"
	}
}

//============================================
// MARK: Port-led headline (port-active basis + renderer)
//============================================

/// The bracketed basis tag for a port-led headline.
///
/// A port verdict has TWO shapes: a port whose cable e-marker decoded (it carries a
/// readable CableInfo) uses the cable's own basis tag (`[e-marker]`, `[known-db]`,
/// ...) exactly as the two-line detail renderer does. A port that is occupied but
/// has no readable e-marker uses the calm port-level `[port active]` tag -- the
/// "detected, no e-marker (port active)" basis the plan calls for, which reads
/// cleanly next to the calm `Unknown` label.
///
/// This is a render-level basis layered over the stable `Verdict`: the no-e-marker
/// port verdict still carries `Verdict.basis == .noEmarker` (so its JSON stays
/// `"basis":"noEmarker"`), and `[port active]` is shown only in the human headline.
/// The machine schema is untouched.
///
/// Args:
///   portVerdict: the merged per-port verdict.
///
/// Returns:
///   A bracketed tag, e.g. "[e-marker]" or "[port active]".
func portBasisTag(_ portVerdict: PortVerdict) -> String {
	// A decoded e-marker rates by its cable basis tag (e-marker / known-db / ...).
	if portVerdict.hasReadableEMarker {
		return basisTag(portVerdict.verdict)
	}
	// M5 device-speed floor: no readable e-marker, but a far-end USB3+ device floored
	// the rating. The "[device]" tag names the evidence source (a paired device, not
	// the cable's own e-marker) so the "At least <speed>" headline reads clearly.
	if portVerdict.verdict.basis == .deviceFloor {
		return DeviceFloorBasis.tag
	}
	// Occupied port, no readable e-marker: the named "detected, no e-marker (port
	// active)" basis from the rating layer. The underlying Verdict stays noEmarker,
	// so JSON is untouched; only the human headline shows this clean tag.
	return PortActiveBasis.tag
}

/// Render one port-led headline: "Port N: <Bucket> [basis]".
///
/// This is the result-focused output: a single calm line per occupied port,
/// leading with the physical port number, then the calm title-case bucket token
/// (the only colored part on a TTY), then the bracketed basis tag in the default
/// color. It consumes a `PortVerdict` (the coordinator's per-port unit) so the
/// renderer owns the final terminal styling while the stable `Verdict`/JSON schema
/// stays untouched.
///
/// Examples:
///   "Port 3: 10G [e-marker]"          (decoded near-end cable e-marker)
///   "Port 3: Unknown [port active]"   (occupied, no readable e-marker)
///   "Port 2: Potentially fast? [unrecognized]" (chip present, speed unproven)
///
/// Args:
///   portVerdict: the merged per-port verdict to render.
///   styled: whether to color the bucket token (TTY only); false keeps the line
///     plain for a pipe, file, or --json run.
///
/// Returns:
///   The single headline line (no trailing newline).
public func renderPortHeadlineStyled(_ portVerdict: PortVerdict, styled: Bool) -> String {
	// The calm bucket token, colored only when styled (the value-only color rule).
	let bucket = styledHumanLabel(portVerdict.verdict, styled: styled)
	// The basis tag stays in the default color (details stay normal color).
	let tag = portBasisTag(portVerdict)
	let line = "Port " + String(portVerdict.portNumber) + ": " + bucket + " " + tag
	return line
}

/// Render one port-led headline, coloring the bucket token only on a real TTY.
///
/// The live convenience form: it reads `stdoutIsTTY()` so piped/captured output and
/// --json stay free of ANSI escape codes, and a terminal gets the calm colored
/// bucket token. Tests call `renderPortHeadlineStyled` directly to force either
/// path deterministically.
///
/// Args:
///   portVerdict: the merged per-port verdict to render.
///
/// Returns:
///   The single headline line (no trailing newline).
public func renderPortHeadline(_ portVerdict: PortVerdict) -> String {
	let styled = stdoutIsTTY()
	let line = renderPortHeadlineStyled(portVerdict, styled: styled)
	return line
}

//============================================
// MARK: Port-led detail line (two-line default output)
//============================================

/// How wide a port detail line is indented under its headline. Eight spaces lines
/// the detail up clearly below the "Port N:" headline without a tab character.
private let portDetailIndent = "        "

/// A concise human speed phrase for a cable speed tier, e.g.
/// "USB3.2 Gen2 (10 Gbps)". This is the advanced-user spec wording for the two-line
/// default detail, distinct from the short bucket token (10G) in the headline.
///
/// The generation names follow the USB-IF marketing-to-signaling map: Gen1 = 5 Gbps,
/// Gen2 = 10 Gbps, USB4 = 20-40 Gbps, USB4 v2 = 80 Gbps. The 20-40G tier is the
/// PD-revision-ambiguous bucket (20 Gbps in PD 3.0, 40 Gbps in PD 3.1), so its
/// phrase keeps the combined range rather than guessing a single rate.
///
/// Args:
///   tier: the decoded speed tier.
///
/// Returns:
///   The spec phrase, or nil for .unknown (the detail line then omits a speed phrase).
private func speedPhrase(_ tier: CableSpeedTier) -> String? {
	switch tier {
	case .usb2:
		return "USB2.0 (480 Mbps)"
	case .gen5g:
		return "USB3.2 Gen1 (5 Gbps)"
	case .gen10g:
		return "USB3.2 Gen2 (10 Gbps)"
	case .gen20to40g:
		return "USB4 (20-40 Gbps)"
	case .gen80g:
		return "USB4 v2 (80 Gbps)"
	case .unknown:
		return nil
	}
}

/// The human avenue names that decided an occupied port, derived from the verdict's
/// own recorded signals (no backend re-read). The detail line for a no-readable-
/// e-marker port lists these so an advanced user sees WHICH detection paths fired
/// rather than a bare "Unknown".
///
/// Only the avenue(s) that DECIDED occupancy are listed -- the signals that crossed
/// the `PortLiveness` threshold. SOP-node presence is timing-variable enrichment:
/// the same cable may have an SOP node enumerated at startup (so `sopServicePresent`
/// is true) but not yet enumerated on a replug poll (so `sopServicePresent` is
/// false), even though the physical cable state is identical. Listing "SOP node"
/// here would cause the evidence line to flip between replug events for the same
/// cable, violating the stability contract. Instead, the line names only the
/// occupancy-deciding source, which is stable across all paths (startup, interest,
/// poll) for the same physical cable state.
///
/// Mapped to their IOKit-key wording:
///   connectionActive   -> ConnectionActive
///   accessoryDetect    -> IOAccessoryDetect
///   transportsActiveCC -> TransportsActive CC
///   pdIdentity         -> PD identity
/// Order is stable: the deciding occupancy source only (one entry per verdict).
///
/// Args:
///   portVerdict: the merged per-port verdict.
///
/// Returns:
///   The avenue names that decided occupancy, in stable order. Never empty for an
///   occupied port (the occupancy source is always recorded).
func portEvidenceAvenues(_ portVerdict: PortVerdict) -> [String] {
	var avenues: [String] = []
	// Only the deciding occupancy avenue is listed. SOP-node presence is
	// enrichment, not a deciding avenue, and is timing-variable (it may not be
	// settled at flush time), so it is omitted here to keep the line stable.
	switch portVerdict.occupancySource {
	case .connectionActive:
		avenues.append("ConnectionActive")
	case .accessoryDetect:
		avenues.append("IOAccessoryDetect")
	case .transportsActiveCC:
		avenues.append("TransportsActive CC")
	case .pdIdentity:
		avenues.append("PD identity")
	}
	return avenues
}

/// The indented detail line for an M5 device-floored port. Default terminal color.
///
/// It names the device evidence -- a far-end USB3+ device negotiated this link speed,
/// which is a conservative floor for the cable -- and states the honest hedge that
/// the cable's true rating (read from its own e-marker) may be higher. The avenue(s)
/// that decided occupancy are appended so the line stays consistent with the
/// no-e-marker evidence line's "via <avenue>" shape.
///
/// Args:
///   portVerdict: the merged per-port verdict (basis .deviceFloor).
///
/// Returns:
///   The indented detail line (no trailing newline).
func deviceFloorDetailLine(_ portVerdict: PortVerdict) -> String {
	// The proven floor as a concise spec phrase (e.g. "USB3.2 Gen2 (10 Gbps)").
	let speedText = speedPhrase(portVerdict.verdict.tier) ?? portVerdict.verdict.bucketLabel
	let avenues = portEvidenceAvenues(portVerdict).joined(separator: ", ")
	var detail = "far-end USB3+ device negotiated " + speedText
	detail += " -- cable carried at least this; its true rating may be higher"
	detail += "; via " + avenues
	let line = portDetailIndent + detail
	return line
}

/// The indented detail line printed under a port headline in the two-line default
/// output. Default terminal color always (only the headline bucket token is colored).
///
/// Two shapes, mirroring the headline's two shapes:
///   - decoded e-marker: a concise spec line of the fields that carry real
///     information, e.g.
///       "USB3.2 Gen2 (10 Gbps), 3A, passive, VID 0x05AC PID 0x720A"
///     Each field is skipped at its absent/zero/unknown sentinel. Raw hex VDO and
///     registry IDs stay under --debug, not here.
///   - no readable e-marker: an honest evidence line naming the avenues that fired,
///     e.g.
///       "no e-marker read yet -- attach a charger/dock/device on the far end to read it; via ConnectionActive, SOP node"
///
/// Args:
///   portVerdict: the merged per-port verdict.
///
/// Returns:
///   The indented detail line (no trailing newline).
func portDetailLine(_ portVerdict: PortVerdict) -> String {
	// M5 device-speed floor: no cable e-marker, but a far-end USB3+ device negotiated
	// a link speed that floors the cable. Name the device evidence and the speed it
	// proved, plus the honest hedge that the cable's own rating may be higher.
	if portVerdict.verdict.cable == nil && portVerdict.verdict.basis == .deviceFloor {
		let line = deviceFloorDetailLine(portVerdict)
		return line
	}
	// No readable e-marker: the honest evidence line listing the avenues that fired.
	guard let cable = portVerdict.verdict.cable else {
		let avenues = portEvidenceAvenues(portVerdict).joined(separator: ", ")
		// Honest wording: macOS may not have queried the cable yet. The e-marker chip
		// is VCONN-powered and only answers a Discover Identity message; some Macs
		// wait until a real PD partner is negotiating on the far end. Do NOT claim
		// "likely USB2 / basic" -- the cable's true rating is simply unread yet.
		// Per whatcable README Caveats: attach a charger/dock/device on the far end.
		let line = portDetailIndent + "no e-marker read yet -- attach a charger/dock/device on the far end to read it; via " + avenues
		return line
	}
	// Decoded e-marker: a concise spec line from the CableInfo fields that carry
	// real information. Hex VDO and registry IDs stay under --debug.
	var fields: [String] = []
	// Speed phrase (USB3.2 Gen2 (10 Gbps) etc.) when the tier is decodable.
	if let phrase = speedPhrase(cable.speedTier) {
		fields.append(phrase)
	}
	// Current rating (5A / 3A / USB-default) when known.
	if let amps = currentWord(cable.current) {
		fields.append(amps)
	}
	// Product type word (passive / active) when it is a real cable type.
	if let typeWord = productTypeWord(cable.productType) {
		fields.append(typeWord)
	}
	// Vendor and product IDs as a single "VID 0x.. PID 0x.." field when present.
	let idField = vendorProductField(vendorID: cable.vendorID, productID: cable.productID)
	if let ids = idField {
		fields.append(ids)
	}
	// A matched DB brand when the DB refined the result.
	if let known = portVerdict.verdict.knownCable {
		fields.append("matched: " + known.brand)
	}
	let line = portDetailIndent + fields.joined(separator: ", ")
	return line
}

/// The "VID 0xVVVV PID 0xPPPP" field for the detail line, with each half omitted at
/// its zero (absent) sentinel. Returns nil when neither ID is present.
///
/// Args:
///   vendorID: the 16-bit USB vendor ID (0 == absent).
///   productID: the 16-bit USB product ID (0 == absent).
///
/// Returns:
///   The combined ID field, or nil when both IDs are absent.
private func vendorProductField(vendorID: UInt16, productID: UInt16) -> String? {
	var parts: [String] = []
	if vendorID != 0 {
		parts.append(String(format: "VID 0x%04X", vendorID))
	}
	if productID != 0 {
		parts.append(String(format: "PID 0x%04X", productID))
	}
	if parts.isEmpty {
		return nil
	}
	let field = parts.joined(separator: " ")
	return field
}

/// Render one port as the two-line default block: the colored headline plus the
/// indented detail line beneath it.
///
/// This is the richer default output: line 1 is the existing port-led headline
/// ("Port N: <Bucket> [basis]", bucket token colored only on a TTY), line 2 is the
/// indented detail line (always default color). Tests force `styled` to exercise both
/// the colored-TTY path and the plain-pipe path deterministically.
///
/// Args:
///   portVerdict: the merged per-port verdict to render.
///   styled: whether to color the headline bucket token (TTY only); false keeps the
///     whole block plain for a pipe, file, or capture.
///
/// Returns:
///   The two-line block (no trailing newline).
public func renderPortBlockStyled(_ portVerdict: PortVerdict, styled: Bool) -> String {
	let headline = renderPortHeadlineStyled(portVerdict, styled: styled)
	let detail = portDetailLine(portVerdict)
	let block = headline + "\n" + detail
	return block
}

/// Render one port as the two-line default block, coloring the headline bucket token
/// only on a real TTY.
///
/// The live convenience form: it reads `stdoutIsTTY()` so a pipe, file, or capture
/// stays free of ANSI escape codes while a terminal gets the calm colored bucket.
///
/// Args:
///   portVerdict: the merged per-port verdict to render.
///
/// Returns:
///   The two-line block (no trailing newline).
public func renderPortBlock(_ portVerdict: PortVerdict) -> String {
	let styled = stdoutIsTTY()
	let block = renderPortBlockStyled(portVerdict, styled: styled)
	return block
}

//============================================
// MARK: Unplug rendering (distinct remove line)
//============================================

/// Render a distinct one-line unplug message for a removed-port transition, e.g.
/// "Port 3: unplugged".
///
/// The remove transition is reliable on this hardware: the pure
/// `PortTransitionTracker` emits exactly one true->false event per physical unplug
/// (deduped per PortNumber), and both the live interest path and the backup poll feed
/// that same tracker. So an unplug yields a clean removed transition carrying the
/// port number, and this renders it distinctly instead of the previous behavior,
/// which printed a plug-shaped "Port N: Unknown [port active]" line for a removal.
///
/// The word "unplugged" is intentionally lowercase and uncolored: an unplug is the
/// absence of a cable, so there is no speed bucket to color. The line is a single
/// line with no detail beneath it (there is nothing left to describe).
///
/// Args:
///   portNumber: the port that went idle.
///
/// Returns:
///   The single unplug line (no trailing newline).
public func renderPortUnplug(portNumber: Int) -> String {
	let line = "Port " + String(portNumber) + ": unplugged"
	return line
}

/// The indented verbose detail line printed under each cable line.
///
/// Prints the raw e-marker fields that are AVAILABLE, skipping any field at its
/// absent/zero/unknown sentinel, and always ends with the bracketed basis tag.
/// Fields, in order: vendor, product, cableVDO (hex), product type word, current,
/// matched DB brand. The line is indented two spaces. It is never styled (the
/// detail stays default terminal color); only the label token gets color/bold.
///
/// When there is no CableInfo at all (the noEmarker case) the line is a short
/// hint plus the basis tag, e.g. "no e-marker (likely USB2 / basic)  [no e-marker]".
///
/// Args:
///   verdict: the rated cable.
///
/// Returns:
///   The two-space-indented detail line (no trailing newline).
func verboseDetail(_ verdict: Verdict) -> String {
	let tag = basisTag(verdict)
	// No decoded e-marker: short hint plus the tag.
	guard let cable = verdict.cable else {
		let line = "  no e-marker (likely USB2 / basic)  " + tag
		return line
	}
	// Collect only the fields that carry real information.
	var fields: [String] = []
	// vendor 0xVVVV when the vendor ID is set.
	if cable.vendorID != 0 {
		fields.append(String(format: "vendor 0x%04X", cable.vendorID))
	}
	// product 0xPPPP when the product ID is set.
	if cable.productID != 0 {
		fields.append(String(format: "product 0x%04X", cable.productID))
	}
	// cableVDO 0xWWWWWWWW when the raw Cable VDO word is set.
	if cable.rawCableVDO != 0 {
		fields.append(String(format: "cableVDO 0x%08X", cable.rawCableVDO))
	}
	// product type word (passive / active) when it is a real cable type.
	if let typeWord = productTypeWord(cable.productType) {
		fields.append(typeWord)
	}
	// current rating (5A / 3A / USB-default) when known.
	if let amps = currentWord(cable.current) {
		fields.append(amps)
	}
	// matched DB brand/name when the DB refined the result.
	if let known = verdict.knownCable {
		fields.append("matched: " + known.brand)
	}
	// Always end with the basis tag.
	fields.append(tag)
	// Two-space indent; single spaces between fields keeps it scannable.
	let line = "  " + fields.joined(separator: "  ")
	return line
}

//============================================
// MARK: Text rendering
//============================================

/// Render one cable as a numbered text block: a prefixed label line plus the
/// indented verbose detail line.
///
/// Line 1 is "<prefix><LABEL>" where prefix is the caller-built "cable N: " (watch)
/// or "cable N of M: " (--once) string. The label is bold + tier-colored on a TTY
/// and plain otherwise (driven by stdoutIsTTY). Line 2 is the verbose detail line,
/// always default color.
///
/// Args:
///   verdict: the rated cable.
///   prefix: the leading "cable N: " / "cable N of M: " text (caller-built).
///
/// Returns:
///   The two-line block (no trailing newline).
public func renderCableText(_ verdict: Verdict, prefix: String) -> String {
	let styled = stdoutIsTTY()
	let text = renderCableTextStyled(verdict, prefix: prefix, styled: styled)
	return text
}

/// Style-explicit form of renderCableText for deterministic testing.
///
/// `swift test` runs with stdout NOT a TTY, so tests force `styled` to exercise
/// both the colored-TTY path and the plain-pipe path without depending on the
/// process environment.
///
/// Args:
///   verdict: the rated cable.
///   prefix: the leading "cable N: " / "cable N of M: " text.
///   styled: whether to apply ANSI bold + color to the label.
///
/// Returns:
///   The two-line block (no trailing newline).
public func renderCableTextStyled(_ verdict: Verdict, prefix: String, styled: Bool) -> String {
	let labelLine = prefix + styledLabel(verdict, styled: styled)
	let detail = verboseDetail(verdict)
	let text = labelLine + "\n" + detail
	return text
}

//============================================
// MARK: JSON rendering
//============================================

/// Render a Verdict as a single-line JSON object with a stable key order.
///
/// Keys, in fixed order: event, bucket, tier, basis, vendorId, productId,
/// cableVDO, brand. vendorId is taken from the decoded e-marker; productId and
/// cableVDO are only known when the caller supplied them (DB-refine path), so
/// they are null when absent. This avoids JSONEncoder's nondeterministic key
/// ordering by assembling the object by hand.
///
/// This schema is the stable machine interface and is intentionally unchanged by
/// the text-UX redesign.
///
/// Args:
///   verdict: the rated cable.
///   event: the event name ("inserted", "removed", or "snapshot").
///
/// Returns:
///   A one-line JSON object string (no trailing newline).
public func renderJSON(_ verdict: Verdict, event: String) -> String {
	// vendorId comes from the e-marker when a cable was decoded.
	let vendorIdJSON: String
	if let cable = verdict.cable {
		vendorIdJSON = jsonHex16(cable.vendorID)
	} else {
		vendorIdJSON = "null"
	}
	// productId and cableVDO are only present via a DB match record.
	let productIdJSON: String
	let cableVDOJSON: String
	let brandJSON: String
	if let known = verdict.knownCable {
		productIdJSON = jsonString(known.pid)
		cableVDOJSON = jsonString(known.cableVDO)
		brandJSON = jsonString(known.brand)
	} else {
		productIdJSON = "null"
		cableVDOJSON = "null"
		brandJSON = "null"
	}
	// Assemble in a fixed, deterministic key order.
	var parts: [String] = []
	parts.append("\"event\":" + jsonString(event))
	parts.append("\"bucket\":" + jsonString(verdict.bucketLabel))
	parts.append("\"tier\":" + jsonString(verdict.tier.rawValue))
	parts.append("\"basis\":" + jsonString(verdict.basis.rawValue))
	parts.append("\"vendorId\":" + vendorIdJSON)
	parts.append("\"productId\":" + productIdJSON)
	parts.append("\"cableVDO\":" + cableVDOJSON)
	parts.append("\"brand\":" + brandJSON)
	let object = "{" + parts.joined(separator: ",") + "}"
	return object
}

//============================================
// MARK: JSON value helpers
//============================================

/// JSON-encode a string value with proper escaping of quotes and backslashes.
///
/// Args:
///   value: the raw string to encode.
///
/// Returns:
///   A quoted, escaped JSON string literal.
func jsonString(_ value: String) -> String {
	// Escape backslash first, then double quote, then control whitespace.
	var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
	escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
	escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
	escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
	escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
	let literal = "\"" + escaped + "\""
	return literal
}

/// JSON-encode a 16-bit value as a quoted "0x" hex string for stable output.
///
/// Args:
///   value: the 16-bit number (e.g. a vendor ID).
///
/// Returns:
///   A JSON string literal like "0x05AC".
func jsonHex16(_ value: UInt16) -> String {
	// Zero-pad to four hex digits, uppercase, to match the DB hex convention.
	let hex = String(format: "0x%04X", value)
	let literal = jsonString(hex)
	return literal
}
