use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Test::UnblockHTTP2 qw(pump_until);
use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP2::Client;
use Unblock::HTTP2::Server;
use Unblock::HTTP2::Transaction;
use Unblock::HTTP2::Stream;

my $server_transaction;

my $server = Unblock::HTTP2::Server->new(
    on_request => sub {
        my ($transaction, $request) = @_;
        $server_transaction = $transaction;

        $transaction->respond(
            Uniform::HTTP::Response->new(
                status => 200,
                body   => 'ok',
            ),
        );
    },
);

my $client = Unblock::HTTP2::Client->new;

ok $client->can_open_transaction,
    'client exposes transaction-oriented capacity API';
is $client->can_open_stream, $client->can_open_transaction,
    'old can_open_stream remains a compatibility alias';

my $transaction = $client->request(
    Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => '/transaction',
        scheme    => 'https',
        authority => 'example.test',
    ),
);

isa_ok $transaction, 'Unblock::HTTP2::Transaction';
is $transaction->stream_id, 1,
    'transaction exposes its HTTP/2 stream id';
is $transaction->id, $transaction->stream_id,
    'old id accessor remains a compatibility alias';

is $client->transaction_count, 1,
    'connection exposes active transaction count';
is $client->stream_count, $client->transaction_count,
    'old stream_count remains a compatibility alias';
is $client->transaction_for_stream_id($transaction->stream_id), $transaction,
    'transaction can be looked up by protocol stream id';
is $client->stream_for_id($transaction->stream_id), $transaction,
    'old stream_for_id remains a compatibility alias';

pump_until(
    $client,
    $server,
    sub { $transaction->is_complete && $server_transaction },
);

isa_ok $server_transaction, 'Unblock::HTTP2::Transaction';
is $server_transaction->stream_id, $transaction->stream_id,
    'client and server transactions refer to the same HTTP/2 stream';

done_testing;
