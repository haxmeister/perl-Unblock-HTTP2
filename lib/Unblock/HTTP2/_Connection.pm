package Unblock::HTTP2::_Connection;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use utf8 ();

our $VERSION = '0.001';

my @SETTING_NAMES = qw(
    header_table_size
    enable_push
    max_concurrent_streams
    initial_window_size
    max_frame_size
    max_header_list_size
    enable_connect_protocol
);

my %SETTING_ID = (
    header_table_size       => 1,
    enable_push             => 2,
    max_concurrent_streams  => 3,
    initial_window_size     => 4,
    max_frame_size          => 5,
    max_header_list_size    => 6,
    enable_connect_protocol => 8,
);

my %SETTING_NAME = reverse %SETTING_ID;


sub _initialize_connection {
    my ($self, $session, %option) = @_;

    croak 'HTTP/2 session must be an object'
        unless blessed($session);

    my $role = delete $option{role};
    my $callbacks = delete($option{callbacks}) || {};

    croak 'HTTP/2 connection role must be client or server'
        unless defined($role) && ($role eq 'client' || $role eq 'server');
    croak 'HTTP/2 connection callbacks must be a hash reference'
        unless ref($callbacks) eq 'HASH';
    croak 'unknown HTTP/2 connection options: ' . join(', ', sort keys %option)
        if %option;

    $self->{session}          = $session;
    $self->{role}             = $role;
    $self->{callbacks}        = $callbacks;
    $self->{streams}          = {};
    $self->{closed}           = 0;
    $self->{in_session_call}  = 0;
    $self->{close_pending}    = undef;
    $self->{pending_drain}    = {};
    $self->{local_settings}   = {};
    $self->{peer_settings}    = {};
    $self->{settings_pending} = [];

    $self->_refresh_peer_settings;
    return $self;
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
    return $self->{session}->want_write ? 1 : 0;
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

    $self->_after_session_call;
    return $consumed;
}

