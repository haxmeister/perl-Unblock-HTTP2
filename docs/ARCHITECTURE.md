# Unblock::HTTP2 architecture

## Purpose

Unblock::HTTP2 is the reusable HTTP/2 protocol engine.

It sits below HTTP client/server policy and above an arbitrary byte transport.

    application or HTTP policy
              |
              v
         Unblock::HTTP2
              |
              v
     transport chosen by caller

The transport may be TCP, TLS, an event-loop stream, a blocking socket, an
in-memory connection, or another byte carrier.

## Byte boundary

The core transport contract is deliberately not an object interface.

Incoming bytes:

    $engine->input($bytes);

Outgoing bytes:

    while ($engine->want_write) {
        my $bytes = $engine->output;
        last unless length $bytes;
        ...
    }

The engine therefore does not know how writes are queued or when a file
descriptor is writable.

want_read() reports whether nghttp2 still expects protocol input. It does not
register a read watcher.

## Messages

Requests and responses are Uniform::HTTP 0.04 objects:

    Uniform::HTTP::Request
    Uniform::HTTP::Response

Received HTTP/2 pseudo-headers map as follows:

    :method     -> method
    :path       -> target
    :scheme     -> scheme
    :authority  -> authority
    :protocol   -> protocol
    :status     -> status

Pseudo-headers are not inserted into the ordinary field list.

Ordinary fields map to Uniform headers. A later HTTP/2 HEADERS block maps to
the separate Uniform trailer section.

For received messages, Unblock creates canonical Uniform objects. Once the
initial field block has been validated it calls freeze_initial(), leaving the
message incomplete while DATA and trailers may still arrive. END_STREAM makes
the message complete and fully frozen.

For outgoing messages, Unblock does not take ownership of the application's
Uniform object. A neutral version value of undef is valid and is not rewritten
to 2 just because the HTTP/2 engine was selected.

## CONNECT

Ordinary CONNECT maps to:

    :method     CONNECT
    :authority  host:port

with the exact authority-form target represented by Uniform.

Extended CONNECT maps Uniform protocol metadata to :protocol and retains
scheme, authority, and path. The protocol value is generic; WebSocket,
CONNECT-UDP, WebTransport, and other tunnel semantics remain outside this
distribution.

The server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL by default because the
engine understands the generic Extended CONNECT message form. A host can turn
that advertisement off.

The client queries libnghttp2's effective remote SETTINGS before sending
Extended CONNECT. It refuses :protocol until the peer has advertised
SETTINGS_ENABLE_CONNECT_PROTOCOL = 1. The same remote SETTINGS view is used to
cap locally opened streams by the peer's SETTINGS_MAX_CONCURRENT_STREAMS.

## Streams

One Unblock::HTTP2::Stream represents one HTTP/2 stream.

A Stream owns:

- stream id
- request
- response when available
- local streaming body production
- cancellation
- terminal stream state

A Stream does not own the connection transport.

HTTP/2 half-close state matters. A client can receive a complete Response while
its streaming Request body is still open. Response completion therefore does
not by itself make the Stream terminal. The Stream becomes complete when
nghttp2 closes the full HTTP/2 stream normally.

## Bodies and trailers

Uniform body() represents a complete buffered body. Incremental transfer stays
on the Unblock Stream.

Streaming local bodies use a small per-stream queue.

Current cooperative thresholds:

    high water: 65,536 bytes
    low water:  32,768 bytes

write() always accepts the supplied bytes. It returns false when the queue
reaches the high-water mark. nghttp2 pulls bytes from the queue as protocol and
flow-control credit permit. Once the queue falls below the low-water mark,
on_drain is delivered after the current nghttp2 call has returned.

Receive flow control uses nghttp2 with automatic WINDOW_UPDATE disabled.
Connection-level DATA credit is released as bytes are delivered into the
Unblock stream, while stream-level credit is released separately. Streams
auto-consume delivered body bytes by default after their body callback returns.

A caller can disable automatic consumption on one Stream with
auto_consume(0). Delivered-but-unreleased bytes are then bounded by that
stream's HTTP/2 receive window. consume($bytes) releases stream-level credit as
the application actually processes data. This keeps a slow stream from
unnecessarily consuming the shared connection window and blocking unrelated
streams.

