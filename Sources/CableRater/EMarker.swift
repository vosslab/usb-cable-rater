// EMarker.swift -- pure Cable VDO and ID Header VDO decode functions.
//
// Adapted from whatcable Sources/WhatCableCore/USB/USBPDVDO.swift:
//   PDVDO.CableSpeed (rawValues 0-4, speed bit extraction)
//   PDVDO.CableCurrent (rawValues 0-2, current bit extraction)
//   PDVDO.UFPProductType (rawValues 3/4 -> passive/active)
//   PDVDO.decodeIDHeader (bit extraction for UFP field, vendor ID)
//   PDVDO.decodeCableVDO (speed bits 2..0, current bits 6..5)
// MIT license, Darryl Morley 2026.
//
// IMPORTANT (value-3 ambiguity):
//   PD revision is NOT available at this layer. VDO speed bits == 3 means
//   20 Gbps in PD 3.0 or 40 Gbps in PD 3.1. Until the step-3 IOKit spike
//   confirms PD-revision availability, value 3 decodes to gen20to40g.
//   The step-3 spike will decide whether a split is possible.

/// Pure decode functions for USB-PD e-marker VDO data.
///
/// No IOKit imports; these functions work on raw UInt32 values so they
/// can be fully unit-tested without hardware.
public enum EMarker {

	//============================================
	// MARK: Cable VDO speed decode
	//============================================

	/// Decode the USB-signaling speed tier from a raw 32-bit Cable VDO.
	///
	/// Extracts bits 2..0 (USB Highest Speed field) and maps to a speed tier.
	/// Adapted from PDVDO.decodeCableVDO and PDVDO.CableSpeed in
	/// whatcable Sources/WhatCableCore/USB/USBPDVDO.swift.
	///
	/// Value-3 note: no PD-revision info at this layer, so 3 maps to gen20to40g.
	/// Out-of-range bits (5-7, which are undefined by the PD spec) map to unknown.
	///
	/// Args:
	///   cableVDO: raw 32-bit Cable VDO as read from the e-marker chip.
	///
	/// Returns:
	///   The decoded CableSpeedTier; never traps.
	public static func decodeSpeed(cableVDO: UInt32) -> CableSpeedTier {
		// Extract bits 2..0: USB Highest Speed field.
		// Adapted from PDVDO.decodeCableVDO: `let speedBits = Int(vdo & 0b111)`
		let speedBits = Int(cableVDO & 0b111)
		let tier = speedTierFromBits(speedBits)
		return tier
	}

	/// Map the raw 3-bit speed field value to a CableSpeedTier.
	///
	/// Adapted from PDVDO.CableSpeed rawValues in USBPDVDO.swift:
	///   0 -> usb20, 1 -> usb32Gen1 (5G), 2 -> usb32Gen2 (10G),
	///   3 -> usb4Gen3 (20/40G ambiguous), 4 -> usb4Gen4 (80G).
	///
	/// Args:
	///   bits: the 3-bit integer value (0-7).
	///
	/// Returns:
	///   CableSpeedTier; unknown for any value not defined by the PD spec (5-7).
	static func speedTierFromBits(_ bits: Int) -> CableSpeedTier {
		switch bits {
		case 0:
			// USB 2.0 only (480 Mbps)
			return .usb2
		case 1:
			// USB 3.2 Gen 1 (5 Gbps)
			return .gen5g
		case 2:
			// USB 3.2 Gen 2 (10 Gbps)
			return .gen10g
		case 3:
			// USB4 Gen 3: 20 Gbps (PD 3.0) or 40 Gbps (PD 3.1).
			// PD revision is not available here; default to the combined bucket.
			return .gen20to40g
		case 4:
			// USB4 Gen 4 (80 Gbps)
			return .gen80g
		default:
			// Values 5-7 are out of range / reserved by the PD spec.
			return .unknown
		}
	}

	//============================================
	// MARK: Cable VDO current decode
	//============================================

	/// Decode the cable current rating from a raw 32-bit Cable VDO.
	///
	/// Extracts bits 6..5 (VBUS Current Handling field).
	/// Adapted from PDVDO.decodeCableVDO:
	///   `let currentBits = Int((vdo >> 5) & 0b11)`
	/// and PDVDO.CableCurrent rawValues:
	///   0 -> usbDefault, 1 -> threeAmp, 2 -> fiveAmp.
	///
	/// Args:
	///   cableVDO: raw 32-bit Cable VDO.
	///
	/// Returns:
	///   CableCurrent; unknown for any out-of-range value (bits == 3).
	public static func decodeCurrent(cableVDO: UInt32) -> CableCurrent {
		// Extract bits 6..5: VBUS Current Handling field.
		let currentBits = Int((cableVDO >> 5) & 0b11)
		let current = cableCurrentFromBits(currentBits)
		return current
	}

