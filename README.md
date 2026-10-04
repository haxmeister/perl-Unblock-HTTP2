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
Mojolicious, blocking sockets, test transports, and other environments.

## Message objects

Unblock::HTTP2 uses the shared Uniform HTTP message model directly:

    Uniform::HTTP::Request
    Uniform::HTTP::Response

It does not define competing request and response classes.

A Request can carry HTTP/2 :scheme and :authority through neutral Uniform
request properties. Received message metadata is committed while body
completeness can continue to change during streaming.

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

## What Unblock::HTTP2 owns

- HTTP/2 client and server sessions
- multiplexed stream state
- HTTP/2 header and pseudo-header mapping
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

Those belong to the caller or to a higher HTTP client/server layer.

## Dependencies

Unblock::HTTP2 currently uses Uniform::HTTP 0.03 or newer for HTTP messages and
Net::HTTP2::nghttp2 0.011 or newer for libnghttp2 bindings.

The intended Perl compatibility floor is Perl 5.16.

## Development status

The distribution is under active development and has not been released.

The current development tests include a complete HTTP/2 client/server exchange
entirely in memory. No socket, TLS implementation, or event loop is involved in
that test.

## License

MIT License.
