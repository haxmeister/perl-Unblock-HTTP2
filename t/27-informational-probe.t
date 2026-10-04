use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Test::UnblockHTTP2 qw(pump_until);
use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP2::Client;
use Unblock::HTTP2::Server;

my @informational;
my $final;
my @errors;

my $server;
$server = Unblock::HTTP2::Server->new(
    on_request => sub {
        my ($stream, $request) = @_;

        # Backend capability probe: if nghttp2 treats a 1xx response as
        # non-final, Unblock can expose this without extending the binding.
        $server->{session}->submit_response(
            $stream->id,
            status  => 103,
            headers => [
                [ 'link', '</style.css>; rel=preload' ],
            ],
        );

        $stream->respond(
            Uniform::HTTP::Response->new(
                status => 200,
                body   => 'ok',
            ),
        );
    },

    on_error => sub {
        my ($stream, $error) = @_;
        push @errors, "server: $error";
    },
);

my $client = Unblock::HTTP2::Client->new;

my $stream = $client->request(
    Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => '/',
        scheme    => 'https',
        authority => 'example.test',
    ),

    on_informational => sub {
        my ($stream, $response) = @_;
        push @informational, $response;
    },

    on_response => sub {
        my ($stream, $response) = @_;
        $final = $response;
    },

    on_error => sub {
        my ($stream, $error) = @_;
        push @errors, "client: $error";
    },
);

pump_until($client, $server, sub { $stream->is_terminal });

is scalar(@informational), 1,
    'backend permits one non-final informational response';
is $informational[0]->status, 103,
    'informational response status is preserved';
is $informational[0]->header('link'), '</style.css>; rel=preload',
    'informational response fields are preserved';
is $final->status, 200,
    'final response follows informational response';
is_deeply \@errors, [],
    'informational response path reports no protocol errors';

done_testing;