When an outgoing Uniform message contains trailers, the final DATA deliberately
reserves END_STREAM and Unblock submits the Uniform trailer fields as the
terminal HEADERS block. For a streaming body, trailer fields are snapshotted
when end() is called.

Incoming trailing HEADERS are validated as ordinary HTTP/2 fields, added to the
Uniform trailer section, then frozen before message completion is reported.

## SETTINGS control plane

SETTINGS is part of the public protocol engine rather than a private backend
escape hatch. Client and Server accept an initial settings hash, expose the
locally advertised values and libnghttp2's effective peer values, and can
submit later SETTINGS changes.

Peer SETTINGS frames are surfaced as protocol facts through on_settings. The
callback receives both the current effective peer snapshot and the values that
changed in that frame. SETTINGS acknowledgements are matched in submission
order and surfaced through on_settings_ack. settings_pending() reports the
number of locally submitted SETTINGS frames still awaiting ACK.

The public layer validates RFC value ranges before asking libnghttp2 to submit
a frame. It also enforces extension semantics that are part of the HTTP/2
protocol surface, including the rule that SETTINGS_ENABLE_CONNECT_PROTOCOL
cannot be changed from 1 back to 0.

The private binding remains responsible for SETTINGS frame processing and
effective state. It only exposes the received identifier/value pairs needed to
describe peer changes without exposing nghttp2 objects to callers.

## Graceful draining

Client and Server expose drain() as the graceful connection-shutdown operation.
It submits GOAWAY and prevents new locally initiated client streams while
letting streams already accepted by the peer finish normally.

The server remembers the highest peer-initiated request stream it has seen and
uses that value when initiating GOAWAY. The client advertises ENABLE_PUSH = 0,
so its locally initiated GOAWAY can use last-stream-id zero without pretending
to support server-initiated push streams.

Received GOAWAY also places the engine in draining state. The engine preserves
the peer's last stream ID, HTTP/2 error code, and debug data so a higher layer
can make its own retry decision. Retry policy remains above this engine.

## Reentrancy

input() drives nghttp2_session_mem_recv.

output() drives nghttp2_session_mem_send.

Neither operation may recursively call the other from an nghttp2 callback.
If connection close is requested from inside a callback, destruction is
deferred until that nghttp2 call returns.

## TLS and ALPN

TLS and ALPN are outside Unblock::HTTP2.

A host that uses HTTPS normally performs:

    connect transport
    perform TLS handshake
    ALPN selects h2
    create/use Unblock::HTTP2 engine
    feed decrypted HTTP/2 bytes

Cleartext HTTP/2 can feed bytes directly without TLS.

HTTP/1 Upgrade negotiation is also outside this distribution. An HTTP/1 engine
can hand the resulting byte stream to Unblock::HTTP2 after the protocol switch.

## Linux::Event integration

Linux::Event::HTTP can become one caller of this engine.

The Linux::Event adapter should own:

- Stream connection objects
- TLS and ALPN
- readiness
- native transport output
- connection pooling
- HTTP/1 fallback
- high-level Transaction integration

It should not reimplement HTTP/2 framing, stream state, HPACK, SETTINGS,
GOAWAY, trailer framing, Extended CONNECT pseudo-header mapping, or flow
control.

## nghttp2

libnghttp2 remains the low-level protocol engine. It owns frame
encoding/decoding, HPACK, HTTP/2 state validation, SETTINGS mechanics, and
connection/stream flow control.

Unblock::HTTP2 talks to libnghttp2 through the private
Unblock::HTTP2::_nghttp2 XS binding in this distribution. The binding is kept
small: it exposes protocol facts and operations needed by Unblock, including
memory I/O, callbacks, DATA providers, remote SETTINGS, generic HEADERS,
trailers, RST_STREAM, and GOAWAY details.

The private binding does not know about Uniform::HTTP and is not a supported
public API. Unblock::HTTP2 owns the Perl-facing stream/message mapping and the
portable byte-engine boundary around libnghttp2.
