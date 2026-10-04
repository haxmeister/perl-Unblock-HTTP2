# Unblock::HTTP2

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

## Graceful draining

Both client and server engines can begin a graceful HTTP/2 shutdown with:

    $engine->drain;

This queues GOAWAY and marks the connection as draining. A client will not open
new request streams after local drain or after receiving peer GOAWAY. Streams
that were already accepted can continue to completion.

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

## Development status

The distribution is under active development and has not been released.

The development suite includes complete HTTP/2 client/server exchanges entirely
in memory, including streaming bodies, multiplexing, cancellation isolation,
header-list limits, trailers, informational responses, peer SETTINGS
enforcement, GOAWAY details, and Extended CONNECT. No socket, TLS
implementation, or event loop is involved in those tests.

## License

MIT License.
