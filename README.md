# Unblock::HTTP2

[![CPAN version](https://badge.fury.io/pl/Unblock-HTTP2.svg)](https://metacpan.org/dist/Unblock-HTTP2)
[![CPANTS Kwalitee](https://cpants.cpanauthors.org/dist/Unblock-HTTP2.svg)](https://cpants.cpanauthors.org/dist/Unblock-HTTP2)
[![CI](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/test.yml)
[![Interop](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/interop.yml/badge.svg?branch=main)](https://github.com/haxmeister/perl-Unblock-HTTP2/actions/workflows/interop.yml)
[![License](https://img.shields.io/cpan/l/Unblock-HTTP2.svg)](https://github.com/haxmeister/perl-Unblock-HTTP2/blob/main/LICENSE)
[![Perl](https://img.shields.io/badge/perl-5.16%2B-blue.svg)](https://www.perl.org/)
[![HTTP/2](https://img.shields.io/badge/HTTP%2F2-RFC%209113-blue.svg)](https://www.rfc-editor.org/rfc/rfc9113)

Unblock::HTTP2 is a non-blocking HTTP/2 protocol engine for Perl.

It handles HTTP/2 framing, HPACK, streams, SETTINGS, flow control, PING,
GOAWAY, trailers, CONNECT, and modern priority signaling.

It does not open sockets, perform TLS, select ALPN, or run an event loop.

```text
application or HTTP library
        |
  Uniform::HTTP messages
        |
   Unblock::HTTP2
        |
   byte transport
```

The transport can be Linux::Event, IO::Async, AnyEvent, Mojolicious, a blocking
socket, an in-memory test connection, or something else.

## Installation

From CPAN:

```text
cpanm Unblock::HTTP2
```

Unblock::HTTP2 0.02 requires Perl 5.16 or newer.

The distribution uses:

```text
Uniform::HTTP  0.05+
Alien::nghttp2 0.003+
```

Alien::nghttp2 supplies libnghttp2 and the build flags needed by the private XS
binding.

## Start here

The public API is built around three objects:

- `Unblock::HTTP2::Client` - one client HTTP/2 connection
- `Unblock::HTTP2::Server` - one server HTTP/2 connection
- `Unblock::HTTP2::Stream` - one multiplexed request/response stream

HTTP messages are normal `Uniform::HTTP::Request` and
`Uniform::HTTP::Response` objects.

Canonical Uniform::HTTP 0.05 messages use its native FastPath ABI. Uniform
subclasses and framework adapters continue to use the portable message API.

The basic transport contract is byte-in, byte-out:

```perl
$engine->input($bytes_from_transport);

while ($engine->want_write) {
    my $bytes = $engine->output;
    last unless length $bytes;
    $transport->write($bytes);
}
```

Unblock::HTTP2 never waits for network activity itself.

## Client

```perl
use Uniform::HTTP::Request;
use Unblock::HTTP2::Client;

my $client = Unblock::HTTP2::Client->new;

my $stream = $client->request(
    Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => '/',
        scheme    => 'https',
        authority => 'example.com',
    ),

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
        print "done\n";
    },
);
```

Many streams can be active on one Client at the same time.

## Server

```perl
use Uniform::HTTP::Response;
use Unblock::HTTP2::Server;

my $server = Unblock::HTTP2::Server->new(
    on_request => sub {
        my ($stream, $request) = @_;

        $stream->respond(
            Uniform::HTTP::Response->new(
                status => 200,
                body   => "hello\n",
            ),
        );
    },
);
```

Request body chunks arrive through `on_body`.
`on_request_end` runs when the complete request, including trailers, has
arrived.

## Streaming bodies

Buffered bodies can live directly on the Uniform message object.

For a streaming local body:

```perl
my $stream = $client->request(
    $request,
    stream_body => 1,
    on_drain => sub {
        my ($stream) = @_;
        produce_more($stream);
    },
);

$stream->write($chunk);
$stream->end($last_chunk);
```

The same `write()` and `end()` API is used for a streaming server response.

`write()` always accepts the bytes. A false return means the stream reached
its cooperative high-water mark. Pause production until `on_drain` runs.

Incoming body bytes are automatically credited back to the peer after the body
callback returns. A slow consumer can take manual flow-control ownership with:

```perl
$stream->auto_consume(0);
$stream->consume($bytes_processed);
```

## Trailers and informational responses

Request and response trailers are supported through the Uniform trailer fields.
Unblock sends them as HTTP/2 trailing HEADERS.

A server can send an informational response before the final response:

```perl
$stream->inform(
    Uniform::HTTP::Response->new(
        status => 103,
    ),
);

$stream->respond($final_response);
```

## CONNECT

Ordinary CONNECT and generic Extended CONNECT are supported.

An Extended CONNECT request uses the Uniform `protocol` field:

```perl
my $request = Uniform::HTTP::Request->new(
    method    => 'CONNECT',
    protocol  => 'websocket',
    scheme    => 'https',
    authority => 'example.com',
    target    => '/chat',
);
```

Unblock maps this to HTTP/2 `:protocol`. It does not implement the tunneled
protocol itself.

## Connection controls

The engine exposes HTTP/2 protocol controls without exposing the private
libnghttp2 session.

Examples:

```perl
$engine->ping("12345678");

$engine->update_settings(
    initial_window_size => 131_072,
);

$engine->drain;

$engine->goaway(
    error_code => Unblock::HTTP2::NO_ERROR(),
);
```

Received GOAWAY details are available through `peer_goaway()`.

A Stream can be cancelled or reset explicitly:

```perl
$stream->cancel;

$stream->reset(
    Unblock::HTTP2::REFUSED_STREAM(),
);
```

Reset error codes and whether the reset came from the peer are preserved on the
Stream.

RFC 9218 extensible priorities are supported. The old RFC 7540 dependency-tree
priority model is intentionally not part of the public API.

## What Unblock::HTTP2 owns

Unblock::HTTP2 owns:

- HTTP/2 client and server session state
- framing and HPACK through libnghttp2
- multiplexed streams
- request and response mapping
- trailers and informational responses
- SETTINGS, PING, GOAWAY, and RST_STREAM
- connection and stream flow control
- streaming body backpressure
- ordinary and Extended CONNECT
- RFC 9218 priority updates

## What it does not own

Unblock::HTTP2 does not own:

- sockets
- DNS
- TLS
- ALPN
- event loops
- connection pools
- redirects
- cookies
- authentication policy
- proxy policy
- retry policy
- HTTP/1 upgrade negotiation
- WebSocket, CONNECT-UDP, or other tunnel semantics

Those responsibilities belong to the transport, application, or a higher HTTP
client/server layer.

Server Push is intentionally not exposed. Clients advertise
`SETTINGS_ENABLE_PUSH = 0`.

## Testing

The normal suite runs complete client/server exchanges in memory.

CI covers:

- Perl 5.16 on Linux
- current Perl on Linux
- current Perl on macOS
- Strawberry Perl on Windows
- `distcheck` and `disttest` against the generated distribution

A separate interoperability workflow tests both directions against the stock
nghttp2 tools:

- Unblock client -> nghttpd server
- nghttp client -> Unblock server

The interoperability and performance harnesses live under `xt/` and are not
included in the CPAN distribution.

## More documentation

- `Unblock::HTTP2::Client` - client connection API
- `Unblock::HTTP2::Server` - server connection API
- `Unblock::HTTP2::Stream` - per-stream API
- `docs/ARCHITECTURE.md` - ownership and data flow
- `docs/FEATURE-COMPLETENESS.md` - release scope and deliberate exclusions
- `docs/BACKEND-REQUIREMENTS.md` - private libnghttp2 binding contract

## Status

Unblock::HTTP2 0.02 is feature-complete for its intended role as a reusable,
event-loop-neutral HTTP/2 engine.

Future work can focus on bug fixes, interoperability, performance, or optional
extensions without changing the transport boundary.

## License

MIT.
