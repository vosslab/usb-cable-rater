# usb-cable-rater

Reads a plugged-in USB-C cable's e-marker over IOKit and reports its rated data-rate bucket (USB2, 5G, 10G, 20-40G, or 80G), updating live as you swap cables. Built to sort a bin of unlabeled USB-C cables by speed on macOS.

## Status

Early-stage. The Swift package skeleton is scaffolded; e-marker reading and live cable detection are still being implemented.

## Quick start

This is a macOS-only Swift command-line tool. Build it with one of the bundled scripts:

```bash
bash build_debug.sh
```

For an optimized build:

```bash
bash build_release.sh
```

Both produce the `usb-cable-rater` binary.

## Documentation

- [docs/CHANGELOG.md](docs/CHANGELOG.md): chronological record of changes.
- [docs/REPO_STYLE.md](docs/REPO_STYLE.md): repo-level organization and conventions.
- [docs/PYTHON_STYLE.md](docs/PYTHON_STYLE.md): Python formatting and conventions for tooling.
- [docs/PYTEST_STYLE.md](docs/PYTEST_STYLE.md): pytest test-writing rules and commands.
- [docs/E2E_TESTS.md](docs/E2E_TESTS.md): end-to-end testing conventions.
- [docs/MARKDOWN_STYLE.md](docs/MARKDOWN_STYLE.md): Markdown writing rules for this repo.

## License

The bundled design is adapted from the MIT-licensed whatcable project. See [LICENSE.MIT.md](LICENSE.MIT.md).
