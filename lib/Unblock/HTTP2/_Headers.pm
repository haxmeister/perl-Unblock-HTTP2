package Unblock::HTTP2::_Headers;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

use Uniform::HTTP::Request 0.03;
use Uniform::HTTP::Response 0.03;

our $VERSION = '0.001';

my %FORBIDDEN = map { $_ => 1 } qw(
    connection
    keep-alive
    proxy-connection
    transfer-encoding
    upgrade
);

sub _pairs {
    my ($operation, $pairs) = @_;

    croak "$operation: header block must be an array reference"
        unless ref($pairs) eq 'ARRAY';

    for my $pair (@$pairs) {
        croak "$operation: each field must be a [name, value] pair"
            unless ref($pair) eq 'ARRAY' && @$pair == 2;
        croak "$operation: field name and value must be defined scalars"
            if !defined($pair->[0]) || ref($pair->[0])
            || !defined($pair->[1]) || ref($pair->[1]);
    }

    return $pairs;
}

sub _normal_field {
    my ($operation, $name, $value) = @_;

    croak "$operation: HTTP/2 field names must be lowercase"
        unless $name eq lc $name;

    croak "$operation: HTTP/2 forbids connection-specific field '$name'"
        if $FORBIDDEN{$name};

    croak "$operation: HTTP/2 TE is limited to trailers"
        if $name eq 'te' && lc($value) ne 'trailers';

    return [ $name, $value ];
}

sub _split_header_block {
    my ($operation, $pairs, $allowed) = @_;
    _pairs($operation, $pairs);

    my %pseudo;
    my @normal;
    my $saw_normal = 0;

    for my $pair (@$pairs) {
        my ($name, $value) = @$pair;

        if (substr($name, 0, 1) eq ':') {
            croak "$operation: pseudo-header follows a regular field"
                if $saw_normal;
            croak "$operation: unsupported pseudo-header '$name'"
                unless $allowed->{$name};
            croak "$operation: duplicate pseudo-header '$name'"
                if exists $pseudo{$name};
            $pseudo{$name} = $value;
            next;
        }

        $saw_normal = 1;
        push @normal, _normal_field($operation, $name, $value);
    }

    return (\%pseudo, \@normal);
}

sub request_from_headers {
    my ($class, $pairs, %option) = @_;

    my $end_stream = delete($option{end_stream}) ? 1 : 0;
    croak 'request_from_headers(): unknown options: '
        . join(', ', sort keys %option)
        if %option;

    my ($pseudo, $normal) = _split_header_block(
        'request_from_headers()',
        $pairs,
        {
            ':method'    => 1,
            ':scheme'    => 1,
            ':authority' => 1,
            ':path'      => 1,
        },
    );

    my $method = $pseudo->{':method'};
    croak 'request_from_headers(): missing :method'
        unless defined($method) && length($method);

    my ($target, $scheme, $authority);

    if (uc($method) eq 'CONNECT') {
        croak 'request_from_headers(): CONNECT requires :authority'
            unless defined($pseudo->{':authority'})
                && length($pseudo->{':authority'});
        croak 'request_from_headers(): ordinary CONNECT must omit :scheme and :path'
            if exists($pseudo->{':scheme'}) || exists($pseudo->{':path'});

        $authority = $pseudo->{':authority'};
        $target = $authority;
    }
    else {
        croak 'request_from_headers(): missing :scheme'
            unless defined($pseudo->{':scheme'})
                && length($pseudo->{':scheme'});
        croak 'request_from_headers(): missing :path'
            unless defined($pseudo->{':path'})
                && length($pseudo->{':path'});
        croak 'request_from_headers(): missing :authority'
            unless defined($pseudo->{':authority'})
                && length($pseudo->{':authority'});

        $scheme = $pseudo->{':scheme'};
        $authority = $pseudo->{':authority'};
        $target = $pseudo->{':path'};
    }

    my $request = Uniform::HTTP::Request->new(
        method    => $method,
        target    => $target,
        version   => '2',
        defined($scheme) ? (scheme => $scheme) : (),
        authority => $authority,
        headers   => $normal,
    );

    $request->mark_incomplete unless $end_stream;
    $request->commit;
    return $request;
}

sub response_from_headers {
    my ($class, $pairs, %option) = @_;

    my $end_stream = delete($option{end_stream}) ? 1 : 0;
    croak 'response_from_headers(): unknown options: '
        . join(', ', sort keys %option)
        if %option;

    my ($pseudo, $normal) = _split_header_block(
        'response_from_headers()',
        $pairs,
        { ':status' => 1 },
    );

    my $status = $pseudo->{':status'};
    croak 'response_from_headers(): missing :status'
        unless defined($status) && length($status);

    my $response = Uniform::HTTP::Response->new(
        status  => $status,
        version => '2',
        headers => $normal,
    );

    $response->mark_incomplete unless $end_stream;
    $response->commit;
    return $response;
}

sub _request_contract {
    my ($request) = @_;
    return unless blessed($request);

    for my $method (qw(
        method target scheme authority version
        header_count header_name header_value
        is_mutable commit mark_incomplete mark_complete
        has_buffered_body body
    )) {
        return unless $request->can($method);
    }

    return 1;
}

sub _response_contract {
    my ($response) = @_;
    return unless blessed($response);

    for my $method (qw(
        status version header_count header_name header_value
        is_mutable commit mark_incomplete mark_complete
        has_buffered_body body
    )) {
        return unless $response->can($method);
    }

    return 1;
}

sub normal_fields {
    my ($class, $operation, $message) = @_;

    my @fields;
    for my $index (0 .. $message->header_count - 1) {
        my $name = lc $message->header_name($index);
        my $value = $message->header_value($index);
        push @fields, _normal_field($operation, $name, $value);
    }

    return \@fields;
}

sub request_headers {
    my ($class, $request) = @_;

    croak 'request_headers(): requires the Uniform HTTP request contract'
        unless _request_contract($request);
    croak 'request_headers(): Request version must be 2'
        unless defined($request->version) && $request->version eq '2';

    my @block = ([ ':method', $request->method ]);

    if (uc($request->method) eq 'CONNECT') {
        my $authority = $request->authority;
        croak 'request_headers(): CONNECT requires authority'
            unless defined($authority) && length($authority);
        push @block, [ ':authority', $authority ];
    }
    else {
        my $scheme = $request->scheme;
        my $authority = $request->authority;

        croak 'request_headers(): HTTP/2 Request requires scheme'
            unless defined($scheme) && length($scheme);
        croak 'request_headers(): HTTP/2 Request requires authority'
            unless defined($authority) && length($authority);

        push @block,
            [ ':scheme', $scheme ],
            [ ':authority', $authority ],
            [ ':path', $request->target ];
    }

    push @block, @{ $class->normal_fields('request_headers()', $request) };
    return \@block;
}

sub response_headers {
    my ($class, $response) = @_;

    croak 'response_headers(): requires the Uniform HTTP response contract'
        unless _response_contract($response);
    croak 'response_headers(): Response version must be 2'
        unless defined($response->version) && $response->version eq '2';

    my @block = ([ ':status', '' . $response->status ]);
    push @block, @{ $class->normal_fields('response_headers()', $response) };
    return \@block;
}

1;
