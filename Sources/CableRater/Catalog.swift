// Catalog.swift -- known-cable lookup table loaded from the bundled JSON database.
//
// Data source: whatcable docs/cables.json
//   https://github.com/darrylmorley/whatcable
// MIT license, Darryl Morley 2026.
//
// This file vendors a subset of the whatcable cable database for offline lookup.
// It is a REFINEMENT ONLY layer: a normal e-marked cable must rate correctly with
// NO DB hit. The catalog is used only when a real SOP' e-marker is present but
// its VDO fields are zeroed or sparse.
//
// Usage:
//   let hit = Catalog.shared.lookup(byCableVDO: vdo)
//   let hit = Catalog.shared.lookup(byVendorID: vid, productID: pid)
//   Each returns KnownCable? -- nil when no match is found.

import Foundation

//============================================
// MARK: KnownCable record type
//============================================

/// A single record from the bundled known-cable catalog.
///
/// Decoded from known_cables.json (vendored from whatcable, MIT, Darryl Morley 2026).
/// All fields are present in every record; cableVDO may be an empty string for
/// records whose VDO was not captured at collection time.
public struct KnownCable: Codable {
	/// Human-readable cable brand / model name.
	public let brand: String
	/// Raw Cable VDO as a hex string (e.g. "0x000A4644"), or "" when unknown.
	public let cableVDO: String
	/// USB-IF vendor ID as a hex string (e.g. "0x05AC").  "0x0000" when zeroed.
	public let vid: String
	/// USB-IF product ID as a hex string (e.g. "0x720A").  "0x0000" when zeroed.
	public let pid: String
	/// Vendor name from the USB-IF registry, or "(zeroed)" / "Unregistered".
	public let vendor: String
	/// Speed string as stored in the source database (may be localized).
	public let speed: String
	/// Cable product type string: "passive" or "active".
	public let type: String
	/// Power rating string (informational only).
	public let power: String

	//============================================
	// MARK: Derived typed fields
	//============================================

	/// Numeric Cable VDO parsed from the hex `cableVDO` field.
	///
	/// Returns nil when `cableVDO` is empty or unparseable (four known records).
	public var numericCableVDO: UInt32? {
		// Parse "0x..." hex strings from the DB field.
		let trimmed = cableVDO.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		// Strip the leading "0x" or "0X" prefix before parsing.
		let hexPart: String
		if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
			hexPart = String(trimmed.dropFirst(2))
		} else {
			hexPart = trimmed
		}
		return UInt32(hexPart, radix: 16)
	}

	/// Numeric vendor ID parsed from the hex `vid` field.
	public var numericVID: UInt16? {
		// Parse "0x..." hex strings from the DB field.
		let trimmed = vid.trimmingCharacters(in: .whitespaces)
		let hexPart: String
		if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
			hexPart = String(trimmed.dropFirst(2))
		} else {
			hexPart = trimmed
		}
		return UInt16(hexPart, radix: 16)
	}

	/// Numeric product ID parsed from the hex `pid` field.
	public var numericPID: UInt16? {
		// Parse "0x..." hex strings from the DB field.
		let trimmed = pid.trimmingCharacters(in: .whitespaces)
		let hexPart: String
		if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
			hexPart = String(trimmed.dropFirst(2))
		} else {
			hexPart = trimmed
		}
		return UInt16(hexPart, radix: 16)
	}

	/// Speed tier derived from the `speed` string field.
	///
	/// Maps the human-readable speed label to a typed CableSpeedTier.
	/// Speed strings in the DB are multilingual (English, Spanish, Russian, Chinese);
	/// matching is done on the ASCII prefix "USB 2.0", "USB 3.2 Gen 1",
	/// "USB 3.2 Gen 2", "USB4 Gen 3", "USB4 Gen 4" which is consistent across
	/// all localized variants observed in the source data.
	///
	/// Returns .unknown when the speed string does not match any known prefix.
	public var speedTier: CableSpeedTier {
		return Catalog.speedTierFromString(speed)
	}
}

//============================================
// MARK: Catalog singleton
//============================================

/// Lookup table for the bundled known-cable database.
///
/// Loads known_cables.json once at first access via Bundle.module.
/// Provides two lookup paths:
///   - by exact Cable VDO (UInt32): primary key for zeroed-VID records.
///   - by vendor ID + product ID (UInt16 pair): secondary key for registered cables.
///
/// Fails loudly (preconditionFailure) if the bundled JSON is missing or unparseable,
/// because that indicates a packaging defect, not a runtime cable-lookup miss.
public final class Catalog {

