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
my $long = File::Spec->catfile(
    't', 'sample-tests', 'long_top_level_name_for_width_truncation'
);

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
    $out =~ s/\r\n/\n/g;
    $out =~ s/\r/\n/g;
    return $out;
}

sub run_prove_file {
    my @args = @_;
    local $ENV{HARNESS_NOTTY} = 1;
    my $out = util::stdout_of(
        sub {
            system( $^X, $prove, '--norc', @args ) == 0
              or die "prove failed: $?";
        }
    );
    $out =~ s/\r\n/\n/g;
    $out =~ s/\r/\n/g;
    return $out;
}

my $out = run_prove($sample);
unlike( $out, qr/^  outer\b/m, 'no expanded subtests without -x' );

$out = run_prove($long);
like(
    $out,
    qr/^\Q$long\E\s/m,
    'no truncation for long top-level name without --width'
);

$out = run_prove( '--width=36', $long );
my $top_trailer = length(' x');
my $top_max = 36 - $top_trailer - 4 - 1;
my $top_truncated
  = length($long) > $top_max
  ? substr( $long, 0, $top_max - 3 ) . '...'
  : $long;
like(
    $out,
    qr/^\Q$top_truncated\E\s/m,
    'truncates long top-level name with --width'
);

$out = run_prove( '-x', $sample );
my $ok_token = qr/(?:\x{2713}|\xE2\x9C\x93)/;
like( $out, qr/^  outer\b.*$ok_token/m, 'expanded top-level subtest' );
like( $out, qr/^  outer\b.*1\/3/m, 'subtest progress shown' );
unlike( $out, qr/^    inner\b/m, 'nested subtest suppressed at depth 1' );

$out = run_prove( '--expand', '2', $sample );
like( $out, qr/^  outer\b.*$ok_token/m,
    'expanded top-level subtest at depth 2' );
like( $out, qr/\s+inner\b.*$ok_token/m,
    'expanded nested subtest at depth 2' );

$out = run_prove( '-x', '-v', $sample );
unlike( $out, qr/^  outer\b.*\.+/m, 'no expanded lines with -v' );

$out = run_prove( '-x', '-j2', $sample, $simple );
like( $out, qr/^  outer\b.*$ok_token/m, 'expanded subtest in parallel mode' );

$out = run_prove( '-x', '--width=36', $sample );
my ($progress_line) = $out =~ /^(  outer.*\b\d+\/\d+\b.*)$/m;
my ($final_line)    = $out =~ /^(  outer.*$ok_token.*)$/m;
ok( $progress_line && $final_line, 'expanded subtest lines captured' );
my ($progress_prefix) = $progress_line =~ /^(.*?)\d+\/\d+/;
my ($final_prefix)    = $final_line =~ /^(.*?)$ok_token/;
is(
    length($progress_prefix),
    length($final_prefix),
    'expanded subtest trailers align'
);

my $long_subtest = 'a very long subtest name that should be truncated';
my $subtest_trailer = length(' x');
my $subtest_indent = 4;
my $subtest_max = 36 - $subtest_trailer - 4 - ( $subtest_indent + 1 );
my $subtest_truncated
  = length($long_subtest) > $subtest_max
  ? substr( $long_subtest, 0, $subtest_max - 3 ) . '...'
  : $long_subtest;
$out = run_prove( '--expand', '2', '--width=36', $sample );
like(
    $out,
    qr/^\s{$subtest_indent}\Q$subtest_truncated\E\s/m,
    'long subtest name truncated'
);

$out = run_prove_file( '-x', $sample );
unlike(
    $out,
    qr/^  outer\b.*\d+\/\d+/m,
    'file formatter omits subtest progress'
);
like( $out, qr/^  outer\b.*\bok\b/m, 'file formatter shows subtest final' );
like(
    $out,
    qr/^\Q$sample\E\b.*\bok\b/m,
    'file formatter includes test name in final line'
);

done_testing;
