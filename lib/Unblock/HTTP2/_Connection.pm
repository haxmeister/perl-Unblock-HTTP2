package Unblock::HTTP2::_Connection;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use utf8 ();

our $VERSION = '0.001';

sub _initialize_connection {
    my ($self, $session) = @_;

    croak 'HTTP/2 session must be an object'
        unless blessed($session);

    $self->{session}         = $session;
    $self->{streams}         = {};
    $self->{closed}          = 0;
    $self->{in_session_call} = 0;
    $self->{close_pending}   = undef;
    $self->{pending_drain}   = {};
    $self->{output_pending}  = 0;
    return $self;
}

sub session {
    return $_[0]{session};
}

sub is_closed {
    return $_[0]{closed} ? 1 : 0;
}

sub stream_count {
    return scalar keys %{ $_[0]{streams} };
}

sub stream_for_id {
    my ($self, $stream_id) = @_;
    return $self->{streams}{$stream_id};
}

sub want_read {
    my ($self) = @_;
    return 0 if $self->{closed} || !$self->{session};
    return $self->{session}->want_read ? 1 : 0;
}

sub want_write {
    my ($self) = @_;
    return 0 if $self->{closed} || !$self->{session};
    return $self->{output_pending} ? 1 : 0;
}

sub _mark_output_pending {
    my ($self) = @_;
    $self->{output_pending} = 1
        unless $self->{closed};
    return;
}

sub input {
    my ($self, $bytes) = @_;

    croak 'input(): connection is closed' if $self->{closed};
    croak 'input(): bytes must be a scalar' if ref($bytes);
    return 0 unless defined($bytes) && length($bytes);
    croak 'input(): cannot be called from an HTTP/2 session callback'
        if $self->{in_session_call};

    my $consumed;
    {
        local $self->{in_session_call} = 1;
        $consumed = $self->{session}->mem_recv($bytes);
    }

    croak 'input(): nghttp2 did not consume complete input'
        unless defined($consumed) && $consumed == length($bytes);

    if (defined $self->{close_pending}) {
        $self->_finish_close(delete $self->{close_pending});
        return $consumed;
    }

    $self->_mark_output_pending;
    $self->_after_session_call;
    return $consumed;
}

sub output {
    my ($self) = @_;

    croak 'output(): connection is closed' if $self->{closed};
    croak 'output(): cannot be called from an HTTP/2 session callback'
        if $self->{in_session_call};

    return '' unless $self->{output_pending};

    my $bytes;
    {
        local $self->{in_session_call} = 1;
        $bytes = $self->{session}->mem_send;
    }

    if (defined $self->{close_pending}) {
        $self->_finish_close(delete $self->{close_pending});
        return defined($bytes) ? $bytes : '';
    }

    $bytes = '' unless defined $bytes;
    $self->{output_pending} =
        length($bytes) && $self->{session}->want_write ? 1 : 0;

    $self->_after_session_call;
    return $bytes;
}

sub _register_stream {
    my ($self, $stream) = @_;
    $self->{streams}{ $stream->id } = $stream;
    return $stream;
}

sub _remove_stream {
    my ($self, $stream_id) = @_;
    delete $self->{pending_drain}{$stream_id};
    return delete $self->{streams}{$stream_id};
}

sub _queue_drain {
    my ($self, $stream_id) = @_;
    $self->{pending_drain}{$stream_id} = 1;
    return;
}

sub _after_session_call {
    my ($self) = @_;

    my @ids = keys %{ $self->{pending_drain} };
    $self->{pending_drain} = {};

    for my $stream_id (@ids) {
        my $stream = $self->{streams}{$stream_id} or next;
        next if $stream->is_terminal;

        my $result = $stream->_drain;
        next if $result && $result eq '1';

        if ($result && $result ne '1') {
            $self->_stream_failure($stream_id, "$result");
        }
    }

    return;
}

sub _body_bytes {
    my ($self, $operation, $bytes) = @_;

    croak "$operation: body must be a scalar" if ref($bytes);
    $bytes = '' unless defined $bytes;

    my $copy = "$bytes";
    if (utf8::is_utf8($copy)) {
        croak "$operation: body must be a byte string"
            unless utf8::downgrade($copy, 1);
    }

    return $copy;
}

sub close {
    my ($self, $error) = @_;
    return $self if $self->{closed};

    $error = 'HTTP/2 connection closed'
        unless defined($error) && length($error);

    if ($self->{in_session_call}) {
        $self->{close_pending} = "$error";
        return $self;
    }

    return $self->_finish_close($error);
}

sub _finish_close {
    my ($self, $error) = @_;
    return $self if $self->{closed};

    $self->{closed} = 1;

    for my $stream (values %{ $self->{streams} }) {
        next if $stream->is_terminal;
        $stream->_fail($error);
        $self->_invoke_stream_error($stream, $error);
    }

    $self->{streams} = {};
    $self->{pending_drain} = {};
    $self->{session} = undef;
    return $self;
}

sub _invoke_stream_error {
    my ($self, $stream, $error) = @_;
    my $result = $stream->_invoke('on_error', $error);
    return $result;
}

1;
