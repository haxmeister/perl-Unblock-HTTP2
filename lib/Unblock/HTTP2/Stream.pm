package Unblock::HTTP2::Stream;

use strict;
use warnings;
use parent 'Unblock::HTTP2::Transaction';

our $VERSION = '0.02';

1;

__END__

=head1 NAME

Unblock::HTTP2::Stream - compatibility name for Unblock::HTTP2::Transaction

=head1 DESCRIPTION

New code should use L<Unblock::HTTP2::Transaction>.

HTTP/2 still has protocol streams, but the public request/response object is a
Transaction so Unblock::HTTP1, Unblock::HTTP2, and Unblock::HTTP3 use the same
application-facing concept.

This class remains available for compatibility with code that loads or
constructs C<Unblock::HTTP2::Stream> directly.

=head1 SEE ALSO

L<Unblock::HTTP2::Transaction>, L<Unblock::HTTP2>

=head1 LICENSE

MIT License.

=cut
