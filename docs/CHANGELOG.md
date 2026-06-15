## 2026-06-15

### Additions and New Features

- M5 device-negotiated-speed fallback: added `Sources/CableRater/DeviceWatch.swift`,
  which rates a far-end USB device that actually enumerates. When no cable e-marker
  is read but a USB3+ device is present on the far end, the tool now reports an
  observed `At least <speed> [device]` floor from the negotiated link, with
  `deviceFloor` as the rating basis. This is an observed capability (what the
  device and cable negotiated together), not a proven cable maximum.
- M4 fixture-driven acceptance suite: added a 16-test acceptance suite that drives
  the merged backend from captured M1 IOKit fixtures end to end, asserting the
  port-led verdicts and rendered output for the real three-cable hardware state.
- E-marker decode-pipeline proof: added fixtures and tests proving the SOP'
  e-marker decode path produces the correct bucket for the 10G, 40G, and 80G cases
  when an SOP' node is present, confirming the decode pipeline is correct end to end.
- Added a "Reading an Unknown cable: far-end partner workflow" section to
  docs/USAGE.md (placed after "Invisible bare cables", before "How a bucket is
  decided"). It explains that an `Unknown [port active]` cable may be unqueried
  (the e-marker only answers Discover Identity once a PD partner is on the far
  end), gives the charger/dock far-end steps, notes why a passive female-female
  coupler plus hub fails (no CC termination, so no CC attach), states the honest
  limit for non-e-marked cables and the planned device-negotiated-speed fallback,
  and recommends a USB-C charger (18W+) on the far end as the most reliable
  practical setup for rating a bin of cables.
- Added `docs/HUMAN_GUIDANCE.md`: durable record of human requests and guidance
  covering product use case, backend correctness, CLI flags, git ownership,
  workflow delegation, prompting style, and environment notes.
- WP-M1a: Added fixture directory `tests/CableRaterTests/Fixtures/` with two plist
  files capturing the authoritative M1 MacBook Pro IOKit snapshot (three cables
  plugged in during the probe, Port 3 active, Ports 1-2 inactive):
  - `port_controllers_m1.plist`: array of three `AppleTCControllerType10` entries
    (PortNumber 1-3), Port 3 with `ConnectionActive = true`, `IOAccessoryDetect = true`,
    `TransportsActive = ["CC"]`; Ports 1-2 with all three fields false/empty.
    Key names match the live IOKit property set the port-state watcher will read.
  - `sop_port3.plist`: single `IOPortTransportComponentCCUSBPDSOP` node for Port 3,
    key names copied verbatim from `/tmp/sop_node.plist` (live IOKit probe), with
    `Metadata = {}` (empty dict, non-e-marked cable), `ParentPortNumber = 3`.
- WP-M1a: Added `tests/CableRaterTests/Fixtures` resource processing to the
  `CableRaterTests` target in `Package.swift` (`.process("Fixtures")`), mirroring
  the `CableRater` library's `known_cables.json` resource wiring. Fixtures are now
  bundled and reachable via `Bundle.module` in test code.
- WP-M1a: Added `tests/CableRaterTests/FixtureLoadTests.swift` with 13 XCTest cases
  proving both fixture files load via `Bundle.module`, are parseable as plist
  arrays, and contain the expected M1 seed values (Port 3 active, Ports 1-2 inactive,
  SOP present with `ParentPortNumber = 3` and empty `Metadata`).
- WP-M1b: Added `Sources/CableRater/PortWatch.swift`, the PRIMARY port-state plug
  signal, ported from whatcable
  `Sources/WhatCableDarwinBackend/Watchers/AppleHPMInterfaceWatcher.swift` and
  `Sources/WhatCableCore/Port/AppleHPMInterface.swift` (MIT, Darryl Morley 2026).
  The watch reports a cable attach from the port controller's own
  `ConnectionActive` bit instead of from a cable e-marker service, so a
  non-e-marked cable is no longer invisible. `PortWatcher.candidateClasses` matches
  `AppleTCControllerType10` plus the portable HPM/TC set, with `IOPort` kept only as
  a class-discovery catch-all (adapted from `candidateClasses`).
- WP-M1b: `PortState.from(...)` reads each operational key one at a time
  (`ConnectionActive` primary, `IOAccessoryDetect`, `TransportsActive` containing
  `"CC"`, and `PortNumber`) via per-key `IORegistryEntryCreateCFProperty`, NOT a
  bulk property fetch -- faithful to whatcable's teardown-safe `makePort`/`from`
  read path. Added `coercePortBool`/`coercePortInt`/`coercePortStringArray` helpers
  (adapted from whatcable's `NSNumber.boolValue` / `stringArrayProperty` coercions);
  an absent key reads as nil/empty, never a silent default.
- WP-M1b: `PortWatcher.watch(...)` ports the matched-notification arm-by-drain plus
  per-service `IOServiceAddInterestNotification` (`kIOGeneralInterest`) and the
  `refresh()` registry-rebuild path (adapted from whatcable `start` /
  `registerInterest` / `refresh`), including the stale-interest prune so Mach port
  references do not leak across plug/unplug cycles. Property-only `ConnectionActive`
  changes on a persistent port object reach the diff via the interest callback.
- WP-M1b: Added the detected-insertion event model distinct from the e-marker:
  `PortEvent` (`.inserted`/`.removed` + the contributing `PortSignalSource`),
  `PortLiveness` (the occupied/idle decision enforcing the plan's IOPort guard --
  an `IOPort`-derived candidate emits only after it maps to a USB-C `PortNumber` and
  passes liveness), and the pure `PortTransitionTracker` that emits one event per
  `false->true` (insert) / `true->false` (remove) transition, deduped per
  `PortNumber`.
- WP-M1b: Added the `--debug` port-probe line `portDebugLine(for:)` in
  `Sources/CableRater/CLI.swift`, printing the matched backend source (IOKit class,
  `PortNumber`, the property that produced the event, and the raw `ConnectionActive`
  value) so a rendered port line counts only when its backend source is shown.
- WP-M1b: Added `tests/CableRaterTests/PortWatchTests.swift` (17 XCTest cases)
  driven by injected in-memory snapshots with the live IOKit keys: discovers
  `AppleTCControllerType10` in the candidate set, reads `PortNumber` and
  `ConnectionActive`, proves the liveness decision and corroboration paths, proves a
  synthetic `false->true` emits insert and `true->false` emits remove (no duplicate
  for a steady port), and proves an `IOPort`-only candidate with no port mapping
  does NOT emit. The existing SOP'/e-marker probe in `Probe.swift` is unchanged
  (additive rollout).
- WP-M1c: Extended `Sources/CableRater/Probe.swift` toward whatcable
  `USBPDSOPWatcher`. Added the SOP'' class `IOPortTransportComponentCCUSBPDSOPpp` to
  `IOKitCableSource.matchedClasses`, so SOP, SOP', and SOP'' are all enumerated
  (mirrors `USBPDSOPWatcher.matchedClasses`).
- WP-M1c: Added `SOPEndpoint` enum (`sop`/`sopPrime`/`sopDoublePrime`/`unknown`)
  classified from the live IOKit class name, adapted from whatcable
  `USBPDSOP.Endpoint` and `USBPDSOPWatcher.endpoint(read:className:)`.
- WP-M1c: Exposed SOP `ParentPortNumber` on `DetectedCable` (plus `parentPortType`,
  `endpoint`, and a `portKey` "type/number" join key). `parentPortIdentity(read:)`
  reads `ParentBuiltInPortNumber`/`ParentBuiltInPortType` first, then
  `ParentPortNumber`/`ParentPortType`, matching whatcable's BuiltIn-first priority;
  an absent number reads `DetectedCable.unknownPortNumber` (-1) instead of port 0.
- WP-M1c: Added `coerceInt(_:)` IOKit value coercion helper (NSNumber/Int -> Int?)
  for the parent-port reads, alongside the existing coercion helpers.
- WP-M1c: Added the per-port decode API the coordinator will call:
  `PortPDIdentity` result type (portKey, portNumber, decoded `info`,
  `sopServicePresent`, computed `hasReadableEMarker`); pure correlation cores
  `IOKitCableSource.decodePort(forPortKey:from:)` and the convenience
  `decodePort(forPortType:portNumber:from:)`; `portKey(forPortType:portNumber:)`
  builder; and the live entry point `portIdentity(forPortType:portNumber:)`. SOP'
  supplies the cable headline; SOP'' is used only as a fallback and never
  overwrites an SOP' headline (confirmed against whatcable `USBPDSOP.cableVDO`,
  USBPDSOP.swift:93-99: SOP' near plug and SOP'' far plug carry the same cable
  VDO). The SOP (non-prime) partner node is the device/charger
  (USBPDSOP.swift:6-10) and is never used as the cable e-marker source. An
  SOP-present-but-empty-Metadata node returns a clean `info == nil`,
  `sopServicePresent == true` ("detected, no readable e-marker"), not a crash.
- WP-M1c: Added `tests/CableRaterTests/PdIdentityTests.swift` (12 XCTest cases)
  driving the pure correlation from synthetic service dictionaries shaped like the
  captured `/tmp/sop_node.plist` (ParentPortNumber 3, type 2 USB-C, empty
  Metadata): reads `ParentPortNumber` and BuiltIn-key priority; empty Metadata ->
  "no readable e-marker" clean result; SOP'-with-VDO correlates to the matching
  port by "type/number" portKey; SOP'' does not overwrite the SOP' headline;
  SOP'' fallback when no SOP'; SOP partner node is not the headline.
- WP-M1d: Added `Sources/CableRater/PlugSource.swift`, the `PlugCoordinator`. It
  merges the two ported M1 backends -- the port-state watcher (`PortWatch.swift`,
  primary plug signal) and the PD-identity decode (`Probe.swift`, cable e-marker)
  -- into ONE verdict per occupied physical USB-C port, correlated by the whatcable
  "type/number" portKey. The occupied/idle decision reuses the ported
  `PortLiveness` (ConnectionActive primary, IOPort guard) for the M1 required-now
  floor; an idle or invisible port produces no verdict (stays silent). A decoded
  e-marker rates by the cable; an occupied port with no readable e-marker yields the
  clean `Port N: Unknown [port active]` verdict. The backend logic stays in the
  faithful whatcable ports; this coordinator is original frontend glue (MIT
  attribution carried in `PortWatch.swift`/`Probe.swift`).
- WP-M1d: Added `PortBackendSource` (portInterest/portPoll/sopIdentity/usbDevice)
  and `PortVerdict` (portNumber, portKey, the existing pure `Verdict`, backendSource,
  occupancySource, sopServicePresent, plus computed `headline` and
  `hasReadableEMarker`). Each emitted verdict records which backend source produced
  it, so a rendered line counts only when its backend source is shown.
- WP-M1d: Exposed the initial-scan parity path `PlugCoordinator.currentVerdicts()`
  (one verdict per currently-occupied port from a live snapshot, matching `--once`)
  and the pure, injectable merge core `mergeSnapshot(ports:sopNodes:backendSource:)`
  the M1 gate tests drive from fixtures with no live IOKit. Added
  `PlugCoordinator.ingest(ports:sopNodes:)` + `PortTransition` for synthetic/live
  transitions: a false->true ConnectionActive emits a plug, true->false an unplug,
  via the pure `PortTransitionTracker` diff.
- WP-M1d: Added a numeric `portType` field to `PortState`, read from the
  controller's own `PortType` key (the required-now type half of the "type/number"
  portKey in the plan's data-sources table, alongside `PortNumber`). Additive: the
  new initializer parameter defaults to nil, so existing `PortState.from` callers
  and the synthesized idle-state in `PortTransitionTracker` are unchanged; an absent
  `PortType` reads nil and the coordinator defaults to the USB-C type (2).
- WP-M1d: Added `tests/CableRaterTests/PlugCoordinatorTests.swift` (11 XCTest
  cases), the M1 gate, driven from the M1 fixtures and synthetic transitions:
  initial-scan parity (Port 3 verdict equals the `--once` verdict), false->true
  plug / true->false unplug (and no duplicate for a steady port), SOP correlation
  to Port 3 by the "2/3" type/number portKey, SOP-present-empty-Metadata ->
  `Port 3: Unknown [port active]` clean verdict, an SOP' 10G e-marker rated by the
  cable, visible no-e-marker -> Unknown while idle/invisible ports stay silent, the
  IOPort-only candidate never emits, and the backend source recorded per verdict.
- WP-M1e: Added the PD-identity-present occupancy avenue to the PlugCoordinator
  merge so the backend now uses every avenue whatcable's `isPortLive` uses. Added
  `PortLiveness.passesPortGuard(_:)` (the USB-C + PortNumber gate, factored out of
  `isOccupied`) and the coordinator's `portHasCorrelatedIdentity(state:sopNodes:)`
  helper. `mergeSnapshot`/`mergePort` now admit a port when EITHER a port-controller
  signal (`PortLiveness.isOccupied`: ConnectionActive primary plus IOAccessoryDetect
  and TransportsActive-"CC" corroboration) OR a correlated PD identity is present,
  all behind the existing IOPort guard. This mirrors whatcable
  `Sources/WhatCableCore/Port/PortLiveness.swift:27` priority 2 (a non-empty PD
  identity makes a port live on its own), so a port presenting a decodable SOP' /
  SOP'' e-marker while ConnectionActive is false/nil is now rated instead of dropped.
- WP-M1e: Extended `PortSignalSource` with a `pdIdentity` case (in
  `PortWatch.swift`) and recorded the deciding avenue on `PortVerdict.occupancySource`
  (`connectionActive` / `accessoryDetect` / `transportsActiveCC` / `pdIdentity`) so a
  rendered port line can name which avenue produced occupancy. The coordinator
  supplies `pdIdentity`; `PortLiveness` itself still sees only port-controller state.
- WP-M1e: Added five `PlugCoordinatorTests` cases proving each occupancy avenue:
  a PD-identity-only port (ConnectionActive nil) is occupied AND rated from the SOP'
  e-marker, a PD-identity-only port with empty Metadata renders `Unknown [port
  active]`, IOAccessoryDetect-only and TransportsActive-"CC"-only ports are occupied
  at the coordinator, and an idle port with no signal and no correlated identity
  stays silent.
- WP-M2: Added `Sources/CableRater/WatchFrontend.swift`, the watch-mode frontend
  glue. `WatchEmitter` owns the debounce + coalesce policy and line rendering: it
  prints the startup scan, holds a freshly-detected plug for `watchDebounceSeconds`
  (0.4s) so a late SOP' e-marker can upgrade the held `Unknown [port active]` line
  to the rated e-marker headline, coalesces by port (one line per plug), and prints
  removes immediately. The emitter is pure with respect to its inputs: time and
  snapshots are injected and printing goes through a sink, so the policy is unit
  tested with no timers and no live IOKit. Consumes only the PlugCoordinator public
  API (`currentVerdicts` / `mergeSnapshot` / `ingest` / `reset`) and the existing
  `renderJSON` helper; the backend occupancy logic is untouched.
- WP-M2: Added `tests/CableRaterTests/WatchFrontendTests.swift` (5 XCTest cases)
  driving the frontend from synthetic snapshots: `--once`/watch-startup parity for
  one visible no-e-marker cable, the late-e-marker coalesce, a steady-window Unknown
  flush, and the poll-backup transition + removal paths with the interest callback
  simulated absent.
- WP-M3: Added the result-focused port-led renderer in
  `Sources/CableRater/Render.swift`: `humanLabel`/`styledHumanLabel` (calm
  title-case bucket token, colored only on a TTY), `portBasisTag`, and
  `renderPortHeadlineStyled`/`renderPortHeadline` producing the calm
  `Port N: <Bucket> [basis]` headline. Only the speed/bucket token is colored
  (like Python `rich`); the `Port N:` prefix and the basis tag stay the default
  color, and the token is not bolded (the calm value-only color rule).
- WP-M3: Added `PortActiveBasis` to `Sources/CableRater/Rating.swift`, the named
  "detected, no e-marker (port active)" basis (`tag`/`phrase`). The underlying
  `Verdict` stays `noEmarker`, so the JSON `basis` token is unchanged; the renderer
  shows the clean `[port active]` tag only in the human headline.
- WP-M3: Added a raw per-port `--debug` line, `portVerdictDebugLine`, in
  `Sources/CableRater/CLI.swift`: it names the matched backend source, the occupancy
  avenue, the `type/number` portKey, the SOP-present flag, and (when a cable decoded)
  the raw `rawCableVDO`/`productID`/`vendorID` hex, the SOP endpoint (SOP'), and the
  decoded speed tier. Wired via `writeVerdictDebug` into the `--once` and
  watch-startup debug paths (stderr). `--debug` stays raw diagnostics, not a verbose
  alias.
- WP-M6: Added the two-line default-output renderers in
  `Sources/CableRater/Render.swift`: `renderPortBlockStyled(_:styled:)` /
  `renderPortBlock(_:)` print the existing colored port headline plus an indented
  detail line beneath it. For a decoded e-marker the detail is a concise spec
  (`speedPhrase` -> "USB3.2 Gen2 (10 Gbps)", current, product type, "VID 0xVVVV PID
  0xPPPP"), each field skipped at its absent sentinel; raw hex VDO / registry IDs stay
  under `--debug`. For a no-readable-e-marker port the detail is an honest evidence
  line ("no readable e-marker; likely USB2 / basic; via <avenues>"). The avenue list
  comes from `portEvidenceAvenues(_:)`, which maps the verdict's recorded
  `occupancySource` (ConnectionActive / IOAccessoryDetect / TransportsActive CC / PD
  identity) plus a present SOP node to their IOKit-key wording -- derived from the
  signals the detector actually attributed, not a guess.
- WP-M6: Added `renderPortUnplug(portNumber:)` in `Sources/CableRater/Render.swift`,
  the distinct one-line "Port N: unplugged" message for a removed-port transition.
- Added docs/CODE_ARCHITECTURE.md and docs/FILE_STRUCTURE.md documenting the
  IOKit-source -> PlugCoordinator -> WatchEmitter -> Render -> CLI pipeline and the
  repo file layout.
- Added docs/INSTALL.md (macOS 13 floor, Xcode Command Line Tools, no runtime deps,
  build via bash build_debug.sh / build_release.sh, tests via devel/verify.sh).
- Added docs/TROUBLESHOOTING.md, docs/TODO.md, and docs/RELATED_PROJECTS.md;
  confirmed the JSON schema stays documented in docs/USAGE.md (no separate
  OUTPUT_FORMATS.md).

### Behavior or Interface Changes

- M5 device-speed fallback output: a far-end USB device that enumerates over a
  no-e-marker cable now renders as `At least <speed> [device]` (basis
  `deviceFloor`), so an unmarked but capable cable gets an honest observed floor
  instead of only `Unknown [port active]`. The phrasing "At least" is deliberate:
  it reports the negotiated link, not a proven cable maximum. The JSON schema keys
  and order are unchanged.
- WP-M1e: A USB-C port presenting a decodable PD identity (SOP' / SOP'' e-marker)
  is now detected as occupied even when the port controller's `ConnectionActive`
  bit is false/nil. Previously the merge required a port-controller attach signal,
  so such a port was dropped; it is now rated from its e-marker. The PlugCoordinator
  public API (`currentVerdicts()`, `mergeSnapshot(ports:sopNodes:backendSource:)`,
  `ingest(ports:sopNodes:)`, `reset()`) is unchanged -- only the internal occupancy
  decision changed, so the parallel CLI-wiring task is unaffected.
- WP-M2: The M1 PlugCoordinator backend is now wired into the running binary, fixing
  the make-or-break silent-startup bug. `CLI.swift` `runWatch`/`runOnce` no longer
  drive the old e-marker-only path; both now report ONE port-led line per occupied
  port through the coordinator. Watch mode prints the currently-visible cables at
  startup (same merged state as `--once`), then watches for transitions via the
  `PortWatcher` interest-notification path AND a 0.25s main-queue backup poll timer
  that re-snapshots and diffs through `coordinator.ingest`, so a missed interest
  callback is still caught. A bare Port 3 cable already plugged in at start now
  prints `Port 3: Unknown [port active]` instead of nothing. The previously-defined
  `portDebugLine` probe is now wired: `--debug` names the matched port-state backend
  source per occupied port on stderr. The JSON path is preserved (each line still
  renders the stable `Verdict` schema via `renderJSON`). The SIGINT handler now stops
  the `PortWatcher` (releasing its IOKit notification port and interest handles)
  instead of the e-marker source.
- WP-M3: Human text output is now calm and title-case. The two unknown piles render
  as `Unknown` and `Potentially fast?` (was shouty `UNKNOWN` / `POTENTIALLY FAST?`).
  The routine line is a single result-focused headline; the verbose raw e-marker
  fields (hex VDO, product/vendor IDs, SOP endpoint, matched backend source) moved
  from normal text into `--debug`. The `--once`, watch-startup, and watch-transition
  text call sites (`CLI.swift` `runOnce`, `WatchFrontend.swift` `WatchEmitter.line`)
  now render through `renderPortHeadline` (bucket token colored on a TTY).
  `PortVerdict.headline` now delegates to the renderer's plain form, so the
  coordinator gate text and the terminal wording never diverge. The JSON schema --
  keys, order, and the stable `UNKNOWN`/`UNKNOWN*` tokens -- is unchanged.
- WP-M3: `--debug` now prints, in addition to the matched port-state class line, a
  per-port raw-fields line for every rated port (see Additions). A port occupied with
  no readable e-marker prints `decoded=nil` -- the detected, no e-marker (port active)
  signature.
- WP-M6: The default (non-`--debug`) human/TTY text output is now two lines per
  occupied port: the existing colored headline plus an indented detail line (concise
  e-marker spec, or an honest evidence line for a no-e-marker port). `CLI.swift`
  `runOnce` and `WatchFrontend.swift` (`emitStartup` / inserts) render through
  `renderPortBlock`; the coalesce-by-port debounce is unchanged, so a steady port is
  still printed once per real transition, not re-printed every poll. The JSON path is
  untouched: keys, order, and the `UNKNOWN`/`UNKNOWN*` tokens are unchanged, and the
  two-line output is text-only.
- WP-M6: A text-mode unplug now renders the distinct one-line `Port N: unplugged`
  message via `WatchEmitter.removeLine`, instead of the previous behavior, which
  emitted a plug-shaped `Port N: Unknown [port active]` line for a removal (the
  reported "unplug looks identical to a plug" issue). The remove transition is
  reliable on the M1 hardware tested (the pure `PortTransitionTracker` emits one clean
  true->false event per unplug, fed by both the interest path and the backup poll);
  distinct unplug rendering is best-effort on other hardware where the port object can
  vanish or `ConnectionActive` can linger -- documented in `docs/USAGE.md`. `--json`
  still emits one `"event":"removed"` object per removal, unchanged.
- M5 reframe: the no-e-marker detail line in `Sources/CableRater/Render.swift` now
  uses honest wording that matches whatcable's documented position (README Caveats).
  Old: `"no readable e-marker; likely USB2 / basic; via <avenues>"`.
  New: `"no e-marker read yet -- attach a charger/dock/device on the far end to read it; via <avenues>"`.
  The old wording overclaimed: a cable's e-marker chip runs off VCONN and only
  answers a Discover Identity message; some Macs wait until a real PD partner is
  negotiating on the far end before querying it, so "no readable e-marker" does
  not imply a USB2 or basic cable -- the chip may simply not have been queried yet.
  whatcable deliberately avoids "basic cable" and tells users: if a cable shows no
  e-marker, plug a charger/dock/device into the far end and recheck. JSON tokens,
  the headline `[port active]` basis tag, and all `--debug` fields are unchanged;
  only the human-readable detail line (second line of each port block) changed.
  `docs/USAGE.md` sample output updated and a guidance note added under "Unknown
  vs Potentially fast?" explaining the unqueried-cable scenario and the retry workflow.
  `RenderTests.swift` and `WatchFrontendTests.swift` updated: old "likely USB2 / basic"
  assertion replaced with assertions that the new wording is present, that "basic" is
  absent, and that the far-end retry hint is present.
- Refreshed README.md to link into the updated docs set and expand Status (live-watch
  default, --once/--json/--debug, M5 device-speed fallback, macOS e-marker limitation);
  cross-linked docs/USAGE.md to INSTALL/CODE_ARCHITECTURE/TROUBLESHOOTING; trimmed
  AGENTS.md to concise operational pointers with corrected Swift-package runtime framing.

### Fixes and Maintenance

- Applied code-review audit source fixes: removed temporary WP-* and milestone
  planning tags from code comments; replaced the dead
  `state.portNumber ?? unknownPortNumber` fallback with a guard-justified
  force-unwrap in PlugSource.swift; deleted the unused
  `Probe.portIdentity(forPortType:portNumber:)` method and the unused
  `PortActiveBasis.phrase`/`DeviceFloorBasis.phrase` constants; reworded the stale
  `--with-device-floor` comment; split fused doc comments in Render.swift and
  PortWatch.swift; added `set -e` to build_debug.sh.
- Applied code-review audit doc fixes: corrected the README first paragraph (live
  identifier/rater, not a sorter; softened the e-marker claim), added the M5
  device-speed fallback note to the README Status section, removed the stale
  ", SOP node" avenue from the two no-e-marker USAGE samples, added a `deviceFloor`
  row and an `At least <speed> [device]` sample block to USAGE, renumbered the
  duplicate manual-test step, and reordered/merged the duplicate
  "Fixes and Maintenance" subsection in the 2026-06-15 changelog block.
- Refined the "Reading an Unknown cable: far-end partner workflow" section in
  docs/USAGE.md with a confirmed hardware finding (live ioreg diagnosis on M1):
  a cable into a female-female coupler into a powered USB hub gave
  `ConnectionActive=Yes` but no SOP'/SOP'' node and no enumerated USB device, so
  the cable e-marker was never queried and `Unknown [port active]` was correct.
  Clarified that reading the e-marker requires macOS to run Discover Identity
  (typically only over a direct PD power contract, often above 3A), that
  user-space tools can only read what macOS has queried, that a hub or dock in
  the middle is usually not enough, and that the best setup is a PD charger
  (5A/100W+) plugged directly onto the cable's far end. Split the e-marker-read
  fallback (direct charger) from the device-negotiated-speed fallback (a far-end
  USB device that enumerates), and reframed the honest limit as a macOS PD-policy
  limit rather than proof the cable is unmarked.
- Fix no-e-marker evidence line stability (task 28): the detail line beneath
  "Port N: Unknown [port active]" previously flipped between
  "via ConnectionActive, SOP node" and "via ConnectionActive" across replug events
  for the same physical cable. Root cause: `portEvidenceAvenues` (Render.swift)
  appended "SOP node" when `sopServicePresent` was true, but `sopServicePresent`
  is timing-variable (the SOP controller node may not be settled at debounce-flush
  time on a replug poll). Fix: chose Option B -- removed "SOP node" from the avenue
  list entirely. `ConnectionActive` is the occupancy-deciding signal; SOP-node
  presence is enrichment, not a deciding avenue, so naming it in the evidence line
  was both inaccurate and unstable. The line is now deterministically
  "via ConnectionActive" for the same cable regardless of which path (startup,
  interest, poll) produced the verdict. `sopServicePresent` is preserved on
  `PortVerdict` for `--debug` use and for the PD-identity liveness decision in
  `PlugSource.swift`; only the human evidence line no longer lists it.
- Updated `portEvidenceAvenues` doc comment in Render.swift to explain the
  stability rationale (why SOP-node presence is excluded from the avenue list).
- Updated `test_evidence_line_lists_sop_node_when_present` (RenderTests.swift) to
  `test_evidence_line_connectionActive_only_even_when_sop_present`, asserting that
  `portEvidenceAvenues` returns `["ConnectionActive"]` for both `sopServicePresent=true`
  and `sopServicePresent=false` and that the two are identical.
- Added `test_evidence_line_stable_across_sop_presence_states` (RenderTests.swift):
  builds the full two-line block from PortVerdicts with `sopServicePresent` true
  and false, asserts the blocks are identical, asserts "via ConnectionActive" is
  present, and asserts "SOP node" does not appear.
- Renamed `test_evidence_line_pd_identity_not_doubled` to
  `test_evidence_line_pd_identity_is_sole_avenue` (RenderTests.swift) for clarity.
- Added `test_no_emarker_evidence_line_stable_across_startup_interest_poll`
  (WatchFrontendTests.swift): the stability integration test. Uses the coordinator's
  `mergeSnapshot` (startup path, sopServicePresent=true re-constructed) and `ingest`
  (interest path, sopServicePresent=false at flush time) to assert the two-line
  blocks are identical and contain "via ConnectionActive" with no "SOP node".
- Fixed two HIGH crash guards found in the closeout backend audit. H1: added the
  missing nil-check on `IONotificationPortCreate`, whose result was dereferenced
  unconditionally (PortWatch.swift line 700 and Probe.swift line 706); a nil port
  would crash the watch on startup. H2: guarded a buffer `baseAddress`
  force-unwrap that crashes on an empty buffer (PortWatch.swift near line 955).
  All 220 tests pass after the fixes.
- Added `docs/active_plans/audits/backend_audit_2026-06-15.md`: the closeout
  backend audit. HIGH (now fixed): H1 IONotificationPortCreate nil-check, H2
  baseAddress force-unwrap. MEDIUM (open): M1 occSource mislabel on PD-identity
  admission without an SOPp service, M2 flushReady always tagging backendSource
  `.portPoll`. LOW (open): dead-code portNumber fallbacks, fragile dict
  force-unwrap, stale step-numbering comments, incomplete JSON control-char
  escaping (only `\\ \" \n \r \t`, not the full U+0000-U+001F range), double IOKit
  poll at watch startup. Also records coverage gaps and non-M1 divergence (D1
  hardcoded `usbCPortType=2`, D2 attached-device avenue not top priority).
- Added `docs/active_plans/reports/closeout_2026-06-15.md`: the final status and
  known-limitations report (Working / Known limitations (macOS-bounded, not code)
  / Future direction).
- Fixed pre-existing regression in `tests/CableRaterTests/CLITests.swift`: three
  `DetectedCable(...)` call sites were missing the `endpoint`, `parentPortNumber`,
  and `parentPortType` arguments added by the WS-pdidentity workstream. Updated each
  call with `endpoint: .sopPrime` / `.sop` (derived from the `serviceClass` literal
  in each test), `parentPortNumber: DetectedCable.unknownPortNumber`, and
  `parentPortType: 0`. All 105 tests now pass.
- Live-hardware backend confirmation for the reported "Apple cable into an F-F USB
  hub does not detect" case. Captured the real `AppleTCControllerType10` node shape
  via `ioreg -r -c AppleTCControllerType10 -l -a` and confirmed the controller DOES
  publish `PortTypeDescription = "USB-C"`, `PortNumber` (1/2/3), `PortType = 2`,
  `IORegistryEntryName = "Port-USB-C"`, `IORegistryEntryLocation` = the "@N" suffix,
  and `ConnectionActive` (false/false/true with Port 3 plugged). The known-class +
  PortNumber gate (PortWatch.swift `PortState.from` lines ~216-231), the
  location-suffix PortNumber fallback (`portNumberFromLocation`), and the
  interest-driven continuous-refresh watch loop (PortWatch.swift `watch` /
  `refresh` / `registerInterest`; CLI.swift `runWatch` interest + backup-timer
  `pollStep`) were already present and correct, so no production-source change was
  needed: the binary already detects the live Port 3 cable. End-to-end
  `usb-cable-rater --once --debug` prints `Port 3: Unknown [port active]` with debug
  `class=AppleTCControllerType10 port=3 source=connectionActive connectionActive=true`
  and `portKey=2/3 sopPresent=true decoded=nil` (Apple cable, no readable e-marker).
- Rebuilt `tests/CableRaterTests/Fixtures/port_controllers_m1.plist` to the faithful
  RAW captured controller-node shape: it now carries the real keys the live service
  publishes (`PortType`, `PortTypeDescription`, `Description`, `PortDescription`,
  `IORegistryEntryName`, `IORegistryEntryLocation`) instead of the trimmed
  operational-only shape, with the irrelevant boot/firmware blobs and child services
  omitted. Updated `PlugCoordinatorTests.portState(from:)` to read the gate inputs
  (name, location, PortType, PortTypeDescription) straight off the fixture instead of
  injecting `PortTypeDescription`/`PortType`/a synthesized `Port-USB-C@N` name, so the
  M1 gate tests now exercise the real-port gate against hardware reality.

### Developer Tests and Notes

- Pruned brittle test assertions per docs/PYTEST_STYLE.md (full-render-block
  snapshot strings, exact debug-line, JSON key-order walks, Codable round-trips,
  placeholder scaffolding tests, count-only fixture checks) across six test files;
  suite 220 -> 216 tests, 0 failures.
- M4 acceptance suite: 16 fixture-driven acceptance tests added, driving the
  merged backend end to end from the captured M1 IOKit fixtures and asserting the
  port-led verdicts and rendered two-line output for the real three-cable state.
- E-marker decode-pipeline proof: added decode-proof fixtures and tests covering
  the 10G, 40G, and 80G buckets, each asserting the SOP' decode path yields the
  correct bucket when its SOP' node is present.
- Full suite is green at closeout: 220 tests, 0 failures, including the M4
  acceptance suite, the 10G/40G/80G decode-proof tests, and the M5 device-speed
  fallback tests; the two HIGH crash-guard fixes are covered.
- `Executed 105 tests, with 0 failures (0 unexpected)` -- `=== verify.sh: PASS ===`
- Backend acceptance tests for the raw controller shape: added
  `tests/CableRaterTests/RawControllerShapeTests.swift` and two RAW-shape variant
  fixtures (`controller_no_porttypedescription.plist`,
  `controller_no_port_name.plist`). Proves a known-class controller WITHOUT
  `PortTypeDescription` and one WITHOUT a `Port-` name are still recognized as real
  USB-C ports, that `PortNumber` + `ConnectionActive` produce an occupied verdict,
  that an SOP child correlates by its `ParentPortType`/`ParentPortNumber` portKey
  (`2/3`), and that a broad `IOPort` candidate still does not emit alone.
  `RawControllerShapeTests` -- `Executed 6 tests, with 0 failures (0 unexpected)`;
  full suite `Executed 173 tests, with 0 failures (0 unexpected)` --
  `=== verify.sh: PASS ===`.
- WP-M1c: `PdIdentityTests` -- `Executed 12 tests, with 0 failures (0 unexpected)`;
  full suite `Executed 133 tests, with 0 failures (0 unexpected)` --
  `=== verify.sh: PASS ===`.
- WP-M3: Added 10 `RenderTests` cases (port-led headline per representative verdict:
  e-marker bucket, Unknown port-active, decoded speed; calm title-case casing;
  trimmed single-line output; color applied only on a TTY and only to the bucket
  token; bucket not bolded; Unknown red on TTY; the human/JSON token split) and 3
  `CLITests` cases (the `--debug` raw per-port fields present for an e-marker port,
  the `decoded=nil` no-e-marker signature, and the SOP-identity source naming).
  `RenderTests` `Executed 26 tests, with 0 failures (0 unexpected)`; full suite
  `Executed 167 tests, with 0 failures (0 unexpected)` -- `=== verify.sh: PASS ===`.
- WP-M3: Updated `docs/USAGE.md` to the port-led output (sample watch, `--once`, and
  `--debug` lines), calm title-case label table, and an "Invisible bare cables" note
  documenting the open-far-end electrical limit and the far-end-device workflow.
- WP-M1d: `PlugCoordinatorTests` -- all 11 cases pass; full suite
  `Executed 144 tests, with 0 failures (0 unexpected)` -- `=== verify.sh: PASS ===`
  (combined PortWatch + Probe + fixtures + CLI tree built green before and after,
  no stale call-site repair needed).
- WP-M1e: PD-identity occupancy avenue added; full suite
  `Executed 149 tests, with 0 failures (0 unexpected)` -- `=== verify.sh: PASS ===`.
  New `PlugCoordinatorTests` cases all pass:
  `test_pd_identity_present_with_connection_false_is_occupied_and_rated`,
  `test_pd_identity_empty_metadata_no_connection_is_unknown_port_active`,
  `test_accessory_detect_only_is_occupied_at_coordinator`,
  `test_transports_cc_only_is_occupied_at_coordinator`,
  `test_idle_port_with_no_signal_and_no_identity_stays_silent`.
- WP-M2: backend wired into the binary; full suite
  `Executed 154 tests, with 0 failures (0 unexpected)` -- `=== verify.sh: PASS ===`.
  New `WatchFrontendTests` cases all pass: the parity gate
  `test_once_and_startup_agree_on_visible_no_emarker_cable` (one visible no-e-marker
  cable yields the same `Port 3: Unknown [port active]` line in the --once render
  path and the watch-startup render path), the coalesce
  `test_late_emarker_coalesces_to_one_emarker_headline` (late SOP' upgrades the held
  line to `Port 3: 10G [e-marker]`, one line total),
  `test_no_emarker_within_window_prints_one_unknown_line`, and the poll-backup
  `test_poll_backup_catches_transition_without_interest_callback` /
  `test_poll_backup_catches_removal_in_json` (a missed interest callback is still
  caught by the poll alone). `build_debug.sh` builds `.build/debug/usb-cable-rater`.
- WP-M2 decision (debounce constant): `watchDebounceSeconds = 0.4`. The SOP' e-marker
  on this M1 hardware can appear a beat after `ConnectionActive` flips true; 0.4s is
  long enough to catch the typical settle (~100-300ms observed) yet short enough that
  the printed line still feels immediate. If the window closes with no SOP', the held
  Unknown line prints as-is. The backup poll cadence `watchPollSeconds = 0.25` is
  finer than the window, so a held line flushes within one window of its deadline and
  a missed plug surfaces within a quarter second.
- WP-M2 decision (interest path as a poke): `PortWatcher.watch` insert/remove
  callbacks are used purely as a "something changed" trigger that re-runs the shared
  `pollStep` (snapshot -> `coordinator.ingest` -> emitter offer/flush). The
  coordinator's single tracker -- not the watcher's internal tracker -- owns the
  merged verdict, so the interest path and the backup poll feed the SAME diff and a
  transition is never double-reported. The startup snapshot seeds the coordinator
  tracker via a discarded `ingest`, so already-present ports are not re-emitted as
  inserts after the scan prints them.
- WP-M1d decision (seam): `PlugCoordinator` lives in a NEW
  `Sources/CableRater/PlugSource.swift` rather than inside `Probe.swift`. The
  coordinator merges two backends and belongs to neither; `Probe.swift` is already
  ~1060 lines, so a dedicated file keeps the merge glue readable and the faithful
  whatcable backend ports untouched (additive: the existing e-marker decode,
  known_cables refinement, SOP'/port-state APIs are unchanged).
- WP-M1d decision (wording boundary): the `Unknown [port active]` text is supplied
  by `PortVerdict.headline` (and the future WP-M3 renderer), NOT by mutating the
  stable `Verdict`/JSON schema -- an occupied no-e-marker port still carries the
  honest UNKNOWN/noEmarker `Verdict`, so the initial scan matches the `--once`
  verdict exactly while the port-led headline gets the "[port active]" qualifier.
- WP-M1d API for WP-M2/WP-M3: `PlugCoordinator.currentVerdicts() -> [PortVerdict]`
  (initial scan / startup parity), `mergeSnapshot(ports:sopNodes:backendSource:) ->
  [PortVerdict]` (pure merge), `ingest(ports:sopNodes:) -> [PortTransition]` (live
  diff), and `reset()`. `PortVerdict` exposes `portNumber`, `portKey`, `verdict`,
  `backendSource`, `occupancySource`, `sopServicePresent`, `headline`,
  `hasReadableEMarker`.
- WP-M1c decision: correlation joins on the whatcable "type/number" portKey
  (`USBPDSOP.portKey`, USBPDSOP.swift:52,147-155), not `ParentPortNumber` alone.
  On this M1 hardware no HPM controller UUID is exposed, so the type/number portKey
  is the active join path; the by-number form builds the same key. The coordinator
  joins SOP identity to the port controller's PortType+PortNumber via this key.
- WP-M1c rating confirmation: SOP' (near-end cable e-marker) is the headline rating
  source; SOP'' (far-end) is a fallback only and never overwrites the SOP' headline,
  mirroring whatcable `USBPDSOP.cableVDO` (USBPDSOP.swift:93-99). The new param
  defaults on `DetectedCable.init` keep the change additive (existing callers unchanged).
- Fixture format chosen: XML plist (Apple DTD 1.0), matching the exact IOKit key
  names returned by the live M1 probe (`ConnectionActive`, `IOAccessoryDetect`,
  `TransportsActive`, `PortNumber`, `IOObjectClass`, `Metadata`, `ParentPortNumber`,
  `IOObjectClass`, etc.). This lets the watcher parser read the same key names from
  fixtures and from live services without any translation layer.
- Fixture bundling wired via `.process("Fixtures")` in the test target, same pattern
  as the library target's `.process("Resources/known_cables.json")`. The watcher
  parser (WP-M1b/WP-M1c) should load fixtures by calling
  `Bundle.module.url(forResource:withExtension:subdirectory:)` from within the test
  target, or by accepting a dictionary read-closure (the pattern `ProbeTests.swift`
  already uses) so no `Bundle.module` dependency bleeds into the parser under test.
- WP-M6: Added `RenderTests` cases for the two-line output:
  `test_block_emarker_detail_spec_line` (speed phrase + current + type + VID/PID, raw
  VDO excluded), `test_block_emarker_detail_speed_phrase_80g`,
  `test_block_no_emarker_evidence_line` (avenue list + likely-basic hint),
  `test_evidence_line_lists_sop_node_when_present`,
  `test_evidence_line_pd_identity_not_doubled`,
  `test_block_color_only_on_bucket_detail_uncolored`,
  `test_block_no_ansi_when_not_styled`, and `test_unplug_line_is_distinct_and_plain`.
  Added `WatchFrontendTests.test_text_unplug_renders_distinct_unplugged_line` (a
  text-mode removal renders `Port N: unplugged`, not a plug-shaped line) and updated
  the existing startup/insert assertions to the two-line block shape. Captured the
  real M1 `--once` output for the no-e-marker case via a throwaway `_temp` script
  (since removed): "Port 3: Unknown [port active]" followed by the indented evidence
  line "no readable e-marker; likely USB2 / basic; via ConnectionActive, SOP node".
  Full suite: 182 tests, 0 failures; `bash devel/verify.sh` PASS.

## 2026-06-14

### Additions and New Features

- Patch 1: Created SwiftPM package scaffold (`Package.swift`) with three targets:
  `CableRater` library, `usb-cable-rater` executable (depends on CableRater),
  and `CableRaterTests` test target. Platform set to macOS 13 (.macOS(.v13)).
- Added `Sources/CableRater/CableRater.swift` with trivial `placeholder()` function
  and `cableRaterVersion` constant as a skeleton for later VDO/IOKit work.
- Added `Sources/usb-cable-rater/main.swift` that imports CableRater and prints
  the placeholder status string; binary name is exactly `usb-cable-rater`.
- Added `tests/CableRaterTests/CableRaterTests.swift` with two passing XCTest cases
  exercising `placeholder()` and `cableRaterVersion`.
- Patch 2: Added `Sources/CableRater/Model.swift` with pure value types:
  `CableSpeedTier` enum (usb2/gen5g/gen10g/gen20to40g/gen80g/unknown) with
  `bucketLabel` strings matching User-facing contract sort piles; `CableProductType`
  (passive/active/unknown); `CableCurrent` (usbDefault/threeAmp/fiveAmp/unknown);
  `CableInfo` struct (Codable, Equatable). Adapted from whatcable
  `LinkSpeed.Tier` (LinkSpeed.swift) and `PDVDO.CableSpeed`, `PDVDO.CableCurrent`,
  `PDVDO.UFPProductType` (USBPDVDO.swift). MIT, Darryl Morley 2026.
- Patch 2: Added `Sources/CableRater/EMarker.swift` with pure decode functions:
  `EMarker.decodeSpeed(cableVDO:)` extracts bits 2..0 -> CableSpeedTier;
  `EMarker.decodeCurrent(cableVDO:)` extracts bits 6..5 -> CableCurrent;
  `EMarker.decodeProductType(idHeaderVDO:)` extracts UFP bits 29..27 ->
  CableProductType; `EMarker.decodeVendorID(idHeaderVDO:)` extracts bits 15..0;
  `EMarker.decode(cableVDO:idHeaderVDO:)` convenience combining all four.
  Value 3 hard-coded to gen20to40g (PD-revision split deferred to step-3 spike).
  Never traps on any bit pattern. Adapted from `PDVDO.decodeCableVDO`,
  `PDVDO.decodeIDHeader`, `PDVDO.CableSpeed`, `PDVDO.CableCurrent`,
  `PDVDO.UFPProductType` in whatcable USBPDVDO.swift. MIT, Darryl Morley 2026.
- Patch 2: Added `tests/CableRaterTests/EMarkerTests.swift` with 20 XCTest cases
  covering speed values 0-4, value 3 -> gen20to40g (contract gate), unknown
  bits 5 and 7, high-bit isolation, current values 0-3, product type 0/3/4,
  vendor ID extraction, full convenience decode, Codable round-trip, and all
  bucket labels.
- Patch 3: Added `Sources/CableRater/Probe.swift` with `IOKitCableSource`, the
  IOKit source layer that produces `CableInfo` from real SOP' cable e-marker
  services. Pure static `parseCableInfo(read:)` reads `Metadata`, extracts the
  `VDOs` array of little-endian 4-byte Data blobs, decodes VDO[0] (ID Header)
  and VDO[3] (Cable VDO) via `EMarker.decode`, and returns nil when Metadata or
  the ID Header VDO is absent. `currentCables()` snapshots attached cables via
  `IOServiceGetMatchingServices` + `IOIteratorNext`, releasing each service and
  iterator. `watch(onInsert:onRemove:)` registers matched + terminated
  notifications on a main-queue notification port; `stop()` releases all
  iterators and the port. Matches both `IOPortTransportComponentCCUSBPDSOPp`
  (cable e-marker) and `IOPortTransportComponentCCUSBPDSOP`. Adapted from
  whatcable `VDMIdentityWatcher` (start/stop/refresh/makeUpdate/parseUpdate,
  VDMIdentityWatcher.swift) and `wcDictionary`/`wcArray`/`wcData`
  (IOKitHelpers.swift). MIT, Darryl Morley 2026.
- Patch 3: Added `tests/CableRaterTests/ProbeTests.swift` with 8 XCTest cases
  driving the pure `parseCableInfo(read:)` with synthetic Metadata dictionaries:
  a 40G-class cable VDO (speed bits 3 -> gen20to40g), a 10G cable VDO, a sparse
  VDO set with only the ID Header, a fully zeroed VDO set, and four nil cases
  (missing Metadata, no VDOs key, empty VDOs array, truncated ID Header).
- Patch 5 (DB portion): Vendored 74 records from whatcable docs/cables.json (MIT,
  Darryl Morley 2026) into `Sources/CableRater/Resources/known_cables.json`; all
  fields preserved verbatim (brand, cableVDO, vid, pid, speed, type, power, vendor,
  issueNum, issueURL, xid, registered). 4 records have empty cableVDO (no VDO was
  captured at collection time); they are matchable by VID/PID only.
- Patch 5 (DB portion): Added `Sources/CableRater/Catalog.swift` with `KnownCable`
  Codable struct (fields: brand, cableVDO, vid, pid, vendor, speed, type, power;
  computed: numericCableVDO, numericVID, numericPID, speedTier); `Catalog` singleton
  loads once from Bundle.module, fails loudly (preconditionFailure) if JSON is missing
  or unparseable; exposes `lookup(byCableVDO:) -> KnownCable?` (primary; handles
  zeroed-VID records) and `lookup(byVendorID:productID:) -> KnownCable?` (secondary).
  Static `speedTierFromString(_:)` maps DB speed strings to CableSpeedTier via ASCII
  prefix matching; handles all 14 observed speed string variants (English, Spanish,
  Cyrillic, CJK localized forms) correctly. Attribution header in source file.
- Patch 5 (DB portion): Updated `Package.swift` to add
  `resources: [.process("Resources/known_cables.json")]` on the CableRater target
  (linkerSettings unchanged); JSON is accessible at runtime via Bundle.module.
- Patch 5 (DB portion): Added `tests/CableRaterTests/CatalogTests.swift` with 21
  XCTest cases: load-without-crash; cableVDO lookups for Apple TB5 (0x110A2644->gen80g),
  UGREEN Revodok (0x11082043->gen20to40g), zeroed-VID 5G (0x00084841->gen5g), zeroed-VID
  USB2 (0x00082040->usb2); absent VDO (0xDEADBEEF->nil); VID/PID lookups for Apple TB5
  (0x05AC/0x720A->gen80g), Cable Matters TB5 (0x2B1D/0x1533->gen80g), absent pair->nil;
  zeroed-VID record found by cableVDO (0x00082042->gen10g); 11 speed-string mapping cases.
  All 51 tests pass (30 existing + 21 new).
- Patch 5 (Rating portion): Added `Sources/CableRater/Rating.swift` with the
  `Verdict` value type (Codable, Equatable; fields: bucketLabel, tier, basis,
  cable, knownCable) and the `VerdictBasis` enum (emarker / emarkerAmbiguous /
  knownDB / emarkerUnrecognized / noEmarker). `verdict(for:catalog:)` merges a
  decoded CableInfo into one user-facing Verdict with precedence live decode ->
  DB refine -> UNKNOWN: nil cable -> UNKNOWN/noEmarker; clear tier
  (usb2/5G/10G/80G) -> that bucket/emarker with NO DB lookup; value 3 -> 20-40G/
  emarkerAmbiguous; zeroed/sparse e-marker -> DB refine by cableVDO then VID/PID,
  hit -> DB tier/knownDB, miss -> UNKNOWN*/emarkerUnrecognized. A full form
  `verdict(for:cableVDO:productID:catalog:)` accepts the raw DB keys the pure
  CableInfo does not carry, keeping the design open for the later
  `--with-device-floor` opt-in. Retroactively conforms `KnownCable` to Equatable.
- Patch 6: Added `Sources/CableRater/Render.swift` with `renderText(_:plugged:)`
  (bold bucket line via ANSI only on a TTY, then a plain-English basis detail
  line; no escape codes leak into pipes) and `renderJSON(_:event:)` (hand-built
  object with stable key order event, bucket, tier, basis, vendorId, productId,
  cableVDO, brand; renders removed events too).
- Patch 6: Added `Sources/CableRater/CLI.swift` with hand-rolled flag parsing
  (`--once`, `--json`, `--help`/`-h`, `--version`/`-v`; unknown flags fail loud
  with exit 2) and `runCLI(_:)`. Default mode is a live watch via
  `IOKitCableSource.watch` running `dispatchMain()` so main-queue callbacks fire
  (text shows inserts only; `--json` shows inserted and removed); `--once`
  snapshots `currentCables()` and exits 0, printing the nothing-plugged message
  when empty. SIGINT calls `source.stop()` and exits 130.
- Patch 6: Replaced `Sources/usb-cable-rater/main.swift` placeholder with a thin
  entry point that forwards `CommandLine.arguments` (minus argv[0]) to `runCLI`
  and exits with its return code.
- Patch 6: Added `tests/CableRaterTests/RatingTests.swift` (11 cases) covering
  every contract row, including a clear-tier cable with no DB match (proves the
  tool is not DB-dependent) and clear-tier short-circuiting the DB; and
  `tests/CableRaterTests/RenderTests.swift` (10 cases) asserting plain non-TTY
  text buckets/details with no raw ANSI, stable JSON key order, a removed event,
  and null fields when no e-marker is present. 72 tests pass after Patch 6 (51 +
  21 new); the live-DB wiring step below adds 1 more for a session total of 73.
- Patch 6: Added `docs/USAGE.md` documenting build (`bash build_debug.sh`), the
  live/`--once`/`--json` run modes, bucket meanings, UNKNOWN vs UNKNOWN*, the
  basis field, and a manual hardware test (plug e-marked -> bucket; plain cable
  -> UNKNOWN; Ctrl+C exits 130).

- Watch correctness + diagnostics: Added a `DetectedCable` value type in
  `Sources/CableRater/Probe.swift` (`info: CableInfo?`, `serviceClass: String`,
  `registryID: UInt64`, plus diagnostic `vdoCount`/`metadataKeyCount`). It is the
  unit the snapshot and watch layers now emit, so a matched IOKit service whose
  e-marker cannot be decoded (empty/absent Metadata) is carried as `info == nil`
  instead of being dropped. Added the pure static `describeService(serviceClass:
  registryID:read:)` that runs `parseCableInfo` and counts the raw Metadata shape,
  and a private `serviceClassName(_:)` (IOObjectGetClass) so the live IOKit class
  is reported accurately.
- Added a `--debug` / `-d` flag (`CLIOptions.debug`, parsed in `parseCLI`,
  documented in `usageText()` and `docs/USAGE.md`). It writes a raw IOKit
  diagnostic line to STDERR for every matched and terminated service the watch
  sees -- including baseline/pre-existing services on arm -- so silent-plug
  troubleshooting is possible. The pure `debugLine(for:matched:)` builds the line
  (`[debug] matched class=... id=0x... metadataKeys=N vdos=N decoded=<tier|nil>`)
  and `writeDebug(_:)` sends it to stderr only, keeping `--json` clean on stdout.
  `--once --debug` dumps one line per enumerated service.

### Behavior or Interface Changes

- Text-output UX redesign (JSON unchanged): The human text mode is now numbered
  and verbose for power users. `--once` prints `cable N of M: <LABEL>` per cable
  (1-based, M = total) and `No cable plugged in.` when empty; live watch prints a
  one-line startup banner ("Watching for USB-C cables. ...") then a monotonic
  `cable N: <LABEL>` per insert (no total). Labels are friendlier: clear tiers
  stay `USB2`/`5G`/`10G`/`80G`, ambiguous stays `20-40G`, the old `UNKNOWN*` pile
  now reads `POTENTIALLY FAST?` in text, and no-e-marker reads `UNKNOWN`. Under
  each cable an indented detail line prints the raw e-marker fields that are
  available (`vendor 0x%04X`, `product 0x%04X`, `cableVDO 0x%08X`, product type
  word, current, `matched: <brand>` on a DB hit), skipping any zero/unknown
  sentinel, and always ends with a bracketed basis tag (`[e-marker]`,
  `[e-marker ambiguous]`, `[known-db]`, `[unrecognized]`, `[no e-marker]`). The
  `<LABEL>` token is bold and color-coded by speed on a TTY only (bright green
  80G, green 20-40G, cyan 10G, blue 5G, yellow USB2, magenta POTENTIALLY FAST?,
  red UNKNOWN); the `cable N:` prefix and the detail line stay default color, and
  pipes/files/`--json` get no escape codes. The tier->color map is centralized in
  `labelColor` in `Render.swift`. `renderText(_:plugged:)` was replaced by
  `renderCableText(_:prefix:)` (plus a style-explicit `renderCableTextStyled`
  used by tests). The stable `--json` schema (keys event/bucket/tier/basis/
  vendorId/productId/cableVDO/brand and the `UNKNOWN*` bucket token) is unchanged.
  `--help` LABELS section and `docs/USAGE.md` sample output updated to match.
  `build_debug.sh` now builds and then echoes the binary path and run commands
  (watch / --once / --json) instead of auto-running `--once`, so a Swift newcomer
  sees where the binary is without the watch loop blocking the terminal. Rewrote
  `tests/CableRaterTests/RenderTests.swift` for the new text format (numbered
  prefix, POTENTIALLY FAST? label, verbose fields present/omitted, basis tags,
  TTY color for two tiers, zero ANSI codes when not styled) and kept the JSON
  schema assertions, including a new check that the unrecognized bucket is still
  `UNKNOWN*` in JSON.
- Patch (step 5 DB refinement): Wired the live path through the known-cable DB.
  `CableInfo` gains two stored fields, `rawCableVDO` (the raw VDO[3] Cable VDO
  word, preserved by `EMarker.decode`) and `productID` (the USB PID read from
  IOKit Metadata by the Probe layer); both default to 0 (Codable + Equatable).
  `Probe.parseCableInfo` now sets `productID` from `Metadata["PID"]` (coerced to
  UInt16 via `coerceUInt16`, 0 when absent) and threads `rawCableVDO` through.
  The convenience `verdict(for:catalog:)` now reads `rawCableVDO`/`productID` off
  the cable and forwards them to the full verdict, so the LIVE path (the form
  CLI.swift calls) reaches the known-cable database: a zeroed/sparse real cable
  whose Cable VDO or VID/PID is in the DB is refined to its DB speed (basis
  knownDB) instead of always rating UNKNOWN*. The clear-tier short-circuit
  (USB2/5G/10G/80G) still wins before any DB lookup, so a normally e-marked cable
  rates by e-marker with the catalog untouched; a zeroed/sparse cable with no DB
  match still rates UNKNOWN*, and a nil cable still rates UNKNOWN/noEmarker.
  Added `test_live_convenience_path_reaches_db_byCableVDO_is_knownDB` in
  `tests/CableRaterTests/RatingTests.swift` proving the convenience path reaches
  knownDB via a zeroed cable carrying `rawCableVDO` 0x00084841 (UGreen 5G,
  zeroed-VID row). Stale comments in Rating.swift and CLI.swift that claimed the
  live path passes nil / cannot reach the DB were corrected.
- `IOKitCableSource.currentCables()` now returns `[DetectedCable]` (was
  `[CableInfo]`) and includes services that fail to decode (`info == nil`), so a
  plugged-in non-e-marked cable appears as an UNKNOWN entry in `--once` rather
  than vanishing. `watch(onInsert:onRemove:)` callbacks now take `DetectedCable`
  (was `CableInfo`) and fire for EVERY new matched service, so a non-e-marked plug
  prints `cable N: UNKNOWN` in normal text mode (and `inserted`/`removed` events
  in `--json`) instead of producing no output. `watch` gained an optional
  `onDebug: ((DetectedCable, Bool) -> Void)?` parameter (Bool true = matched,
  false = terminated). CLI `runOnce`/`runWatch` rate each emitted service via
  `verdict(for: detected.info, catalog:)`, where a nil info yields the existing
  UNKNOWN/noEmarker verdict; the `--json` schema and keys are unchanged.
- Live-watch baseline suppression: services already present when `watch` arms (the
  persistent host-port SOP services on this Mac) are recorded as a baseline during
  the initial arming drain and are NOT emitted as `onInsert`, so an idle watch with
  nothing newly plugged prints no phantom cable line. Only services that appear
  AFTER arming fire `onInsert`; pre-existing cables remain covered by `--once`
  (which snapshots without a baseline). The debug sink still sees baseline services.
- Changed `REPO_TYPE` from `rust` to `other` (Swift is not a recognized REPO_TYPE
  token; `other` is the correct fallback per docs/REPO_STYLE.md).
- Clarified the default watch behavior in the `--help` text emitted by `CLI.swift`:
  the `(default)` mode line now reads "runs until Ctrl+C (exit 130)" so the
  live-watch-until-SIGINT contract is visible without reading the source.
  `docs/USAGE.md` already stated this; no prose change needed there.

### Fixes and Maintenance

- Fixed the silent-watch bug: a user running `.build/debug/usb-cable-rater`
  plugged/unplugged three non-e-marked cables and saw no output at all. Root
  cause: the watch path only emitted `onInsert` when `parseCableInfo` returned a
  non-nil `CableInfo`, so the lone matched non-prime SOP service (whose `Metadata`
  was an empty dict, decoding to nil) was dropped. The matched callback now emits a
  `DetectedCable` for every matched service, so a non-e-marked plug renders
  `cable N: UNKNOWN` (basis noEmarker) instead of nothing. The fix is in the source
  layer, not the rating layer (`verdict(for:catalog:)` already handles a nil cable).
  The remaining open question -- whether a hot-plug of such a cable fires ANY IOKit
  matched callback on this hardware -- is exactly what the new `--debug` flag lets
  the user confirm on a real Mac.
- Extended `.gitignore` to ignore `.build/`, `*.o`, `*.d`, `*.swp` (Swift build
  artifacts). The `.build/` directory must not be committed.
- Added `build_debug.sh` at repo root: runs `swift build` then launches
  `.build/debug/usb-cable-rater`; includes comment noting future `--once` flag switch.
- Added `build_release.sh` at repo root: `set -e`, `swift build -c release`, echoes
  binary path `.build/release/usb-cable-rater`; no .app bundle (plain CLI binary).
- Added `devel/verify.sh`: per-patch verification gate; runs `swift build` then
  `swift test` with `set -e`; echoes `=== verify.sh: PASS ===` on success.
- Added `devel/clean_swift_artifacts.sh`: scoped to repo root via `git rev-parse`,
  removes `.build/`, `Sources/CableSorter/`, and `tests/CableSorterTests/` if present;
  safe to re-run. Confirmed no stale CableSorter dirs remain.
- Patch 2 nit: corrected `Tests/CableRaterTests/` (capital T) to `tests/CableRaterTests/`
  (lowercase) in the Patch 1 changelog entry above; the actual directory is lowercase.
- Patch 2 nit: changed `devel/clean_swift_artifacts.sh` shebang from
  `#!/usr/bin/env bash` to `#!/bin/bash` to match the other devel scripts.
- Step-2 post-review nit: corrected XCTest count in changelog from 18 to 20 to match
  the actual number of `func test_` methods in `tests/CableRaterTests/EMarkerTests.swift`
  (verified by grep count).
- Step-2 post-review nit: added `Tests/` to `.gitignore` to suppress untracked-path noise
  from SwiftPM/Xcode creating an uppercase `Tests/` entry on macOS case-insensitive FS.
  Tracked files under lowercase `tests/` are unaffected (`.gitignore` never un-tracks
  files already in the index).

### Removals and Deprecations

- Dropped `--with-device-floor` from scope. The flag was mentioned in the plan as
  a future opt-in but was never implemented and is not referenced anywhere in the
  shipped CLI or docs. It will not be added; the tool is intentionally flag-minimal.
  Comments in `Sources/CableRater/Rating.swift` that framed the full
  `verdict(for:cableVDO:productID:catalog:)` signature as "keeping the design open
  for --with-device-floor" remain accurate as historical context and are left as-is
  (they describe why the signature accepts raw DB keys, which is still true).

### Decisions and Failures

- Package was initially scaffolded as `CableSorter` then immediately renamed to
  `CableRater` before the first commit. Rationale: `CableRater` is distinct from
  the `whatcable` reference codebase name and better reflects the tool's purpose
  (rating/sorting cables by data speed). The `clean_swift_artifacts.sh` script
  removes any stale `Sources/CableSorter/` and `tests/CableSorterTests/` directories
  left over from build artifacts before the rename was finalized.
- Value-3 VDO speed bits default to `gen20to40g` (bucket "20-40G") because PD
  revision is not available in the pure VDO decode layer. The step-3 IOKit spike
  will determine whether PD revision is readable from the SOP' service; only then
  can value 3 be split into 20G (PD 3.0) vs 40G (PD 3.1). Do not attempt the
  split before the spike confirms the data path.

### Developer Tests and Notes

- Watch correctness + diagnostics tests: extended
  `tests/CableRaterTests/ProbeTests.swift` with `describeService` coverage (empty
  Metadata and empty-dict Metadata both keep `info == nil` with zero counts; a
  decodable service populates info and correct vdo/key counts) and a nil-info
  render proof (`test_nil_info_detected_renders_unknown_line`: a DetectedCable with
  info nil rates and renders `cable 1: UNKNOWN` with the `[no e-marker]` tag).
  Added `tests/CableRaterTests/CLITests.swift` covering `--debug`/`-d` parsing
  (including composition with `--json`/`--once` and an unknown-flag error),
  `usageText()` documenting the flag, and `debugLine(for:matched:)` for a decoded
  match, the silent-plug `decoded=nil` signature, and a terminated event. The live
  IOKit loop and the watch/baseline notification plumbing are deliberately not
  unit-tested (hardware-bound); only the pure, deterministic surface is covered.
  `bash devel/verify.sh` reports `Executed 92 tests, with 0 failures (0
  unexpected)` and `=== verify.sh: PASS ===`.
- Session closeout verified test count by reading all six test files under
  `tests/CableRaterTests/` and counting `func test_` declarations: 2
  (CableRaterTests) + 20 (EMarkerTests) + 8 (ProbeTests) + 21 (CatalogTests) +
  12 (RatingTests) + 10 (RenderTests) = 73 total. Earlier patch entries that
  stated 18, 20, 30, 51, or 72 were accurate at the time each patch completed;
  the session total is 73 after the live-DB wiring step added its 1 proof test.
- Closeout coverage nit (3 items): added `rawCableVDO` and `productID` assertions
  to `test_parse_40g_class_cable_vdo` and `test_parse_10g_cable_vdo` in
  `tests/CableRaterTests/ProbeTests.swift` so both new fields are observed in the
  parse path (rawCableVDO == Cable VDO word fed to VDO[3]; productID == PID from
  Metadata dict). Added `test_cable_info_codable_round_trip_with_new_fields` in
  `tests/CableRaterTests/EMarkerTests.swift` constructing a CableInfo with non-zero
  rawCableVDO (0x00084841) and productID (0x720A), encode+decode via
  JSONEncoder/JSONDecoder, asserting decoded == original (proves new fields survive
  JSON). Added a clarifying block comment in `Sources/CableRater/Rating.swift` near
  the isZeroedOrSparse check noting the check runs before the clear-tier and value-3
  short-circuits so a zeroed cable cannot bypass DB refinement (comment-only, no
  logic change). Total test count after nit: 74 (verify.sh green,
  "Executed 74 tests, with 0 failures (0 unexpected)").
