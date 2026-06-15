#!/bin/bash

set -e

swift build

# Tell a Swift newcomer where the binary is and how to run it. We do NOT auto-run
# the binary here: the no-flag default is a live watch that blocks until Ctrl+C,
# which would tie up this script's terminal. Run it yourself with one of the lines
# below.
echo ""
echo "Built: .build/debug/usb-cable-rater"
echo "Run it (watch mode, Ctrl+C to quit):  .build/debug/usb-cable-rater"
echo "One-shot snapshot:                     .build/debug/usb-cable-rater --once"
echo "JSON output:                           .build/debug/usb-cable-rater --json"
