// WatchFrontend.swift -- the watch-mode frontend glue that turns PlugCoordinator
// PortVerdict / PortTransition values into printed lines, with the debounce +
// coalesce policy that lets a late-arriving e-marker (SOP') replace the first
// "Unknown [port active]" line for the same plug.
//
// This file is the frontend layer. It consumes only the PlugCoordinator
// PUBLIC API (currentVerdicts / mergeSnapshot / ingest / reset) and the existing
// Render helpers; it does not touch the backend occupancy logic in PlugSource.swift
// or PortWatch.swift.
//
// The make-or-break contract this wiring satisfies:
//   - watch startup prints the currently-visible cables (same state as --once),
//   - then prints insert/remove transitions as they occur,
//   - a plug yields ONE headline even when the e-marker arrives a beat late:
//       t0 ConnectionActive false->true (no SOP') -> a pending insert is HELD,
//       t1 SOP' appears for the same port  -> the held line is upgraded,
//       debounce window closes             -> ONE line is printed (e-marker if it
//                                             arrived, else Unknown [port active]).
//
// The debounce/coalesce core (WatchEmitter) is pure with respect to its inputs:
// the caller injects "now", the snapshot, and a print sink, so the policy is unit
// tested with no timers and no live IOKit. The live run loop in CLI.swift wraps it
// with a real main-queue tick that polls and flushes.

import Foundation

//============================================
// MARK: Debounce constant
//============================================

/// How long a freshly-detected plug is held before its line is printed, so a
/// late SOP' e-marker (which on this M1 hardware can appear a beat after the port
/// goes ConnectionActive) can upgrade the held "Unknown [port active]" line to the
/// rated e-marker headline. A single plug therefore yields exactly one line.
///
/// 0.4s is long enough to catch the typical SOP' settle (observed ~100-300ms after
/// ConnectionActive on this Mac) yet short enough that the printed line still feels
/// immediate. If the window closes before any SOP' arrives, the held Unknown line
/// is printed as-is (the honest occupied-but-no-readable-e-marker result).
public let watchDebounceSeconds: Double = 0.4

//============================================
// MARK: Pending insert (one per port per plug)
//============================================

/// A plug detected but not yet printed: it is held until its debounce deadline so a
/// late e-marker can upgrade it. Coalesced by port number, so repeated detections
/// of the same ongoing plug do not stack up multiple pending lines.
struct PendingInsert: Equatable {
	/// The port number this plug is for (the coalesce key).
	let portNumber: Int
	/// The wall-clock time at which the held line should be printed (set when the
	/// plug was first seen; not extended on later sightings, so a steady plug is
	/// printed once the original window closes).
	let deadline: Double
	/// The best verdict seen for this port so far (upgraded if a later snapshot
	/// carries a readable e-marker for the same port).
	let verdict: PortVerdict
}

//============================================
// MARK: Watch emitter (pure debounce + coalesce)
//============================================

/// Turns coordinator transitions into printed lines under the debounce + coalesce
/// policy. Pure with respect to its inputs: time and snapshots are injected, and
/// printing goes through an injected sink, so the policy is fully unit-testable.
///
/// Usage from the live loop:
///   1. on each tick, snapshot ports + SOP nodes and call `coordinator.ingest(...)`;
///   2. pass the resulting transitions to `offer(transitions:now:)`;
///   3. call `flushReady(now:ports:sopNodes:coordinator:)` so any held insert past
///      its deadline is re-merged against the latest snapshot (picking up a late
///      e-marker) and printed once.
/// Removes are printed immediately (there is nothing to wait for on an unplug).
public final class WatchEmitter {

	/// Where a finished line goes. Injected so tests capture lines instead of
	/// writing to stdout.
	private let emit: (String) -> Void

	/// True for JSON output (machine events) instead of human text headlines.
	private let json: Bool

	/// Held inserts awaiting their debounce deadline, keyed by port number so a
	/// repeated detection of the same plug coalesces into the one pending entry.
	private var pending: [Int: PendingInsert] = [:]

	/// Build an emitter over a print sink.
	///
	/// Args:
	///   json: whether to emit JSON event lines instead of human headlines.
	///   emit: the sink that receives each finished line (no trailing newline).
	public init(json: Bool, emit: @escaping (String) -> Void) {
		self.json = json
		self.emit = emit
	}

	//============================================
	// MARK: Startup scan
	//============================================

