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
    for my $name (qw(on_request on_body on_request_end on_error)) {
        next unless exists $option{$name};
        my $callback = delete $option{$name};
        croak "new(): $name must be a coderef"
            if defined($callback) && ref($callback) ne 'CODE';
        $callbacks{$name} = $callback if $callback;
    }

    my $max_concurrent_streams = exists($option{max_concurrent_streams})
        ? delete($option{max_concurrent_streams})
        : 100;
    my $max_header_list_size = exists($option{max_header_list_size})
        ? delete($option{max_header_list_size})
        : 65_536;

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
    croak 'new(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    require Net::HTTP2::nghttp2;
    Net::HTTP2::nghttp2->VERSION('0.011');
    require Net::HTTP2::nghttp2::Session;
    croak 'new(): nghttp2 library is unavailable'
        unless Net::HTTP2::nghttp2->available;

    my $self = bless {
        callbacks              => \%callbacks,
        draining               => 0,
        max_concurrent_streams => 0 + $max_concurrent_streams,
        max_header_list_size   => 0 + $max_header_list_size,
        receive                => {},
        providers              => {},
    }, $class;

    my $weak = $self;
    weaken($weak);

    my $session = Net::HTTP2::nghttp2::Session->new_server(
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
            on_error => sub {
                my $self = $weak or return 0;
                return $self->_on_session_error(@_);
            },
        },
    );

    $self->_initialize_connection($session);

    $session->send_connection_preface(
        max_concurrent_streams => $self->{max_concurrent_streams},
        max_header_list_size   => $self->{max_header_list_size},
    );
    $self->_mark_output_pending;

    return $self;
}

sub draining {
    return $_[0]{draining} ? 1 : 0;
}

sub _on_begin_headers {
    my ($self, $stream_id, $frame_type, $flags) = @_;

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

    if (($frame->{type} || -1) == H2_GOAWAY) {
        $self->{draining} = 1;
        return 0;
    }

    my $stream_id = $frame->{stream_id} || 0;
    return 0 unless $stream_id;

    my $state = $self->{receive}{$stream_id} or return 0;
    return 0 if $state->{header_limit_exceeded};

    if (($frame->{type} || -1) == H2_HEADERS) {
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

        if (($frame->{flags} || 0) & H2_END_STREAM) {
            $self->_request_end($stream_id);
        }

        return 0;
    }

    if (($frame->{type} || -1) == H2_DATA
        && (($frame->{flags} || 0) & H2_END_STREAM)) {
        $self->_request_end($stream_id);
    }

    return 0;
}

sub _on_data_chunk_recv {
    my ($self, $stream_id, $data, $flags) = @_;
    my $stream = $self->stream_for_id($stream_id) or return 0;

    my $result = $self->_invoke_callback(
        'on_body', $stream, $stream->request, $data,
    );

    $self->_stream_failure($stream_id, "$result")
        unless $result eq '1';

    return 0;
}

sub _request_end {
    my ($self, $stream_id) = @_;
    my $state = $self->{receive}{$stream_id} or return;
    return if $state->{request_end_called}++;

    my $stream = $self->stream_for_id($stream_id) or return;
    $stream->request->mark_complete;

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

sub _on_session_error {
    my ($self, $lib_error_code, $message) = @_;
    my $callback = $self->{callbacks}{on_error} or return 0;
    eval { $callback->(undef, "$message") };
    return 0;
}

sub _respond_stream {
    my ($self, $stream, $response, %option) = @_;

    croak 'respond(): requires the Uniform HTTP response contract'
        unless Unblock::HTTP2::_Headers::_response_contract($response);
    croak 'respond(): Stream already has a Response'
        if $stream->response;

    if ($response->is_mutable) {
        $response->version('2');
    }
    elsif (!defined($response->version) || $response->version ne '2') {
        croak 'respond(): immutable Response must already have version 2';
    }

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

    my $provider;
    if ($stream_body) {
        $provider = {
            queue     => '',
            eof       => 0,
            blocked   => 0,
            stream_id => $stream->id,
        };

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
        $response->mark_incomplete;
    }

    $response->commit;
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

sub _write_stream_body {
    my ($self, $stream, $bytes, $final, $operation) = @_;

    my $provider = $self->{providers}{ $stream->id }
        or croak "$operation(): Stream has no streaming Response body";

    $bytes = $self->_body_bytes("$operation()", $bytes);
    croak "$operation(): streaming Response body is already complete"
        if $provider->{eof};

    $provider->{queue} .= $bytes;
    $provider->{eof} = 1 if $final;

    if ($final && $stream->response) {
        $stream->response->mark_complete;
    }

    if ($self->{session}->is_stream_deferred($stream->id)) {
        $self->{session}->resume_stream($stream->id);
    }

    $self->_mark_output_pending;

    my $blocked = length($provider->{queue}) >= $BODY_HIGH_WATER;
    $provider->{blocked} = 1 if $blocked;
    return $blocked ? 0 : 1;
}

sub _cancel_stream {
    my ($self, $stream) = @_;
    return if $stream->is_terminal;

    eval { $self->{session}->submit_rst_stream($stream->id, H2_CANCEL) };
    $self->_mark_output_pending;
    $stream->_mark_cancelled;
    return;
}

sub _stream_failure {
    my ($self, $stream_id, $error, $code) = @_;
    $code = H2_INTERNAL_ERROR unless defined $code;
    $error = 'HTTP/2 stream failure'
        unless defined($error) && length($error);

    my $stream = $self->stream_for_id($stream_id);

    if ($stream && !$stream->is_terminal) {
        $stream->_fail($error);
        $self->_invoke_stream_error($stream, $error);
    }

    eval { $self->{session}->submit_rst_stream($stream_id, $code) };
    $self->_mark_output_pending;
    return;
}

sub _invoke_stream_error {
    my ($self, $stream, $error) = @_;

    my $result = $stream->_invoke('on_error', $error);
    if ($result ne '1') {
        my $callback = $self->{callbacks}{on_error};
        eval { $callback->($stream, "$result") } if $callback;
        return;
    }

    my $callback = $self->{callbacks}{on_error};
    eval { $callback->($stream, $error) } if $callback;
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
            $stream->_fail($error);
            $self->_invoke_stream_error($stream, $error);
        }
        else {
            $stream->request->mark_complete
                unless $stream->request->is_complete;
            $stream->response->mark_complete
                if $stream->response
                    && !$stream->response->is_complete;
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
