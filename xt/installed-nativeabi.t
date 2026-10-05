use strict;
use warnings;

BEGIN {
    unless ($ENV{UNBLOCK_HTTP2_INSTALL_ROOT}) {
        require Test::More;
        Test::More::plan(
            skip_all => 'set UNBLOCK_HTTP2_INSTALL_ROOT for staged install test',
        );
    }
}

use Config;
use ExtUtils::CBuilder;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Unblock::HTTP2::NativeABI;

my $install_root = File::Spec->rel2abs(
    $ENV{UNBLOCK_HTTP2_INSTALL_ROOT},
);

my $loaded_module = File::Spec->rel2abs(
    $INC{'Unblock/HTTP2/NativeABI.pm'},
);

ok index($loaded_module, $install_root) == 0,
    'NativeABI was loaded from the staged installation';

my $include_dir = File::Spec->rel2abs(
    Unblock::HTTP2::NativeABI::native_include_dir(),
);
ok -d $include_dir,
    'staged NativeABI include directory exists';
ok index($include_dir, $install_root) == 0,
    'NativeABI include directory belongs to the staged installation';

my $header_path = File::Spec->rel2abs(
    Unblock::HTTP2::NativeABI::header_path(),
);
ok -f $header_path,
    'staged NativeABI header exists';
ok index($header_path, $install_root) == 0,
    'NativeABI header belongs to the staged installation';

open my $fh, '<', $header_path
    or die "could not read $header_path: $!";
local $/;
my $installed_header = <$fh>;
close $fh
    or die "could not close $header_path: $!";

is Unblock::HTTP2::NativeABI::c_header(), $installed_header,
    'c_header returns the exact installed header';

my $definition = Unblock::HTTP2::NativeABI::definition();

is $definition->{abi_version}, 1,
    'staged native ABI reports version 1';
ok $definition->{struct_size},
    'staged native ABI reports a structure size';
ok $definition->{operations_address},
    'staged native ABI reports an operations address';
is $definition->{provider}->(), $definition->{operations_address},
    'staged provider returns the advertised operations address';

my $tmp = tempdir(CLEANUP => 1);
my $source = File::Spec->catfile($tmp, 'nativeabi_probe.c');

open my $probe, '>', $source
    or die "could not write $source: $!";

my $expected_size = 0 + $definition->{struct_size};

print {$probe} <<"C";
#include "unblock_http2_native_abi.h"

#if UB_HTTP2_NATIVE_ABI_VERSION != 1U
#error unexpected Unblock::HTTP2 NativeABI version
#endif

typedef char ub_http2_native_struct_size_matches[
    sizeof(ub_http2_native_ops_v1) == $expected_size ? 1 : -1
];

int
ub_http2_native_abi_probe(void)
{
    return (int)sizeof(ub_http2_native_ops_v1);
}
C

close $probe
    or die "could not close $source: $!";

my $core_include = File::Spec->catdir(
    $Config{archlib},
    'CORE',
);

my $builder = ExtUtils::CBuilder->new(quiet => 1);
my $object = eval {
    $builder->compile(
        source       => $source,
        include_dirs => [
            $include_dir,
            $core_include,
        ],
    );
};

ok $object && -f $object,
    'external C consumer compiles against the installed NativeABI header';
diag $@ if $@;

done_testing;