	/// Print the startup scan: one two-line block per currently-occupied port (text)
	/// or one JSON event per port (--json). This is the make-or-break fix -- a cable
	/// already plugged in when the watch starts is printed immediately, matching
	/// `--once`. Startup verdicts are NOT debounced (they are the already-settled
	/// current state), so they print directly.
	///
	/// Args:
	///   verdicts: the coordinator's `currentVerdicts()` at startup.
	public func emitStartup(_ verdicts: [PortVerdict]) {
		for portVerdict in verdicts {
			emit(line(for: portVerdict, event: "snapshot"))
		}
	}

	//============================================
	// MARK: Live transitions
	//============================================

	/// Accept the transitions from one `coordinator.ingest(...)` call. Inserts are
	/// held (debounced + coalesced by port); removes are printed immediately and
	/// also clear any still-pending insert for that port (a plug that was unplugged
	/// before its line printed never prints).
	///
	/// Args:
	///   transitions: the plug/unplug verdicts from the latest ingest.
	///   now: the current wall-clock time (injected for testability).
	public func offer(transitions: [PlugCoordinator.PortTransition], now: Double) {
		for transition in transitions {
			switch transition.kind {
			case .inserted:
				offerInsert(transition.verdict, now: now)
			case .removed:
				// A plug removed before its held line printed never prints.
				pending[transition.portNumber] = nil
				emit(removeLine(for: transition.verdict))
			}
		}
	}

	/// Record or upgrade a held insert for a port.
	///
	/// The first sighting sets the deadline (now + the debounce window). A later
	/// sighting for the same ongoing plug keeps the original deadline (so a steady
	/// plug still prints once the first window closes) but upgrades the held verdict
	/// when the new one carries a readable e-marker -- the late-SOP' upgrade.
	///
	/// Args:
	///   verdict: the merged verdict for the freshly-occupied port.
	///   now: the current wall-clock time.
	private func offerInsert(_ verdict: PortVerdict, now: Double) {
		let number = verdict.portNumber
		if let existing = pending[number] {
			// Coalesce: keep the original deadline; upgrade to the e-marker verdict
			// if the new one is readable and the held one was not.
			let upgraded = chooseRicher(existing.verdict, verdict)
			pending[number] = PendingInsert(
				portNumber: number,
				deadline: existing.deadline,
				verdict: upgraded
			)
			return
		}
		// First sighting of this plug: hold it until the debounce window closes.
		pending[number] = PendingInsert(
			portNumber: number,
			deadline: now + watchDebounceSeconds,
			verdict: verdict
		)
	}

	/// Flush every held insert whose debounce deadline has passed. Before printing,
	/// each is re-merged against the LATEST snapshot so a late e-marker that arrived
	/// during the window upgrades the line; a plug that vanished during the window is
	/// dropped silently. Exactly one line is printed per surviving plug.
	///
	/// Args:
	///   now: the current wall-clock time.
	///   ports: the latest port-state snapshot (for the re-merge).
	///   sopNodes: the latest SOP-node snapshot (carries any late e-marker).
	///   devices: the latest attached-USB-device snapshot (carries any far-end device
	///     speed floor). Defaults to empty so pre-M5 callers keep their behavior.
	///   coordinator: the coordinator whose pure `mergeSnapshot` does the re-merge.
	public func flushReady(
		now: Double,
		ports: [PortState],
		sopNodes: [DetectedCable],
		devices: [DeviceState] = [],
		coordinator: PlugCoordinator
	) {
		// Re-merge once against the latest snapshot; index by port number so each
		// ready insert reads the freshest verdict (with any late e-marker or device
		// floor).
		let fresh = coordinator.mergeSnapshot(
			ports: ports,
			sopNodes: sopNodes,
			devices: devices
		)
		var freshByNumber: [Int: PortVerdict] = [:]
		for portVerdict in fresh {
			freshByNumber[portVerdict.portNumber] = portVerdict
		}

		// Collect the ready port numbers first so mutating `pending` is safe.
		let readyNumbers = pending.values
			.filter { $0.deadline <= now }
			.map { $0.portNumber }
			.sorted()

		for number in readyNumbers {
			guard let held = pending[number] else {
				continue
			}
			pending[number] = nil
			// Prefer the freshest re-merged verdict (late e-marker upgrade); fall
			// back to the held verdict when the port is no longer in the snapshot but
			// has not been seen as a remove (rare race). A port that flipped idle and
			// is now absent from the snapshot is dropped (no line).
			if let current = freshByNumber[number] {
				let best = chooseRicher(held.verdict, current)
				emit(line(for: best, event: "inserted"))
			} else {
				// Not in the fresh snapshot: the plug vanished within the window.
				// Drop it silently rather than printing a stale headline.
				continue
			}
		}
	}

