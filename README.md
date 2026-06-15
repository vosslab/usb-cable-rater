# usb-cable-rater

Detects plugged-in USB-C cables live over IOKit and rates each by data-speed bucket (USB2, 5G, 10G, 20-40G, or 80G) from port state and PD identity, with a device-speed fallback. Built to identify and rate a bin of unlabeled USB-C cables on macOS.

## Status

Runnable. E-marker decoding, live cable detection, the rating verdict, and the
text/JSON CLI are implemented. Default mode is a live watch that prints a calm
two-line block per occupied port (a headline plus an indented detail line);
`--once` enumerates current state and exits, and `--json` emits one
machine-readable object per event for both modes. The M5 device-speed fallback
reports an observed `At least <speed> [device]` floor when a far-end USB device
enumerates over a no-e-marker cable. `--debug` (short `-d`) prints raw IOKit
diagnostics to stderr so it never pollutes `--json` on stdout. On macOS, PD
policy hides some e-markers; see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
for that limitation. See [docs/USAGE.md](docs/USAGE.md) for how to run it and
interpret the buckets.

## Quick start

This is a macOS-only Swift command-line tool. No Homebrew or pip runtime
dependency is needed; you only need a Swift toolchain to build it. See
[docs/INSTALL.md](docs/INSTALL.md) for setup details.

Build it with one of the bundled scripts:

```bash
bash build_debug.sh
```

For an optimized build:

```bash
bash build_release.sh
```

Both produce the `usb-cable-rater` binary.

## Documentation

- [docs/USAGE.md](docs/USAGE.md): how to build, run, and read the output.
- [docs/INSTALL.md](docs/INSTALL.md): toolchain requirements and build setup.
- [docs/CODE_ARCHITECTURE.md](docs/CODE_ARCHITECTURE.md): high-level design and data flow.
- [docs/FILE_STRUCTURE.md](docs/FILE_STRUCTURE.md): directory map of the SwiftPM package.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): known symptoms and the macOS PD limits behind them.
- [docs/RELATED_PROJECTS.md](docs/RELATED_PROJECTS.md): upstream references such as whatcable.
- [docs/TODO.md](docs/TODO.md): deferred backlog work captured at closeout.
- [docs/CHANGELOG.md](docs/CHANGELOG.md): chronological record of changes.

## License

The bundled design is adapted from the MIT-licensed whatcable project. See [LICENSE.MIT.md](LICENSE.MIT.md).
