# Code architecture

usb-cable-rater is a macOS Swift command-line tool that identifies USB-C cables
live by reading their USB-PD e-marker over IOKit and sorting them into data-rate
buckets. It watches the system's USB-C port controllers, decodes any cable
e-marker present, optionally floors the rating from a far-end USB device speed,
and prints one calm line per occupied port (or machine JSON).

## Overview

The program is a single SwiftPM package with two products: a `CableRater`
library that holds all logic, and a thin `usb-cable-rater` executable that
forwards arguments to the library. Every backend detection module is a faithful
port of the MIT-licensed whatcable project (Darryl Morley 2026); the coordinator
and frontend are this project's original glue.

The design separates hardware-facing IOKit enumeration from pure, hardware-free
decision logic. Each IOKit source exposes a pure value-type factory and a pure
decision function so the full pipeline runs under unit tests from injected
in-memory snapshots, with no live hardware.

## Components

The library splits into a backend (IOKit sources and pure decoders, ported from
whatcable) and a coordinator/frontend (the merge, debounce, render, and CLI
layers, original to this project).

### Backend: IOKit sources and pure decoders

- `PortWatch.swift` is the port-controller state watcher and the PRIMARY plug
  signal. `PortWatcher` matches the named port-controller classes plus the broad
  `IOPort` catch-all, arms matched and interest notifications, and rebuilds a
  snapshot of `PortState` values. Occupancy comes from the port's own
  `ConnectionActive` bit (with `IOAccessoryDetect` and a `TransportsActive` "CC"
  entry as corroboration), so a non-e-marked cable still registers as a plug.
  `PortLiveness` decides occupied versus idle behind the `IOPort` guard (a
  candidate must map to a real USB-C `PortNumber`), and `PortTransitionTracker`
  diffs snapshots into plug/unplug `PortEvent` values.
- `Probe.swift` holds `IOKitCableSource`, the cable e-marker reader. It matches
  the SOP, SOP', and SOP'' classes, decodes each service's VDOs into a
  `CableInfo` via `EMarker`, and records each service's SOP endpoint and parent
  port. `decodePort` correlates SOP nodes to a physical port by the whatcable
  "type/number" `portKey`, keeping the near-end SOP' e-marker as the headline and
  never letting SOP'' overwrite it.
- `DeviceWatch.swift` holds `DeviceWatcher`, the attached-USB-device pairing and
  negotiated-speed floor (the fallback path). It enumerates `IOUSBHostDevice`,
  reads each device's negotiated speed, and pairs it to a port via the
  `UsbIOPort` ancestor name. `decodeDeviceFloor` turns the fastest USB3+ device
  on a port into a conservative `CableSpeedTier` floor ("At least <speed>").
- `Model.swift` defines the pure value types: `CableSpeedTier`,
  `CableProductType`, `CableCurrent`, and `CableInfo`.
- `EMarker.swift` is the pure VDO decoder (speed bits, current bits, product
  type, vendor ID), with no IOKit dependency.
- `Catalog.swift` loads the bundled `known_cables.json` database and offers
  lookup by Cable VDO or by VID/PID. It is a refinement-only layer used only
  when a real e-marker is present but zeroed or sparse.

### Coordinator and frontend

- `PlugSource.swift` holds `PlugCoordinator`, the port-centered merge layer. Its
  pure `mergeSnapshot` core reconciles port state and PD identity (and the device
  floor) into one `PortVerdict` per OCCUPIED port via the port-liveness occupancy
  decision; an idle or invisible port produces no verdict. Live entry points
  (`currentVerdicts`, `ingest`) wrap that core with real IOKit enumeration.
- `Rating.swift` builds a `Verdict` from a `CableInfo` following the precedence
  e-marker decode, then DB refinement (zeroed/sparse only), then UNKNOWN. It also
  builds the device-floor verdict and owns the port-active and device-floor basis
  tags.
- `Render.swift` turns a `PortVerdict` into the two-line port-led output (a calm
  colored bucket token plus an indented detail line) or into stable machine JSON.
  Color is applied only on a real TTY.
- `WatchFrontend.swift` holds `WatchEmitter`, the debounce and coalesce policy. A
  freshly detected plug is held briefly so a late-arriving SOP' e-marker can
  upgrade the held "Unknown [port active]" line; each plug yields exactly one
  line. It is pure with respect to injected time, snapshots, and a print sink.
- `Rating.swift`, `Render.swift`, and `WatchFrontend.swift` together keep the
  stable `Verdict` and JSON schema untouched while the human text reads calmly.
- `CLI.swift` parses flags (`--once`, `--json`, `--debug`, `--help`,
  `--version`), builds the backend sources and coordinator, and drives the run
  loop: a startup scan, an interest-notification poke, and a backup poll timer,
  with a SIGINT handler that exits cleanly.

### Entry point

- `Sources/usb-cable-rater/main.swift` drops `argv[0]` and calls `runCLI`, then
  exits with the returned code.

## Data flow

The pipeline runs from IOKit sources through the coordinator and frontend to
stdout or JSON:

```
+------------------+   +------------------+   +------------------+
| PortWatch.swift  |   | Probe.swift      |   | DeviceWatch.swift|
| port state       |   | SOP e-marker     |   | device speed     |
| (ConnectionActive|   | (SOP/SOP'/SOP'') |   | floor            |
+--------+---------+   +--------+---------+   +---------+--------+
         |                      |                       |
         +----------+-----------+-----------+-----------+
                    v
         +---------------------------+
         | PlugCoordinator           |
         | (PlugSource.swift)        |
         | occupancy + one verdict   |
         | per occupied port         |
         +-------------+-------------+
                       v
         +---------------------------+
         | WatchEmitter              |
         | (WatchFrontend.swift)     |
         | debounce + coalesce       |
         +-------------+-------------+
                       v
         +---------------------------+
         | Render.swift              |
         | two-line text or JSON     |
         +-------------+-------------+
                       v
         +---------------------------+
         | CLI.swift                 |
         | stdout / JSON             |
         +---------------------------+
```

The three IOKit sources are correlated by the whatcable "type/number" `portKey`,
so a port controller, its cable e-marker, and any far-end device resolve to one
physical port. Ratings follow a strict precedence: a readable cable e-marker
wins over a device-speed floor, which wins over the honest "Unknown [port active]"
result.

## macOS Discover-Identity limitation

This limitation sits at the backend boundary, not in the coordinator. A cable's
e-marker chip is VCONN-powered and answers only a USB-PD Discover Identity
message. On some Macs the system does not issue that message until a real PD
partner is negotiating on the far end, so a bare cable with nothing attached can
present a port controller occupancy signal but no readable SOP' e-marker. The
tool reports that honestly as "Unknown [port active]" rather than guessing. The
two fallbacks soften this: a far-end USB3+ device floors the rating from its
negotiated speed (`DeviceWatch.swift`), and a zeroed or sparse e-marker is
refined against the known-cable database (`Catalog.swift`). Attaching a charger,
dock, or device on the far end is the documented way to make the cable's own
e-marker readable.

## Related documents

- [FILE_STRUCTURE.md](FILE_STRUCTURE.md) for the directory map.
- [USAGE.md](USAGE.md) for how to run the tool.
