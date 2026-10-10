#!/usr/bin/env bash
set -euo pipefail

# The normal tests need no event loop. The Linux latest CI job installs
# optional host frameworks and exercises complete client/server examples.
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch"

for framework in io-async anyevent; do
    if [[ "$framework" == io-async ]]; then
        port=18142
    else
        port=18143
    fi

    log="$(mktemp)"
    server_pid=''

    cleanup() {
        if [[ -n "$server_pid" ]]; then
            kill "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
        fi
        rm -f "$log"
    }
    trap cleanup EXIT

    perl "examples/$framework-server.pl" "$port" > "$log" 2>&1 &
    server_pid=$!

    ready=0
    for attempt in {1..40}; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            cat "$log"
            echo "$framework server exited before listening" >&2
            exit 1
        fi
        if perl -MIO::Socket::INET -e '
            my $s = IO::Socket::INET->new(
                PeerAddr => "127.0.0.1",
                PeerPort => $ARGV[0],
                Proto    => "tcp",
                Timeout  => 1,
            );
            exit($s ? 0 : 1);
        ' "$port"; then
            ready=1
            break
        fi
        sleep 0.25
    done

    if [[ "$ready" != 1 ]]; then
        cat "$log"
        echo "$framework server did not start" >&2
        exit 1
    fi

    output="$(timeout 20s perl "examples/$framework-client.pl" "$port")" || {
        cat "$log"
        echo "$framework client failed" >&2
        exit 1
    }
    echo "$output"
    if [[ "$output" != *"HTTP status: 200"* ]]; then
        cat "$log"
        echo "$framework client did not receive HTTP 200" >&2
        exit 1
    fi
    if [[ "$output" != *"hello from"* ]]; then
        cat "$log"
        echo "$framework client did not receive the response body" >&2
        exit 1
    fi

    cleanup
    trap - EXIT
done
