package Unblock::HTTP2;

use strict;
use warnings;

our $VERSION = '0.001';

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
