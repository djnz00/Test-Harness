#!/usr/bin/perl -w

BEGIN {
    unshift @INC, 't/lib';
}

use strict;
use warnings;
use Test::More;
use File::Spec;
use IO::c55Capture;    # for util

my $prove = File::Spec->catfile( 'bin', 'prove' );
my $sample = File::Spec->catfile( 't', 'sample-tests', 'subtest_expand' );
my $simple = File::Spec->catfile( 't', 'sample-tests', 'simple' );

sub run_prove {
    my @args = @_;
    local $ENV{HARNESS_NOTTY} = 1;
    my $out = util::stdout_of(
        sub {
            system(
                $^X, $prove, '--norc',
                '--formatter=TAP::Formatter::Console',
                @args
            ) == 0
              or die "prove failed: $?";
        }
    );
    $out =~ s/\r//g;
    return $out;
}

my $out = run_prove($sample);
unlike( $out, qr/^  outer\b/m, 'no expanded subtests without -x' );

$out = run_prove( '-x', $sample );
like( $out, qr/^  outer\b.*\bok\b/m, 'expanded top-level subtest' );
like( $out, qr/^  outer\b.*1\/2/m, 'subtest progress shown' );
unlike( $out, qr/^    inner\b/m, 'nested subtest suppressed at depth 1' );

$out = run_prove( '--expand', '2', $sample );
like( $out, qr/^  outer\b.*\bok\b/m, 'expanded top-level subtest at depth 2' );
like( $out, qr/\s+inner\b.*\bok\b/m, 'expanded nested subtest at depth 2' );

$out = run_prove( '-x', '-v', $sample );
unlike( $out, qr/^  outer\b.*\.+/m, 'no expanded lines with -v' );

$out = run_prove( '-x', '-j2', $sample, $simple );
like( $out, qr/^  outer\b.*\bok\b/m, 'expanded subtest in parallel mode' );

done_testing;
