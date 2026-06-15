# Install

`usb-cable-rater` is a macOS-only Swift command-line tool. It reads a plugged-in
USB-C cable's e-marker over IOKit, so there is no Homebrew or pip runtime
dependency to install. You only need a Swift toolchain to build it.

## Requirements

- macOS 13 (Ventura) or newer. The deployment target is set in
  [Package.swift](../Package.swift) (`platforms: [.macOS(.v13)]`); the IOKit USB
  descriptor APIs the tool uses are stable on 13+.
- Xcode Command Line Tools, which provide the `swift` toolchain used to build.
  Install them with:

  ```bash
  xcode-select --install
  ```

- No Homebrew packages and no Python packages are required at runtime. The
  cable database ships vendored in the package
  (`Sources/CableRater/Resources/known_cables.json`).

## Build

The repo ships two wrapper scripts around `swift build`.

Debug build (prints the binary path and run commands):

```bash
bash build_debug.sh
```

`build_debug.sh` runs `swift build`, then prints where the binary is and the
commands to run it. It does not auto-run the binary, because the no-flag default
is a live watch that blocks until Ctrl+C.

Release (optimized) build:

```bash
bash build_release.sh
```

`build_release.sh` runs `swift build -c release` and prints the release binary
path.

## Binary location

Swift Package Manager writes the built binary under `.build/`:

- Debug: `.build/debug/usb-cable-rater`
- Release: `.build/release/usb-cable-rater`

Run it from there, for example:

```bash
.build/debug/usb-cable-rater --once
```

See [USAGE.md](USAGE.md) for flags and output details.

## Tests

Run the build-and-test gate (it runs `swift build` then `swift test`):

```bash
bash devel/verify.sh
```

The live IOKit watch loop touches hardware and is not unit-tested; verify it by
hand with real cables. See the manual test steps in [USAGE.md](USAGE.md).

## Related documents

- [USAGE.md](USAGE.md): flags, output format, and the far-end-partner workflow.
- [CODE_ARCHITECTURE.md](CODE_ARCHITECTURE.md): components and data flow.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): why a cable can read as `Unknown`.
