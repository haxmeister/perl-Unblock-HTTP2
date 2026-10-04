package Unblock::HTTP2::Server;

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
        on_request on_body on_request_end on_error
        on_settings on_settings_ack on_ping on_ping_ack on_priority
        on_invalid_frame
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

    my $max_concurrent_streams = exists($option{max_concurrent_streams})
        ? delete($option{max_concurrent_streams})
        : 100;
    my $max_header_list_size = exists($option{max_header_list_size})
        ? delete($option{max_header_list_size})
        : 65_536;
    my $enable_connect_protocol = exists($option{enable_connect_protocol})
        ? delete($option{enable_connect_protocol})
        : 1;

    croak 'new(): max_concurrent_streams must be a positive integer'
        unless defined($max_concurrent_streams)
            && !ref($max_concurrent_streams)
            && $max_concurrent_streams =~ /\A[0-9]+\z/
            && $max_concurrent_streams > 0;
    croak 'new(): max_header_list_size must be a positive integer'
        unless defined($max_header_list_size)
            && !ref($max_header_list_size)
            && $max_header_list_size =~ /\A[0-9]+\z/
            && $max_header_list_size > 0;
    croak 'new(): enable_connect_protocol must be zero or one'
        if !defined($enable_connect_protocol)
            || ref($enable_connect_protocol)
            || "$enable_connect_protocol" !~ /\A[01]\z/;
    $enable_connect_protocol = $enable_connect_protocol ? 1 : 0;

    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    require Unblock::HTTP2::_nghttp2;
    croak 'new(): nghttp2 library is unavailable'
        unless Unblock::HTTP2::_nghttp2->available;

    my $self = bless {
        callbacks               => \%callbacks,
        draining                => 0,
        max_concurrent_streams  => 0 + $max_concurrent_streams,
        max_header_list_size    => 0 + $max_header_list_size,
        enable_connect_protocol => $enable_connect_protocol,
        last_peer_stream_id     => 0,
        receive                 => {},
        providers               => {},
        peer_goaway              => undef,
    }, $class;

    my $weak = $self;
    weaken($weak);

    my $session = Unblock::HTTP2::_nghttp2::Session->new_server(
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
        role      => 'server',
        callbacks => \%callbacks,
    );

    my %initial_settings = (
        max_concurrent_streams  => $self->{max_concurrent_streams},
        max_header_list_size    => $self->{max_header_list_size},
        enable_connect_protocol => $self->{enable_connect_protocol},
        no_rfc7540_priorities   => 1,
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
    return $self->goaway(error_code => 0);
}

