use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);
use Unblock::HTTP2::Server;
use Unblock::HTTP2::_nghttp2;
use Uniform::HTTP::Response;

# Standalone test endpoint; no framework adapter or production socket API.
my $port = $ENV{UNBLOCK_HTTP2_SERVER_PORT} || 18082;
my $response_mode = $ENV{UNBLOCK_HTTP2_RESPONSE_MODE} || 'request';
my $input_mode = $ENV{UNBLOCK_HTTP2_INPUT_MODE} || 'perl';
my $tls = $ENV{UNBLOCK_HTTP2_TLS_CERT};
die "response mode must be headers or request\n"
    unless $response_mode =~ /\A(?:headers|request)\z/;
die "input mode must be perl or native\n"
    unless $input_mode =~ /\A(?:perl|native)\z/;
require IO::Socket::SSL if $tls;
my $response_callback = $response_mode eq 'headers' ? 'on_request' : 'on_request_end';
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => $port,
    Proto => 'tcp', Listen => 128, ReuseAddr => 1,
) or die "listen on 127.0.0.1:$port: $!\n";
$SIG{PIPE} = 'IGNORE';
my $stopping = 0;
my $failures = 0;
sub child_result {
    my ($pid, $status) = @_;
    if ($status) {
        ++$failures;
        warn "HARNESS FAILURE: child $pid status $status\n";
    }
}
$SIG{CHLD} = sub {
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) { child_result($pid, $?) }
};
$SIG{TERM} = sub { $stopping = 1; close $listener };
$| = 1;
print "ready 127.0.0.1:$port input=$input_mode response=$response_mode\n";

while (!$stopping) {
    my $socket = $listener->accept;
    if (!$socket) {
        last if $stopping;
        next if $!{EINTR};
        die "accept: $!\n";
    }
    # h2spec keeps one socket open while probing another for response length.
    my $pid = fork;
    die "fork: $!\n" unless defined $pid;
    if ($pid) { close $socket; next }
    $SIG{CHLD} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    close $listener;
    my ($server, $driver);
    my $ok = eval {
        if ($tls) {
            IO::Socket::SSL->start_SSL($socket,
                SSL_server => 1, SSL_cert_file => $tls,
                SSL_key_file => $ENV{UNBLOCK_HTTP2_TLS_KEY},
                SSL_alpn_protocols => ['h2'],
            ) or die "TLS handshake: " . IO::Socket::SSL::errstr() . "\n";
        }
        $server = Unblock::HTTP2::Server->new(
            $response_callback => sub {
                $_[0]->respond(Uniform::HTTP::Response->new(
                    status => 200, headers => [ [ 'content-type', 'text/plain' ] ],
                    body => "unblock-h2spec-ok\n",
                ));
            },
        );
        $driver = Unblock::HTTP2::_nghttp2::NativeDriver->new($server)
            if $input_mode eq 'native';
        my $select = IO::Select->new($socket);
        while (!$server->is_closed) {
            # Protocol errors may leave a final GOAWAY queued. Flush it before
            # honoring want_read == false, then close the underlying socket.
            while ($server->want_write) {
                my $bytes;
                if ($driver) { (undef, $bytes) = $driver->drain }
                else { $bytes = $server->output }
                last unless length $bytes;
                my $offset = 0;
                while ($offset < length $bytes) {
                    my $n = syswrite($socket, $bytes, length($bytes) - $offset, $offset);
                    next if !defined($n) && $!{EINTR};
                    die "peer closed during write\n" if !defined($n) && ($!{EPIPE} || $!{ECONNRESET});
                    die "write failed: $!\n" unless $n;
                    $offset += $n;
                }
            }
            last unless $server->want_read;
            last unless ($tls && $socket->pending) || $select->can_read(5);
            my $n = sysread($socket, my $bytes, 65_536);
            next if !defined($n) && $!{EINTR};
            die "peer closed during read\n" if !defined($n) && $!{ECONNRESET};
            die "read failed: $!\n" unless defined $n;
            last unless $n;
            if ($driver) { $driver->feed($bytes) }
            else { $server->input($bytes) }
        }
        1;
    };
    my $error = $@;
    my $expected = $error =~ /\Apeer closed during (?:read|write)\n/
        || $error =~ /nghttp2_session_mem_recv failed \(-903\): Received bad client magic/;
    warn "HARNESS FAILURE: $error" if !$ok && !$expected;
    if ($ok && $server && !$server->want_read) {
        # A plain close with unread kernel data can send TCP RST and erase the
        # peer's view of the GOAWAY just written, especially with TLS records.
        # Finish the write side, then drain in-flight input without parsing it.
        $socket->blocking(0);
        $socket->stop_SSL(SSL_fast_shutdown => 1) if $tls;
        shutdown($socket, 1);
        my $select = IO::Select->new($socket);
        my $deadline = time() + 1;
        while (time() < $deadline) {
            my $pending = $socket->can('pending') && $socket->pending;
            last unless $pending || $select->can_read($deadline - time());
            my $n = sysread($socket, my $ignored, 65_536);
            next if !defined($n) && ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK});
            last unless $n;
        }
    }
    $server->close if $server && !$server->is_closed;
    close $socket;
    exit($ok || $expected ? 0 : 1);
}
$SIG{CHLD} = 'DEFAULT';
while ((my $pid = wait) > 0) { child_result($pid, $?) }
exit($failures ? 1 : 0);
