// CLI.swift -- argument parsing and the run loop for the usb-cable-rater binary.
//
// Modes:
//   default     live watch: one line per physical plug. Text mode shows inserts
//               only (quiet on unplug); --json shows inserted AND removed events.
//   --once      snapshot currentCables() once, print verdict(s), exit 0.
//   --json      machine output (works with both live and --once).
//   --help      usage text, exit 0.
//   --version   version string, exit 0.
//
// Ctrl+C (SIGINT) calls source.stop() and exits 130 cleanly.
//
// main.swift is intentionally thin and delegates to runCLI here.

import Foundation

//============================================
// MARK: Parsed options
//============================================

/// The supported flags after hand-rolled parsing.
struct CLIOptions: Equatable {
	/// --once: take a single snapshot and exit instead of watching.
	var once: Bool = false
	/// --json: emit machine-readable JSON instead of human text.
	var json: Bool = false
	/// --debug: print raw IOKit event diagnostics to stderr (also covers
	/// baseline/pre-existing services). Visibility tool for silent-plug debugging.
	var debug: Bool = false
	/// --help: print usage and exit.
	var help: Bool = false
	/// --version: print the version and exit.
	var version: Bool = false
}

/// Result of parsing: either valid options or an error message to report.
enum CLIParseResult: Equatable {
	case options(CLIOptions)
	case error(String)
}

//============================================
// MARK: Argument parsing
//============================================

/// Parse the four supported flags from raw CLI arguments (excluding argv[0]).
///
/// Unknown flags produce an error result so the caller can fail loud rather than
/// silently ignoring a typo. Flags may appear in any order; duplicates are
/// idempotent.
///
/// Args:
///   arguments: the argument list without the program name.
///
/// Returns:
///   .options on success, or .error with a message naming the bad flag.
func parseCLI(_ arguments: [String]) -> CLIParseResult {
	var options = CLIOptions()
	for argument in arguments {
		switch argument {
		case "--once":
			options.once = true
		case "--json":
			options.json = true
		case "--debug", "-d":
			options.debug = true
		case "--help", "-h":
			options.help = true
		case "--version", "-v":
			options.version = true
		default:
			// Unknown flag: report it rather than ignoring it.
			let message = "unknown argument: " + argument
			return .error(message)
		}
	}
	return .options(options)
}

//============================================
// MARK: Usage and version text
//============================================

/// The usage/help text for --help.
///
/// Returns:
///   A multi-line usage string (no trailing newline).
func usageText() -> String {
	var lines: [String] = []
	lines.append("usb-cable-rater -- sort USB-C cables by data-rate from their e-marker")
	lines.append("")
	lines.append("USAGE:")
	lines.append("  usb-cable-rater [--once] [--json] [--debug] [--help] [--version]")
	lines.append("")
	lines.append("MODES:")
	lines.append("  (default)   live watch: print one line per cable plugged in,")
	lines.append("              runs until Ctrl+C (exit 130)")
	lines.append("  --once      snapshot plugged-in cables once, then exit")
	lines.append("")
	lines.append("OPTIONS:")
	lines.append("  --json      machine-readable JSON output (also reports unplug events)")
	lines.append("  --debug, -d  print raw IOKit event diagnostics to stderr")
	lines.append("              (use this to troubleshoot a cable that plugs in silently)")
	lines.append("  --help, -h  show this help and exit")
	lines.append("  --version, -v  show version and exit")
	lines.append("")
	lines.append("LABELS:")
	lines.append("  USB2 / 5G / 10G / 20-40G / 80G  -- data-rate piles")
	lines.append("  UNKNOWN            no e-marker found (likely a plain USB2 cable)")
	lines.append("  POTENTIALLY FAST?  e-marker present but unrecognized -- worth investigating")
	let text = lines.joined(separator: "\n")
	return text
}

/// The version line for --version.
///
/// Returns:
///   "usb-cable-rater <version>".
func versionText() -> String {
	// Reuse the single source-of-truth version constant from CableRater.swift.
	let text = "usb-cable-rater " + cableRaterVersion
	return text
}

//============================================
// MARK: Debug diagnostics
//============================================

