#!/usr/bin/env bash
# debug_step_00_asi_speed_sweep.sh
#
# Find the maximum reliable ASI SPI clock, then report a safe production value.
#
# This is a DIAGNOSTIC, not a build step: nothing downstream depends on it and
# it is interactive (it pauses for you to restart the receiver between runs).
# Formerly build_step_11_asi_speed_sweep.sh.
#
# Method:
#   phase 1  ramp   -- double the clock from START_HZ until a run FAILS
#   phase 2  bisect -- binary search between last PASS and first FAIL
#   report          -- max passing clock, plus a safe value 16% lower
#
# Pass criterion (per your spec): the transfer completes AND retries < 10.
# Every run ships the same ~1 MB file so the numbers are comparable.
#
# Self-contained: calls only scripts outside this tools dir.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
SENDER="$ASI/target/release/asi"

START_HZ="${START_HZ:-4000000}"
CEILING_HZ="${CEILING_HZ:-16000000}"   # sysclk/4; the slave syncs SCK on 64MHz
CHUNK_BYTES="${CHUNK_BYTES:-8192}"     # multiple of 4, <= FIFO 4096 words (16384 B)
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
MAX_RETRIES="${MAX_RETRIES:-10}"       # retries >= this counts as FAIL
PAYLOAD_BYTES="${PAYLOAD_BYTES:-1048576}"
SAFETY_PCT="${SAFETY_PCT:-16}"         # report a value this % below max
FIFO_WORD=4

# Which receiver is under test.  The chardev path sleeps on the spi_ext
# interrupt and batches reads; the CSR path polls /dev/mem and is the
# reference implementation.  Sweep whichever one you actually ship -- their
# ceilings differ, because the bottleneck is not the bit rate.
RECEIVER="${RECEIVER:-chardev}"
case "$RECEIVER" in
    chardev) RECEIVER_FLAGS="--chardev" ;;
    csr)     RECEIVER_FLAGS="" ;;
    *) echo "ERROR: RECEIVER must be 'chardev' or 'csr' (got '$RECEIVER')" >&2; exit 2 ;;
esac
OC_ASI_BIN="${OC_ASI_BIN:-/root/8gb/spis/bin/asi}"
OC_INCOMING_DIR="${OC_INCOMING_DIR:-/root/8gb/oled/incoming}"

TESTFILE="${TESTFILE:-/tmp/asi_speed_test_1mb.bin}"
RESULTS="/tmp/asi_speed_sweep_results.txt"

(( CHUNK_BYTES % FIFO_WORD == 0 )) || { echo "ERROR: CHUNK_BYTES must be a multiple of $FIFO_WORD" >&2; exit 2; }
(( CHUNK_BYTES <= 16384 )) || { echo "ERROR: CHUNK_BYTES exceeds the 4096-word RX FIFO (16384 bytes)" >&2; exit 2; }

"$ASI/tools/build_host.sh"
[[ -x "$SENDER" ]] || { echo "ERROR: missing $SENDER" >&2; exit 1; }

if [[ ! -s "$TESTFILE" ]] || [[ "$(stat -c%s "$TESTFILE")" != "$PAYLOAD_BYTES" ]]; then
    echo "== generating $PAYLOAD_BYTES byte test payload =="
    head -c "$PAYLOAD_BYTES" /dev/urandom > "$TESTFILE"
fi
echo "receiver under test: $RECEIVER"
echo "payload: $TESTFILE ($(stat -c%s "$TESTFILE") bytes)"
sha256sum "$TESTFILE"
: > "$RESULTS"

