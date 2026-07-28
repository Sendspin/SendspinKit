#!/bin/bash
# ABOUTME: Long-running playback stability test for SendspinKit.
# ABOUTME: Serves the demo stream, plays it, and reports drop/underrun/sync statistics.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DURATION=300
PORT=8927
SERVER_URL=""
SOURCE=""
CLIENT_NAME="Test Client"
DO_BUILD=1
SENDSPIN_CLI="${SENDSPIN_CLI:-${REPO_DIR}/../sendspin-cli/.venv/bin/sendspin}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Long-running stability test. Serves the demo stream (varied music, unlike the
short tone smoke-test uses) and reports playback statistics over the full run.

  --duration N     Seconds to play (default: ${DURATION})
  --url URL        Use an existing server instead of launching one
                   (must include the /sendspin path)
  --source FILE    Serve a file instead of the demo stream
  --port N         Port for the local server (default: ${PORT})
  --name NAME      Client name (default: "${CLIENT_NAME}")
  --no-build       Skip the CLIPlayer rebuild
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2 ;;
        --url) SERVER_URL="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --name) CLIENT_NAME="$2"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 2 ;;
    esac
done

LOG_DIR="${REPO_DIR}/test-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PLAYER_LOG="${LOG_DIR}/5min_${TIMESTAMP}.log"
TELEMETRY_LOG="${LOG_DIR}/5min_${TIMESTAMP}_telemetry.log"
mkdir -p "${LOG_DIR}"

