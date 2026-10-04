use strict;
use warnings;
use Test::More;
use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);

use Uniform::HTTP::Request;
use Unblock::HTTP2::Client;

plan skip_all => 'set UNBLOCK_HTTP2_INTEROP=1 to run nghttpd interoperability'
    unless $ENV{UNBLOCK_HTTP2_INTEROP};

my $host = $ENV{UNBLOCK_HTTP2_NGHTTPD_HOST} || '127.0.0.1';
my $port = $ENV{UNBLOCK_HTTP2_NGHTTPD_PORT} || 18080;

my $socket;
for (1 .. 50) {
    $socket = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
    );
    last if $socket;
    sleep 0.1;
}

BAIL_OUT("cannot connect to nghttpd at $host:$port") unless $socket;
$socket->autoflush(1);

my $client = Unblock::HTTP2::Client->new;
my %seen;
my @errors;
my $complete = 0;

for my $spec (
    [ '/one.txt', "nghttpd-one\n" ],
    [ '/two.txt', "nghttpd-two\n" ],
) {
    my ($target, $expected) = @$spec;

    my $request = Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => $target,
        scheme    => 'http',
        authority => "$host:$port",
    );

    $client->request(
        $request,

        on_response => sub {
            my ($stream, $response) = @_;
            $seen{$target}{status} = $response->status;
        },

        on_body => sub {
            my ($stream, $response, $bytes) = @_;
            $seen{$target}{body} .= $bytes;
        },

        on_complete => sub {
            $seen{$target}{complete} = 1;
            ++$complete;
        },

        on_error => sub {
            my ($stream, $error) = @_;
            push @errors, "$target: $error";
        },
    );

    $seen{$target}{expected} = $expected;
}

sub write_all {
    my ($fh, $bytes) = @_;
    my $offset = 0;

    while ($offset < length($bytes)) {
        my $written = syswrite(
            $fh,
            $bytes,
            length($bytes) - $offset,
            $offset,
        );
        die "socket write failed: $!" unless defined $written;
        die "socket write returned zero" unless $written;
        $offset += $written;
    }

    return;
}

my $select = IO::Select->new($socket);
my $deadline = time + 10;

while ($complete < 2 && time < $deadline) {
    while ($client->want_write) {
        my $bytes = $client->output;
        last unless length $bytes;
        write_all($socket, $bytes);
    }

    my @ready = $select->can_read(0.1);
    next unless @ready;

    my $bytes = '';
    my $read = sysread($socket, $bytes, 65_536);
    die "socket read failed: $!" unless defined $read;
    last unless $read;

    $client->input($bytes);
}

is scalar(@errors), 0, 'nghttpd exchange reports no stream errors';

for my $target (qw(/one.txt /two.txt)) {
    is $seen{$target}{status}, 200,
        "$target receives HTTP 200 from nghttpd";
    is $seen{$target}{body}, $seen{$target}{expected},
        "$target body matches nghttpd static resource";
    ok $seen{$target}{complete},
        "$target stream completes";
}

is $complete, 2,
    'two multiplexed requests complete over one nghttpd connection';

close $socket;

done_testing;
