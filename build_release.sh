#!/bin/bash

set -e

# Build release binary (CLI only; no .app bundle needed).
echo "Building release..."
swift build -c release

# Show the path to the built binary.
echo "Done! Binary built at:"
echo "   $(pwd)/.build/release/usb-cable-rater"
