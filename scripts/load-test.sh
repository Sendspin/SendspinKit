#!/bin/bash
# ABOUTME: Runs prebuilt Swift tests under CPU saturation and low scheduling priority.
# ABOUTME: Samples stalled testing helpers and reports failures and leftover processes.
# Usage: STALL_SECONDS=30 SUITE_POLICY="-b -t 5 -l 5" scripts/load-test.sh <label> [hogs-per-core] [fg|bg]
# Build tests unloaded first with: timeout 600 swift build --build-tests
set -o pipefail
# GNU timeout (brew install coreutils) bounds the suite and the sampler; without it the run is unbounded.
command -v timeout > /dev/null 2>&1 || { echo "requires GNU timeout: brew install coreutils"; exit 2; }
LABEL="${1:-run}"
PER_CORE="${2:-4}"
MODE="${3:-bg}"
STALL_SECONDS="${STALL_SECONDS:-30}"
PREFIX=""
if [ "${MODE}" = "bg" ]; then PREFIX="taskpolicy -b"; fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="/tmp/sendspin-loadrepro-${LABEL}.log"
N=$(sysctl -n hw.ncpu)
HOGS=$((N * PER_CORE))
echo "ncpu=${N} hogs=${HOGS} label=${LABEL}"
pids=""
cleanup() {
    kill ${pids} 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 "${HOGS}"); do
    ${PREFIX} yes > /dev/null &
    pids="${pids} $!"
done
cd "${REPO}" || exit 2
if [ -n "${SUITE_POLICY:-}" ]; then
    taskpolicy ${SUITE_POLICY} timeout 300 swift test --skip-build > "${LOG}" 2>&1 &
else
    ${PREFIX} timeout 300 swift test --skip-build > "${LOG}" 2>&1 &
fi
suite_pid=$!
# The testing helper that descends from this run's suite process, if one is alive.
find_helper() {
    ps -axo pid,ppid,command | awk -v root="${suite_pid}" '
        { parent[$1]=$2; command[$1]=$0 }
        END {
            for (pid in parent) {
                ancestor=pid
                while (ancestor in parent && ancestor != root) ancestor=parent[ancestor]
                if (ancestor == root && command[pid] ~ /swiftpm-testing-helper/) { print pid; exit }
            }
        }'
}
last_size=-1
quiet=0
while kill -0 "${suite_pid}" 2>/dev/null; do
    sleep 1
    helper=$(find_helper)
    [ -z "${helper}" ] && continue
    size=$(stat -f %z "${LOG}" 2>/dev/null || echo 0)
    if [ "${size}" = "${last_size}" ]; then
        quiet=$((quiet + 1))
    else
        quiet=0
        last_size=${size}
    fi
    if [ "${quiet}" -ge "${STALL_SECONDS}" ]; then
        echo "WATCHDOG: log quiet for ${quiet}s with helper ${helper} alive; sampling"
        timeout 15 sample "${helper}" 5 -file "/tmp/sendspin-hang-${LABEL}.sample" > /dev/null 2>&1
        kill -9 "${helper}" 2>/dev/null
        kill -9 "${suite_pid}" 2>/dev/null
        break
    fi
done
wait "${suite_pid}"
rc=$?
live=$(find_helper)
[ -n "${live}" ] && kill -9 "${live}" 2>/dev/null
cleanup
trap - EXIT
echo "exit=${rc}"
grep -E 'Test run with' "${LOG}" | tail -1
fails=$(grep -cE '✘ Test .* recorded an issue' "${LOG}")
echo "issues=${fails}"
pgrep -fl swiftpm-testing-helper || echo "no leftover testing helpers"
if pgrep -x yes > /dev/null; then echo "WARNING: busy loops still running"; else echo "busy loops stopped"; fi
exit "${rc}"
