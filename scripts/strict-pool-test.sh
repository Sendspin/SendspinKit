#!/bin/bash
# ABOUTME: Runs prebuilt tests with one cooperative-pool thread to expose blocking calls.
# ABOUTME: Samples a stalled helper and reports test completion and issue counts.
# Usage: scripts/strict-pool-test.sh <label> [quiet-seconds]
# Build tests unloaded first: timeout 600 swift build --build-tests
set -o pipefail
LABEL="${1:-strict}"
QUIET_LIMIT="${2:-15}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="/tmp/sendspin-strictpool-${LABEL}.log"
SAMPLE="/tmp/sendspin-strictpool-${LABEL}.sample"
BUNDLE=$(find "${REPO}/.build" -type f -path '*Tests.xctest/Contents/MacOS/*Tests' 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
TOOLCHAIN=$(xcode-select -p)
HELPER="${TOOLCHAIN}/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
[ -x "${HELPER}" ] && [ -f "${BUNDLE}" ] || { echo "missing helper or bundle; build tests first"; exit 2; }
PRODUCTS=$(dirname "$(dirname "$(dirname "$(dirname "${BUNDLE}")")")")
PLATFORM="${TOOLCHAIN}/Platforms/MacOSX.platform/Developer"
export DYLD_LIBRARY_PATH="${PRODUCTS}:${PLATFORM}/usr/lib"
export DYLD_FRAMEWORK_PATH="${PLATFORM}/Library/Frameworks:${PLATFORM}/Library/PrivateFrameworks"
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 timeout 400 "${HELPER}" \
    --test-bundle-path "${BUNDLE}" "${BUNDLE}" --testing-library swift-testing > "${LOG}" 2>&1 &
runner=$!
helper=""
cleanup() {
    [ -n "${helper}" ] && kill -9 "${helper}" 2>/dev/null
    kill "${runner}" 2>/dev/null
    wait "${runner}" 2>/dev/null
}
trap cleanup EXIT INT TERM
started=$(date +%s)
last_size=-1
quiet=0
while kill -0 "${runner}" 2>/dev/null; do
    sleep 1
    helper=$(pgrep -P "${runner}" -x swiftpm-testing-helper | head -1)
    size=$(stat -f %z "${LOG}" 2>/dev/null || echo 0)
    if [ "${size}" = "${last_size}" ]; then quiet=$((quiet + 1)); else quiet=0; last_size=${size}; fi
    if [ "${quiet}" -ge "${QUIET_LIMIT}" ] && grep -q '◇ Test ' "${LOG}"; then
        echo "WATCHDOG: no output for ${quiet}s; sampling helper ${helper}"
        [ -n "${helper}" ] && timeout 15 sample "${helper}" 3 -file "${SAMPLE}" > /dev/null 2>&1
        cleanup
        echo "sample=${SAMPLE}"
        break
    fi
done
wait "${runner}" 2>/dev/null
rc=$?
trap - EXIT INT TERM
echo "exit=${rc} elapsed=$(( $(date +%s) - started ))s"
grep -E 'Test run with' "${LOG}" | tail -1
echo "issues=$(grep -cE '✘ Test .* recorded an issue' "${LOG}")"
exit "${rc}"
