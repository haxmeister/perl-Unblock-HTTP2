use strict;
use warnings;

use Time::HiRes qw(time);

use Uniform::HTTP::FastPath ();
use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::HTTP2::_Headers;
use Unblock::HTTP2::_nghttp2;
use Unblock::HTTP2::Client;
use Unblock::HTTP2::Server;

my $label = $ENV{BENCH_LABEL} || 'unknown';
my $expected_path = $ENV{BENCH_EXPECT_PATH} || '';
my $submit_iterations = $ENV{BENCH_SUBMIT_ITERATIONS} || 20_000;
my $loopback_iterations = $ENV{BENCH_LOOPBACK_ITERATIONS} || 8_000;
my $warmup_iterations = $ENV{BENCH_WARMUP_ITERATIONS} || 750;

my $request = Uniform::HTTP::Request->new(
    method    => 'GET',
    target    => '/benchmark?value=123',
    scheme    => 'https',
    authority => 'benchmark.example',
    headers   => [
        [ 'User-Agent',      'Unblock-HTTP2-benchmark' ],
        [ 'Accept',          'application/json' ],
        [ 'X-Benchmark-One', 'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Benchmark-Two', 'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Benchmark-3',   'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Benchmark-4',   'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Benchmark-5',   'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Benchmark-6',   'abcdefghijklmnopqrstuvwxyz012345' ],
    ],
);

sub submit_batch {
    my ($iterations) = @_;

    my $session = Unblock::HTTP2::_nghttp2::Session->new_client;
    $session->send_connection_preface;
    $session->mem_send;

    my $native_fast = $session->can('_submit_request_uniform_xs') ? 1 : 0;

    if ($expected_path eq 'fastpath' && !$native_fast) {
        die "expected FastPath implementation but portable module was loaded from "
            . ($INC{'Unblock/HTTP2/_nghttp2.pm'} || 'unknown path');
    }
    if ($expected_path eq 'portable' && $native_fast) {
        die "expected portable baseline but FastPath module was loaded from "
            . ($INC{'Unblock/HTTP2/_nghttp2.pm'} || 'unknown path');
    }

    for my $index (1 .. $iterations) {
        if ($native_fast) {
            my $view = Uniform::HTTP::FastPath::view($request);
            $session->_submit_request_uniform_xs($view, undef);
        }
        else {
            my $block = Unblock::HTTP2::_Headers->request_headers($request);
            $session->_submit_request_xs($block, undef);
        }

        $session->mem_send if ($index & 127) == 0;
    }

    $session->mem_send;
    return $native_fast;
}

submit_batch($warmup_iterations);
my $submit_start = time;
my $native_fast = submit_batch($submit_iterations);
my $submit_seconds = time - $submit_start;
my $submit_rate = $submit_iterations / $submit_seconds;

my $response = Uniform::HTTP::Response->new(
    status => 204,
    headers => [
        [ 'Content-Type',     'application/json' ],
        [ 'Cache-Control',    'no-store' ],
        [ 'X-Response-One',   'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Response-Two',   'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Response-3',     'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Response-4',     'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Response-5',     'abcdefghijklmnopqrstuvwxyz012345' ],
        [ 'X-Response-6',     'abcdefghijklmnopqrstuvwxyz012345' ],
    ],
);

my $completed = 0;
my $server = Unblock::HTTP2::Server->new(
    on_request_end => sub {
        my ($stream) = @_;
        $stream->respond($response);
    },
    on_error => sub {
        my ($stream, $error) = @_;
        die "server benchmark error: $error";
    },
);

my $client = Unblock::HTTP2::Client->new(
    max_active_streams => 128,
);

sub transfer {
    my ($from, $to) = @_;
    my $moved = 0;

    while ($from->want_write) {
        my $bytes = $from->output;
        last unless length $bytes;
        $to->input($bytes);
        $moved += length $bytes;
    }

    return $moved;
}

sub pump_idle {
    my $turns = 0;

    for (;;) {
        my $moved = transfer($client, $server);
        $moved += transfer($server, $client);
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
        my ($stream, $error) = @_;
        die "client benchmark error: $error";
    };

    while ($completed < $target) {
        while ($submitted < $count
            && ($submitted - ($completed - $start_completed)) < 96
            && $client->can_open_stream) {
            $client->request(
                $request,
                on_complete => $on_complete,
                on_error    => $on_error,
            );
            $submitted++;
        }

        my $moved = transfer($client, $server);
        $moved += transfer($server, $client);

        die 'benchmark exchange stalled'
            unless $moved || $completed >= $target;
    }

    pump_idle();
}

pump_idle();
exchange_count($warmup_iterations);

my $loopback_start = time;
exchange_count($loopback_iterations);
my $loopback_seconds = time - $loopback_start;
my $loopback_rate = $loopback_iterations / $loopback_seconds;

printf "INFO label=%s module=%s\n",
    $label,
    $INC{'Unblock/HTTP2/_nghttp2.pm'} || 'unknown';

printf "RESULT label=%s path=%s mode=submit iterations=%d seconds=%.6f rate=%.3f\n",
    $label,
    $native_fast ? 'fastpath' : 'portable',
    $submit_iterations,
    $submit_seconds,
    $submit_rate;

printf "RESULT label=%s path=%s mode=loopback iterations=%d seconds=%.6f rate=%.3f\n",
    $label,
    $native_fast ? 'fastpath' : 'portable',
    $loopback_iterations,
    $loopback_seconds,
    $loopback_rate;