	/// Shared singleton; loads on first access.
	public static let shared: Catalog = Catalog()

	/// All records decoded from the bundled JSON.
	public let records: [KnownCable]

	//============================================
	// MARK: Initializer
	//============================================

	private init() {
		// Locate the bundled JSON resource; fail loudly if absent (packaging bug).
		guard let url = Bundle.module.url(forResource: "known_cables", withExtension: "json") else {
			preconditionFailure("Catalog: bundled resource known_cables.json not found in Bundle.module -- packaging defect.")
		}
		// Load the JSON data; fail loudly if the file cannot be read.
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			preconditionFailure("Catalog: failed to load known_cables.json from \(url): \(error)")
		}
		// Decode the JSON array; fail loudly if the schema does not match.
		do {
			records = try JSONDecoder().decode([KnownCable].self, from: data)
		} catch {
			preconditionFailure("Catalog: failed to decode known_cables.json: \(error)")
		}
	}

	//============================================
	// MARK: Lookups
	//============================================

	/// Look up a cable record by its exact Cable VDO value.
	///
	/// The Cable VDO is the primary key for the catalog.  Records with zeroed VID
	/// (vid == "0x0000") can only be matched by cableVDO; this lookup handles them.
	///
	/// Returns the first matching record, or nil when none match.
	/// Records with an empty or unparseable cableVDO field are skipped.
	///
	/// Args:
	///   cableVDO: the 32-bit Cable VDO as decoded from the e-marker chip.
	///
	/// Returns:
	///   The first KnownCable whose numericCableVDO equals cableVDO, or nil.
	public func lookup(byCableVDO cableVDO: UInt32) -> KnownCable? {
		// Scan all records; return the first VDO match found.
		for record in records {
			guard let vdo = record.numericCableVDO else { continue }
			if vdo == cableVDO {
				return record
			}
		}
		return nil
	}

	/// Look up a cable record by USB-IF vendor ID and product ID.
	///
	/// Used for registered cables where both VID and PID are nonzero.
	/// A zeroed VID (0x0000) with any PID will never match a meaningful registered
	/// cable entry because no real vendor has VID 0; callers should prefer
	/// lookup(byCableVDO:) first when the VDO is available.
	///
	/// Returns the first matching record, or nil when none match.
	///
	/// Args:
	///   vendorID: the 16-bit USB vendor ID.
	///   productID: the 16-bit USB product ID.
	///
	/// Returns:
	///   The first KnownCable whose numericVID and numericPID match, or nil.
	public func lookup(byVendorID vendorID: UInt16, productID: UInt16) -> KnownCable? {
		// Scan all records; return the first VID+PID match found.
		for record in records {
			guard let v = record.numericVID, let p = record.numericPID else { continue }
			if v == vendorID && p == productID {
				return record
			}
		}
		return nil
	}

	//============================================
	// MARK: Speed string -> CableSpeedTier mapping
	//============================================

	/// Map a DB speed string to the matching CableSpeedTier.
	///
	/// The speed strings in the DB are multilingual; matching uses the stable
	/// ASCII prefixes that appear in all observed variants:
	///   "USB 2.0"      -> usb2
	///   "USB 3.2 Gen 1" -> gen5g
	///   "USB 3.2 Gen 2" -> gen10g
	///   "USB4 Gen 3"   -> gen20to40g
	///   "USB4 Gen 4"   -> gen80g
	///
	/// Returns .unknown for any string not matching these prefixes.
	///
	/// Args:
	///   speed: the raw speed string from the database record.
	///
	/// Returns:
	///   The matching CableSpeedTier; .unknown when unrecognized.
	static func speedTierFromString(_ speed: String) -> CableSpeedTier {
		// Match USB4 Gen 4 before Gen 3 to avoid a shorter prefix match.
		if speed.hasPrefix("USB4 Gen 4") {
			return .gen80g
		}
		if speed.hasPrefix("USB4 Gen 3") {
			return .gen20to40g
		}
		// Match USB 3.2 Gen 2 before Gen 1 to avoid a shorter prefix match.
		if speed.hasPrefix("USB 3.2 Gen 2") {
			return .gen10g
		}
		if speed.hasPrefix("USB 3.2 Gen 1") {
			return .gen5g
		}
		if speed.hasPrefix("USB 2.0") {
			return .usb2
		}
		// No recognized prefix; return unknown rather than crashing.
		return .unknown
	}
}
