package Unblock::HTTP2::Client;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed weaken);
use parent 'Unblock::HTTP2::_Connection';

use Unblock::HTTP2::_Headers;
use Unblock::HTTP2::Stream;

our $VERSION = '0.001';

use constant {
    H2_DATA              => 0,
    H2_HEADERS           => 1,
    H2_GOAWAY            => 7,
    H2_END_STREAM        => 0x1,
    H2_INTERNAL_ERROR    => 2,
    H2_CANCEL            => 8,
    H2_ENHANCE_YOUR_CALM => 11,
};

my $BODY_HIGH_WATER = 65_536;
my $BODY_LOW_WATER  = 32_768;

sub new {
    my ($class, %option) = @_;

    my $max_active_streams = exists($option{max_active_streams})
        ? delete($option{max_active_streams})
        : 100;
    my $max_header_list_size = exists($option{max_header_list_size})
        ? delete($option{max_header_list_size})
        : 65_536;

    croak 'new(): max_active_streams must be a positive integer'
        unless defined($max_active_streams) && !ref($max_active_streams)
            && $max_active_streams =~ /\A[0-9]+\z/
            && $max_active_streams > 0;
    croak 'new(): max_header_list_size must be a positive integer'
        unless defined($max_header_list_size) && !ref($max_header_list_size)
            && $max_header_list_size =~ /\A[0-9]+\z/
            && $max_header_list_size > 0;
    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    require Net::HTTP2::nghttp2;
    Net::HTTP2::nghttp2->VERSION('0.011');
    require Net::HTTP2::nghttp2::Session;
    croak 'new(): nghttp2 library is unavailable'
        unless Net::HTTP2::nghttp2->available;

    my $self = bless {
        draining             => 0,
        max_active_streams   => 0 + $max_active_streams,
        max_header_list_size => 0 + $max_header_list_size,
        receive              => {},
        providers            => {},
    }, $class;

    my $weak = $self;
    weaken($weak);

    my $session = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers => sub {
                my $self = $weak or return 0;
                return $self->_on_begin_headers(@_);
            },
            on_header => sub {
                my $self = $weak or return 0;
                return $self->_on_header(@_);
            },
            on_frame_recv => sub {
                my $self = $weak or return 0;
                return $self->_on_frame_recv(@_);
            },
            on_data_chunk_recv => sub {
                my $self = $weak or return 0;
                return $self->_on_data_chunk_recv(@_);
            },
            on_stream_close => sub {
                my $self = $weak or return 0;
                return $self->_on_stream_close(@_);
            },
        },
    );

    $self->_initialize_connection($session);

    $session->send_connection_preface(
        max_concurrent_streams => 100,
        max_header_list_size   => $self->{max_header_list_size},
    );
    $self->_mark_output_pending;

    return $self;
}

sub draining {
    return $_[0]{draining} ? 1 : 0;
}

sub can_open_stream {
    my ($self) = @_;
    return 0 if $self->is_closed || $self->{draining};
    return $self->stream_count < $self->{max_active_streams} ? 1 : 0;
}

sub request {
    my ($self, $request, %option) = @_;

    croak 'request(): connection is closed' if $self->is_closed;
    croak 'request(): connection cannot accept another stream'
        unless $self->can_open_stream;
    croak 'request(): requires the Uniform HTTP request contract'
        unless Unblock::HTTP2::_Headers::_request_contract($request);

    if ($request->is_mutable) {
        $request->version('2');
    }
    elsif (!defined($request->version) || $request->version ne '2') {
        croak 'request(): immutable Request must already have version 2';
    }

    croak 'request(): ordinary CONNECT is not supported by the current client API'
        if uc($request->method) eq 'CONNECT';

    my $stream_body = exists($option{stream_body})
        ? delete($option{stream_body})
        : 0;
    croak 'request(): stream_body must be zero or one'
        if !defined($stream_body) || ref($stream_body)
            || "$stream_body" !~ /\A[01]\z/;
    $stream_body = $stream_body ? 1 : 0;

    my %callbacks;
    for my $name (qw(
        on_response on_body on_complete on_error on_informational on_drain
    )) {
        next unless exists $option{$name};
        my $callback = delete $option{$name};
        croak "request(): $name must be a coderef"
            if defined($callback) && ref($callback) ne 'CODE';
        $callbacks{$name} = $callback if $callback;
    }

    croak 'request(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    croak 'request(): on_drain requires stream_body'
        if $callbacks{on_drain} && !$stream_body;
    croak 'request(): stream_body cannot be combined with a buffered body'
        if $stream_body && $request->has_buffered_body;

    my $block = Unblock::HTTP2::_Headers->request_headers($request);
    my @headers = grep { substr($_->[0], 0, 1) ne ':' } @$block;

    my ($provider, $body_callback, $body);
    if ($stream_body) {
        $provider = {
            queue     => '',
            eof       => 0,
            blocked   => 0,
            stream_id => undef,
        };

        my $weak_self = $self;
        weaken($weak_self);

        $body_callback = sub {
            my $self = $weak_self or return ('', 1);
            return $self->_provide_body($provider, @_);
        };
        $body = $body_callback;
    }
    elsif ($request->has_buffered_body) {
        $body = $request->body;
    }

    my $stream_id = $self->{session}->submit_request(
        method    => $request->method,
        path      => $request->target,
        scheme    => $request->scheme,
        authority => $request->authority,
        headers   => \@headers,
        body      => $body,
    );

    my $stream = Unblock::HTTP2::Stream->_new(
        connection => $self,
        id         => $stream_id,
        request    => $request,
        callbacks  => \%callbacks,
    );

    $self->_register_stream($stream);
    $self->{receive}{$stream_id} = {
        header_block         => [],
        header_list_size     => 0,
        header_limit_exceeded => 0,
        response             => undef,
        response_done        => 0,
    };

    if ($provider) {
        $provider->{stream_id} = $stream_id;
        $self->{providers}{$stream_id} = $provider;
        $request->mark_incomplete;
    }

    $request->commit;
    $self->_mark_output_pending;
    return $stream;
}

