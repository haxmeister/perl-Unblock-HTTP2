use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

require Alien::nghttp2;

my $nghttp2_cflags = Alien::nghttp2->cflags;
my $nghttp2_libs   = Alien::nghttp2->libs;
my $nghttp2_define = $^O eq 'MSWin32' ? ' -DNGHTTP2_STATICLIB' : '';

my $dist_version = MM->parse_version('lib/Unblock/HTTP2.pm');

my @public_modules = qw(
    Unblock::HTTP2
    Unblock::HTTP2::Client
    Unblock::HTTP2::Server
    Unblock::HTTP2::Transaction
    Unblock::HTTP2::Stream
);

my %provides = map {
    my $file = "lib/$_.pm";
    $file =~ s{::}{/}g;
    $_ => {
        file    => $file,
        version => $dist_version,
    };
} @public_modules;

WriteMakefile(
    NAME             => 'Unblock::HTTP2',
    VERSION_FROM     => 'lib/Unblock/HTTP2.pm',
    ABSTRACT_FROM    => 'lib/Unblock/HTTP2.pm',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '5.016',

    CONFIGURE_REQUIRES => {
        'Alien::nghttp2'       => '0.003',
        'ExtUtils::MakeMaker'  => '6.64',
    },

    PREREQ_PM => {
        'Carp'          => 0,
        'Scalar::Util'  => 0,
        'Uniform::HTTP' => '0.05',
        'XSLoader'      => 0,
    },

    TEST_REQUIRES => {
        'Test::More' => 0,
    },

    XS      => { 'nghttp2.xs' => 'nghttp2.c' },
    OBJECT  => '$(O_FILES)',
    CCFLAGS => "$Config{ccflags} $nghttp2_cflags$nghttp2_define",
    LIBS    => [ $nghttp2_libs ],

    META_MERGE => {
        'meta-spec' => { version => 2 },
        provides    => \%provides,
        resources   => {
            homepage => 'https://github.com/haxmeister/perl-Unblock-HTTP2',
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
                Unblock::HTTP2::_nghttp2
                Unblock::HTTP2::_nghttp2::Session
            )],
        },
    },

    clean => {
        FILES => 'Unblock-HTTP2-* nghttp2.c nghttp2.o nghttp2.obj HTTP2.bs',
    },
);