	/// True when any insert is still held (used by the live loop to keep ticking
	/// promptly until the debounce window drains, and by tests).
	public var hasPending: Bool {
		return !pending.isEmpty
	}

	/// Forget all held inserts. Mirrors `coordinator.reset()` for a fresh watch.
	public func reset() {
		pending.removeAll()
	}

	//============================================
	// MARK: Line rendering
	//============================================

	/// Pick the richer of two verdicts for the same port, following the rating
	/// precedence: a readable cable e-marker wins over a device-speed floor, which in
	/// turn wins over an Unknown [port active] line. When the two verdicts have the
	/// same richness, the newer (incoming) one wins so the freshest occupancy source
	/// is reflected.
	///
	/// This mirrors the coordinator's mergePort precedence (e-marker > device floor >
	/// Unknown) so a held Unknown line is upgraded to an "At least <speed> [device]"
	/// line when a USB3+ device appears within the debounce window, and to the full
	/// "<Bucket> [e-marker]" line when the cable's e-marker is finally read.
	///
	/// Args:
	///   held: the verdict already held for the port.
	///   incoming: the newly-seen verdict for the same port.
	///
	/// Returns:
	///   The verdict to keep/print.
	private func chooseRicher(_ held: PortVerdict, _ incoming: PortVerdict) -> PortVerdict {
		// Higher rank == richer rating. e-marker (2) > device floor (1) > Unknown (0).
		if verdictRichness(incoming) >= verdictRichness(held) {
			return incoming
		}
		return held
	}

	/// Rank a port verdict by how much information it carries, for the coalesce
	/// upgrade order: a readable cable e-marker (2) beats a device-speed floor (1),
	/// which beats the honest Unknown [port active] line (0).
	///
	/// Args:
	///   portVerdict: the verdict to rank.
	///
	/// Returns:
	///   2 for a readable e-marker, 1 for a device floor, 0 otherwise.
	private func verdictRichness(_ portVerdict: PortVerdict) -> Int {
		if portVerdict.hasReadableEMarker {
			return 2
		}
		if portVerdict.verdict.basis == .deviceFloor {
			return 1
		}
		return 0
	}

	/// Render one occupied-port verdict (startup or insert) as a finished output unit:
	/// the two-line block for human text (colored headline + indented detail
	/// line), or the stable JSON event line for --json.
	///
	/// The emitted text is a two-line block ("Port N: <Bucket> [basis]\n<detail>");
	/// the print sink writes it with one trailing newline, so the block stays one
	/// logical unit per port. The JSON path is unchanged (one event object per line).
	///
	/// Args:
	///   portVerdict: the verdict to render.
	///   event: the JSON event name ("snapshot" / "inserted" / "removed"); ignored
	///     in text mode.
	///
	/// Returns:
	///   The finished output unit (no trailing newline): a JSON object, or a two-line
	///   human block.
	private func line(for portVerdict: PortVerdict, event: String) -> String {
		if json {
			// Keep the JSON schema stable: reuse the existing Verdict renderer with
			// the port verdict's underlying Verdict and the event name.
			let text = renderJSON(portVerdict.verdict, event: event)
			return text
		}
		// Human text: the richer two-line block -- the calm port-led headline (bucket
		// token colored only on a real TTY) plus the indented detail line beneath it.
		let text = renderPortBlock(portVerdict)
		return text
	}

	/// Render a removal as a finished output unit: a distinct one-line unplug message
	/// for human text ("Port N: unplugged"), or the stable JSON "removed" event line
	/// for --json.
	///
	/// The remove transition is reliable here (the pure PortTransitionTracker emits
	/// one clean true->false event per physical unplug), so text mode renders it
	/// distinctly instead of the old plug-shaped "Port N: Unknown [port active]" line.
	/// The JSON schema is untouched: a removal is still one "event":"removed" object.
	///
	/// Args:
	///   portVerdict: the removed-port verdict (carries the port number).
	///
	/// Returns:
	///   The finished output unit (no trailing newline).
	private func removeLine(for portVerdict: PortVerdict) -> String {
		if json {
			// JSON unchanged: a removal is still a "removed" event with the stable
			// schema (the underlying Verdict is the honest UNKNOWN/noEmarker value).
			let text = renderJSON(portVerdict.verdict, event: "removed")
			return text
		}
		// Human text: a distinct unplug line, never a plug-shaped headline.
		let text = renderPortUnplug(portNumber: portVerdict.portNumber)
		return text
	}
}
