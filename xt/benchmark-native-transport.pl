use strict;
use warnings;

use Time::HiRes qw(time);
use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP2::Client;
use Unblock::HTTP2::Server;
use Unblock::HTTP2::_nghttp2;

my $mode = $ENV{BENCH_MODE} || 'portable';
my $iterations = $ENV{BENCH_ITERATIONS} || 8_000;
my $warmup = $ENV{BENCH_WARMUP} || 750;

die "BENCH_MODE must be portable or native\n"
    unless $mode eq 'portable' || $mode eq 'native';

my $response = Uniform::HTTP::Response->new(
    status => 204,
    headers => [
        [ 'x-benchmark', 'native-transport' ],
    ],
);

my $completed = 0;
my $server = Unblock::HTTP2::Server->new(
    on_request_end => sub {
        my ($transaction) = @_;
        $transaction->respond($response);
    },
    on_error => sub {
        my ($transaction, $error) = @_;
        die "server benchmark error: $error";
    },
);

my $client = Unblock::HTTP2::Client->new(
    max_active_transactions => 128,
);

my ($client_driver, $server_driver);
if ($mode eq 'native') {
    $client_driver =
        Unblock::HTTP2::_nghttp2::NativeDriver->new($client);
    $server_driver =
        Unblock::HTTP2::_nghttp2::NativeDriver->new($server);
}

sub portable_transfer {
    my ($from, $to) = @_;
    my $moved = 0;

    while ($from->want_write) {
        my $bytes = $from->output;
        last unless length $bytes;
        my $consumed = $to->input($bytes);
        die 'portable transport did not consume complete output'
            unless $consumed == length($bytes);
        $moved += $consumed;
    }

    return $moved;
}

sub native_transfer {
    my ($from, $to) = @_;
    my $moved = 0;

    while ($from->want_write) {
        my ($output_status, $input_status, $bytes) =
            $from->transfer_to($to);
        die "native source closed during benchmark"
            if $output_status;
        die "native destination closed during benchmark"
            if $input_status;
        last unless $bytes;
        $moved += $bytes;
    }

    return $moved;
}

sub pump_idle {
    my $turns = 0;

    for (;;) {
        my $moved;
        if ($mode eq 'native') {
            $moved = native_transfer($client_driver, $server_driver);
            $moved += native_transfer($server_driver, $client_driver);
        }
        else {
            $moved = portable_transfer($client, $server);
            $moved += portable_transfer($server, $client);
        }

        last unless $moved;
        die 'benchmark pump did not become idle'
            if ++$turns > 100_000;
    }
}

sub exchange_count {
    my ($count) = @_;
    my $start_completed = $completed;
    my $target = $start_completed + $count;
    my $submitted = 0;

    my $on_complete = sub {
        $completed++;
    };
    my $on_error = sub {
        my ($transaction, $error) = @_;
        die "client benchmark error: $error";
    };

    while ($completed < $target) {
        while ($submitted < $count
            && ($submitted - ($completed - $start_completed)) < 96
            && $client->can_open_transaction) {
            $client->request(
                Uniform::HTTP::Request->new(
                    method    => 'GET',
                    target    => '/native-transport',
                    scheme    => 'https',
                    authority => 'benchmark.example',
                ),
                on_complete => $on_complete,
                on_error    => $on_error,
            );
            $submitted++;
        }

        my $moved;
        if ($mode eq 'native') {
            $moved = native_transfer($client_driver, $server_driver);
            $moved += native_transfer($server_driver, $client_driver);
        }
        else {
            $moved = portable_transfer($client, $server);
            $moved += portable_transfer($server, $client);
        }

        die 'benchmark exchange stalled'
            unless $moved || $completed >= $target;
    }

    pump_idle();
}

pump_idle();
exchange_count($warmup);

my $start = time;
exchange_count($iterations);
my $seconds = time - $start;
my $rate = $iterations / $seconds;

printf "RESULT mode=%s iterations=%d seconds=%.6f rate=%.3f\n",
    $mode, $iterations, $seconds, $rate;