sub _provide_body {
    my ($self, $provider, $stream_id, $max_length) = @_;

    if (!length($provider->{queue})) {
        return ('', 1) if $provider->{eof};
        return;
    }

    my $take = length($provider->{queue}) < $max_length
        ? length($provider->{queue})
        : $max_length;
    my $chunk = substr($provider->{queue}, 0, $take, '');
    my $eof = $provider->{eof} && !length($provider->{queue}) ? 1 : 0;

    if ($provider->{blocked}
        && length($provider->{queue}) < $BODY_LOW_WATER) {
        $provider->{blocked} = 0;
        $self->_queue_drain($provider->{stream_id});
    }

    return ($chunk, $eof);
}

sub _on_begin_headers {
    my ($self, $stream_id, $frame_type, $flags) = @_;
    my $state = $self->{receive}{$stream_id} or return 0;

    $state->{header_block} = [];
    $state->{header_list_size} = 0;
    $state->{header_limit_exceeded} = 0;
    return 0;
}

sub _on_header {
    my ($self, $stream_id, $name, $value, $flags) = @_;
    my $state = $self->{receive}{$stream_id} or return 0;
    return 0 if $state->{header_limit_exceeded};

    my $size = $state->{header_list_size}
        + length($name) + length($value) + 32;

    if ($size > $self->{max_header_list_size}) {
        $state->{header_limit_exceeded} = 1;
        $self->_stream_failure(
            $stream_id,
            'HTTP/2 response header list exceeds configured limit',
            H2_ENHANCE_YOUR_CALM,
        );
        return 0;
    }

    $state->{header_list_size} = $size;
    push @{ $state->{header_block} }, [ $name, $value ];
    return 0;
}

sub _status_from_block {
    my ($block) = @_;
    for my $pair (@$block) {
        return $pair->[1] if $pair->[0] eq ':status';
    }
    return;
}

sub _on_frame_recv {
    my ($self, $frame) = @_;

    if (($frame->{type} || -1) == H2_GOAWAY) {
        $self->{draining} = 1;
        return 0;
    }

    my $stream_id = $frame->{stream_id} || 0;
    return 0 unless $stream_id;

    my $state = $self->{receive}{$stream_id} or return 0;
    return 0 if $state->{header_limit_exceeded};

    my $stream = $self->stream_for_id($stream_id) or return 0;

    if (($frame->{type} || -1) == H2_HEADERS) {
        if (!$state->{response}) {
            my $status = _status_from_block($state->{header_block});

            if (defined($status) && $status =~ /\A1[0-9][0-9]\z/) {
                my $response = eval {
                    Unblock::HTTP2::_Headers->response_from_headers(
                        $state->{header_block},
                        end_stream => 1,
                    );
                };

                if (!$response) {
                    $self->_stream_failure($stream_id, "$@");
                    return 0;
                }

                my $result = $stream->_invoke(
                    'on_informational', $response,
                );
                $self->_stream_failure($stream_id, "$result")
                    unless $result eq '1';
                return 0;
            }

            my $response = eval {
                Unblock::HTTP2::_Headers->response_from_headers(
                    $state->{header_block},
                    end_stream => (($frame->{flags} || 0) & H2_END_STREAM)
                        ? 1 : 0,
                );
            };

            if (!$response) {
                $self->_stream_failure($stream_id, "$@");
                return 0;
            }

            $state->{response} = $response;
            $stream->_set_response($response);

            my $result = $stream->_invoke('on_response', $response);
            if ($result ne '1') {
                $self->_stream_failure($stream_id, "$result");
                return 0;
            }

            if (($frame->{flags} || 0) & H2_END_STREAM) {
                $self->_finish_response($stream_id);
            }

            return 0;
        }

        if (($frame->{flags} || 0) & H2_END_STREAM) {
            $self->_finish_response($stream_id);
        }

        return 0;
    }

    if (($frame->{type} || -1) == H2_DATA
        && (($frame->{flags} || 0) & H2_END_STREAM)) {
        $self->_finish_response($stream_id);
    }

    return 0;
}

