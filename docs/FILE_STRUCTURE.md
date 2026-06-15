# File structure

This map shows where each part of usb-cable-rater lives and what it provides.
The project is a single SwiftPM package: a `CableRater` library holds all logic
and a thin `usb-cable-rater` executable forwards to it. For the design and data
flow, see [CODE_ARCHITECTURE.md](CODE_ARCHITECTURE.md).

## Top-level layout

```
usb-cable-rater/
  Package.swift            SwiftPM manifest: library + executable + test targets
  build_debug.sh           Build the debug binary and print run hints
  build_release.sh         Build the release binary
  source_me.sh             Shell bootstrap for repo-local Python tooling
  README.md                Project purpose and quick start
  AGENTS.md                Agent instructions and constraints
  Sources/                 Swift source for the library and executable
  tests/                   Swift library tests plus repo-wide Python lint tests
  docs/                    Project documentation
  devel/                   Developer maintenance scripts
```

## Sources

### Sources/CableRater (the library)

Backend modules ported from whatcable (MIT, Darryl Morley 2026):

| File | Role |
| --- | --- |
| `PortWatch.swift` | Port-controller state watcher; the primary plug signal from `ConnectionActive`. Holds `PortState`, `PortLiveness`, `PortTransitionTracker`, `PortWatcher`. |
| `Probe.swift` | `IOKitCableSource`: SOP/SOP'/SOP'' enumeration, e-marker decode, and per-port `portKey` correlation. Holds `DetectedCable`, `PortPDIdentity`. |
| `DeviceWatch.swift` | `DeviceWatcher`: USB device-to-port pairing and the negotiated-speed floor. Holds `DeviceState`, `DeviceFloor`. |
| `Model.swift` | Pure value types: `CableSpeedTier`, `CableProductType`, `CableCurrent`, `CableInfo`. |
| `EMarker.swift` | Pure VDO decode functions (speed, current, product type, vendor ID). |
| `Catalog.swift` | Known-cable database loader and lookup; holds `KnownCable`, `Catalog`. |

Coordinator and frontend modules (original to this project):

| File | Role |
| --- | --- |
| `PlugSource.swift` | `PlugCoordinator`: merges port state, PD identity, and device floor into one `PortVerdict` per occupied port. |
| `Rating.swift` | Builds `Verdict` and basis precedence; device-floor and port-active basis tags. |
| `Render.swift` | Port-led two-line text output, colored bucket token, and stable JSON. |
| `WatchFrontend.swift` | `WatchEmitter`: debounce and coalesce policy plus line rendering. |
| `CLI.swift` | Flag parsing and the run loop (startup scan, interest path, poll backup, SIGINT). |
| `CableRater.swift` | Library version constant and a skeleton placeholder. |

Bundled resource:

| Path | Role |
| --- | --- |
| `Resources/known_cables.json` | Vendored cable database loaded by `Catalog.swift` via `Bundle.module`. |

### Sources/usb-cable-rater (the executable)

| File | Role |
| --- | --- |
| `main.swift` | Thin entry point: drops `argv[0]` and calls `runCLI`, then exits. |

## Tests

`tests/CableRaterTests/` holds the Swift library tests, one suite per concern
(port watch, probe, device watch, e-marker, catalog, rating, render, watch
frontend, plug coordinator, CLI, acceptance, fixture loading, raw shapes, PD
identity). `tests/CableRaterTests/Fixtures/` holds captured M1 IOKit
port-controller and SOP-node plists, loaded as a processed resource so the pure
decode and merge logic runs offline.

`tests/` also holds the repo-wide Python lint and hygiene tests (ASCII
compliance, markdown links, pyflakes, typing, imports, shebangs, whitespace,
security), plus shared helpers (`file_utils.py`, `conftest.py`) and the
single-file ASCII checker and fixer.

## Documentation

`docs/` holds project documentation, including the centrally maintained style
guides. The architecture and layout docs are
[CODE_ARCHITECTURE.md](CODE_ARCHITECTURE.md) and this file. Other docs include
[USAGE.md](USAGE.md), [HUMAN_GUIDANCE.md](HUMAN_GUIDANCE.md), the
[CHANGELOG.md](CHANGELOG.md), and the style references.

## Developer scripts

`devel/` holds maintenance scripts: changelog rotation, query, and commit
helpers built on `changelog_lib.py`, a version bumper, Swift artifact cleaners,
a markdown-link flattener, and a verify runner. See
[../devel/DEVEL_README.md](../devel/DEVEL_README.md) for details.

## Generated assets

Build output lands in `.build/` (debug and release binaries from the build
scripts) and is not tracked in git.