/// Build the one-line raw IOKit diagnostic string for a detected service.
///
/// This is the visibility tool for silent-plug debugging: it reports exactly what
/// IOKit delivered for an event -- the service class, registry ID, how many
/// Metadata keys and VDO blobs were present, and whether the e-marker decoded.
/// A non-e-marked cable's silent-plug signature looks like
/// `metadataKeys=0 vdos=0 decoded=nil`. The label is "matched" for a match event
/// and "terminated" for a removal.
///
/// Pure (no I/O) so it is unit-testable; the caller writes the returned line to
/// stderr so it never pollutes --json on stdout.
///
/// Args:
///   detected: the matched/terminated service.
///   matched: true for a matched event, false for a terminated event.
///
/// Returns:
///   The single diagnostic line (no trailing newline), e.g.
///   "[debug] matched class=IOPortTransportComponentCCUSBPDSOP id=0x100080c39 metadataKeys=0 vdos=0 decoded=nil".
public func debugLine(for detected: DetectedCable, matched: Bool) -> String {
	let label = matched ? "matched" : "terminated"
	// Decoded shows the speed tier raw value on a hit, or "nil" when the service
	// had no usable e-marker (the silent-plug case).
	let decoded: String
	if let info = detected.info {
		decoded = info.speedTier.rawValue
	} else {
		decoded = "nil"
	}
	// Registry ID in hex matches IOKit tooling (ioreg) conventions.
	let idHex = String(format: "0x%llx", detected.registryID)
	var line = "[debug] " + label
	line += " class=" + detected.serviceClass
	line += " id=" + idHex
	line += " metadataKeys=" + String(detected.metadataKeyCount)
	line += " vdos=" + String(detected.vdoCount)
	line += " decoded=" + decoded
	return line
}

/// Build the one-line raw diagnostic string for a port-controller event.
///
/// This is the --debug probe path for the PRIMARY (port-state) backend source. It
/// names the matched backend source -- the IOKit class that produced the event
/// and which property carried the occupancy signal -- so a rendered port line
/// counts only when its backend source is shown (frontend success cannot hide a
/// backend failure). A non-USB-C / no-PortNumber candidate that the IOPort guard
/// suppressed never produces a PortEvent, so it never reaches this line.
///
/// Pure (no I/O) so it is unit-testable; the caller writes the returned line to
/// stderr so it never pollutes --json on stdout.
///
/// Args:
///   event: the port plug/unplug event.
///
/// Returns:
///   The single diagnostic line (no trailing newline), e.g.
///   "[debug] port inserted class=AppleTCControllerType10 port=3 source=ConnectionActive connectionActive=true".
public func portDebugLine(for event: PortEvent) -> String {
	let state = event.state
	// Port number is the correlation key; "?" when the (synthesized remove) state
	// somehow lacks one, though removes always carry the port number.
	let portText: String
	if let number = state.portNumber {
		portText = String(number)
	} else {
		portText = "?"
	}
	// The property that produced the event (matched backend source detail).
	let sourceText = event.source.rawValue
	// Raw ConnectionActive value for transparency: "true"/"false"/"nil".
	let connText: String
	if let active = state.connectionActive {
		connText = active ? "true" : "false"
	} else {
		connText = "nil"
	}
	var line = "[debug] port " + event.kind.rawValue
	line += " class=" + state.serviceClass
	line += " port=" + portText
	line += " source=" + sourceText
	line += " connectionActive=" + connText
	return line
}

