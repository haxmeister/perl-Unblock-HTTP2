package Unblock::HTTP2;

use strict;
use warnings;

our $VERSION = '0.001';

use constant {
    NO_ERROR            => 0,
    PROTOCOL_ERROR      => 1,
    INTERNAL_ERROR      => 2,
    FLOW_CONTROL_ERROR  => 3,
    SETTINGS_TIMEOUT    => 4,
    STREAM_CLOSED       => 5,
    FRAME_SIZE_ERROR    => 6,
    REFUSED_STREAM      => 7,
    CANCEL              => 8,
    COMPRESSION_ERROR   => 9,
    CONNECT_ERROR       => 10,
    ENHANCE_YOUR_CALM   => 11,
    INADEQUATE_SECURITY => 12,
    HTTP_1_1_REQUIRED   => 13,
};

my @ERROR_NAME = qw(
    NO_ERROR
    PROTOCOL_ERROR
    INTERNAL_ERROR
    FLOW_CONTROL_ERROR
    SETTINGS_TIMEOUT
    STREAM_CLOSED
    FRAME_SIZE_ERROR
    REFUSED_STREAM
    CANCEL
    COMPRESSION_ERROR
    CONNECT_ERROR
    ENHANCE_YOUR_CALM
    INADEQUATE_SECURITY
    HTTP_1_1_REQUIRED
);

sub error_name {
    my ($class, $code) = @_;
    return unless defined($code) && !ref($code)
        && "$code" =~ /\A[0-9]+\z/;
    return $ERROR_NAME[0 + $code];
}

1;

__END__

=head1 NAME

Unblock::HTTP2 - Event-loop and operating-system neutral HTTP/2 engine

=head1 DESCRIPTION

Unblock::HTTP2 provides HTTP/2 protocol execution without owning sockets, TLS,
or an event loop.

The client and server engines accept protocol bytes through C<input()> and
return protocol bytes through C<output()>. The caller decides how those bytes
are transported.

HTTP messages use L<Uniform::HTTP::Request> and L<Uniform::HTTP::Response>.
HTTP/2 framing, HPACK, stream state, SETTINGS, GOAWAY, and flow control are
provided by libnghttp2 through a small private XS binding contained in this
distribution. The binding is not public API.

HTTP/2 error codes are available as package constants such as
C<Unblock::HTTP2::REFUSED_STREAM> and C<Unblock::HTTP2::CANCEL>.
C<error_name($code)> returns the standard symbolic name for known codes.

=head1 MODULES

=over 4

=item * L<Unblock::HTTP2::Client>

=item * L<Unblock::HTTP2::Server>

=item * L<Unblock::HTTP2::Stream>

=back

=head1 TRANSPORT BOUNDARY

Unblock::HTTP2 does not connect sockets, negotiate TLS, select ALPN, poll file
descriptors, or queue operating-system writes. A host transport feeds received
bytes to C<input()> and drains C<output()> while C<want_write()> is true.

This keeps the same protocol engine usable with blocking sockets, event loops,
TLS implementations, test harnesses, and different operating systems.

=head1 LICENSE

MIT License.

=cut
