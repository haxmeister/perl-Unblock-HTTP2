# Unblock::HTTP2 architecture

## Purpose

Unblock::HTTP2 is the reusable HTTP/2 protocol engine.

It is designed to sit below HTTP client/server policy and above an arbitrary
byte transport.

    application or HTTP policy
              |
              v
         Unblock::HTTP2
              |
              v
     transport chosen by caller

The transport may be TCP, TLS, an event-loop stream, a blocking socket, an
in-memory test connection, or another byte carrier.

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

Requests and responses are Uniform objects:

    Uniform::HTTP::Request
    Uniform::HTTP::Response

Received HTTP/2 pseudo-headers map as follows:

    :method     -> method
    :path       -> target
    :scheme     -> scheme
    :authority  -> authority
    :status     -> status

Pseudo-headers are not inserted into the ordinary field list.

Received metadata is committed as soon as the complete header block has been
validated. Message completeness is independent from metadata mutability, so a
message can remain incomplete while DATA is still arriving.

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

## Body flow control

Streaming local bodies use a small per-stream queue.

Current cooperative thresholds:

    high water: 65,536 bytes
    low water:  32,768 bytes

write() always accepts the supplied bytes. It returns false when the queue
reaches the high-water mark. nghttp2 pulls bytes from the queue as protocol and
flow-control credit permit. Once the queue falls below the low-water mark,
on_drain is delivered after the current nghttp2 call has returned.

This avoids invoking application production recursively from inside an nghttp2
data callback.

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

Linux::Event::HTTP will eventually become one caller of this engine.

The Linux::Event adapter should own:

- Stream connection objects
- TLS and ALPN
- readiness
- native transport output
- connection pooling
- HTTP/1 fallback
- high-level Transaction integration

It should not reimplement HTTP/2 framing, stream state, HPACK, SETTINGS,
GOAWAY, or flow control.

## nghttp2

Net::HTTP2::nghttp2 remains the low-level protocol backend.

libnghttp2 owns frame encoding/decoding, HPACK, HTTP/2 state validation,
SETTINGS mechanics, and connection/stream flow control.

Unblock::HTTP2 owns the Perl-facing stream/message mapping and portable engine
boundary around that backend.
