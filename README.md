# Unblock::HTTP2

[![CPAN version](https://badge.fury.io/pl/Unblock-HTTP2.svg)](https://metacpan.org/dist/Unblock-HTTP2)
[![CPANTS Kwalitee](https://cpants.cpanauthors.org/dist/Unblock-HTTP2.svg)](https://cpants.cpanauthors.org/dist/Unblock-HTTP2)
[![CI](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/test.yml)
[![Interop](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/interop.yml/badge.svg?branch=main)](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/interop.yml)
[![License](https://img.shields.io/cpan/l/Unblock-HTTP2.svg)](https://github.com/haxmeister/perl-Unblock-HTTP2/blob/main/LICENSE)
[![Perl](https://img.shields.io/badge/perl-5.16%2B-blue.svg)](https://www.perl.org/)
[![HTTP/2](https://img.shields.io/badge/HTTP%2F2-RFC%209113-blue.svg)](https://www.rfc-editor.org/rfc/rfc9113)

Event-loop and operating-system neutral HTTP/2 for Perl.

Unblock::HTTP2 is a protocol engine. It does not open sockets, negotiate TLS,
select ALPN, or run an event loop.

The caller gives it HTTP/2 bytes with:

    $client->input($bytes_from_transport);

The caller takes bytes back out with:

    while ($client->want_write) {
        my $bytes = $client->output;
        last unless length $bytes;
        $transport->write($bytes);
    }

This makes the same engine usable with Linux::Event, IO::Async, AnyEvent,
Mojolicious, blocking sockets, in-memory transports, and other environments.

## Installation

Install from CPAN with:

    cpanm Unblock::HTTP2

or:

    cpan Unblock::HTTP2

The distribution builds a small private XS binding against libnghttp2.
Alien::nghttp2 supplies the build flags and library dependency.

## Message objects

Unblock::HTTP2 uses Uniform::HTTP 0.04 directly:

    Uniform::HTTP::Request
    Uniform::HTTP::Response

It does not define competing request and response classes.

Uniform carries the shared HTTP message semantics:

- method, target, scheme, authority, and Extended CONNECT protocol
- status
- ordered duplicate-preserving headers
- ordered duplicate-preserving trailers
- an optional buffered body
- message completeness and section mutability

Unblock owns the HTTP/2 stream and connection behavior around those messages.

Application-created outgoing messages may leave version unset. Sending them
over HTTP/2 does not rewrite the object merely to set version 2. Received
messages report version 2.

Received initial metadata is frozen after validation while the body and trailer
sections can continue to arrive. At END_STREAM the received message is complete
and fully frozen.

## Client

    use Uniform::HTTP::Request;
    use Unblock::HTTP2::Client;

    my $client = Unblock::HTTP2::Client->new;

    my $request = Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => '/',
        scheme    => 'https',
        authority => 'example.com',
    );

    my $stream = $client->request(
        $request,

        on_response => sub {
            my ($stream, $response) = @_;
            print $response->status, "\n";
        },

        on_body => sub {
            my ($stream, $response, $bytes) = @_;
            process_bytes($bytes);
        },

        on_complete => sub {
            my ($stream) = @_;
            print "response complete\n";
        },
    );

For a streaming request body:

    my $stream = $client->request(
        $request,
        stream_body => 1,
        on_drain => sub {
            my ($stream) = @_;
            produce_more($stream);
        },
    );

    $stream->write($chunk);
    $stream->end($final_chunk);

write() accepts the bytes even when it returns false. A false return means the
per-stream cooperative high-water mark was reached. Resume production after
on_drain.

## Trailers

Uniform trailers are sent as real HTTP/2 trailing HEADERS.

    my $request = Uniform::HTTP::Request->new(
        method    => 'POST',
        target    => '/upload',
        scheme    => 'https',
        authority => 'example.com',
        body      => $bytes,
        trailers  => [
            [ 'Content-Digest', $digest ],
        ],
    );

For a streaming local body, add any final trailer fields to the Uniform message
before calling stream end(). Unblock snapshots them when body production ends.

Incoming trailers are added to the received Uniform Request or Response before
on_request_end or on_complete runs.

## Extended CONNECT

Extended CONNECT uses Uniform's neutral protocol metadata:

    my $request = Uniform::HTTP::Request->new(
        method    => 'CONNECT',
        protocol  => 'websocket',
        scheme    => 'https',
        authority => 'example.com',
        target    => '/chat',
    );

The same API can carry connect-udp or future Extended CONNECT protocol tokens.
Unblock maps the value to :protocol. It does not implement WebSocket,
CONNECT-UDP, or WebTransport semantics itself.

Servers advertise SETTINGS_ENABLE_CONNECT_PROTOCOL by default. Set:

    enable_connect_protocol => 0

on Server->new if the host does not want to advertise generic Extended CONNECT
support.

Ordinary CONNECT is also represented directly with an authority-form target.

## Server

    use Uniform::HTTP::Response;
    use Unblock::HTTP2::Server;

    my $server = Unblock::HTTP2::Server->new(
        on_request => sub {
            my ($stream, $request) = @_;

            my $response = Uniform::HTTP::Response->new(
                status => 200,
                body   => "hello\n",
            );

            $stream->respond($response);
        },
    );

Incoming request bodies are delivered incrementally with on_body and
on_request_end callbacks.

A server can send one or more informational responses before the final
response:

    $stream->inform(
        Uniform::HTTP::Response->new(
            status => 103,
            headers => [
                [ 'Link', '</style.css>; rel=preload' ],
            ],
        ),
    );

The final response still uses respond().

For a streaming response:

    $stream->respond(
        $response,
        stream_body => 1,
        on_drain => sub {
            my ($stream) = @_;
            produce_more($stream);
        },
    );

    $stream->write($chunk);
    $stream->end;

## Stream resets and error codes

`cancel()` remains the simple way to cancel a stream. It sends the standard
`CANCEL` RST_STREAM code.

For explicit protocol reasons, use:

    $stream->reset(Unblock::HTTP2::REFUSED_STREAM());

Known HTTP/2 error codes are public package constants on Unblock::HTTP2,
including `NO_ERROR`, `PROTOCOL_ERROR`, `FLOW_CONTROL_ERROR`,
`REFUSED_STREAM`, and `CANCEL`.

When a stream is reset, the Stream preserves:

    $stream->error_code
    $stream->error_name
    $stream->reset_by_peer

`reset_by_peer` distinguishes a received RST_STREAM from one initiated by the
local application. Error callbacks also receive the numeric HTTP/2 error code
as an additional argument when one exists. This lets higher layers implement
retry policy without Unblock deciding which requests should be retried.

## Receive-side flow control

Incoming body bytes are automatically credited back to the peer after the body
callback returns. This keeps simple consumers simple.

A slow consumer can take explicit control for one stream:

    $stream->auto_consume(0);

    on_body => sub {
        my ($stream, $message, $bytes) = @_;
        queue_for_later($bytes);
    };

When the application has actually consumed queued bytes, release exactly that
credit:

    $stream->consume($bytes_consumed);

`unconsumed_bytes()` reports delivered body bytes that have not yet been
released. Re-enable automatic consumption with `auto_consume(1)`; any
outstanding stream credit is released immediately.

Unblock keeps connection-level receive credit moving independently, so one slow
stream can exhaust its own receive window without unnecessarily stalling other
streams on the same HTTP/2 connection. No timer or transport policy is involved.

## SETTINGS

Both Client and Server expose HTTP/2 SETTINGS without exposing the private
nghttp2 session.

Initial settings can be supplied at construction:

    my $server = Unblock::HTTP2::Server->new(
        settings => {
            initial_window_size => 262_144,
            max_frame_size      => 32_768,
        },

        on_settings => sub {
            my ($engine, $peer, $changed) = @_;
            # $peer is the current effective peer SETTINGS snapshot.
            # $changed contains values from this SETTINGS frame.
        },

        on_settings_ack => sub {
            my ($engine, $acked) = @_;
            # $acked contains the values from our acknowledged SETTINGS frame.
        },
    );

The public setting names are:

    header_table_size
    enable_push
    max_concurrent_streams
    initial_window_size
    max_frame_size
    max_header_list_size
    enable_connect_protocol
    no_rfc7540_priorities

Read the values currently advertised by this endpoint with local_settings() or
local_setting($name). Read the peer's effective values with peer_settings() or
peer_setting($name). Returned hashes are copies.

A connection can send later SETTINGS at any time:

    $engine->update_settings(
        initial_window_size => 131_072,
    );

settings_pending() reports how many locally submitted SETTINGS frames are still
waiting for ACK. Unblock validates the HTTP/2 value ranges and keeps the
SETTINGS_ENABLE_CONNECT_PROTOCOL transition one-way: once 1 has been sent it
cannot later be reset to 0.

SETTINGS_ENABLE_PUSH is a client-to-server setting. The client keeps it at 0
because server push is not part of the public Unblock API, and the server API
rejects any attempt to send ENABLE_PUSH, including value 0.

## Modern prioritization

Unblock::HTTP2 uses the RFC 9218 extensible priority scheme rather than the
deprecated RFC 7540 dependency tree.

Client and Server advertise:

    no_rfc7540_priorities => 1

in their first SETTINGS frame by default. A caller can override that initial
value with the normal settings constructor option.

The HTTP Priority header remains an ordinary Uniform::HTTP header and can be
placed on a Request without an HTTP/2-specific object:

    headers => [
        [ 'Priority', 'u=1, i' ],
    ]

After a request has been sent, a client can change its preference with the
HTTP/2-specific PRIORITY_UPDATE frame:

    $stream->update_priority('u=0, i');

The server can observe hop-by-hop updates with:

    on_priority => sub {
        my ($server, $stream_id, $field_value) = @_;
    }

Unblock preserves the complete Priority field value instead of limiting the API
to today's urgency and incremental parameters. nghttp2 owns parsing and
scheduling. If the peer did not advertise RFC 9218 priority support,
update_priority() is refused.

## PING

Both endpoints can send an HTTP/2 PING with exactly eight opaque bytes:

    $engine->ping("12345678");

Incoming PING and PING ACK frames can be observed independently:

    my $client = Unblock::HTTP2::Client->new(
        on_ping => sub {
            my ($engine, $opaque) = @_;
        },

        on_ping_ack => sub {
            my ($engine, $opaque) = @_;
        },
    );

libnghttp2 automatically generates the required ACK for a received PING, and
Unblock preserves the eight opaque bytes exactly. PING is connection-level; it
is not associated with a Stream.

Unblock does not implement keepalive intervals, deadlines, liveness policy, or
round-trip timers. Those decisions belong to the caller or higher connection
policy.

## Fatal engine failures

If libnghttp2 reports a fatal receive or send failure, `input()` or `output()`
still throws so the transport integration cannot miss the failure. The engine
also closes itself before rethrowing and records the reason:

    $engine->is_closed
    $engine->close_reason

This prevents a caught backend exception from leaving an HTTP/2 session that
appears reusable. Explicit `close($reason)` uses the same retained
`close_reason` state.

## Invalid frames and extension safety

nghttp2 performs HTTP/2 frame and state validation. When it receives an invalid
non-DATA frame, it automatically queues the protocol-required RST_STREAM or
GOAWAY response.

Both Client and Server can observe that event without taking over protocol
handling:

    on_invalid_frame => sub {
        my ($engine, $frame, $lib_error_code) = @_;
    }

The frame value is a plain hash containing protocol facts such as type, flags,
stream_id, and length. The library error code is the numeric nghttp2 validation
code; it is deliberately not translated into an HTTP/2 wire error code.

Unknown extension frame types remain valid HTTP/2 extensibility points and are
ignored rather than reported as invalid.

nghttp2's separate error logging callback is not public protocol state and is
not routed through application on_error callbacks.

## Graceful draining

Both client and server engines can begin a graceful HTTP/2 shutdown with:

    $engine->drain;

This queues a NO_ERROR GOAWAY and marks the connection as draining. A client
will not open new request streams after local drain or after receiving peer
GOAWAY. Streams that were already accepted can continue to completion.

For an explicit protocol shutdown reason, use:

    $engine->goaway(
        error_code => Unblock::HTTP2::ENHANCE_YOUR_CALM(),
        debug_data => $bytes,
    );

Server GOAWAY defaults to the highest peer request stream already observed.
Client GOAWAY defaults to stream zero because server push is disabled.
`last_stream_id` can be supplied explicitly when an application needs a
narrower boundary. A later GOAWAY may keep or lower that boundary but cannot
increase it.

`local_goaway()` returns a copy of the most recently submitted boundary,
error code, and debug bytes.

After receiving GOAWAY, peer_goaway() returns the peer's last stream ID, HTTP/2
error code, and debug data. Unblock exposes those facts but does not decide
whether a higher layer should retry a request.

The client advertises ENABLE_PUSH = 0 because server push is not currently part
of the Unblock public API.

## What Unblock::HTTP2 owns

- HTTP/2 client and server sessions
- multiplexed stream state
- HTTP/2 header, trailer, and pseudo-header mapping
- ordinary and Extended CONNECT mapping
- SETTINGS
- GOAWAY drain state
- RST_STREAM cancellation
- HTTP/2 flow control through nghttp2
- per-stream cooperative body buffering
- decoded header-list limits

## What it does not own

- sockets
- DNS
- TLS
- ALPN
- event loops
- threads or processes
- connection pools
- redirects
- cookies
- authentication policy
- proxy policy
- HTTP/1 fallback
- WebSocket, CONNECT-UDP, or WebTransport tunnel semantics

Those belong to the caller or to a higher HTTP client/server layer.

## Dependencies

Unblock::HTTP2 uses Uniform::HTTP 0.04 or newer for HTTP messages and
Alien::nghttp2 to provide libnghttp2.

The distribution contains a small private XS binding to libnghttp2. That
binding is an implementation detail, not a public API.

The intended Perl compatibility floor is Perl 5.16.

## Status

The core HTTP/2 protocol engine is feature-complete for the 0.01 release line.
The test suite includes complete client/server exchanges entirely in memory,
including streaming bodies, multiplexing, cancellation isolation, header-list
limits, trailers, informational responses, peer SETTINGS enforcement, GOAWAY,
receive flow control, PING, RFC 9218 priority updates, reset codes, and Extended
CONNECT.

The CI release gate also runs the suite from the generated distribution tree.
A separate interoperability workflow exercises an Unblock client against the
stock nghttpd server and the Unblock server against the stock nghttp client.

No socket, TLS implementation, or event loop is required by the packaged
protocol engine; the TCP adapters used for interoperability live only under
xt/ and are excluded from the CPAN distribution.

## License

MIT License.
