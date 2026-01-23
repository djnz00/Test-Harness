#!/usr/bin/perl -w

BEGIN {
    delete $ENV{HARNESS_OPTIONS};
    unshift @INC, 't/lib';
}

use strict;
use warnings;

use Test::More;

use TAP::Harness;

my $HARNESS = 'TAP::Harness';

my $source_tests = 't/source_tests';
my $sample_tests = 't/sample-tests';

plan tests => 58;

# note that this test will always pass when run through 'prove'
ok $ENV{HARNESS_ACTIVE},  'HARNESS_ACTIVE env variable should be set';
ok $ENV{HARNESS_VERSION}, 'HARNESS_VERSION env variable should be set';

{
    my @output;
    no warnings 'redefine';
    require TAP::Formatter::Base;
    local *TAP::Formatter::Base::_output = sub {
        my $self = shift;
        push @output => grep { $_ ne '' }
          map {
            local $_ = $_;
            chomp;
            trim($_)
          } map { split /\n/ } @_;
    };

    # Make sure verbosity 1 overrides failures and comments.
    my $harness = TAP::Harness->new(
        {   verbosity => 1,
            failures  => 1,
            comments  => 1,
        }
    );
    my $harness_whisper    = TAP::Harness->new( { verbosity  => -1 } );
    my $harness_mute       = TAP::Harness->new( { verbosity  => -2 } );
    my $harness_directives = TAP::Harness->new( { directives => 1 } );
    my $harness_failures   = TAP::Harness->new( { failures   => 1 } );
    my $harness_comments   = TAP::Harness->new( { comments   => 1 } );
    my $harness_fandc      = TAP::Harness->new(
        {   failures => 1,
            comments => 1
        }
    );
    my $ok_token = $harness->formatter->can('_status_token')
      ? $harness->formatter->_status_token(1)
      : 'ok';

    is $harness->formatter->_format_time_ms(0), '0ms',
      '... 0ms formatting is stable';
    is $harness->formatter->_format_time_ms(0.0004), '<1ms',
      '... sub-millisecond formatting is stable';

    can_ok $harness, 'runtests';

    # normal tests in verbose mode

    ok my $aggregate = _runtests( $harness, "$source_tests/harness" ),
      '... runtests returns the aggregate';

    isa_ok $aggregate, 'TAP::Parser::Aggregator';

    chomp(@output);

    my $longest = longest_name("$source_tests/harness");
    my @expected = (
        header_for( "$source_tests/harness", $longest ),
        '1..1',
        'ok 1 - this is a test',
        $ok_token,
        'All tests successful.',
    );
    my $status           = pop @output;
    my $expected_status  = qr{^Result: PASS$};
    my $summary          = pop @output;
    my $expected_summary = qr{^Files=1, Tests=1, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)};

    is_deeply \@output, \@expected, '... the output should be correct';
    like $status, $expected_status,
      '... and the status line should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    # use an alias for test name

    @output = ();
    ok $aggregate
      = _runtests( $harness, [ "$source_tests/harness", 'My Nice Test' ] ),
      'runtests returns the aggregate';

    isa_ok $aggregate, 'TAP::Parser::Aggregator';

    chomp(@output);

    $longest = longest_name('My Nice Test');
    @expected = (
        header_for( 'My Nice Test', $longest ),
        '1..1',
        'ok 1 - this is a test',
        $ok_token,
        'All tests successful.',
    );
    $status           = pop @output;
    $expected_status  = qr{^Result: PASS$};
    $summary          = pop @output;
    $expected_summary = qr{^Files=1, Tests=1, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)};

    is_deeply \@output, \@expected, '... the output should be correct';
    like $status, $expected_status,
      '... and the status line should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    # run same test twice

    @output = ();
    ok $aggregate = _runtests(
        $harness, [ "$source_tests/harness", 'My Nice Test' ],
        [ "$source_tests/harness", 'My Nice Test Again' ]
      ),
      'runtests labels returns the aggregate';

    isa_ok $aggregate, 'TAP::Parser::Aggregator';

    chomp(@output);

    $longest = longest_name( 'My Nice Test', 'My Nice Test Again' );
    @expected = (
        header_for( 'My Nice Test', $longest ),
        '1..1',
        'ok 1 - this is a test',
        $ok_token,
        header_for( 'My Nice Test Again', $longest ),
        '1..1',
        'ok 1 - this is a test',
        $ok_token,
        'All tests successful.',
    );
    $status           = pop @output;
    $expected_status  = qr{^Result: PASS$};
    $summary          = pop @output;
    $expected_summary = qr{^Files=2, Tests=2, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)};

    is_deeply \@output, \@expected, '... the output should be correct';
    like $status, $expected_status,
      '... and the status line should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    # normal tests in quiet mode

    @output = ();
    ok _runtests( $harness_whisper, "$source_tests/harness" ),
      'Run tests with whisper';

    chomp(@output);
    $longest = longest_name("$source_tests/harness");
    @expected = (
        header_for( "$source_tests/harness", $longest ),
        $ok_token,
        'All tests successful.',
    );

    $status           = pop @output;
    $expected_status  = qr{^Result: PASS$};
    $summary          = pop @output;
    $expected_summary = qr/^Files=1, Tests=1, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;

    is_deeply \@output, \@expected, '... the output should be correct';
    like $status, $expected_status,
      '... and the status line should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    # normal tests in really_quiet mode

    @output = ();
    ok _runtests( $harness_mute, "$source_tests/harness" ), 'Run tests mute';

    chomp(@output);
    @expected = (
        'All tests successful.',
    );

    $status           = pop @output;
    $expected_status  = qr{^Result: PASS$};
    $summary          = pop @output;
    $expected_summary = qr/^Files=1, Tests=1, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;

    is_deeply \@output, \@expected, '... the output should be correct';
    like $status, $expected_status,
      '... and the status line should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    # normal tests with failures

    @output = ();
    ok _runtests( $harness, "$source_tests/harness_failure" ),
      'Run tests with failures';

    $status  = pop @output;
    $summary = pop @output;

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';

    my @summary = @output[ 9 .. $#output ];
    @output = @output[ 0 .. 8 ];

    $longest = longest_name("$source_tests/harness_failure");
    @expected = (
        header_for( "$source_tests/harness_failure", $longest ),
        '1..2',
        'ok 1 - this is a test',
        'not ok 2 - this is another test',
        q{#   Failed test 'this is another test'},
        '#   in harness_failure.t at line 5.',
        q{#          got: 'waffle'},
        q{#     expected: 'yarblokos'},
        'Failed 1/2 subtests',
    );

    is_deeply \@output, \@expected,
      '... and failing test output should be correct';

    my @expected_summary = (
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    is_deeply \@summary, \@expected_summary,
      '... and the failure summary should also be correct';

    # quiet tests with failures

    @output = ();
    ok _runtests( $harness_whisper, "$source_tests/harness_failure" ),
      'Run whisper tests with failures';

    $status   = pop @output;
    $summary  = pop @output;
    $longest = longest_name("$source_tests/harness_failure");
    @expected = (
        header_for( "$source_tests/harness_failure", $longest ),
        'Failed 1/2 subtests',
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';

    is_deeply \@output, \@expected,
      '... and failing test output should be correct';

    # really quiet tests with failures

    @output = ();
    ok _runtests( $harness_mute, "$source_tests/harness_failure" ),
      'Run mute tests with failures';

    $status   = pop @output;
    $summary  = pop @output;
    @expected = (
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';

    is_deeply \@output, \@expected,
      '... and failing test output should be correct';

    # only show directives

    @output = ();
    ok _runtests(
        $harness_directives,
        "$source_tests/harness_directives"
      ),
      'Run tests with directives';

    chomp(@output);

    $longest = longest_name("$source_tests/harness_directives");
    @expected = (
        header_for( "$source_tests/harness_directives", $longest ),
        'not ok 2 - we have a something # TODO some output',
        "ok 3 houston, we don't have liftoff # SKIP no funding",
        $ok_token,
        'All tests successful.',

        # ~TODO {{{ this should be an option
        #'Test Summary Report',
        #'-------------------',
        #"$source_tests/harness_directives (Wstat: 0 Tests: 3 Failed: 0)",
        #'Tests skipped:',
        #'3',
        # }}}
    );

    $status           = pop @output;
    $summary          = pop @output;
    $expected_summary = qr/^Files=1, Tests=3, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;

    is_deeply \@output, \@expected, '... the output should be correct';
    like $summary, $expected_summary,
      '... and the report summary should look correct';

    like $status, qr{^Result: PASS$},
      '... and the status line should be correct';

    # normal tests with bad tap

    @output = ();
    ok _runtests( $harness, "$source_tests/harness_badtap" ),
      'Run tests with bad TAP';
    chomp(@output);

    @output   = map { trim($_) } @output;
    $status   = pop @output;
    @summary  = @output[ 6 .. ( $#output - 1 ) ];
    @output   = @output[ 0 .. 5 ];
    $longest = longest_name("$source_tests/harness_badtap");
    @expected = (
        header_for( "$source_tests/harness_badtap", $longest ),
        '1..2',
        'ok 1 - this is a test',
        'not ok 2 - this is another test',
        '1..2',
        'Failed 1/2 subtests',
    );
    is_deeply \@output, \@expected,
      '... failing test output should be correct';
    like $status, qr{^Result: FAIL$},
      '... and the status line should be correct';
    @expected_summary = (
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_badtap (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
        'Parse errors: More than one plan found in TAP output',
    );
    is_deeply \@summary, \@expected_summary,
      '... and the badtap summary should also be correct';

    # coverage testing for _should_show_failures
    # only show failures

    @output = ();
    ok _runtests( $harness_failures, "$source_tests/harness_failure" ),
      'Run tests with failures only';

    chomp(@output);

    $longest = longest_name("$source_tests/harness_failure");
    @expected = (
        header_for( "$source_tests/harness_failure", $longest ),
        'not ok 2 - this is another test',
        'Failed 1/2 subtests',
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    $status  = pop @output;
    $summary = pop @output;

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';
    $expected_summary = qr/^Files=1, Tests=2, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;
    is_deeply \@output, \@expected, '... and the output should be correct';

    # check the status output for no tests

    @output = ();
    ok _runtests( $harness_failures, "$sample_tests/no_output" ),
      'Run tests with failures';

    chomp(@output);

    $longest = longest_name("$sample_tests/no_output");
    @expected = (
        header_for( "$sample_tests/no_output", $longest ),
        'No subtests run',
        'Test Summary Report',
        '-------------------',
        "$sample_tests/no_output (Wstat: 0 Tests: 0 Failed: 0)",
        'Parse errors: No plan found in TAP output',
    );

    $status  = pop @output;
    $summary = pop @output;

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';
    $expected_summary = qr/^Files=1, Tests=2, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;
    is_deeply \@output, \@expected, '... and the output should be correct';

    # coverage testing for _should_show_comments
    # only show comments

    @output = ();
    ok _runtests( $harness_comments, "$source_tests/harness_failure" ),
      'Run tests with comments';
    chomp(@output);

    $longest = longest_name("$source_tests/harness_failure");
    @expected = (
        header_for( "$source_tests/harness_failure", $longest ),
        q{#   Failed test 'this is another test'},
        '#   in harness_failure.t at line 5.',
        q{#          got: 'waffle'},
        q{#     expected: 'yarblokos'},
        'Failed 1/2 subtests',
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    $status  = pop @output;
    $summary = pop @output;

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';
    $expected_summary = qr/^Files=1, Tests=2, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;
    is_deeply \@output, \@expected, '... and the output should be correct';

    # coverage testing for _should_show_comments and _should_show_failures
    # only show comments and failures

    @output = ();
    $ENV{FOO} = 1;
    ok _runtests( $harness_fandc, "$source_tests/harness_failure" ),
      'Run tests with failures and comments';
    delete $ENV{FOO};
    chomp(@output);

    $longest = longest_name("$source_tests/harness_failure");
    @expected = (
        header_for( "$source_tests/harness_failure", $longest ),
        'not ok 2 - this is another test',
        q{#   Failed test 'this is another test'},
        '#   in harness_failure.t at line 5.',
        q{#          got: 'waffle'},
        q{#     expected: 'yarblokos'},
        'Failed 1/2 subtests',
        'Test Summary Report',
        '-------------------',
        "$source_tests/harness_failure (Wstat: 0 Tests: 2 Failed: 1)",
        'Failed test:',
        '2',
    );

    $status  = pop @output;
    $summary = pop @output;

    like $status, qr{^Result: FAIL$}, '... the status line should be correct';
    $expected_summary = qr/^Files=1, Tests=2, +\S+ms wallclock \(\S+ms usr \+ \S+ms sys = \S+ms CPU\)/;
    is_deeply \@output, \@expected, '... and the output should be correct';

    #XXXX
}

sub longest_name {
    my @names = @_;
    my $longest = 0;
    for my $name (@names) {
        my $len = length $name;
        $longest = $len if $len > $longest;
    }
    return $longest;
}

sub header_for {
    my ( $name, $longest ) = @_;
    my $trailer_len = length(' x');
    my $width = $longest + 1 + 4 + $trailer_len;
    $width = 28 if $width < 28;
    my $header_len = length($name) + 1;
    my $dots = $width - $header_len - $trailer_len - 1;
    $dots = 3 if $dots < 3;
    return $name . ' ' . ( '.' x $dots );
}

sub trim {
    $_[0] =~ s/^\s+|\s+$//g;
    return $_[0];
}

sub _runtests {
    my ( $harness, @tests ) = @_;
    local $ENV{PERL_TEST_HARNESS_DUMP_TAP} = 0;
    my $aggregate = $harness->runtests(@tests);
    return $aggregate;
}
