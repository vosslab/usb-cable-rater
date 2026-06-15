# Related projects

## whatcable

`whatcable` is the upstream reference for reading USB-C cable e-markers on macOS.
It is vendored read-only under `OTHER_REPOS/whatcable/` and is MIT licensed.

This tool follows whatcable's core finding: user-space tools can only read the
cable e-marker (SOP') that macOS has already queried via Discover Identity; they
cannot force that query. The `Unknown [port active]` handling and the far-end
partner workflow in [USAGE.md](USAGE.md) follow whatcable's README caveats.
