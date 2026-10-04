# Backend requirements

Unblock::HTTP2 uses libnghttp2 directly through the private
Unblock::HTTP2::_nghttp2 XS binding contained in this distribution.

The binding is intentionally small. It exists to expose the libnghttp2
operations and protocol facts required by Unblock without creating another
public HTTP/2 API.

## Responsibilities

libnghttp2 remains responsible for:

- HTTP/2 frame encoding and decoding
- HPACK
- protocol validation
- stream state
- SETTINGS state
- flow control

The private binding exposes only the pieces Unblock needs:

- client and server session lifecycle
- memory input and output
- frame, header, DATA, error, and stream-close callbacks
- local SETTINGS submission
- effective remote SETTINGS queries
- received SETTINGS identifier/value details and ACK flags
- request and response submission
- generic HEADERS submission
- deferred DATA providers and resume
- trailers
- RST_STREAM
- PING submission and received opaque-data details
- GOAWAY submission and received GOAWAY details
- stream half-close queries
- disabled automatic receive WINDOW_UPDATE
- independent connection and stream consumption credit

Uniform::HTTP message construction and validation remain in Perl.

## Remote SETTINGS

The private binding queries libnghttp2's effective remote SETTINGS directly.

Unblock uses this to enforce SETTINGS_ENABLE_CONNECT_PROTOCOL before sending
Extended CONNECT and to combine the local active-stream cap with the peer's
SETTINGS_MAX_CONCURRENT_STREAMS.

The binding also exposes the identifier/value pairs carried by received
SETTINGS frames and the normal frame flags. Unblock maps known identifiers to
portable public setting names, reports peer changes, and tracks outbound
SETTINGS acknowledgements without exposing raw nghttp2 objects.

## Receive flow control

Sessions are created with nghttp2_option_set_no_auto_window_update enabled.

For every received DATA chunk the private binding releases connection-level
credit with nghttp2_session_consume_connection. Stream-level credit is kept
separate and released with nghttp2_session_consume_stream only when the public
Stream consumption policy allows it.

This split is deliberate. It permits one application-stalled stream to stop its
own WINDOW_UPDATE progress without exhausting the shared connection window and
stalling unrelated streams.

Unblock does not use nghttp2_submit_window_update as a substitute for
application-consumption accounting.

## Informational responses

Generic non-final HEADERS submission is available through the private binding.

The public server API is Stream->inform($response). It accepts a Uniform
informational Response and leaves the stream available for later informational
responses and the final Stream->respond($response).

## PING

The private binding exposes nghttp2_submit_ping for non-ACK PING submission and
includes the eight opaque payload bytes on received PING frame callbacks.
libnghttp2's automatic PING ACK behavior remains enabled.

The public layer distinguishes PING from PING ACK using the frame ACK flag. It
does not disable automatic acknowledgement or implement liveness timers.

## GOAWAY

Received GOAWAY callback data includes:

- last stream ID
- HTTP/2 error code
- debug data

Client and Server retain this as peer_goaway() information while entering
draining state.

Automatic replay or retry policy remains outside Unblock.

## Server push

Server push is still deliberately not exposed.

The client advertises SETTINGS_ENABLE_PUSH = 0 until push is intentionally
given a public Unblock model. The private binding should remain easy to extend
with PUSH_PROMISE support later, but push is not required by the current
engine.

## Portability

The binding must continue to work with:

- Perl 5.16 and newer
- threaded and multiplicity Perl builds
- Linux
- macOS
- Strawberry Perl on Windows

PERL_NO_GET_CONTEXT is enabled. Native callbacks that use Perl APIs establish
an interpreter context with dTHX. Native storage uses ordinary C allocation,
so a callback without a Perl context does not accidentally invoke Perl
allocator macros.

Outgoing bytes use nghttp2_session_mem_send directly. The binding does not
maintain a second send buffer.

## Reentrancy and ownership

Unblock prevents recursive input/output calls while libnghttp2 is executing.

The binding also defers freeing a DATA provider that is released from inside an
active libnghttp2 call. Perl callbacks and provider state are released only
after the native call unwinds.

This protects callback-driven cancellation, connection close, stream close,
and Perl object destruction from use-after-free and double-free hazards.
