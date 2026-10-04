use strict;
use warnings;
use Test::More;

use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP2::_Headers;

my $request = Unblock::HTTP2::_Headers->request_from_headers(
    [
        [ ':method',    'POST' ],
        [ ':scheme',    'https' ],
        [ ':authority', 'example.test' ],
        [ ':path',      '/items' ],
        [ 'x-test',     'one' ],
        [ 'x-test',     'two' ],
    ],
    end_stream => 0,
);

isa_ok $request, 'Uniform::HTTP::Request';
is $request->method, 'POST', 'method maps from :method';
is $request->target, '/items', 'target maps from :path';
is $request->scheme, 'https', 'scheme maps from :scheme';
is $request->authority, 'example.test', 'authority maps from :authority';
is $request->version, '2', 'request reports HTTP version 2';
ok !$request->is_mutable, 'received request metadata is committed';
ok !$request->is_complete, 'open request body is incomplete';
is_deeply $request->header_values('x-test'), [ 'one', 'two' ],
    'normal duplicate fields remain lossless';

$request->mark_complete;
ok $request->is_complete, 'message completeness can advance after commit';

my $outgoing = Uniform::HTTP::Request->new(
    method    => 'GET',
    target    => '/',
    scheme    => 'https',
    authority => 'example.test',
    version   => '2',
    headers   => [
        [ 'X-Test', 'one' ],
        [ 'x-test', 'two' ],
    ],
);

is_deeply(
    Unblock::HTTP2::_Headers->request_headers($outgoing),
    [
        [ ':method',    'GET' ],
        [ ':scheme',    'https' ],
        [ ':authority', 'example.test' ],
        [ ':path',      '/' ],
        [ 'x-test',     'one' ],
        [ 'x-test',     'two' ],
    ],
    'outgoing fields are mapped and normalized for HTTP/2',
);

my $response = Unblock::HTTP2::_Headers->response_from_headers(
    [
        [ ':status',      '204' ],
        [ 'content-type', 'text/plain' ],
    ],
    end_stream => 1,
);

isa_ok $response, 'Uniform::HTTP::Response';
is $response->status, 204, 'status maps from :status';
is $response->reason, undef, 'HTTP/2 does not synthesize a reason phrase';
ok $response->is_complete, 'END_STREAM response is complete';
ok !$response->is_mutable, 'received response metadata is committed';

my $ok = eval {
    Unblock::HTTP2::_Headers->request_from_headers(
        [
            [ ':method',    'GET' ],
            [ ':scheme',    'https' ],
            [ ':authority', 'example.test' ],
            [ ':path',      '/' ],
            [ 'Connection', 'close' ],
        ],
        end_stream => 1,
    );
    1;
};
ok !$ok, 'uppercase HTTP/2 field names are rejected';
like $@, qr/field names must be lowercase/,
    'uppercase field rejection is explicit';

$ok = eval {
    Unblock::HTTP2::_Headers->request_from_headers(
        [
            [ ':method',    'GET' ],
            [ ':scheme',    'https' ],
            [ ':authority', 'example.test' ],
            [ ':path',      '/' ],
            [ 'connection', 'close' ],
        ],
        end_stream => 1,
    );
    1;
};
ok !$ok, 'connection-specific fields are rejected';
like $@, qr/forbids connection-specific field/,
    'connection-specific rejection is explicit';

done_testing;