# Run one transfer at a given clock. Returns 0 = PASS, 1 = FAIL.
# Echoes "retries throughput_kbs" on stdout via globals.
LAST_RETRIES=""; LAST_KBS=""
run_at() {
    local hz="$1" log rc line elapsed retries bytes
    log="$(mktemp /tmp/asi_sweep.XXXXXX.log)"

    cat <<EOT

──────────────────────────────────────────────────────────────
  NEXT TEST: ${hz} Hz   (chunk=${CHUNK_BYTES} timeout=${TIMEOUT_SECONDS}s)

  On the OrangeCrab, start a FRESH receiver now:
    ${OC_ASI_BIN} ${RECEIVER_FLAGS} --timeout-seconds ${TIMEOUT_SECONDS} receive ${OC_INCOMING_DIR}
──────────────────────────────────────────────────────────────
EOT
    read -r -p "  press ENTER when the receiver is listening (or 's' to skip): " reply
    if [[ "${reply:-}" == "s" ]]; then
        echo "  skipped"; rm -f "$log"; return 1
    fi

    set +e
    "$SENDER" --speed-hz "$hz" --chunk-bytes "$CHUNK_BYTES" \
        --timeout-seconds "$TIMEOUT_SECONDS" send "$TESTFILE" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e

    line="$(grep -m1 '^complete:' "$log" || true)"
    if (( rc != 0 )) || [[ -z "$line" ]]; then
        echo "  -> FAIL (sender exit $rc, no completion line)"
        printf '%s\tFAIL\t-\t-\n' "$hz" >> "$RESULTS"
        rm -f "$log"; return 1
    fi

    retries="$(sed -n 's/.*retries=\([0-9]\+\).*/\1/p' <<<"$line")"
    elapsed="$(sed -n 's/.*elapsed=\([0-9.]\+\)s.*/\1/p' <<<"$line")"
    bytes="$(sed -n 's/^complete: \([0-9]\+\) bytes.*/\1/p' <<<"$line")"
    rm -f "$log"

    LAST_KBS="$(awk -v b="$bytes" -v e="$elapsed" 'BEGIN{ if (e>0) printf "%.1f", b/1024/e; else print "0" }')"
    LAST_RETRIES="$retries"

    if (( retries < MAX_RETRIES )); then
        echo "  -> PASS  retries=$retries  throughput=${LAST_KBS} KB/s"
        printf '%s\tPASS\t%s\t%s\n' "$hz" "$retries" "$LAST_KBS" >> "$RESULTS"
        return 0
    fi
    echo "  -> FAIL  retries=$retries (>= $MAX_RETRIES)  throughput=${LAST_KBS} KB/s"
    printf '%s\tFAIL\t%s\t%s\n' "$hz" "$retries" "$LAST_KBS" >> "$RESULTS"
    return 1
}

echo
echo "════════ phase 1: ramp (doubling from ${START_HZ} Hz) ════════"
best_hz=0; best_kbs=""; fail_hz=0; hz="$START_HZ"
while (( hz <= CEILING_HZ )); do
    if run_at "$hz"; then
        best_hz="$hz"; best_kbs="$LAST_KBS"
    else
        fail_hz="$hz"; break
    fi
    hz=$(( hz * 2 ))
done
(( fail_hz == 0 )) && fail_hz=$(( hz ))

if (( best_hz == 0 )); then
    echo
    echo "RESULT: even ${START_HZ} Hz failed. Lower START_HZ and retry."
    exit 1
fi

echo
echo "════════ phase 2: bisect between ${best_hz} (pass) and ${fail_hz} (fail) ════════"
lo="$best_hz"; hi="$fail_hz"
# Stop when the window is under 5% of lo -- finer than that is noise.
while (( hi - lo > lo / 20 )); do
    mid=$(( (lo + hi) / 2 ))
    mid=$(( mid - mid % FIFO_WORD ))
    (( mid <= lo || mid >= hi )) && break
    if run_at "$mid"; then
        lo="$mid"; best_hz="$mid"; best_kbs="$LAST_KBS"
    else
        hi="$mid"
    fi
done

safe_hz=$(( best_hz * (100 - SAFETY_PCT) / 100 ))
safe_hz=$(( safe_hz - safe_hz % FIFO_WORD ))

cat <<EOT

════════════════════════════════════════════════════════════
  SWEEP COMPLETE

  max reliable clock : ${best_hz} Hz   (retries < ${MAX_RETRIES})
  throughput there   : ${best_kbs} KB/s
  first failing clock: ${fail_hz} Hz

  RECOMMENDED (${SAFETY_PCT}% margin, floored to ${FIFO_WORD}-byte FIFO word):
      --speed-hz ${safe_hz} --chunk-bytes ${CHUNK_BYTES}

  full log: ${RESULTS}
════════════════════════════════════════════════════════════

Note: throughput will NOT scale linearly with the clock. At 4 MHz you were
seeing ~55 KB/s = ~0.44 Mbit/s against a 4 Mbit/s wire, i.e. ~11% efficiency,
because per-chunk handshake round trips dominate rather than the bit rate.
Raising the clock shrinks only the streaming portion. If the sweep plateaus
well below the wire rate, the next win is fewer/larger chunks (raise
CHUNK_BYTES toward the 16384-byte FIFO limit), not a faster clock.
EOT
column -t -s$'\t' "$RESULTS" 2>/dev/null || cat "$RESULTS"
