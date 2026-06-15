#!/bin/bash
# verify.sh -- per-patch verification gate: build and test must both pass.
# Run this before marking any patch done.

set -e

echo "=== verify.sh: building ==="
swift build

echo "=== verify.sh: testing ==="
swift test

echo "=== verify.sh: PASS ==="
