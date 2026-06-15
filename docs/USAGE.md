# Usage

`usb-cable-rater` reads a plugged-in USB-C cable's e-marker over IOKit and reports
its rated data-rate bucket, so a bin of unlabeled cables can be sorted by speed.
macOS only.

## Build

For toolchain requirements and the binary location under `.build/`, see
[INSTALL.md](INSTALL.md). In short, use the bundled scripts (they wrap
`swift build`):

```bash
bash build_debug.sh
```

`build_debug.sh` builds the debug binary, then prints where the binary is and the
commands to run it (watch mode, `--once`, and `--json`). It does not auto-run the
binary, because the no-flag default is a live watch that blocks until Ctrl+C.
For an optimized binary:

```bash
bash build_release.sh
```

Both produce the `usb-cable-rater` binary under `.build/`.

## Run

### Live watch (default)

With no flags, the tool watches for cable plug events. It first prints a one-line
banner so you know it is running, then prints the cables already plugged in, and
then one calm two-line block per cable as you plug it. It keeps running until you
press Ctrl+C.

```bash
.build/debug/usb-cable-rater
```

Sample text output (the speed/bucket token in the headline is color-coded on a
terminal; the rest stays the default color; plain in a pipe or file). Each occupied
port prints a two-line block -- the colored headline, then an indented detail line:

```
Watching for USB-C cables. Plug one in. Press Ctrl+C to quit.
Port 3: 10G [e-marker]
        USB3.2 Gen2 (10 Gbps), 3A, passive, VID 0x05AC PID 0x720A
Port 1: Unknown [port active]
        no e-marker read yet -- attach a charger/dock/device on the far end to read it; via ConnectionActive
Port 2: Potentially fast? [unrecognized]
        no e-marker read yet -- attach a charger/dock/device on the far end to read it; via ConnectionActive
```

The headline (line 1) is result-focused: it leads with the physical port number,
then the calm speed/bucket token, then a bracketed basis tag. Only the bucket token
is colored on a terminal (like Python `rich`); the `Port N:` prefix, the basis tag,
and the whole detail line stay the default color. Labels are calm title-case
(`Unknown`, `Potentially fast?`) rather than shouty all-caps.

The detail line (line 2) is for an advanced user. When a cable e-marker decoded, it
is a concise spec: the speed phrase, current rating, product type, and VID/PID. When
no e-marker is readable, it is an honest evidence line naming the detection avenues
that fired for the port (for example `ConnectionActive`, `SOP node`,
`IOAccessoryDetect`, or `TransportsActive CC`). The avenue list is derived from the
avenues the detector actually recorded for the port -- the deciding occupancy signal
plus a present SOP PD-identity node -- so it reflects real evidence, not a guess.

An unplug renders a distinct one-line message, never a plug-shaped line:

```
Port 3: unplugged
```

Press Ctrl+C to exit cleanly (exit code 130).

A cable that is plugged in when the watch starts is printed at startup, so an
already-connected cable is never silent. The raw e-marker fields (hex VDO word, the
SOP endpoint, the matched backend source) stay under `--debug`; the routine detail
line carries only the concise advanced-user spec.

### One-shot snapshot

`--once` enumerates the cables currently plugged in, prints one calm two-line block
per occupied port, and exits. When nothing is plugged in it prints
`No cable plugged in.` and exits 0. `--once` prints the SAME current-state blocks the
watch prints at startup.

```bash
.build/debug/usb-cable-rater --once
```

Sample text output with three ports occupied (each port is a two-line block):

```
Port 1: 80G [e-marker]
        USB4 v2 (80 Gbps), 5A, passive, VID 0x05AC PID 0x720A
Port 2: Potentially fast? [unrecognized]
        no e-marker read yet -- attach a charger/dock/device on the far end to read it; via ConnectionActive
Port 3: Unknown [port active]
        no e-marker read yet -- attach a charger/dock/device on the far end to read it; via ConnectionActive
```

### JSON output

`--json` emits one machine-readable JSON object per event. It works with both
the live watch and `--once`. In live mode, `--json` reports unplug events
(`"event":"removed"`); text mode renders an unplug as the distinct one-line
`Port N: unplugged` message instead. The JSON schema is unchanged by the two-line
text output: it is a human/TTY presentation only, and the JSON keys, order, and
tokens (including `UNKNOWN` / `UNKNOWN*`) are untouched.

