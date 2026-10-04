use strict;
use warnings;
use ExtUtils::MakeMaker;

my @public_modules = qw(
    Unblock::HTTP2
    Unblock::HTTP2::Client
    Unblock::HTTP2::Server
    Unblock::HTTP2::Stream
);

my %provides = map {
    my $file = "lib/$_.pm";
    $file =~ s{::}{/}g;
    $_ => {
        file    => $file,
        version => '0.001',
    };
} @public_modules;

WriteMakefile(
    NAME             => 'Unblock::HTTP2',
    VERSION_FROM     => 'lib/Unblock/HTTP2.pm',
    ABSTRACT         => 'Event-loop and operating-system neutral HTTP/2 engine',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '5.016',

    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '6.64',
    },

    PREREQ_PM => {
        'Carp'                => 0,
        'Net::HTTP2::nghttp2' => '0.011',
        'Scalar::Util'        => 0,
        'Test::More'          => 0,
        'Uniform::HTTP'       => '0.04',
    },

    META_MERGE => {
        'meta-spec' => { version => 2 },
        provides    => \%provides,
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/haxmeister/perl-Unblock-HTTP2.git',
                web  => 'https://github.com/haxmeister/perl-Unblock-HTTP2',
            },
            bugtracker => {
                web => 'https://github.com/haxmeister/perl-Unblock-HTTP2/issues',
            },
        },
        no_index => {
            package => [qw(
                Unblock::HTTP2::_Connection
                Unblock::HTTP2::_Headers
            )],
        },
    },

    clean => {
        FILES => 'Unblock-HTTP2-*',
    },
);