/// Build the one-line raw diagnostic string for a merged per-port verdict.
///
/// This is the --debug raw-fields probe for a RATED port: it names the matched
/// backend source (`backendSource`) and the occupancy avenue (`occupancySource`)
/// that decided the port, the "type/number" `portKey` the port-state and PD-identity
/// sources correlated on, whether an SOP node was present (`sopServicePresent`), and
/// -- when a cable e-marker decoded -- its raw hex fields (`rawCableVDO`,
/// `productID`, `vendorID`) plus the SOP endpoint that supplied the headline.
///
/// --debug is raw diagnostics, not a verbose alias: this prints the unrounded fields
/// (hex VDO word, raw IDs) an advanced user needs to identify a cable, on stderr so
/// --json on stdout stays clean. A port with no readable e-marker prints the
/// occupancy fields and `decoded=nil`, the honest "occupied, no e-marker" signature.
///
/// Pure (no I/O) so it is unit-testable; the caller writes the returned line to
/// stderr.
///
/// Args:
///   portVerdict: the merged per-port verdict to describe.
///
/// Returns:
///   The single diagnostic line (no trailing newline), e.g.
///   "[debug] port 3 source=sopIdentity occupancy=connectionActive portKey=2/3 sopPresent=true cableVDO=0x00000022 productID=0x0001 vendorID=0x05AC endpoint=SOP' decoded=gen10g".
///   A port with no readable e-marker omits the hex/endpoint fields and ends with
///   "decoded=nil".
public func portVerdictDebugLine(for portVerdict: PortVerdict) -> String {
	var line = "[debug] port " + String(portVerdict.portNumber)
	// The matched backend source (which avenue produced the verdict) and the
	// occupancy avenue (the port-controller property or PD identity that decided it).
	line += " source=" + portVerdict.backendSource.rawValue
	line += " occupancy=" + portVerdict.occupancySource.rawValue
	// The whatcable-style join key the two backends correlated on.
	line += " portKey=" + portVerdict.portKey
	// Whether a SOP / SOP' / SOP'' node was present (even with empty Metadata).
	line += " sopPresent=" + (portVerdict.sopServicePresent ? "true" : "false")
	// Raw e-marker fields when a cable decoded; the honest nil signature otherwise.
	if let cable = portVerdict.verdict.cable {
		// rawCableVDO as the full 32-bit hex word (the catalog's primary DB key).
		line += String(format: " cableVDO=0x%08X", cable.rawCableVDO)
		// productID and vendorID as 16-bit hex (the secondary VID/PID DB key).
		line += String(format: " productID=0x%04X", cable.productID)
		line += String(format: " vendorID=0x%04X", cable.vendorID)
		// The SOP endpoint that supplies a decoded headline rating is always the
		// near-end cable e-marker SOP' (decodePort prefers SOP', then SOP'' as a
		// fallback that carries the same cable VDO; the SOP partner node is never the
		// headline). Naming it keeps the per-port probe explicit about the source.
		line += " endpoint=" + SOPEndpoint.sopPrime.rawValue
		// The speed tier the e-marker decoded to (raw enum value).
		line += " decoded=" + cable.speedTier.rawValue
	} else if portVerdict.verdict.basis == .deviceFloor {
		// M5 device-speed floor: no cable e-marker, but a far-end USB3+ device floored
		// the rating. Name the floor tier so the probe shows where the headline came
		// from (the device, not the cable's own e-marker).
		line += " decoded=nil deviceFloor=" + portVerdict.verdict.tier.rawValue
	} else {
		// Occupied port, no readable e-marker and no device floor: name no raw fields.
		line += " decoded=nil"
	}
	return line
}