```bash
.build/debug/usb-cable-rater --once --json
.build/debug/usb-cable-rater --json
```

JSON keys are emitted in a fixed order: `event`, `bucket`, `tier`, `basis`,
`vendorId`, `productId`, `cableVDO`, `brand`. Fields that are unknown for the
current cable are `null`.

### Debug diagnostics

`--debug` (short `-d`) prints raw diagnostics to standard error, so it never
pollutes `--json` on standard output. It is raw diagnostics, not a verbose alias:
it surfaces the unrounded fields an advanced user needs to identify a cable. It
works with both the live watch and `--once`.

```bash
.build/debug/usb-cable-rater --debug
.build/debug/usb-cable-rater --once --debug
```

Two kinds of line are written. A port-state line names the matched port-controller
class and the property that carried the occupancy:

```
[debug] port inserted class=AppleTCControllerType10 port=3 source=connectionActive connectionActive=true
```

A per-port verdict line names the matched backend source, the occupancy avenue, the
`type/number` portKey the port-state and PD-identity sources correlated on, whether
an SOP node was present, and -- when a cable e-marker decoded -- the raw
`rawCableVDO` (hex), `productID`, `vendorID`, the SOP endpoint, and the decoded
speed tier:

```
[debug] port 3 source=sopIdentity occupancy=connectionActive portKey=2/3 sopPresent=true cableVDO=0x110A2644 productID=0x720A vendorID=0x05AC endpoint=SOP' decoded=gen10g
[debug] port 1 source=portPoll occupancy=connectionActive portKey=2/1 sopPresent=false decoded=nil
```

A port occupied with no readable e-marker shows in normal output as
`Port N: Unknown [port active]` instead of producing nothing. The `decoded=nil`
debug line for that port confirms the port controller reported a CC attach while
no cable e-marker was readable -- the detected, no e-marker (port active) case.

### Help and version

```bash
.build/debug/usb-cable-rater --help
.build/debug/usb-cable-rater -h
.build/debug/usb-cable-rater --version
.build/debug/usb-cable-rater -v
```

`--help` lists every flag, including `--debug` / `-d`.

## Reading the labels

The calm bucket token in the `Port N: <Bucket> [basis]` headline is the friendly
verdict word. The machine `bucket` field in `--json` keeps stable all-caps tokens;
the two differ for the two unknown piles (`Unknown` / `Potentially fast?` in text,
`UNKNOWN` / `UNKNOWN*` in JSON).

| Text label          | JSON bucket | Meaning                                                  |
| ---                 | ---         | ---                                                      |
| `USB2`              | `USB2`      | USB 2.0 (480 Mbps) e-marked cable                        |
| `5G`                | `5G`        | USB 3.2 Gen 1 (5 Gbps)                                   |
| `10G`               | `10G`       | USB 3.2 Gen 2 (10 Gbps)                                  |
| `20-40G`            | `20-40G`    | USB4 Gen 3; 20 vs 40 Gbps not split without PD revision  |
| `80G`               | `80G`       | USB4 Gen 4 (80 Gbps)                                     |
| `Unknown`           | `UNKNOWN`   | No readable e-marker; a detected port-active cable       |
| `Potentially fast?` | `UNKNOWN*`  | E-marker present but unrecognized (no DB match)          |

On a terminal only the bucket token is color-coded by speed (bright green 80G,
green 20-40G, cyan 10G, blue 5G, yellow USB2, magenta `Potentially fast?`, red
`Unknown`); the `Port N:` prefix and the basis tag stay the default color. In a
pipe or file no color escape codes are emitted. The labels are calm title-case, not
shouty all-caps.

### Unknown vs Potentially fast?

These are two different sort piles:

- `Unknown` means a port reported a cable attach but no readable SOP' e-marker
  was returned. The detail line reads "no e-marker read yet" rather than assuming
  a USB2 or basic rating: the cable's e-marker chip runs off VCONN and only
  answers a Discover Identity message, and some Macs wait until a real PD partner
  (charger, dock, or device) is negotiating on the far end before querying it.
  So "no e-marker" does not mean the cable has no chip -- it may simply be
  unqueried. If a cable shows `Unknown`, plug a charger, dock, or device into the
  far end and recheck. That triggers the Discover Identity exchange and the tool
  will read the cable's real rating on the next plug cycle (per whatcable's
  README Caveats). An ordinary, non-e-marked cable produces this too; the
  detail names the detection avenues that fired for the port.
