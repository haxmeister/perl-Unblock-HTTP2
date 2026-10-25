use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;
use Unblock::HTTP2::Server;
use Uniform::HTTP::Response;

# Standalone prior-knowledge HTTP/2 endpoint. No framework adapter is involved.
my $port = $ENV{UNBLOCK_HTTP2_SERVER_PORT} || 18082;
my $response_mode = $ENV{UNBLOCK_HTTP2_RESPONSE_MODE} || 'request';
die "response mode must be headers or request\n"
    unless $response_mode =~ /\A(?:headers|request)\z/;
my $response_callback = $response_mode eq 'headers' ? 'on_request' : 'on_request_end';
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => $port,
    Proto => 'tcp', Listen => 128, ReuseAddr => 1,
) or die "listen on 127.0.0.1:$port: $!\n";
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';
$| = 1;
print "ready 127.0.0.1:$port\n";

while (my $socket = $listener->accept) {
    # Some cases keep their test socket open while probing a second connection.
    my $pid = fork;
    die "fork: $!\n" unless defined $pid;
    if ($pid) {
        close $socket;
        next;
    }
    close $listener;
    my $server = Unblock::HTTP2::Server->new(
        $response_callback => sub {
            my ($transaction) = @_;
            $transaction->respond(Uniform::HTTP::Response->new(
                status => 200,
                headers => [ [ 'content-type', 'text/plain' ] ],
                body => "unblock-h2spec-ok\n",
            ));
        },
    );
    eval {
        my $select = IO::Select->new($socket);
        while (!$server->is_closed) {
            # Send queued protocol errors before honoring want_read == false.
            while ($server->want_write) {
                my $bytes = $server->output;
                last unless length $bytes;
                my $offset = 0;
                while ($offset < length $bytes) {
                    my $n = syswrite($socket, $bytes, length($bytes) - $offset, $offset);
                    next if !defined($n) && $!{EINTR};
                    die "write: $!\n" unless $n;
                    $offset += $n;
                }
            }
            last unless $server->want_read;
            last unless $select->can_read(5);
            my $n = sysread($socket, my $bytes, 65_536);
            next if !defined($n) && $!{EINTR};
            die "read: $!\n" unless defined $n;
            last unless $n;
            $server->input($bytes);
        }
        1;
    } or warn $@;
    $server->close unless $server->is_closed;
    close $socket;
    exit 0;
}
