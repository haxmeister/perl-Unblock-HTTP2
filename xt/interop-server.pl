use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;

use Uniform::HTTP::Response;
use Unblock::HTTP2::Server;

my $host = $ENV{UNBLOCK_HTTP2_SERVER_HOST} || '127.0.0.1';
my $port = $ENV{UNBLOCK_HTTP2_SERVER_PORT} || 18081;
my $ready_file = $ENV{UNBLOCK_HTTP2_READY_FILE};

my $listener = IO::Socket::INET->new(
    LocalAddr => $host,
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or die "listen on $host:$port failed: $!\n";

if (defined $ready_file && length $ready_file) {
    open my $ready, '>', $ready_file
        or die "open ready file $ready_file failed: $!\n";
    print {$ready} "$host:$port\n";
    close $ready;
}

local $SIG{ALRM} = sub { die "interop server timed out\n" };
alarm 15;

my $socket = $listener->accept
    or die "accept failed: $!\n";
$socket->autoflush(1);

my $served = 0;
my @errors;

my $server = Unblock::HTTP2::Server->new(
    on_request_end => sub {
        my ($stream, $request) = @_;

        my $response = Uniform::HTTP::Response->new(
            status => 200,
            headers => [
                [ 'content-type', 'text/plain' ],
                [ 'x-unblock-interop', 'nghttp' ],
            ],
            body => "unblock-server-ok\n",
        );

        $stream->respond($response);
        $served = 1;
    },

    on_error => sub {
        my ($stream, $error) = @_;
        push @errors, $error;
    },
);

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
        die "socket write failed: $!\n" unless defined $written;
        die "socket write returned zero\n" unless $written;
        $offset += $written;
    }

    return;
}

my $select = IO::Select->new($socket);

while (1) {
    while ($server->want_write) {
        my $bytes = $server->output;
        last unless length $bytes;
        write_all($socket, $bytes);
    }

    last if $served && !$server->want_write;

    my @ready = $select->can_read(1);
    next unless @ready;

    my $bytes = '';
    my $read = sysread($socket, $bytes, 65_536);
    die "socket read failed: $!\n" unless defined $read;
    last unless $read;

    $server->input($bytes);
}

die "server did not complete a request\n" unless $served;
die "server stream error: $errors[0]\n" if @errors;

close $socket;
close $listener;
alarm 0;

exit 0;
