package Unblock::HTTP2::Client;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(weaken);
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

    my %callbacks;
    for my $name (qw(
        on_settings on_settings_ack on_ping on_ping_ack on_invalid_frame
    )) {
        next unless exists $option{$name};
        my $callback = delete $option{$name};
        croak "new(): $name must be a coderef"
            if defined($callback) && ref($callback) ne 'CODE';
        $callbacks{$name} = $callback if $callback;
    }

    my $settings = exists($option{settings})
        ? delete($option{settings})
        : {};
    croak 'new(): settings must be a hash reference'
        unless ref($settings) eq 'HASH';

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

    require Unblock::HTTP2::_nghttp2;
    croak 'new(): nghttp2 library is unavailable'
        unless Unblock::HTTP2::_nghttp2->available;

    my $self = bless {
        draining             => 0,
        max_active_streams   => 0 + $max_active_streams,
        max_header_list_size => 0 + $max_header_list_size,
        receive              => {},
        providers            => {},
        peer_goaway           => undef,
    }, $class;

    my $weak = $self;
    weaken($weak);

    my $session = Unblock::HTTP2::_nghttp2::Session->new_client(
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
            on_invalid_frame => sub {
                my $self = $weak or return 0;
                return $self->_on_invalid_frame(@_);
            },
        },
    );

    $self->_initialize_connection(
        $session,
        role      => 'client',
        callbacks => \%callbacks,
    );

    my %initial_settings = (
        max_concurrent_streams => 100,
        max_header_list_size   => $self->{max_header_list_size},
        enable_push            => 0,
        no_rfc7540_priorities  => 1,
        %$settings,
    );
    $self->_submit_settings('new()', \%initial_settings);

    return $self;
}

sub draining {
    return $_[0]{draining} ? 1 : 0;
}

sub peer_goaway {
    my ($self) = @_;
    return unless $self->{peer_goaway};
    return { %{ $self->{peer_goaway} } };
}

sub drain {
    my ($self) = @_;
    return $self if $self->is_closed || $self->{draining};

    $self->{session}->submit_goaway(
        last_stream_id => 0,
        error_code     => 0,
    );
    $self->{draining} = 1;
    return $self;
}

sub can_open_stream {
    my ($self) = @_;
    return 0 if $self->is_closed || $self->{draining};

    my $limit = $self->{max_active_streams};
    my $peer_limit = $self->peer_setting('max_concurrent_streams');
    $limit = $peer_limit if $peer_limit < $limit;

    return $self->stream_count < $limit ? 1 : 0;
}

sub request {
    my ($self, $request, %option) = @_;

    croak 'request(): connection is closed' if $self->is_closed;
    croak 'request(): connection cannot accept another stream'
        unless $self->can_open_stream;
    croak 'request(): requires the Uniform HTTP request contract'
        unless Unblock::HTTP2::_Headers::_request_contract($request);

    if (defined($request->protocol) && length($request->protocol)) {
        my $enabled = $self->peer_setting('enable_connect_protocol');
        croak 'request(): peer has not enabled Extended CONNECT'
            unless $enabled == 1;
    }

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
    my $trailers = Unblock::HTTP2::_Headers->trailer_fields(
        'request()', $request,
    );

    my ($provider, $body);
    if ($stream_body || @$trailers) {
        $provider = {
            queue             => '',
            eof               => 0,
            blocked           => 0,
            stream_id         => undef,
            trailers          => undef,
            trailer_submitted => 0,
        };

        if (!$stream_body) {
            $provider->{queue} = $request->has_buffered_body
                ? $request->body
                : '';
            $provider->{eof} = 1;
            $provider->{trailers} = $trailers if @$trailers;
        }

        my $weak_self = $self;
        weaken($weak_self);

        $body = sub {
            my $self = $weak_self or return ('', 1);
            return $self->_provide_body($provider, @_);
        };
    }
    elsif ($request->has_buffered_body) {
        $body = $request->body;
    }

    my $stream_id = $self->{session}->_submit_request_xs(
        $block,
        $body,
    );

    my $stream = Unblock::HTTP2::Stream->_new(
        connection => $self,
        id         => $stream_id,
        request    => $request,
        callbacks  => \%callbacks,
    );

    $self->_register_stream($stream);
    $self->{receive}{$stream_id} = {
        header_block          => [],
        trailer_block         => [],
        collecting            => 'initial',
        header_list_size      => 0,
        header_limit_exceeded => 0,
        response              => undef,
        response_done         => 0,
    };

    if ($provider) {
        $provider->{stream_id} = $stream_id;
        $self->{providers}{$stream_id} = $provider;
    }

    return $stream;
}
sub _provide_body {
    my ($self, $provider, $stream_id, $max_length) = @_;

    if (!length($provider->{queue})) {
        if ($provider->{eof}) {
            if ($provider->{trailers}
                && !$provider->{trailer_submitted}) {
                $self->_submit_provider_trailers($provider);
                return ('', 1, 1);
            }
            return ('', 1);
        }
        return;
    }

    my $take = length($provider->{queue}) < $max_length
        ? length($provider->{queue})
        : $max_length;
    my $chunk = substr($provider->{queue}, 0, $take, '');
    my $eof = $provider->{eof} && !length($provider->{queue}) ? 1 : 0;
    my $no_end_stream = 0;

    if ($eof && $provider->{trailers}
        && !$provider->{trailer_submitted}) {
        $self->_submit_provider_trailers($provider);
        $no_end_stream = 1;
    }

    if ($provider->{blocked}
        && length($provider->{queue}) < $BODY_LOW_WATER) {
        $provider->{blocked} = 0;
        $self->_queue_drain($provider->{stream_id});
    }

    return $no_end_stream
        ? ($chunk, $eof, 1)
        : ($chunk, $eof);
}

