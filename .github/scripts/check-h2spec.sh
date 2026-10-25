#!/usr/bin/env bash
set -euo pipefail

export PERL_DL_NONLAZY=1
H2SPEC_BIN=${H2SPEC_BIN:-h2spec}
RESULT_DIR=${H2SPEC_RESULTS:-.h2spec-results}
mkdir -p "$RESULT_DIR"
transports=(tcp)
if [[ -n "${UNBLOCK_HTTP2_TLS_CERT:-}" ]]; then transports+=(tls); fi
certificate=${UNBLOCK_HTTP2_TLS_CERT:-}
server_pid=''
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" || true
    fi
}
trap cleanup EXIT

for transport in "${transports[@]}"; do
    for response in headers request; do
        for input in perl native; do
            name="$transport-$response-$input"
            log="$RESULT_DIR/$name-server.log"
            args=()
            export UNBLOCK_HTTP2_TLS_CERT=''
            if [[ "$transport" == tls ]]; then
                export UNBLOCK_HTTP2_TLS_CERT="$certificate"
                args+=(--tls --insecure)
            fi
            UNBLOCK_HTTP2_RESPONSE_MODE="$response" UNBLOCK_HTTP2_INPUT_MODE="$input" \
                perl -Mblib xt/h2spec-server.pl > "$log" 2>&1 &
            server_pid=$!
            for attempt in $(seq 1 100); do
                grep -q '^ready ' "$log" && break
                kill -0 "$server_pid"
                sleep 0.1
            done
            grep -q '^ready ' "$log"
            status=0
            "$H2SPEC_BIN" --host 127.0.0.1 --port "${UNBLOCK_HTTP2_SERVER_PORT:-18082}" \
                --strict "${args[@]}" --junit-report "$RESULT_DIR/$name.xml" \
                > "$RESULT_DIR/$name.log" 2>&1 || status=$?
            kill "$server_pid"
            wait "$server_pid" || status=1
            server_pid=''
            if grep -q 'HARNESS FAILURE' "$log"; then status=1; fi
            tail -3 "$RESULT_DIR/$name.log"
            if [[ "$status" != 0 ]]; then
                cat "$log"
                cat "$RESULT_DIR/$name.log"
                exit "$status"
            fi
            python3 - "$RESULT_DIR/$name.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert len(cases) == 147, (sys.argv[1], 'incomplete strict suite', len(cases))
assert not root.findall('.//failure'), sys.argv[1]
assert not root.findall('.//error'), sys.argv[1]
assert not root.findall('.//skipped'), sys.argv[1]
print(sys.argv[1], '147 passed; no failures, skips, or errors')
PY
        done
    done
done
