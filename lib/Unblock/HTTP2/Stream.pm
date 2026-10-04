package Unblock::HTTP2::Stream;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed weaken);

our $VERSION = '0.001';

my %TERMINAL = map { $_ => 1 } qw(complete cancelled error);

sub _new {
    my ($class, %args) = @_;

    my $connection = delete $args{connection};
    my $id         = delete $args{id};
    my $request    = delete $args{request};
    my $callbacks  = delete($args{callbacks}) || {};

    croak 'Stream requires a connection object'
        unless blessed($connection);
    croak 'Stream id must be a positive integer'
        unless defined($id) && !ref($id)
            && $id =~ /\A[0-9]+\z/ && $id > 0;
    croak 'Stream callbacks must be a hash reference'
        unless ref($callbacks) eq 'HASH';
    croak 'unknown Stream option: ' . join(', ', sort keys %args)
        if %args;

    my $self = bless {
        connection => $connection,
        id         => 0 + $id,
        request    => $request,
        response   => undef,
        callbacks  => { %$callbacks },
        state      => 'active',
        error      => undef,
    }, $class;

    weaken($self->{connection});
    return $self;
}

sub id           { return $_[0]{id} }
sub request      { return $_[0]{request} }
sub response     { return $_[0]{response} }
sub state        { return $_[0]{state} }
sub error        { return $_[0]{error} }
sub is_complete  { return $_[0]{state} eq 'complete' ? 1 : 0 }
sub is_cancelled { return $_[0]{state} eq 'cancelled' ? 1 : 0 }
sub is_terminal  { return $TERMINAL{$_[0]{state}} ? 1 : 0 }

sub write {
    my ($self, $bytes) = @_;
    croak 'write(): Stream is already terminal' if $self->is_terminal;

    my $connection = $self->{connection}
        or croak 'write(): HTTP/2 connection is no longer available';

    return $connection->_write_stream_body($self, $bytes, 0, 'write');
}

sub end {
    my ($self, @args) = @_;
    croak 'end(): accepts at most one final byte string' if @args > 1;
    croak 'end(): Stream is already terminal' if $self->is_terminal;

    my $connection = $self->{connection}
        or croak 'end(): HTTP/2 connection is no longer available';

    my $bytes = @args ? $args[0] : '';
    $connection->_write_stream_body($self, $bytes, 1, 'end');
    return $self;
}

sub respond {
    my ($self, $response, %option) = @_;
    croak 'respond(): Stream is already terminal' if $self->is_terminal;

    my $connection = $self->{connection}
        or croak 'respond(): HTTP/2 connection is no longer available';

    $connection->_respond_stream($self, $response, %option);
    return $self;
}

sub cancel {
    my ($self) = @_;
    return $self if $self->is_terminal;

    my $connection = $self->{connection};
    if ($connection) {
        $connection->_cancel_stream($self);
    }
    else {
        $self->_mark_cancelled;
    }

    return $self;
}

sub _set_response {
    my ($self, $response) = @_;
    croak 'Stream already has a Response' if $self->{response};
    $self->{response} = $response;
    return $response;
}

sub _mark_complete {
    my ($self) = @_;
    return $self if $self->is_terminal;
    $self->{state} = 'complete';
    return $self;
}

sub _mark_cancelled {
    my ($self) = @_;
    return $self if $self->is_terminal;
    $self->{state} = 'cancelled';
    return $self;
}

sub _fail {
    my ($self, $error) = @_;
    return $self if $self->is_terminal;

    $error = 'HTTP/2 stream failed'
        unless defined($error) && length($error);

    $self->{state} = 'error';
    $self->{error} = "$error";
    return $self;
}

sub _invoke {
    my ($self, $name, @args) = @_;
    my $callback = $self->{callbacks}{$name} or return 1;

    my $ok = eval {
        $callback->($self, @args);
        1;
    };

    return $ok ? 1 : $@;
}

sub _drain {
    my ($self) = @_;
    my $result = $self->_invoke('on_drain');
    return $result;
}

1;

__END__

=head1 NAME

Unblock::HTTP2::Stream - One HTTP/2 stream

=head1 DESCRIPTION

A Stream is one HTTP/2 request/response exchange inside a multiplexed
connection. It owns stream lifecycle, not the underlying socket or event loop.

C<request()> and C<response()> return Uniform HTTP message objects.

For a streaming local body, C<write()> queues bytes and C<end()> finishes body
production. C<write()> returns false when the per-stream cooperative high-water
mark is reached. The bytes are still accepted; wait for C<on_drain> before
producing more.

Server streams use C<respond()> to submit a Uniform response.

=cut