	/// Map the raw 2-bit current field value to a CableCurrent.
	///
	/// Args:
	///   bits: the 2-bit integer value (0-3).
	///
	/// Returns:
	///   CableCurrent; unknown for bits == 3 (reserved by PD spec).
	static func cableCurrentFromBits(_ bits: Int) -> CableCurrent {
		switch bits {
		case 0:
			return .usbDefault
		case 1:
			return .threeAmp
		case 2:
			return .fiveAmp
		default:
			// Value 3 is reserved per Table 6.42.
			return .unknown
		}
	}

	//============================================
	// MARK: ID Header VDO product type decode
	//============================================

	/// Decode the cable product type from a raw 32-bit ID Header VDO.
	///
	/// Extracts UFP product type from bits 29..27.
	/// Adapted from PDVDO.decodeIDHeader in USBPDVDO.swift:
	///   `ufpProductType: UFPProductType(rawValue: Int((vdo >> 27) & 0b111))`
	/// and PDVDO.UFPProductType: passiveCable=3, activeCable=4.
	///
	/// Args:
	///   idHeaderVDO: raw 32-bit ID Header VDO (VDO[0]).
	///
	/// Returns:
	///   CableProductType; unknown for any value not 3 or 4.
	public static func decodeProductType(idHeaderVDO: UInt32) -> CableProductType {
		// Extract bits 29..27: UFP Product Type field.
		let ufpBits = Int((idHeaderVDO >> 27) & 0b111)
		let productType = productTypeFromBits(ufpBits)
		return productType
	}

	/// Map the raw 3-bit UFP product type field to CableProductType.
	///
	/// Adapted from PDVDO.UFPProductType (passiveCable=3, activeCable=4).
	///
	/// Args:
	///   bits: the 3-bit UFP product type value (0-7).
	///
	/// Returns:
	///   .passive for 3, .active for 4, .unknown for all other values.
	static func productTypeFromBits(_ bits: Int) -> CableProductType {
		switch bits {
		case 3:
			// passiveCable per PDVDO.UFPProductType
			return .passive
		case 4:
			// activeCable per PDVDO.UFPProductType
			return .active
		default:
			// 0=undefined, 1=pdusbHub, 2=pdusbPeripheral, 5=ama, 6=vpd, 7=other
			return .unknown
		}
	}

	//============================================
	// MARK: ID Header VDO vendor ID decode
	//============================================

	/// Decode the USB Vendor ID from a raw 32-bit ID Header VDO.
	///
	/// Extracts bits 15..0 (VID field).
	/// Adapted from PDVDO.decodeIDHeader: `vendorID: Int(vdo & 0xFFFF)`.
	///
	/// Args:
	///   idHeaderVDO: raw 32-bit ID Header VDO (VDO[0]).
	///
	/// Returns:
	///   The 16-bit Vendor ID.
	public static func decodeVendorID(idHeaderVDO: UInt32) -> UInt16 {
		// Low 16 bits are the USB Vendor ID.
		let vendorID = UInt16(idHeaderVDO & 0xFFFF)
		return vendorID
	}

	//============================================
	// MARK: Convenience full decode
	//============================================

	/// Decode a CableInfo from the two primary e-marker VDOs.
	///
	/// Combines speed, current, product type, and vendor ID into one struct.
	/// This is the primary entry point for callers that have both VDOs.
	///
	/// The raw Cable VDO word is preserved on the returned CableInfo as
	/// `rawCableVDO` so the rating layer can use it as the catalog's primary DB
	/// key. The product ID (PID) is NOT a VDO field -- it comes only from IOKit
	/// Metadata -- so it is left at 0 here and filled in by the Probe layer,
	/// keeping this decoder free of IOKit.
	///
	/// Args:
	///   cableVDO: raw 32-bit Cable VDO (passive or active, VDO[3] in PD 3.0+).
	///   idHeaderVDO: raw 32-bit ID Header VDO (VDO[0]).
	///
	/// Returns:
	///   A CableInfo with decoded fields; never traps on any bit pattern.
	public static func decode(cableVDO: UInt32, idHeaderVDO: UInt32) -> CableInfo {
		let speedTier = decodeSpeed(cableVDO: cableVDO)
		let current = decodeCurrent(cableVDO: cableVDO)
		let productType = decodeProductType(idHeaderVDO: idHeaderVDO)
		let vendorID = decodeVendorID(idHeaderVDO: idHeaderVDO)
		// Preserve the raw Cable VDO word as the DB primary key. productID stays
		// 0 here; only the Probe layer (which reads IOKit Metadata) can set it.
		let info = CableInfo(
			speedTier: speedTier,
			productType: productType,
			current: current,
			vendorID: vendorID,
			rawCableVDO: cableVDO
		)
		return info
	}
}
