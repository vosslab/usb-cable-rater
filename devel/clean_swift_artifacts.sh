#!/bin/bash
# clean_swift_artifacts.sh -- remove SwiftPM build artifacts and stale renamed dirs.
# Safe to re-run; all removals are guarded by existence checks.
# Operates only on paths under the repo root (determined via git rev-parse).

set -euo pipefail

# Determine the repo root so all paths are absolute and repo-relative.
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "Repo root: ${REPO_ROOT}"

# Remove SwiftPM build directory if present.
BUILD_DIR="${REPO_ROOT}/.build"
if [ -d "${BUILD_DIR}" ]; then
	echo "Removing ${BUILD_DIR}"
	rm -rf "${BUILD_DIR}"
else
	echo "No .build/ dir found (already clean)"
fi

# Remove stale CableSorter source dir left from a mid-build rename.
STALE_SRC="${REPO_ROOT}/Sources/CableSorter"
if [ -d "${STALE_SRC}" ]; then
	echo "Removing stale ${STALE_SRC}"
	rm -rf "${STALE_SRC}"
else
	echo "No stale Sources/CableSorter/ found"
fi

# Remove stale CableSorterTests dir left from a mid-build rename.
STALE_TESTS="${REPO_ROOT}/tests/CableSorterTests"
if [ -d "${STALE_TESTS}" ]; then
	echo "Removing stale ${STALE_TESTS}"
	rm -rf "${STALE_TESTS}"
else
	echo "No stale tests/CableSorterTests/ found"
fi

echo "Clean done."