/// Write one diagnostic line to standard error (never stdout), so --debug output
/// stays separate from --json machine output on stdout.
///
/// Args:
///   line: the diagnostic line (a trailing newline is added).
func writeDebug(_ line: String) {
	FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Write one `portDebugLine` per OCCUPIED port in a port-state snapshot, naming the
/// matched backend source (IOKit class + the property that carried occupancy). This
/// is the wired --debug probe for the PRIMARY (port-state) backend: a rendered port
/// line counts only when its backend source is shown, so the snapshot/startup paths
/// emit the probe for every port they will rate.
///
/// A port that does not clear the IOPort/PortNumber guard or is idle produces no
/// occupancy source and so prints nothing -- it would never be rated either.
///
/// Args:
///   ports: the port-state snapshot to probe.
func writePortDebug(_ ports: [PortState]) {
	for state in ports {
		// Only an occupied port has a backend source to name; the source mirrors the
		// occupancy decision the coordinator makes for the same port.
		guard let source = PortLiveness.occupancySource(state) else {
			continue
		}
		// Synthesize the inserted event the probe formats. The snapshot/startup paths
		// have no live PortEvent, so this names the matched source for the rated port.
		let event = PortEvent(kind: .inserted, state: state, source: source)
		writeDebug(portDebugLine(for: event))
	}
}

/// Write one `portVerdictDebugLine` per occupied port in a merged snapshot, naming
/// the matched backend source / occupancy avenue and the raw e-marker fields
/// (rawCableVDO, productID, vendorID, SOP endpoint, portKey) for each rated port.
///
/// This is the raw-fields probe: it complements the port-state class probe
/// (`writePortDebug`) with the merged per-port detail an advanced user needs --
/// printed on stderr so --json on stdout stays clean. Driven by the coordinator's
/// verdicts (one per occupied port), so it lists exactly the ports that will be
/// rated and nothing for an idle/invisible port.
///
/// Args:
///   verdicts: the coordinator's merged per-port verdicts (currentVerdicts()).
func writeVerdictDebug(_ verdicts: [PortVerdict]) {
	for portVerdict in verdicts {
		writeDebug(portVerdictDebugLine(for: portVerdict))
	}
}

//============================================
// MARK: SIGINT handling
//============================================

/// Shared reference to the active port watcher so the SIGINT handler can stop it
/// and release its IOKit resources cleanly.
///
/// A C signal handler cannot capture context, so the watcher is held here as a
/// module-level reference set just before the watch loop arms. It is read-only
/// after assignment from the handler's perspective.
private var activePortWatcher: PortWatcher?

/// Install a SIGINT (Ctrl+C) handler that stops the watch cleanly and exits 130.
///
/// 130 is the conventional shell exit code for a process terminated by SIGINT
/// (128 + signal number 2).
///
/// Args:
///   portWatcher: the port-state watcher to stop on interrupt (releases its IOKit
///     notification port and per-service interest handles).
func installSIGINTHandler(_ portWatcher: PortWatcher) {
	activePortWatcher = portWatcher
	// A bare C function pointer: no captures allowed, so it uses activePortWatcher.
	signal(SIGINT) { _ in
		activePortWatcher?.stop()
		// Flush any buffered stdout before exiting.
		fflush(stdout)
		exit(130)
	}
}

//============================================
// MARK: Run loop
//============================================

/// Entry point invoked by main.swift. Parses arguments, builds the catalog and
/// IOKit source, and dispatches to the requested mode.
///
/// Args:
///   arguments: the argument list without the program name (CommandLine.arguments
///     dropping the first element).
///
/// Returns:
///   The process exit code. The live-watch path does not return (it runs the
///   main dispatch loop until SIGINT), so it is annotated accordingly by callers.
public func runCLI(_ arguments: [String]) -> Int32 {
	// Parse first; a bad flag fails loud before any IOKit work.
	let parsed = parseCLI(arguments)
	let options: CLIOptions
	switch parsed {
	case .error(let message):
		FileHandle.standardError.write(Data((message + "\n").utf8))
		FileHandle.standardError.write(Data((usageText() + "\n").utf8))
		return 2
	case .options(let parsedOptions):
		options = parsedOptions
	}

	// --help and --version short-circuit before touching hardware.
	if options.help {
		print(usageText())
		return 0
	}
	if options.version {
		print(versionText())
		return 0
	}

	// Build the two M1 backend sources once and inject them into the coordinator,
	// keeping our own references so the live watch loop can arm the port watcher and
	// poll fresh snapshots from the SAME instances the coordinator merges. The
	// coordinator is the make-or-break wiring: it reports one verdict per occupied
	// port (including a bare no-e-marker cable already plugged in at startup).
	let catalog = Catalog.shared
	let portWatcher = PortWatcher()
	let cableSource = IOKitCableSource()
	let deviceWatcher = DeviceWatcher()
	let coordinator = PlugCoordinator(
		catalog: catalog,
		portWatcher: portWatcher,
		cableSource: cableSource,
		deviceWatcher: deviceWatcher
	)

	if options.once {
		let code = runOnce(
			coordinator: coordinator,
			json: options.json,
			debug: options.debug,
			portWatcher: portWatcher
		)
		return code
	}

	// Live watch never returns under normal operation: it runs the main dispatch
	// loop so IOKit main-queue callbacks fire, exiting only via the SIGINT
	// handler (exit code 130). runWatch is annotated -> Never, so no return
	// statement follows it.
	runWatch(
		coordinator: coordinator,
		json: options.json,
		debug: options.debug,
		portWatcher: portWatcher,
		cableSource: cableSource,
		deviceWatcher: deviceWatcher
	)
}

//============================================
// MARK: --once snapshot mode
//============================================

/// Take one merged snapshot of every currently-occupied USB-C port and print one
/// port-led line per port, then exit. This is the port-centered path: it prints
/// the SAME current state the watch startup scan prints, so `--once` and
/// watch-startup agree (the startup parity contract).
///
/// Every occupied port is listed, including a bare cable with no readable e-marker
/// (which renders "Port N: Unknown [port active]"). An idle/invisible port produces
/// no line. When no port is occupied at all, text prints "No cable plugged in." and
/// JSON prints a snapshot object with a null e-marker; both return 0.
///
/// With `debug`, the port-state probe (`portDebugLine`) names the matched backend
/// source per occupied port on stderr, so a rendered port line counts only when its
/// backend source is shown (frontend success cannot hide backend failure). Debug
/// stays on stderr so --json stays clean on stdout.
///
/// Args:
///   coordinator: the plug coordinator merging the two M1 backends into one verdict
///     per occupied port.
///   json: whether to emit JSON instead of text.
///   debug: whether to write the port-state backend-source probe to stderr.
///   portWatcher: the port-state watcher, snapshotted for the --debug probe (the
///     same instance the coordinator merges).
///
/// Returns:
///   0 always (a clean snapshot, even when empty, is success).
func runOnce(
	coordinator: PlugCoordinator,
	json: Bool,
	debug: Bool,
	portWatcher: PortWatcher
) -> Int32 {
	// The merged current state: one verdict per occupied port (startup parity with
	// the watch scan). currentVerdicts() reads the same backends the watch loop polls.
	let verdicts = coordinator.currentVerdicts()

	// Debug: name the matched port-state backend class per occupied port, then the
	// merged raw e-marker fields (rawCableVDO/productID/vendorID/endpoint/portKey)
	// per rated port. Both go to stderr so --json on stdout stays clean.
	if debug {
		writePortDebug(portWatcher.currentPorts())
		writeVerdictDebug(verdicts)
	}

	// Empty snapshot: no occupied port at all -> honest nothing-plugged result.
	if verdicts.isEmpty {
		if json {
			let emptyVerdict = verdict(for: nil, catalog: Catalog.shared)
			print(renderJSON(emptyVerdict, event: "snapshot"))
		} else {
			// Text mode: a plain one-liner instead of a port block.
			print("No cable plugged in.")
		}
		return 0
	}

	// One two-line block per occupied port. The renderer carries the calm
	// "Port N: <Bucket> [basis]" headline (bucket token colored on a TTY) plus an
	// indented detail line beneath it; the underlying Verdict drives the stable,
	// unchanged JSON.
	for portVerdict in verdicts {
		if json {
			print(renderJSON(portVerdict.verdict, event: "snapshot"))
		} else {
			print(renderPortBlock(portVerdict))
		}
	}
	return 0
}

//============================================
// MARK: Live watch mode
//============================================

/// The backup poll cadence for the watch loop. A repeating main-queue timer fires
/// this often to (1) re-snapshot and diff ports through the coordinator, catching a
/// transition a missed interest callback would otherwise drop, and (2) flush any
/// held insert whose debounce window has closed. 0.25s is finer than the 0.4s
/// debounce window, so a held line is flushed within one window of its deadline and
/// a missed plug surfaces within a quarter second.
let watchPollSeconds: Double = 0.25

/// Arm the IOKit watch and run the main dispatch loop until SIGINT.
///
/// Startup contract (the make-or-break fix): after the banner, the watch prints the
/// currently-visible cables -- the same merged current state `--once` prints -- so a
/// cable already plugged in at start is no longer silent. It then watches for
/// insert/remove transitions and prints them as they occur.
///
/// Three wired avenues drive the run loop, all on the main queue (no locking):
///   - startup scan: `coordinator.currentVerdicts()` prints the current cables, then
///     the same snapshot seeds the coordinator's tracker so those ports are not
///     re-reported as inserts;
///   - interest path: `PortWatcher.watch(...)` fires on a property-only
///     ConnectionActive flip (the common plug on this Mac) and pokes a re-poll;
///   - poll backup: a repeating main-queue timer re-snapshots and diffs through the
///     coordinator so a MISSED interest callback is still caught, and flushes held
///     inserts past their debounce deadline.
///
/// Debounce + coalesce: a freshly-occupied port is held for `watchDebounceSeconds`
/// before its line prints, so a late SOP' e-marker upgrades the line; one line is
/// printed per plug (coalesced by port). Removes print immediately.
///
/// With `debug`, the port-state probe (`portDebugLine`) names the matched backend
/// source for every occupied port on each rebuild (stderr), so a rendered port line
/// counts only when its backend source is shown. Debug stays on stderr so --json
/// stays clean on stdout.
///
/// This function does not return: dispatchMain() runs forever and the SIGINT
/// handler performs the clean exit.
///
/// Args:
///   coordinator: the plug coordinator merging the two M1 backends.
///   json: whether to emit JSON instead of text.
///   debug: whether to write the port-state backend-source probe to stderr.
///   portWatcher: the port-state watcher to arm + poll (the coordinator's instance).
///   cableSource: the PD-identity source to poll for SOP nodes (the coordinator's
///     instance).
///   deviceWatcher: the attached-USB-device source to poll for the M5 device-speed
///     floor (the coordinator's instance).
func runWatch(
	coordinator: PlugCoordinator,
	json: Bool,
	debug: Bool,
	portWatcher: PortWatcher,
	cableSource: IOKitCableSource,
	deviceWatcher: DeviceWatcher
) -> Never {
	// Install the interrupt handler before arming so Ctrl+C is always clean.
	installSIGINTHandler(portWatcher)

	// Text-mode startup banner so an empty watch tells the user it is running.
	// Suppressed under --json so the output stays machine-clean.
	if !json {
		print("Watching for USB-C cables. Plug one in. Press Ctrl+C to quit.")
		fflush(stdout)
	}

	// Fresh watch: clear any prior tracked occupancy in the coordinator.
	coordinator.reset()

	// The frontend emitter owns the debounce + coalesce policy and line rendering.
	let emitter = WatchEmitter(json: json) { line in
		print(line)
		fflush(stdout)
	}

	// Startup scan: print the currently-visible cables (parity with --once), then
	// seed the coordinator's tracker with the SAME current snapshot so these
	// already-present ports are not re-reported as inserts by the first poll.
	let startupVerdicts = coordinator.currentVerdicts()
	emitter.emitStartup(startupVerdicts)
	if debug {
		writePortDebug(portWatcher.currentPorts())
		writeVerdictDebug(startupVerdicts)
	}
	// Seed the tracker: ingest the current snapshot and discard the transitions (the
	// startup scan already printed them). Subsequent diffs are relative to this.
	_ = coordinator.ingest(
		ports: portWatcher.currentPorts(),
		sopNodes: cableSource.currentCables(),
		devices: deviceWatcher.currentDevices()
	)

	// One re-poll step: snapshot ports + SOP nodes, diff through the coordinator,
	// offer the transitions to the debounce emitter, then flush any ready held line.
	// Shared by the interest poke and the backup timer; both run on the main queue.
	func pollStep() {
		let ports = portWatcher.currentPorts()
		let sopNodes = cableSource.currentCables()
		let devices = deviceWatcher.currentDevices()
		let now = Date().timeIntervalSinceReferenceDate
		let transitions = coordinator.ingest(
			ports: ports,
			sopNodes: sopNodes,
			devices: devices
		)
		emitter.offer(transitions: transitions, now: now)
		emitter.flushReady(
			now: now,
			ports: ports,
			sopNodes: sopNodes,
			devices: devices,
			coordinator: coordinator
		)
	}

	// Debug sink for the interest path: name the matched backend source for every
	// occupied port on each rebuild. nil when --debug is off so the watch skips it.
	let onDebug: (([PortState]) -> Void)? = debug ? { ports in
		writePortDebug(ports)
	} : nil

	// Interest path: a property-only ConnectionActive flip pokes a re-poll. The
	// PortWatcher's own insert/remove events are used purely as a "something changed"
	// trigger here -- the coordinator (not the watcher's internal tracker) owns the
	// merged verdict, so both callbacks route to the same pollStep.
	portWatcher.watch(
		onInsert: { _ in pollStep() },
		onRemove: { _ in pollStep() },
		onDebug: onDebug
	)

	// Backup poll timer on the main queue: catches a missed interest callback and
	// drives the debounce flush. A strong reference is kept implicitly by the active
	// dispatch source until process exit.
	let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
	timer.schedule(
		deadline: .now() + watchPollSeconds,
		repeating: watchPollSeconds
	)
	timer.setEventHandler {
		pollStep()
	}
	timer.resume()

	// Run the main dispatch queue forever so IOKit's main-queue callbacks and the
	// poll timer fire. dispatchMain never returns; the process exits via SIGINT.
	dispatchMain()
}