sub output {
    my ($self) = @_;

    croak 'output(): connection is closed' if $self->{closed};
    croak 'output(): cannot be called from an HTTP/2 session callback'
        if $self->{in_session_call};

    return '' unless $self->{session}->want_write;

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

sub _consume_stream_body {
    my ($self, $stream, $bytes) = @_;

    croak 'consume(): connection is closed'
        if $self->{closed} || !$self->{session};
    return unless $bytes;

    $self->{session}->consume_stream($stream->id, $bytes);
    return;
}

sub ping {
    my ($self, $opaque) = @_;

    croak 'ping(): connection is closed'
        if $self->{closed} || !$self->{session};
    croak 'ping(): opaque data is required'
        unless defined $opaque;

    my $bytes = $self->_body_bytes('ping()', $opaque);
    croak 'ping(): opaque data must be exactly 8 bytes'
        unless length($bytes) == 8;

    $self->{session}->submit_ping($bytes);
    return $self;
}

sub _handle_ping_frame {
    my ($self, $frame) = @_;
    return 0 unless (($frame->{type} // -1) == 6);

    my $opaque = defined($frame->{opaque_data})
        ? "$frame->{opaque_data}"
        : '';

    my $callback = (($frame->{flags} || 0) & 0x1)
        ? 'on_ping_ack'
        : 'on_ping';

    $self->_invoke_control_callback($callback, $opaque);
    return 1;
}

sub local_settings {
    my ($self) = @_;
    return { %{ $self->{local_settings} || {} } };
}

sub local_setting {
    my ($self, $name) = @_;
    croak 'local_setting(): setting name is required'
        unless defined($name) && !ref($name) && length($name);
    croak "local_setting(): unknown setting '$name'"
        unless exists $SETTING_ID{$name};
    return $self->{local_settings}{$name};
}

sub peer_settings {
    my ($self) = @_;
    $self->_refresh_peer_settings
        if !$self->{closed} && $self->{session};
    return { %{ $self->{peer_settings} || {} } };
}

sub peer_setting {
    my ($self, $name) = @_;
    croak 'peer_setting(): setting name is required'
        unless defined($name) && !ref($name) && length($name);
    croak "peer_setting(): unknown setting '$name'"
        unless exists $SETTING_ID{$name};

    $self->_refresh_peer_settings
        if !$self->{closed} && $self->{session};
    return $self->{peer_settings}{$name};
}

sub settings_pending {
    my ($self) = @_;
    return scalar @{ $self->{settings_pending} || [] };
}

sub update_settings {
    my ($self, @settings) = @_;

    croak 'update_settings(): connection is closed'
        if $self->{closed} || !$self->{session};

    my $input;
    if (@settings == 1 && ref($settings[0]) eq 'HASH') {
        $input = $settings[0];
    }
    elsif (@settings && @settings % 2 == 0) {
        $input = { @settings };
    }
    else {
        croak 'update_settings(): expected a hash reference or key/value pairs';
    }

    $self->_submit_settings('update_settings()', $input);
    return $self;
}

sub _submit_settings {
    my ($self, $operation, $input) = @_;
    my $settings = $self->_validate_settings($operation, $input);

    $self->{session}->submit_settings($settings);

    my %submitted = %$settings;
    push @{ $self->{settings_pending} }, \%submitted;
    @{$self->{local_settings}}{keys %submitted} = values %submitted;

    if (exists $submitted{max_header_list_size}) {
        $self->{max_header_list_size} = $submitted{max_header_list_size};
    }
    if ($self->{role} eq 'server') {
        if (exists $submitted{max_concurrent_streams}) {
            $self->{max_concurrent_streams} = $submitted{max_concurrent_streams};
        }
        if (exists $submitted{enable_connect_protocol}) {
            $self->{enable_connect_protocol}
                = $submitted{enable_connect_protocol};
        }
    }

    return $self;
}

sub _validate_settings {
    my ($self, $operation, $input) = @_;

    croak "$operation settings must be a hash reference"
        unless ref($input) eq 'HASH';
    croak "$operation requires at least one setting"
        unless keys %$input;

    my %settings;
    for my $name (keys %$input) {
        croak "$operation unknown setting '$name'"
            unless exists $SETTING_ID{$name};

        my $value = $input->{$name};
        croak "$operation $name must be an unsigned integer"
            unless defined($value) && !ref($value)
                && "$value" =~ /\A[0-9]+\z/;

        $value = 0 + $value;

        if ($name eq 'enable_push'
            || $name eq 'enable_connect_protocol') {
            croak "$operation $name must be zero or one"
                unless $value == 0 || $value == 1;
        }
        elsif ($name eq 'initial_window_size') {
            croak "$operation initial_window_size exceeds HTTP/2 maximum"
                if $value > 2_147_483_647;
        }
        elsif ($name eq 'max_frame_size') {
            croak "$operation max_frame_size must be between 16384 and 16777215"
                if $value < 16_384 || $value > 16_777_215;
        }
        else {
            croak "$operation $name exceeds HTTP/2 maximum"
                if $value > 4_294_967_295;
        }

        $settings{$name} = $value;
    }

    if (exists $settings{enable_connect_protocol}
        && ($self->{local_settings}{enable_connect_protocol} || 0) == 1
        && $settings{enable_connect_protocol} == 0) {
        croak "$operation enable_connect_protocol cannot return to zero after one";
    }

    if ($self->{role} eq 'client') {
        croak "$operation enable_push=1 is unsupported because server push is disabled"
            if ($settings{enable_push} || 0) == 1;
    }
    elsif (exists $settings{enable_push}
        && $settings{enable_push} != 0) {
        croak "$operation a server may only send enable_push=0";
    }

    return \%settings;
}

sub _refresh_peer_settings {
    my ($self) = @_;
    return $self->{peer_settings}
        unless $self->{session};

    my %settings;
    for my $name (@SETTING_NAMES) {
        $settings{$name}
            = 0 + $self->{session}->remote_setting($SETTING_ID{$name});
    }

    # RFC 9113 defines a server's initial ENABLE_PUSH value as effectively 0.
    $settings{enable_push} = 0 if $self->{role} eq 'client';

    $self->{peer_settings} = \%settings;
    return $self->{peer_settings};
}

sub _handle_settings_frame {
    my ($self, $frame) = @_;
    return 0 unless (($frame->{type} // -1) == 4);

    if (($frame->{flags} || 0) & 0x1) {
        my $acked = shift @{ $self->{settings_pending} };
        $acked ||= {};
        $self->_invoke_control_callback(
            'on_settings_ack',
            { %$acked },
        );
        return 1;
    }

    my %changed;
    for my $pair (@{ $frame->{settings} || [] }) {
        next unless ref($pair) eq 'ARRAY' && @$pair >= 2;
        my ($id, $value) = @$pair;
        my $name = $SETTING_NAME{$id};
        next unless defined $name;
        $changed{$name} = 0 + $value;
    }

    my $peer = $self->_refresh_peer_settings;
    $self->_invoke_control_callback(
        'on_settings',
        { %$peer },
        \%changed,
    );

    return 1;
}

sub _invoke_control_callback {
    my ($self, $name, @args) = @_;
    my $callback = $self->{callbacks}{$name} or return 1;

    my $ok = eval {
        $callback->($self, @args);
        1;
    };

    return 1 if $ok;

    my $error = "$name callback failed";
    $error .= ": $@" if length $@;
    $self->close($error);
    return 0;
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