sub _on_begin_headers {
    my ($self, $stream_id, $frame_type, $flags) = @_;

    $self->{last_peer_stream_id} = $stream_id
        if $stream_id > $self->{last_peer_stream_id};

    my $state = $self->{receive}{$stream_id} ||= {
        header_block          => [],
        trailer_block         => [],
        collecting            => 'initial',
        header_list_size      => 0,
        header_limit_exceeded => 0,
        request_end_called    => 0,
    };

    $state->{header_list_size} = 0;
    $state->{header_limit_exceeded} = 0;

    if ($self->stream_for_id($stream_id)) {
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
            'HTTP/2 request header list exceeds configured limit',
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

sub _on_frame_recv {
    my ($self, $frame) = @_;

    return 0 if $self->_handle_settings_frame($frame);
    return 0 if $self->_handle_ping_frame($frame);
    return 0 if $self->_handle_priority_update_frame($frame);

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

    if (($frame->{type} // -1) == H2_HEADERS) {
        my $stream = $self->stream_for_id($stream_id);

        if (!$stream) {
            my $request = eval {
                Unblock::HTTP2::_Headers->request_from_headers(
                    $state->{header_block},
                    end_stream => (($frame->{flags} || 0) & H2_END_STREAM)
                        ? 1 : 0,
                );
            };

            if (!$request) {
                $self->_stream_failure($stream_id, "$@");
                return 0;
            }

            $stream = Unblock::HTTP2::Stream->_new(
                connection => $self,
                id         => $stream_id,
                request    => $request,
                callbacks  => {},
            );
            $self->_register_stream($stream);

            my $result = $self->_invoke_callback(
                'on_request', $stream, $request,
            );
            if ($result ne '1') {
                $self->_stream_failure($stream_id, "$result");
                return 0;
            }

            if (($frame->{flags} || 0) & H2_END_STREAM) {
                $self->_request_end($stream_id);
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
                $stream->request,
                $state->{trailer_block},
            );
            1;
        };
        if (!$ok) {
            $self->_stream_failure($stream_id, "$@");
            return 0;
        }

        $self->_request_end($stream_id);
        return 0;
    }

    if (($frame->{type} // -1) == H2_DATA
        && (($frame->{flags} || 0) & H2_END_STREAM)) {
        $self->_request_end($stream_id);
    }

    return 0;
}
sub _on_data_chunk_recv {
    my ($self, $stream_id, $data, $flags) = @_;
    my $stream = $self->stream_for_id($stream_id) or return 0;

    $stream->_receive_body_bytes(length $data);

    my $result = $self->_invoke_callback(
        'on_body', $stream, $stream->request, $data,
    );

    if ($result ne '1') {
        $self->_stream_failure($stream_id, "$result");
        return 0;
    }

    $stream->_auto_consume_body;
    return 0;
}

sub _request_end {
    my ($self, $stream_id) = @_;
    my $state = $self->{receive}{$stream_id} or return;
    return if $state->{request_end_called}++;

    my $stream = $self->stream_for_id($stream_id) or return;
    $stream->request->mark_complete->freeze;

    my $result = $self->_invoke_callback(
        'on_request_end', $stream, $stream->request,
    );
    $self->_stream_failure($stream_id, "$result")
        unless $result eq '1';
    return;
}
sub _invoke_callback {
    my ($self, $name, @args) = @_;
    my $callback = $self->{callbacks}{$name} or return 1;

    my $ok = eval {
        $callback->(@args);
        1;
    };

    return $ok ? 1 : $@;
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

sub _inform_stream {
    my ($self, $stream, $response) = @_;

    croak 'inform(): requires the Uniform HTTP response contract'
        unless Unblock::HTTP2::_Headers::_response_contract($response);
    croak 'inform(): final Response already submitted'
        if $stream->response;

    my $status = $response->status;
    croak 'inform(): status must be informational (100-199, excluding 101)'
        unless defined($status) && !ref($status)
            && $status =~ /\A[0-9]+\z/
            && $status >= 100 && $status < 200 && $status != 101;
    croak 'inform(): informational Response must not have a buffered body'
        if $response->has_buffered_body;

    my $trailers = Unblock::HTTP2::_Headers->trailer_fields(
        'inform()', $response,
    );
    croak 'inform(): informational Response must not have trailers'
        if @$trailers;

    my $block = Unblock::HTTP2::_Headers->response_headers($response);
    $self->{session}->submit_headers(
        $stream->id,
        headers => $block,
    );

    return $stream;
}

sub _respond_stream {
    my ($self, $stream, $response, %option) = @_;

    croak 'respond(): requires the Uniform HTTP response contract'
        unless Unblock::HTTP2::_Headers::_response_contract($response);
    croak 'respond(): Stream already has a Response'
        if $stream->response;

    my $stream_body = exists($option{stream_body})
        ? delete($option{stream_body})
        : 0;
    croak 'respond(): stream_body must be zero or one'
        if !defined($stream_body) || ref($stream_body)
            || "$stream_body" !~ /\A[01]\z/;
    $stream_body = $stream_body ? 1 : 0;

    my $on_drain = delete $option{on_drain};
    my $on_error = delete $option{on_error};

    croak 'respond(): on_drain must be a coderef'
        if defined($on_drain) && ref($on_drain) ne 'CODE';
    croak 'respond(): on_error must be a coderef'
        if defined($on_error) && ref($on_error) ne 'CODE';
    croak 'respond(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    croak 'respond(): on_drain requires stream_body'
        if $on_drain && !$stream_body;
    croak 'respond(): stream_body cannot be combined with a buffered body'
        if $stream_body && $response->has_buffered_body;

    my $block = Unblock::HTTP2::_Headers->response_headers($response);
    my @headers = @$block[1 .. $#$block];
    my $trailers = Unblock::HTTP2::_Headers->trailer_fields(
        'respond()', $response,
    );

    my $provider;
    if ($stream_body || @$trailers) {
        $provider = {
            queue             => '',
            eof               => 0,
            blocked           => 0,
            stream_id         => $stream->id,
            trailers          => undef,
            trailer_submitted => 0,
        };

        if (!$stream_body) {
            $provider->{queue} = $response->has_buffered_body
                ? $response->body
                : '';
            $provider->{eof} = 1;
            $provider->{trailers} = $trailers if @$trailers;
        }

        my $weak_self = $self;
        weaken($weak_self);

        my $data_callback = sub {
            my $self = $weak_self or return ('', 1);
            return $self->_provide_body($provider, @_);
        };

        $self->{session}->submit_response(
            $stream->id,
            status        => $response->status,
            headers       => \@headers,
            data_callback => $data_callback,
        );
    }
    elsif ($response->has_buffered_body) {
        $self->{session}->submit_response(
            $stream->id,
            status  => $response->status,
            headers => \@headers,
            body    => $response->body,
        );
    }
    else {
        $self->{session}->submit_response(
            $stream->id,
            status  => $response->status,
            headers => \@headers,
        );
    }

    $stream->_set_response($response);
    $stream->_set_callback('on_drain', $on_drain) if $on_drain;
    $stream->_set_callback('on_error', $on_error) if $on_error;

    if ($provider) {
        $self->{providers}{ $stream->id } = $provider;
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
sub _write_stream_body {
    my ($self, $stream, $bytes, $final, $operation) = @_;

    my $provider = $self->{providers}{ $stream->id }
        or croak "$operation(): Stream has no streaming Response body";

    $bytes = $self->_body_bytes("$operation()", $bytes);
    croak "$operation(): streaming Response body is already complete"
        if $provider->{eof};

    $provider->{queue} .= $bytes;

    if ($final) {
        my $trailers = Unblock::HTTP2::_Headers->trailer_fields(
            "$operation()", $stream->response,
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
sub _cancel_stream {
    my ($self, $stream) = @_;
    return if $stream->is_terminal;
    $self->_reset_stream($stream, H2_CANCEL);
    return;
}

sub _stream_failure {
    my ($self, $stream_id, $error, $code) = @_;
    $code = H2_INTERNAL_ERROR unless defined $code;
    $error = 'HTTP/2 stream failure'
        unless defined($error) && length($error);

    my $stream = $self->stream_for_id($stream_id);

    if ($stream && !$stream->is_terminal) {
        $stream->_fail($error, $code, 0);
        $self->_invoke_stream_error($stream, $error, $code);
    }
    elsif (my $callback = $self->{callbacks}{on_error}) {
        eval { $callback->(undef, $error, $code) };
    }

    eval { $self->{session}->submit_rst_stream($stream_id, $code) };
    return;
}

sub _invoke_stream_error {
    my ($self, $stream, $error, $error_code) = @_;

    my $result = $stream->_invoke('on_error', $error, $error_code);
    if ($result ne '1') {
        my $callback = $self->{callbacks}{on_error};
        eval { $callback->($stream, "$result", $error_code) } if $callback;
        return;
    }

    my $callback = $self->{callbacks}{on_error};
    eval { $callback->($stream, $error, $error_code) } if $callback;
    return;
}

sub _on_stream_close {
    my ($self, $stream_id, $error_code) = @_;
    delete $self->{receive}{$stream_id};
    delete $self->{providers}{$stream_id};

    my $stream = $self->_remove_stream($stream_id) or return 0;

    if (!$stream->is_terminal) {
        if ($error_code) {
            my $error = "HTTP/2 stream closed with error $error_code";
            $stream->_fail($error, $error_code, 1);
            $self->_invoke_stream_error($stream, $error, $error_code);
        }
        else {
            if (!$stream->request->is_complete) {
                $stream->request->mark_complete->freeze;
            }
            $stream->_mark_complete;
        }
    }

    return 0;
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

Unblock::HTTP2::Server - Standalone HTTP/2 server protocol engine

=head1 SYNOPSIS

    my $server = Unblock::HTTP2::Server->new(
        on_request => sub {
            my ($stream, $request) = @_;

            my $response = Uniform::HTTP::Response->new(
                status => 200,
                body   => "hello\n",
            );

            $stream->respond($response);
        },
    );

=head1 DESCRIPTION

This class owns one HTTP/2 server session. It does not create or own a
listening socket, accepted socket, TLS session, event loop, or transport output
queue.

Feed decrypted HTTP/2 bytes to C<input()>. Drain bytes from C<output()> and send
them through the caller's transport.

=cut
