# Troubleshooting

Known symptoms when reading USB-C cables on macOS, and what they mean. Most of
these are macOS power-delivery (PD) policy limits, not tool bugs. For full output
semantics see [USAGE.md](USAGE.md).

## A cable shows `Unknown [port active]`

The port reported a CC attach, but no readable SOP' e-marker came back. This means
macOS has not run Discover Identity for that cable yet, so the e-marker is unread,
not necessarily absent. The e-marker chip runs off VCONN and only answers a
Discover Identity message, and macOS does not send one merely because a port is
active.

The cable may be unmarked, or macOS may simply have declined to query it. Do not
read `Unknown` as proof the cable has no chip. To force a query attempt, attach a
real far-end partner (see the rating workflow below) and recheck on the next plug
cycle.

## A direct charger gives power but no e-marker (M1)

Plugging a charger directly onto a port gives power but does not surface the
e-marker. Confirmed on M1 hardware: a 60W+ charger plugged directly onto a port
showed `AC Charger Connected` with no device connected and no SOP' node. The power
path worked, but the e-marker was never exposed.

"Power present" does not imply "e-marker visible". A direct charger is not a
reliable way to read the e-marker. User-space tools (this one and `whatcable`) can
only read what macOS has already queried; they cannot force Discover Identity.

## "Up to 40 Gb/s" in System Information is the port, not the cable

The "Speed: Up to 40 Gb/s" line in the Thunderbolt/USB4 section of System
Information reports the Mac receptacle and bus capability, not the rating of any
attached cable. Do not read it as cable evidence.

## A bare open-ended cable prints nothing

A bare, non-e-marked cable with an open far end is electrically invisible to
macOS. It does not terminate the configuration channel (no CC termination), so no
port reports an attach and the tool prints nothing for it. This is a physical
limit, not a bug: there is no software signal to read.

## How to get a rating: a far-end enumerating device

To rate an `Unknown` or bare cable, attach a USB3+ device that actually enumerates
on the far end (a USB3+ SSD or display, not a hub). The tool reports an observed
`At least <speed> [device]` floor from the negotiated link, with `basis`
`deviceFloor`. "At least" is deliberate: the floor is what the device and cable
negotiated together, an observed capability rather than a proven cable maximum.

## A power-only hub gives presence, not a rating

A power-only partner gives presence, not a rating. A charger, or a hub whose USB
data side does not enumerate, produces `ConnectionActive=Yes` but no speed and no
e-marker. The Mac negotiates PD with the hub, not with the cable, so the cable
e-marker stays unread even though the port shows active. Use a device that
enumerates on the data side.

## A passive female-female coupler keeps the port invisible

A passive female-female coupler has no CC termination resistors (no Ra/Rd), so the
Mac never detects a CC attach (`ConnectionActive` stays false) and the port stays
invisible. Use a charger, dock, or device that itself terminates CC.

## See also

- [USAGE.md](USAGE.md): output format, labels, basis tokens, and the full far-end
  partner workflow.
- [TODO.md](TODO.md): deferred work and known code-side gaps.
