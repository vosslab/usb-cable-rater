# Backend audit 2026-06-15

This audit reviews the Swift backend of usb-cable-rater at project closeout. It
covers the live port-detection path, the plug-source merge logic, the device
speed fallback, and the rendering layer. Findings are graded HIGH, MEDIUM, and
LOW by impact. The two HIGH findings are crash guards and are now fixed; the
MEDIUM and LOW findings remain open. Overall the backend is structurally sound,
is a faithful port of whatcable behavior, and all 220 tests pass.

## High findings (fixed)

- H1: missing IONotificationPortCreate nil-check. `IONotificationPortCreate` can
  return nil, and the code dereferenced the result without checking. Locations:
  PortWatch.swift line 700 and Probe.swift line 706. A nil port would crash the
  watch on startup. NOW FIXED: both sites guard the optional before use.
- H2: baseAddress force-unwrap. A buffer `baseAddress` was force-unwrapped, which
  crashes on an empty buffer. Location: PortWatch.swift near line 955. NOW FIXED:
  the unwrap is guarded.

## Medium findings (open)

- M1: occSource mislabel on PD-identity admission. In PlugSource.swift
  `mergePort`, when a port is admitted via PD identity but has no SOPp service,
  the code falls through to `.connectionActive`. The occupancy source label is
  then wrong, which misleads the human evidence line about why the port is
  considered occupied.
- M2: flushReady backend source hardcoded. In WatchFrontend.swift, `flushReady`
  always tags `backendSource` as `.portPoll`, even when the contributing signal
  was an interest callback or startup snapshot. The reported backend source can
  therefore disagree with the actual avenue that produced the verdict.

## Low findings (open)

- Dead-code portNumber fallbacks in PlugSource.swift: branches that can never be
  reached given the upstream guards.
- Fragile dict force-unwrap: a dictionary lookup is force-unwrapped where a
  guarded access would be safer.
- Step-numbering and stale comments: comment step numbers and a few stale notes
  no longer match the current code flow.
- Incomplete JSON control-char escaping. Render.swift `jsonString` escapes only
  `\\`, `\"`, `\n`, `\r`, and `\t`. It does not escape the full U+0000 through
  U+001F control range, so other control characters can produce invalid JSON.
- Double IOKit poll at watch startup in CLI.swift: the startup path polls IOKit
  twice, which is redundant work.

## Coverage gaps

- Silent drop when a plug vanishes within the debounce window is not tested.
- Location-based portNumber recovery is untested.
- The SOP'' headline fallback is untested.

## Non-M1 divergence

- D1: hardcoded usbCPortType=2 in PlugSource.swift. This constant could misfire
  the IOPort guard on other SoCs where the port type differs from the M1 value.
- D2: attached-device occupancy avenue is not top priority. The attached-device
  (M5) occupancy signal is not weighted as the highest-priority signal the way it
  is in whatcable, so the avenue ordering diverges from the upstream reference.

## Summary

The backend is structurally sound and a faithful port of whatcable behavior. The
two HIGH crash guards (H1, H2) are fixed. The MEDIUM (M1, M2), LOW, coverage-gap,
and non-M1 divergence (D1, D2) items remain open and are tracked for future work.
All 220 tests are green.