sub _on_data_chunk_recv {
    my ($self, $stream_id, $data, $flags) = @_;
    my $state = $self->{receive}{$stream_id} or return 0;
    my $stream = $self->stream_for_id($stream_id) or return 0;
    my $response = $state->{response};

    if (!$response) {
        $self->_stream_failure(
            $stream_id,
            'HTTP/2 DATA arrived before final Response headers',
        );
        return 0;
    }

    my $result = $stream->_invoke('on_body', $response, $data);
    $self->_stream_failure($stream_id, "$result")
        unless $result eq '1';

    return 0;
}

sub _finish_response {
    my ($self, $stream_id) = @_;
    my $state = $self->{receive}{$stream_id} or return;
    return if $state->{response_done}++;

    my $stream = $self->stream_for_id($stream_id) or return;
    my $response = $state->{response};

    if (!$response) {
        $self->_stream_failure(
            $stream_id,
            'HTTP/2 stream ended before final Response headers',
        );
        return;
    }

    $response->mark_complete;

    my $result = $stream->_invoke('on_complete');
    $self->_invoke_stream_error($stream, "$result")
        unless $result eq '1';
    return;
}

sub _on_stream_close {
    my ($self, $stream_id, $error_code) = @_;
    my $state = delete $self->{receive}{$stream_id};
    delete $self->{providers}{$stream_id};

    my $stream = $self->_remove_stream($stream_id) or return 0;
    return 0 if $stream->is_terminal;

    if ($error_code) {
        my $error = "HTTP/2 stream closed with error $error_code";
        $stream->_fail($error);
        $self->_invoke_stream_error($stream, $error);
    }
    elsif ($state && $state->{response}) {
        $state->{response}->mark_complete;
        if (!$state->{response_done}) {
            my $result = $stream->_invoke('on_complete');
            $self->_invoke_stream_error($stream, "$result")
                unless $result eq '1';
        }
        $stream->request->mark_complete
            unless $stream->request->is_complete;
        $stream->_mark_complete;
    }
    else {
        my $error = 'HTTP/2 stream closed before final Response';
        $stream->_fail($error);
        $self->_invoke_stream_error($stream, $error);
    }

    return 0;
}

sub _stream_failure {
    my ($self, $stream_id, $error, $code) = @_;
    $code = H2_INTERNAL_ERROR unless defined $code;
    $error = 'HTTP/2 stream failure'
        unless defined($error) && length($error);

    my $stream = $self->stream_for_id($stream_id) or return;
    return if $stream->is_terminal;

    $stream->_fail($error);
    eval { $self->{session}->submit_rst_stream($stream_id, $code) };
    $self->_mark_output_pending;
    $self->_invoke_stream_error($stream, $error);
    return;
}

sub _write_stream_body {
    my ($self, $stream, $bytes, $final, $operation) = @_;

    my $provider = $self->{providers}{ $stream->id }
        or croak "$operation(): Stream has no streaming Request body";

    $bytes = $self->_body_bytes("$operation()", $bytes);
    croak "$operation(): streaming Request body is already complete"
        if $provider->{eof};

    $provider->{queue} .= $bytes;
    $provider->{eof} = 1 if $final;

    if ($final) {
        $stream->request->mark_complete;
    }

    if ($self->{session}->is_stream_deferred($stream->id)) {
        $self->{session}->resume_stream($stream->id);
    }

    $self->_mark_output_pending;

    my $blocked = length($provider->{queue}) >= $BODY_HIGH_WATER;
    $provider->{blocked} = 1 if $blocked;
    return $blocked ? 0 : 1;
}

sub _respond_stream {
    croak 'respond(): client-side streams cannot send Responses';
}

sub _cancel_stream {
    my ($self, $stream) = @_;
    return if $stream->is_terminal;

    eval { $self->{session}->submit_rst_stream($stream->id, H2_CANCEL) };
    $self->_mark_output_pending;
    $stream->_mark_cancelled;
    return;
}

sub close {
    my ($self, @args) = @_;
    $self->SUPER::close(@args);
    $self->{receive} = {};
    $self->{providers} = {};
    return $self;
}

1;

__END__

=head1 NAME

Unblock::HTTP2::Client - Standalone HTTP/2 client protocol engine

=head1 SYNOPSIS

    my $client = Unblock::HTTP2::Client->new;

    my $stream = $client->request(
        $request,
        on_response => sub {
            my ($stream, $response) = @_;
        },
        on_body => sub {
            my ($stream, $response, $bytes) = @_;
        },
        on_complete => sub {
            my ($stream) = @_;
        },
    );

    while ($client->want_write) {
        my $bytes = $client->output;
        last unless length $bytes;
        $transport->write($bytes);
    }

=head1 DESCRIPTION

This class owns one HTTP/2 client session. It does not create or own a socket,
TLS session, event loop, or transport output queue.

Feed decrypted HTTP/2 bytes to C<input()>. Drain bytes from C<output()> and send
them through the transport chosen by the caller.

=cut
