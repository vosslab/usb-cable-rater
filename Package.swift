// swift-tools-version: 5.9
// SwiftPM package manifest for usb-cable-rater.
// Deployment target: macOS 13 (Ventura). Chosen because IOKit USB descriptor APIs
// used in later tasks are stable on 13+ and 13 is the oldest macOS with broad
// Apple Silicon + Intel support as of 2026.

import PackageDescription

let package = Package(
	name: "usb-cable-rater",
	platforms: [
		.macOS(.v13),
	],
	products: [
		.executable(name: "usb-cable-rater", targets: ["usb-cable-rater"]),
		.library(name: "CableRater", targets: ["CableRater"]),
	],
	targets: [
		// Library: USB cable rating logic. Files land flat here in later tasks.
		.target(
			name: "CableRater",
			path: "Sources/CableRater",
			resources: [
				// known_cables.json: vendored cable DB from whatcable (MIT, Darryl Morley 2026).
				// Loaded at runtime by Catalog.swift via Bundle.module.
				.process("Resources/known_cables.json"),
			],
			linkerSettings: [
				// Probe.swift uses IOKit service matching, notification ports,
				// and registry property reads, which require the IOKit and
				// CoreFoundation system frameworks at link time. Foundation is
				// brought in transitively but listed for clarity.
				.linkedFramework("IOKit"),
				.linkedFramework("CoreFoundation"),
				.linkedFramework("Foundation"),
			]
		),
		// Executable: CLI entry point, depends on CableRater library.
		.executableTarget(
			name: "usb-cable-rater",
			dependencies: ["CableRater"],
			path: "Sources/usb-cable-rater"
		),
		// Tests for the CableRater library.
		.testTarget(
			name: "CableRaterTests",
			dependencies: ["CableRater"],
			path: "tests/CableRaterTests",
			resources: [
				// Fixture plists: captured M1 IOKit port-controller and SOP node snapshots.
				// Loaded by FixtureLoadTests via Bundle.module to prove offline fixture loading.
				.process("Fixtures"),
			]
		),
	]
)
