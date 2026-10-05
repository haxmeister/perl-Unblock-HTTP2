package Unblock::HTTP2::NativeABI;

use strict;
use warnings;

use Unblock::HTTP2 ();
use Unblock::HTTP2::_nghttp2 ();

our $VERSION = $Unblock::HTTP2::VERSION;

use constant ABI_VERSION      => 1;
use constant INPUT_OK         => 0;
use constant INPUT_MORE       => 1;
use constant INPUT_CLOSED     => 3;
use constant OUTPUT_OK        => 0;
use constant OUTPUT_CLOSED    => 3;
use constant OUTPUT_CONTINUE  => 0;
use constant OUTPUT_PAUSE     => 1;
use constant OUTPUT_ERROR     => -1;

sub c_header {
    return <<'END_C_HEADER';
#ifndef UNBLOCK_HTTP2_NATIVE_ABI_H
#define UNBLOCK_HTTP2_NATIVE_ABI_H

#include "EXTERN.h"
#include "perl.h"
#include <stddef.h>
#include <stdint.h>

#define UB_HTTP2_NATIVE_ABI_VERSION 1U

#define UB_HTTP2_INPUT_OK      0
#define UB_HTTP2_INPUT_MORE    1
#define UB_HTTP2_INPUT_CLOSED  3

#define UB_HTTP2_OUTPUT_OK      0
#define UB_HTTP2_OUTPUT_CLOSED  3

#define UB_HTTP2_OUTPUT_CONTINUE 0
#define UB_HTTP2_OUTPUT_PAUSE    1
#define UB_HTTP2_OUTPUT_ERROR   -1

typedef int (*ub_http2_output_sink_v1)(
    pTHX_
    void *sink_context,
    const char *data,
    size_t length
);

typedef struct ub_http2_native_ops_v1_s {
    uint32_t abi_version;
    size_t struct_size;
    const char *name;

    void *(*create)(pTHX_ SV *engine);

    int (*input)(
        pTHX_
        void *context,
        const char *data,
        size_t length,
        size_t *consumed
    );

    int (*eof)(pTHX_ void *context);

    void (*destroy)(pTHX_ void *context);

    int (*output)(
        pTHX_
        void *context,
        ub_http2_output_sink_v1 sink,
        void *sink_context,
        size_t *produced
    );

    int (*want_read)(pTHX_ void *context);
    int (*want_write)(pTHX_ void *context);
} ub_http2_native_ops_v1;

#endif
END_C_HEADER
}

sub definition {
    return {
        provider => \&Unblock::HTTP2::_nghttp2::_native_transport_operations_address,
        abi_version => ABI_VERSION,
        operations_address =>
            Unblock::HTTP2::_nghttp2::_native_transport_operations_address(),
    };
}

1;

__END__

=head1 NAME

Unblock::HTTP2::NativeABI - Native transport ABI for Unblock::HTTP2

=head1 DESCRIPTION

This module exposes the optional native transport ABI used by XS-backed
transports and event frameworks.

The ordinary C<input()> and C<output()> methods remain the portable interface.
A native integration can instead feed borrowed input buffers directly and drain
outbound nghttp2 buffers through a native sink callback.

The ABI works with both C<Unblock::HTTP2::Client> and
C<Unblock::HTTP2::Server>.

=head1 DEFINITION

    my $definition = Unblock::HTTP2::NativeABI::definition();

The returned hash contains:

    provider
    abi_version
    operations_address

C<provider> keeps the XS provider loaded and can be called again to obtain the
current operations address. C<abi_version> is currently 1.

=head1 C ABI

C<c_header()> returns the ABI version 1 C declaration. Build-time adapters may
write this text to a generated header instead of carrying a private copy of the
layout.

Consumers must check both C<abi_version> and C<struct_size> before
dereferencing operations.

The initial C<create>, C<input>, C<eof>, and C<destroy> operation layout is
intentionally parallel to C<Unblock::HTTP1::NativeABI> version 1. HTTP/2 then
appends its native output and readiness operations.

C<create> receives one Unblock::HTTP2 Client or Server object and returns a
connection-local native context. Keep that context for the lifetime of the
HTTP/2 connection.

=head1 BORROWED INPUT

The native input operation receives:

    const char *data
    size_t length
    size_t *consumed

C<data> remains owned by the caller. Unblock::HTTP2 may inspect it only during
the input call and never retains the pointer after the call returns.

libnghttp2 incrementally retains protocol parsing state, so fragmented HTTP/2
frames do not require the caller to preserve an incomplete prefix. A successful
call normally reports the complete input window as consumed.

ABI version 1 uses these input result codes:

    INPUT_OK       0
    INPUT_MORE     1
    INPUT_CLOSED   3

C<INPUT_MORE> is reserved for compatibility with the common Unblock borrowed
input pattern. The current HTTP/2 implementation does not normally return it.

=head1 NATIVE OUTPUT

C<output> drains generated HTTP/2 bytes directly from libnghttp2 into a native
sink callback.

The sink receives a borrowed buffer:

    const char *data
    size_t length

That pointer is valid only for the duration of the sink call. The sink must
write or copy the bytes before returning.

The sink return value controls draining:

    OUTPUT_CONTINUE   keep draining
    OUTPUT_PAUSE      current chunk was accepted; stop after it
    OUTPUT_ERROR      fatal sink failure

C<OUTPUT_PAUSE> provides transport backpressure without losing the chunk that
was just accepted. Call C<output> again when the transport can accept more.

C<produced> reports the number of bytes accepted by the sink during the call.

=head1 EOF

HTTP/2 has no message framing based on transport EOF. C<eof> therefore closes
the connection and returns C<INPUT_CLOSED>.

=head1 FALLBACK

The native ABI is an optimization. A framework that does not use XS, cannot
consume ABI version 1, or chooses not to use the fast path should continue to
use C<input()>, C<output()>, C<want_read()>, and C<want_write()>.

=cut