- `Potentially fast?` (JSON `bucket` `UNKNOWN*`) means a real e-marker service was
  present but its VDO fields were zeroed or sparse and the bundled known-cable
  database had no match. This is the "worth investigating" pile: the cable has a
  chip but did not identify itself in a way the tool recognizes.

### Invisible bare cables

A bare, non-e-marked cable with an open far end is electrically invisible to macOS:
it does not terminate the configuration channel, so no port reports an attach and
the tool prints nothing for it. This is a physical limit, not a bug -- there is no
software signal to read. To rate such a cable, attach a USB3+ device or hub on the
far end (joined with a female-female coupler, since both the cable and the hub are
male USB-C); the connected-device speed check rates it from the negotiated link
speed.

## Reading an Unknown cable: far-end partner workflow

For symptom-first guidance (charger vs hub vs enumerating device, and why a
passive coupler keeps the port invisible), see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
The workflow below explains the same situation from the usage side.

If a cable shows `Unknown [port active]`, it is often just unqueried, not
unmarked. The cable e-marker chip (SOP') runs off VCONN and only answers a
Discover Identity message. macOS exposes the e-marker only when it has already
run Discover Identity, and it does NOT do this merely because power is present.
User-space tools (this one and `whatcable`) can only READ what macOS has already
queried; they cannot force Discover Identity.

A direct charger gives power but is NOT a reliable e-marker trigger. Confirmed on
this hardware (live System Information diagnosis on an M1): a 60W+ charger plugged
DIRECTLY onto a port showed `AC Charger Connected` with NO device connected and
NO SOP' node -- the power path worked, but the e-marker was never exposed.
Discover Identity is a choice macOS makes under its own PD policy; from
user-space there is no way to compel it. So "plug in a direct charger" is no
longer presented here as a dependable way to read the e-marker.

A hub or dock in the middle is also usually NOT enough. The Mac negotiates PD
with the hub, not with the cable, so the cable e-marker stays unread even though
the port shows active. Confirmed on this hardware (live ioreg diagnosis on an
M1): a cable into a female-female coupler into a powered USB hub (charger feeding
the hub) gave `ConnectionActive=Yes`, but the active port had only an SOP node
with empty Metadata, no SOP'/SOP'' node anywhere, and no enumerated USB device.
The cable e-marker was never queried, so `Unknown [port active]` was correct.

The "Up to 40 Gb/s" speed shown in System Information is port capability, not
cable. The "Speed: Up to 40 Gb/s" line in the Thunderbolt/USB4 section reports
the Mac receptacle and bus CAPABILITY, not the rating of any attached cable. Do
not read it as cable evidence.

The practical rating path: a far-end USB3+ device that ENUMERATES.

- Attach a USB3+ device that actually enumerates on the cable's far end (a USB3+
  SSD or display, no hub). The tool reports an observed `At least <speed>` floor
  from the negotiated link.
- This floor is what the device and cable together negotiated -- an observed
  capability, not a proven cable maximum. A faster device might negotiate higher.
- A power-only partner (a charger, or a hub whose USB data side does not
  enumerate) gives presence, not a rating: `ConnectionActive=Yes` but no speed
  and no e-marker.

Sample text output when a far-end USB device enumerates over a no-e-marker cable
(the headline reads `At least <speed> [device]`, basis `deviceFloor`):

```
Port 3: At least 10G [device]
        observed from far-end USB device link; no cable e-marker read; via ConnectionActive
```

The JSON `bucket` token stays the normal tier (`10G` here); only the `basis` key
is `deviceFloor`. "At least" is deliberate: the floor is what the device and
cable negotiated together, not a proven cable maximum.

Why a passive female-female coupler plus hub does not work: a passive coupler has
no CC termination resistors (no Ra/Rd), so the Mac never detects a CC attach
(`ConnectionActive` stays false) and the port is invisible. Use a charger, dock,
or device that itself terminates CC.

Honest limit: when the e-marker does not appear, that is a macOS PD-policy limit,
not proof about the cable. The cable may be unmarked, OR macOS may simply have
declined to query it. Do not claim the cable is definitely unmarked. Most quality
cables (5A/100W+, Thunderbolt/USB4) are e-marked; many sub-60W cables are not.

