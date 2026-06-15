// Model.swift -- pure value types for cable speed tier, product type, and current.
//
// Adapted from whatcable Sources/WhatCableCore/Output/LinkSpeed.swift (LinkSpeed.Tier)
// and Sources/WhatCableCore/USB/USBPDVDO.swift (PDVDO.CableSpeed, PDVDO.CableCurrent,
// PDVDO.UFPProductType). MIT license, Darryl Morley 2026.

/// Coarse USB-signaling speed bucket for a cable's e-marker.
///
/// Cases match the User-facing contract sort piles:
///   USB2, 5G, 10G, 20-40G, 80G, unknown.
/// The `unknown` case covers out-of-range or undecodeable VDO bits.
///
/// Adapted from whatcable Sources/WhatCableCore/Output/LinkSpeed.swift `Tier`
/// and USBPDVDO.swift `PDVDO.CableSpeed`.
public enum CableSpeedTier: String, Codable, Equatable, CaseIterable {
	/// USB 2.0 only (480 Mbps). VDO bits 2..0 == 0.
	case usb2
	/// USB 3.2 Gen 1 (5 Gbps). VDO bits 2..0 == 1.
	case gen5g
	/// USB 3.2 Gen 2 (10 Gbps). VDO bits 2..0 == 2.
	case gen10g
	/// USB4 Gen 3 / 20-40 Gbps. VDO bits 2..0 == 3.
	/// PD revision is not yet known, so we cannot split 20G vs 40G.
	/// Defaults to the combined bucket until step-3 spike proves a split.
	case gen20to40g
	/// USB4 Gen 4 (80 Gbps). VDO bits 2..0 == 4.
	case gen80g
	/// Out-of-range or undecodeable VDO speed bits.
	case unknown

	/// Short bucket label matching the User-facing contract sort piles.
	public var bucketLabel: String {
		switch self {
		case .usb2:      return "USB2"
		case .gen5g:     return "5G"
		case .gen10g:    return "10G"
		case .gen20to40g: return "20-40G"
		case .gen80g:    return "80G"
		case .unknown:   return "UNKNOWN"
		}
	}
}

/// Cable product type as declared in the ID Header VDO UFP field (bits 29..27).
///
/// Adapted from whatcable Sources/WhatCableCore/USB/USBPDVDO.swift
/// `PDVDO.UFPProductType` (passiveCable=3, activeCable=4).
public enum CableProductType: String, Codable, Equatable {
	/// UFP product type 3 -- passive cable.
	case passive
	/// UFP product type 4 -- active cable.
	case active
	/// UFP product type is 0, or any other value not directly a cable type.
	case unknown
}

/// Cable current rating decoded from Cable VDO bits 6..5.
///
/// Adapted from whatcable Sources/WhatCableCore/USB/USBPDVDO.swift
/// `PDVDO.CableCurrent` (usbDefault=0, threeAmp=1, fiveAmp=2).
public enum CableCurrent: String, Codable, Equatable {
	/// Bits == 0: USB default current (charitably treated as up to 3 A).
	case usbDefault
	/// Bits == 1: 3 A rated.
	case threeAmp
	/// Bits == 2: 5 A rated.
	case fiveAmp
	/// Bits == 3 or any out-of-range value.
	case unknown
}

/// Decoded summary of a cable's e-marker data for sorting purposes.
///
/// Pure value type -- no IOKit or platform dependencies.
/// Codable so it can be serialized to JSON in later steps.
public struct CableInfo: Codable, Equatable {
	/// Speed tier derived from Cable VDO USB-signaling field (bits 2..0).
	public let speedTier: CableSpeedTier
	/// Product type from ID Header VDO UFP field (bits 29..27).
	public let productType: CableProductType
	/// Current rating from Cable VDO bits 6..5.
	public let current: CableCurrent
	/// USB Vendor ID from the low 16 bits of the ID Header VDO.
	public let vendorID: UInt16
	/// Raw 32-bit Cable VDO word (VDO[3]) as read from the e-marker chip, or 0
	/// when no Cable VDO was captured. This is the catalog's primary DB key, so
	/// carrying it on CableInfo lets the live path refine a zeroed/sparse cable
	/// against the known-cable database. A zeroed Cable VDO is a legitimate value
	/// (it decodes to usb2/usbDefault), so 0 means "absent or genuinely zero".
	public let rawCableVDO: UInt32
	/// USB Product ID from the IOKit Metadata PID key, or 0 when absent. Paired
	/// with vendorID it forms the catalog's secondary VID/PID DB key. PID is not
	/// part of the e-marker VDO words; it comes only from IOKit Metadata, so the
	/// pure EMarker decoder leaves it 0 and the Probe layer fills it in.
	public let productID: UInt16

	public init(
		speedTier: CableSpeedTier,
		productType: CableProductType,
		current: CableCurrent,
		vendorID: UInt16,
		rawCableVDO: UInt32 = 0,
		productID: UInt16 = 0
	) {
		self.speedTier = speedTier
		self.productType = productType
		self.current = current
		self.vendorID = vendorID
		self.rawCableVDO = rawCableVDO
		self.productID = productID
	}
}