sub _submit_provider_trailers {
    my ($self, $provider) = @_;
    return if $provider->{trailer_submitted};

    $self->{session}->submit_trailer(
        $provider->{stream_id},
        headers => $provider->{trailers} || [],
    );
    $provider->{trailer_submitted} = 1;
    return;
}
sub _on_begin_headers {
    my ($self, $stream_id, $frame_type, $flags) = @_;
    my $state = $self->{receive}{$stream_id} or return 0;

    $state->{header_list_size} = 0;
    $state->{header_limit_exceeded} = 0;

    if ($state->{response}) {
        $state->{trailer_block} = [];
        $state->{collecting} = 'trailer';
    }
    else {
        $state->{header_block} = [];
        $state->{collecting} = 'initial';
    }

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
    my $key = $state->{collecting} eq 'trailer'
        ? 'trailer_block'
        : 'header_block';
    push @{ $state->{$key} }, [ $name, $value ];
    return 0;
}
sub _status_from_block {
    my ($block) = @_;
    for my $pair (@$block) {
        return $pair->[1] if $pair->[0] eq ':status';
    }
    return;
}

sub _on_invalid_frame {
    my ($self, $frame, $lib_error_code) = @_;

    my $copy = ref($frame) eq 'HASH' ? { %$frame } : {};
    $self->_invoke_control_callback(
        'on_invalid_frame',
        $copy,
        0 + ($lib_error_code || 0),
    );
    return 0;
}

sub _on_frame_recv {
    my ($self, $frame) = @_;

    return 0 if $self->_handle_settings_frame($frame);
    return 0 if $self->_handle_ping_frame($frame);

    if (($frame->{type} // -1) == H2_GOAWAY) {
        $self->{draining} = 1;
        $self->{peer_goaway} = {
            last_stream_id => 0 + ($frame->{last_stream_id} // 0),
            error_code     => 0 + ($frame->{error_code} // 0),
            debug_data     => defined($frame->{debug_data})
                ? "$frame->{debug_data}"
                : '',
        };
        return 0;
    }

    my $stream_id = $frame->{stream_id} || 0;
    return 0 unless $stream_id;

    my $state = $self->{receive}{$stream_id} or return 0;
    return 0 if $state->{header_limit_exceeded};

    my $stream = $self->stream_for_id($stream_id) or return 0;

    if (($frame->{type} // -1) == H2_HEADERS) {
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

        if (!(($frame->{flags} || 0) & H2_END_STREAM)) {
            $self->_stream_failure(
                $stream_id,
                'HTTP/2 trailing HEADERS must end the stream',
            );
            return 0;
        }

        my $ok = eval {
            Unblock::HTTP2::_Headers->apply_trailers(
                $state->{response},
                $state->{trailer_block},
            );
            1;
        };
        if (!$ok) {
            $self->_stream_failure($stream_id, "$@");
            return 0;
        }

        $self->_finish_response($stream_id);
        return 0;
    }

    if (($frame->{type} // -1) == H2_DATA
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

    $stream->_receive_body_bytes(length $data);

    my $result = $stream->_invoke('on_body', $response, $data);
    if ($result ne '1') {
        $self->_stream_failure($stream_id, "$result");
        return 0;
    }

    $stream->_auto_consume_body;
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

    $response->mark_complete->freeze;

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
        $stream->_fail($error, $error_code, 1);
        $self->_invoke_stream_error($stream, $error, $error_code);
    }
    elsif ($state && $state->{response}) {
        $state->{response}->mark_complete->freeze;
        if (!$state->{response_done}) {
            my $result = $stream->_invoke('on_complete');
            $self->_invoke_stream_error($stream, "$result")
                unless $result eq '1';
        }
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

    $stream->_fail($error, $code, 0);
    eval { $self->{session}->submit_rst_stream($stream_id, $code) };
    $self->_invoke_stream_error($stream, $error, $code);
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

    if ($final) {
        my $trailers = Unblock::HTTP2::_Headers->trailer_fields(
            "$operation()", $stream->request,
        );
        $provider->{trailers} = $trailers if @$trailers;
        $provider->{eof} = 1;
    }

    if ($self->{session}->is_stream_deferred($stream->id)) {
        $self->{session}->resume_stream($stream->id);
    }

    my $blocked = length($provider->{queue}) >= $BODY_HIGH_WATER;
    $provider->{blocked} = 1 if $blocked;
    return $blocked ? 0 : 1;
}
sub _inform_stream {
    croak 'inform(): client-side streams cannot send Responses';
}

sub _respond_stream {
    croak 'respond(): client-side streams cannot send Responses';
}

sub _cancel_stream {
    my ($self, $stream) = @_;
    return if $stream->is_terminal;
    $self->_reset_stream($stream, H2_CANCEL);
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