Recommendation: to rate a bin of cables one at a time, plug each cable into a
far-end USB3+ device that enumerates (SSD or display) and read the observed
`At least <speed>` floor. Treat any e-marker read that does appear as a bonus,
not something you can force.

## How a bucket is decided (basis)

The `basis` field (text detail line, or JSON `basis` key) explains the source:

- `emarker`: a clear speed tier came straight from the cable e-marker. A normal
  e-marked cable rates correctly here with no database lookup.
- `emarkerAmbiguous`: the speed field was value 3 (USB4 Gen 3), reported as the
  combined 20-40G bucket.
- `knownDB`: the e-marker was zeroed/sparse and the bundled database supplied the
  speed by exact Cable VDO or VID/PID match.
- `emarkerUnrecognized`: zeroed/sparse e-marker with no database match (UNKNOWN*).
- `noEmarker`: no readable SOP' e-marker was found (UNKNOWN). In the port-led
  headline this reads as the `[port active]` basis (detected, no e-marker) when a
  port reported a cable attach; the JSON `basis` token stays `noEmarker`.
- `deviceFloor`: no cable e-marker was read, but a far-end USB device enumerated,
  so the speed is an observed floor from the negotiated link (M5 device-speed
  fallback). The port-led headline reads `At least <speed> [device]`. The JSON
  `bucket` token stays the normal tier (for example `10G`); only the `basis` key
  is `deviceFloor`. This is an observed capability the device and cable
  negotiated together, not a proven cable maximum.

## Manual test (requires real cables)

The live IOKit watch loop touches hardware and is not unit-tested. Verify it by
hand:

1. Build: `bash build_debug.sh`.
2. Start live watch: `.build/debug/usb-cable-rater`. A "Watching for USB-C
   cables." banner should print immediately, followed by a line for any cable
   already plugged in.
3. Plug in an e-marked cable. A two-line block should print within a moment: a
   port-led headline (for example `Port 3: 10G [e-marker]`) and an indented spec
   detail line beneath it (the speed phrase, current, product type, and VID/PID).
4. Plug in a plain (non-e-marked) cable that terminates CC. It should print
   `Port N: Unknown [port active]` with an indented evidence detail line naming the
   avenues that fired (a detected, no-e-marker cable now prints a port-active block
   instead of being silently dropped).
5. Unplug a cable. Text mode prints a distinct one-line `Port N: unplugged` message
   (never a plug-shaped line). Note: distinct unplug rendering is best-effort -- it
   depends on the port reporting a clean occupied-to-idle transition; see the
   limitation note below.
6. Press Ctrl+C. The tool should exit cleanly (shell exit code 130).
7. Repeat with `--json` to confirm both `inserted` and `removed` events appear as
   cables are plugged and unplugged.
8. If a plugged-in cable produces no line at all, re-run with `--debug` and watch
   stderr while plugging it: a `[debug] port ... decoded=nil` line confirms a port
   reported a CC attach with no readable e-marker, while no line at all means the
   cable never created a CC attach (an invisible bare cable -- see "Invisible bare
   cables" above).

If no cable is plugged in, `--once` prints `No cable plugged in.` and exits 0; the
default live mode prints the watch banner and waits for the first plug event.

### Unplug rendering limitation (best-effort)

Text mode renders an unplug as a distinct `Port N: unplugged` line when the port
controller reports a clean occupied-to-idle transition (`ConnectionActive` flips
back to false, which the watcher diffs into one `removed` event). This is reliable
on the M1 hardware tested here. On other hardware the unplug signal can be less
clean: the port-controller object can vanish from the registry on detach, or
`ConnectionActive` can linger true briefly after the cable is pulled. When that
happens the `removed` transition may be delayed or coalesced rather than printing
immediately. The plug path is the primary contract; the distinct unplug line is a
best-effort improvement layered on whatever clean `removed` signal the hardware
provides.

## Related documents

- [INSTALL.md](INSTALL.md): requirements, build scripts, and binary location.
- [CODE_ARCHITECTURE.md](CODE_ARCHITECTURE.md): IOKit sources, decoders, and
  data flow, including the macOS Discover-Identity limitation.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptom-first fixes for cables that
  read as `Unknown`.