SERVER_PID=""
LOGGER_PID=""
cleanup() {
    [ -n "${LOGGER_PID}" ] && kill "${LOGGER_PID}" 2>/dev/null || true
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

echo -e "${BLUE}SendspinKit Stability Test (${DURATION}s)${NC}"

# Always rebuild. A stale binary silently tests code you did not write.
CLI_PLAYER="${REPO_DIR}/Examples/CLIPlayer/.build/release/CLIPlayer"
if [ "${DO_BUILD}" -eq 1 ]; then
    echo -e "${YELLOW}Building CLIPlayer...${NC}"
    (cd "${REPO_DIR}/Examples/CLIPlayer" && swift build -c release 2>&1 | tail -2)
fi
[ -x "${CLI_PLAYER}" ] || { echo -e "${RED}FAIL${NC}: CLIPlayer missing at ${CLI_PLAYER}"; exit 1; }

if [ -z "${SERVER_URL}" ]; then
    [ -x "${SENDSPIN_CLI}" ] || {
        echo -e "${RED}FAIL${NC}: sendspin CLI not found at ${SENDSPIN_CLI}"
        echo "Set SENDSPIN_CLI, or pass --url to use an existing server."
        exit 1
    }
    if [ -n "${SOURCE}" ]; then
        [ -f "${SOURCE}" ] || { echo -e "${RED}FAIL${NC}: source not found: ${SOURCE}"; exit 1; }
        echo -e "Serving: ${GREEN}$(basename "${SOURCE}")${NC}"
        "${SENDSPIN_CLI}" serve "${SOURCE}" --port "${PORT}" --name "Stability Server" \
            > "${LOG_DIR}/5min_${TIMESTAMP}_server.log" 2>&1 &
    else
        echo -e "Serving: ${GREEN}demo stream${NC}"
        "${SENDSPIN_CLI}" serve --demo --port "${PORT}" --name "Stability Server" \
            > "${LOG_DIR}/5min_${TIMESTAMP}_server.log" 2>&1 &
    fi
    SERVER_PID=$!
    # Detach so bash does not print "Terminated" job notices during cleanup.
    disown "${SERVER_PID}" 2>/dev/null || true

    for _ in $(seq 1 60); do
        nc -z localhost "${PORT}" 2>/dev/null && break
        sleep 0.5
    done
    nc -z localhost "${PORT}" 2>/dev/null || {
        echo -e "${RED}FAIL${NC}: server never listened on ${PORT}"
        tail -20 "${LOG_DIR}/5min_${TIMESTAMP}_server.log"
        exit 1
    }
    # Path is fixed by the protocol (aiosendspin: API_PATH = "/sendspin").
    SERVER_URL="ws://localhost:${PORT}/sendspin"
fi

echo -e "Server:  ${GREEN}${SERVER_URL}${NC}"

# Playback telemetry goes to OSLog at debug level, not stdout.
log stream --level debug \
    --predicate 'subsystem == "com.sendspin.kit" AND category == "audio"' \
    > "${TELEMETRY_LOG}" 2>&1 &
LOGGER_PID=$!
disown "${LOGGER_PID}" 2>/dev/null || true

echo -e "${BLUE}Running until $(date -v +"${DURATION}"S '+%H:%M:%S' 2>/dev/null || echo "+${DURATION}s")...${NC}"
# `script` gives the player a pty. Without it stdout is block-buffered and the
# events we assert on are lost when the timeout kills the process.
timeout "${DURATION}s" script -q /dev/null \
    "${CLI_PLAYER}" --no-tui "${SERVER_URL}" "${CLIENT_NAME}" \
    > "${PLAYER_LOG}" 2>&1 || true

cleanup
sleep 1
echo ""

grep -q "Server connected" "${PLAYER_LOG}" || {
    sed 's/\r//' "${PLAYER_LOG}" | grep -iE 'fatal|error' | head -3
    echo -e "${RED}FAIL${NC}: never connected to ${SERVER_URL}"
    exit 1
}
grep -q "Stream started" "${PLAYER_LOG}" || {
    echo -e "${YELLOW}SKIP${NC}: connected, but the server never started a stream"
    exit 0
}
echo -e "Stream:  ${GREEN}$(sed 's/\r//' "${PLAYER_LOG}" | grep -m1 'Stream started' | sed 's/.*Stream started: //')${NC}"

# Isolate the telemetry payload from the OSLog line prefix.
STATS=$(grep -oE 'sched=.*pcmDrop=[0-9]+' "${TELEMETRY_LOG}" || true)
SAMPLES=$(printf '%s\n' "${STATS}" | grep -c 'sched=' || true)
[ "${SAMPLES:-0}" -gt 0 ] || {
    echo -e "${YELLOW}SKIP${NC}: no telemetry captured (OSLog unavailable?)"
    exit 0
}

# `sched`/`played`/`late` are per-window deltas and sum; `underrun`/`pcmDrop`
# are cumulative so the last value is the total. `played` legitimately trails
# `sched` because several seconds sit buffered ahead — never compare them.
eval "$(printf '%s\n' "${STATS}" | awk '
{
    for (i = 1; i <= NF; i++) {
        split($i, kv, "=")
        k = kv[1]; v = kv[2]
        gsub(/[a-zA-Z%]+$/, "", v)
        if (k == "sched")    sched += v
        if (k == "played")   played += v
        if (k == "late")     late += v
        if (k == "buf")    { buf += v; n++ }
        if (k == "rtt")      rtt += v
        if (k == "est")      est += v
        if (k == "sync")   { s = (v < 0 ? -v : v); syncsum += s; if (s > syncmax) syncmax = s }
        if (k == "queue")    queue += v
        if (k == "underrun") underrun = v
        if (k == "pcmDrop")  pcmdrop = v
    }
}
END {
    printf "SCHED=%d\nPLAYED=%d\nLATE=%d\nUNDERRUN=%d\nPCMDROP=%d\n", sched, played, late, underrun, pcmdrop
    printf "AVG_BUF=%.1f\nAVG_RTT=%.2f\nAVG_EST=%.0f\nAVG_SYNC=%.0f\nMAX_SYNC=%.0f\nAVG_QUEUE=%.1f\n",
        (n ? buf/n : 0), (n ? rtt/n : 0), (n ? est/n : 0), (n ? syncsum/n : 0), syncmax, (n ? queue/n : 0)
}')"

DROP_RATE=$(awk "BEGIN {printf \"%.3f\", (${SCHED} > 0 ? ${LATE} / ${SCHED} * 100 : 0)}")
# Telemetry is emitted every 2s, so a full run yields about half as many
# samples as it does seconds.
EXPECTED_SAMPLES=$(( DURATION / 2 ))

echo ""
echo -e "${BLUE}Playback${NC}"
echo "  samples=${SAMPLES} (expected ~${EXPECTED_SAMPLES})   scheduled=${SCHED}   played=${PLAYED}"
echo "  late=${LATE} (${DROP_RATE}%)   underrun=${UNDERRUN}   pcmDrop=${PCMDROP}"
echo -e "${BLUE}Sync${NC}"
echo "  error avg=${AVG_SYNC}us max=${MAX_SYNC}us   estimate=${AVG_EST}us   rtt=${AVG_RTT}ms"
echo -e "${BLUE}Buffer${NC}"
echo "  fill avg=${AVG_BUF}ms   queue avg=${AVG_QUEUE} chunks"
echo ""

PASS=0
TOTAL=5
check() {
    if [ "$1" -eq 1 ]; then echo -e "${GREEN}✅${NC} $2"; PASS=$((PASS + 1));
    else echo -e "${RED}❌${NC} $2"; fi
}

check "$(awk "BEGIN {print (${DROP_RATE} <= 1.0) ? 1 : 0}")" "late-frame drop rate ≤ 1% (${DROP_RATE}%)"
# An underrun is the ring running dry on read: an audible dropout, never acceptable.
check "$([ "${UNDERRUN}" -eq 0 ] && echo 1 || echo 0)" "no ring underruns (${UNDERRUN})"
check "$([ "${PCMDROP}" -eq 0 ] && echo 1 || echo 0)" "no PCM lost to ring overflow (${PCMDROP})"
# The spec's steady-state accuracy floor is ±1ms.
check "$(awk "BEGIN {print (${MAX_SYNC} < 1000) ? 1 : 0}")" "max sync error < 1ms (${MAX_SYNC}us)"
# Allow slack for startup before the first telemetry tick.
check "$([ "${SAMPLES}" -ge $(( EXPECTED_SAMPLES - 5 )) ] && echo 1 || echo 0)" \
    "ran the full duration (${SAMPLES}/${EXPECTED_SAMPLES} samples)"

echo ""
if [ "${PASS}" -eq "${TOTAL}" ]; then
    echo -e "${GREEN}PASS${NC}: ${PASS}/${TOTAL} criteria"
else
    echo -e "${RED}FAIL${NC}: ${PASS}/${TOTAL} criteria"
fi
echo ""
echo "Logs: ${PLAYER_LOG}"
echo "      ${TELEMETRY_LOG}"
[ "${PASS}" -eq "${TOTAL}" ]
