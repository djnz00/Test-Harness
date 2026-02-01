#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

eval { require IO::Pty; 1 } or plan skip_all => 'IO::Pty not installed';

use TAP::Formatter::Console;
use TAP::Formatter::Console::ParallelSession;
use TAP::Formatter::Console::Session;

{
    package Colorizer;

    sub new { bless {}, shift }

    sub set_color {
        my ( $self, $output, $color ) = @_;
        $output->("[[$color]]");
    }
}

{
    package FakeParser;

    sub new {
        my ( $class, %args ) = @_;
        return bless {
            tests_planned => 1,
            tests_run     => 1,
            has_problems  => 0,
            skip_all      => undef,
            %args,
        }, $class;
    }

    sub tests_planned { return shift->{tests_planned} }
    sub tests_run     { return shift->{tests_run} }
    sub has_problems  { return shift->{has_problems} }
    sub skip_all      { return shift->{skip_all} }
    sub start_time    { return shift->{start_time} }
    sub end_time      { return shift->{end_time} }
    sub start_times   { return shift->{start_times} }
    sub end_times     { return shift->{end_times} }
}

{
    package FakeResult;

    sub new {
        my ( $class, $number, %args ) = @_;
        return bless {
            number       => $number,
            ok           => exists $args{ok} ? $args{ok} : 1,
            is_test      => exists $args{is_test} ? $args{is_test} : 1,
            is_comment   => $args{is_comment}   || 0,
            has_directive => $args{has_directive} || 0,
            raw          => $args{raw} || '',
        }, $class;
    }

    sub is_bailout    {0}
    sub is_test       { return shift->{is_test} }
    sub number        { return shift->{number} }
    sub is_ok         { return shift->{ok} }
    sub is_comment    { return shift->{is_comment} }
    sub has_directive { return shift->{has_directive} }
    sub raw           { return shift->{raw} }
}

package main;

{
    my $probe;
    my $probe_tty;
    {
        local $SIG{__WARN__} = sub { };
        $probe = IO::Pty->new();
        $probe_tty = $probe ? $probe->slave() : undef;
    }
    plan skip_all => 'PTY allocation failed'
      unless $probe && $probe_tty && -t $probe_tty;
}

plan tests => 16;

sub capture_output {
    my ($code) = @_;
    my @output;
    no warnings 'redefine';
    local *TAP::Formatter::Base::_output = sub {
        my $self = shift;
        push @output, @_;
    };
    $code->();
    return join '', @output;
}

sub make_tty_handle {
    my $pty = IO::Pty->new();
    my $tty = $pty->slave();
    return ( $pty, $tty );
}

my $test_name = 't/sample.t';

sub make_session {
    my (%args) = @_;
    my $formatter_args = $args{formatter} || {};
    my $session_args   = $args{session} || {};
    my $parser_args    = $args{parser} || {};
    my $use_colorizer  = delete $formatter_args->{_colorizer};

    my ( $pty, $tty ) = make_tty_handle();
    my $formatter = TAP::Formatter::Console->new(
        { stdout => $tty, %{$formatter_args} } );
    $formatter->_colorizer( Colorizer->new ) if $use_colorizer;
    $formatter->prepare($test_name);
    my $parser = FakeParser->new(%{$parser_args});
    my $session = TAP::Formatter::Console::Session->new(
        {   name      => $test_name,
            formatter => $formatter,
            parser    => $parser,
            %{$session_args},
        }
    );
    return ( $session, $parser, $formatter, $pty );
}

my $utf_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { show_count => 0, utf => 1 },
            session   => { show_count => 0 },
        );
        $session->close_test;
    }
);
like $utf_output, qr/\x{2713}/, 'UTF checkmark appears on TTY';

my $ascii_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { show_count => 0, utf => 0 },
            session   => { show_count => 0 },
        );
        $session->close_test;
    }
);
like $ascii_output, qr/\bok\b/, 'ASCII ok appears with --noutf';

my $spinner_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { poll => 10, utf => 1, _colorizer => 1 },
        );
        $session->result( FakeResult->new(1) );
        $session->tick;
        $session->tick;
    }
);
my @frames = (
    "\x{2807}", "\x{280B}", "\x{2819}", "\x{2838}",
    "\x{28B0}", "\x{28A0}", "\x{28C4}", "\x{2846}",
);
my @seen = grep { $spinner_output =~ /\Q$_\E/ } @frames;
ok @seen >= 2, 'spinner frames advance on tick';
like $spinner_output, qr/\[\[(?:bright_white|white)\]\]/,
  'spinner uses bright white when color is enabled';

my $failure_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { poll => 10, utf => 0, color => 0, failures => 1 },
        );
        $session->result(
            FakeResult->new( 1, ok => 0, raw => 'not ok 1 - fail' ) );
    }
);
like $failure_output, qr/\r[^\n]*\r[^\n]*\nnot ok 1 - fail/,
  'failure output finalizes progress line before printing';

my $comment_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { poll => 10, utf => 1, color => 0, comments => 1 },
        );
        $session->result( FakeResult->new( 1, ok => 1, raw => 'ok 1 - ok' ) );
        $session->result(
            FakeResult->new(
                0,
                is_test    => 0,
                is_comment => 1,
                raw        => '# Subtest: first'
            )
        );
        $session->result( FakeResult->new( 2, ok => 1, raw => 'ok 2 - ok' ) );
        $session->result(
            FakeResult->new(
                0,
                is_test    => 0,
                is_comment => 1,
                raw        => '# Subtest: second'
            )
        );
    }
);
like $comment_output, qr/\n# Subtest: second/,
  'comment output finalizes progress line before printing';

my $directive_output = capture_output(
    sub {
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { poll => 10, utf => 1, color => 0, directives => 1 },
        );
        $session->result( FakeResult->new( 1, ok => 1, raw => 'ok 1 - ok' ) );
        $session->result(
            FakeResult->new(
                2,
                is_test       => 1,
                has_directive => 1,
                raw           => 'ok 2 - todo # TODO'
            )
        );
        $session->result( FakeResult->new( 3, ok => 1, raw => 'ok 3 - ok' ) );
        $session->result(
            FakeResult->new(
                4,
                is_test       => 1,
                has_directive => 1,
                raw           => 'ok 4 - todo # TODO'
            )
        );
    }
);
like $directive_output, qr/\nok 4 - todo # TODO/,
  'directive output finalizes progress line before printing';

my $stderr_capture = '';
my $stderr_output = capture_output(
    sub {
        local *STDERR;
        open STDERR, '>', \$stderr_capture or die $!;
        my ( $session, undef, undef, $pty ) = make_session(
            formatter => { poll => 10, utf => 0, color => 0 },
        );
        $session->result( FakeResult->new(1) );
        $session->stderr_output("diag line\n");
    }
);
like $stderr_output, qr/\r\Q$test_name\E.*1\/1.*\n\z/,
  'stderr output finalizes progress line before printing';
is $stderr_capture, "diag line\n", 'stderr output preserved';

my $parallel_output = capture_output(
    sub {
        my ( $pty, $tty ) = make_tty_handle();
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $tty, poll => 10, utf => 1, expand => 1 } );
        $formatter->prepare($test_name);
        my $parser_a = FakeParser->new( tests_planned => 2, tests_run => 1 );
        my $parser_b = FakeParser->new( tests_planned => 2, tests_run => 1 );
        my $session_a = TAP::Formatter::Console::ParallelSession->new(
            {   name      => $test_name,
                formatter => $formatter,
                parser    => $parser_a,
            }
        );
        my $session_b = TAP::Formatter::Console::ParallelSession->new(
            {   name      => $test_name,
                formatter => $formatter,
                parser    => $parser_b,
            }
        );
        $session_a->result( FakeResult->new( 1, raw => '# Subtest: foo' ) );
        $session_a->result(
            FakeResult->new( 0, is_test => 0, raw => '    1..2' ) );
        $session_a->result(
            FakeResult->new( 0, is_test => 0, raw => '    ok 1 - ok' ) );
        $session_a->close_test;
        $session_b->close_test;
    }
);
like $parallel_output, qr/\r===[^\r\n]*=\n  foo\b/m,
  'parallel ruler finalizes before subtest output';

my $color_output = capture_output(
    sub {
        my ( $session, $parser, undef, $pty ) = make_session(
            formatter => { timer => 1, utf => 1, _colorizer => 1 },
            session   => { show_count => 0 },
            parser    => {
                start_time  => 0,
                end_time    => 0.0014,
                start_times => [ 0, 0, 0, 0 ],
                end_times   => [ 0.0014, 0.0016, 0, 0 ],
            },
        );
        $session->close_test;
    }
);
like $color_output, qr/\[\[white\]\]\Q$test_name\E/,
  'name segment uses white';
like $color_output, qr/(?:\[\[white\]\])?\[\[(?:bright_black|dark)\]\]\s*\.+/,
  'dot leaders use muted color';
like $color_output, qr/\[\[(?:bright_yellow|yellow)\]\]\d+/,
  'ms digits use amber';
like $color_output, qr/\[\[dark\]\]ms/,
  'ms suffix is dimmed';
like $color_output, qr/\[\[green\]\]/,
  'success glyph uses green';

my $non_tty_output = capture_output(
    sub {
        open my $fh, '>', \my $sink;
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $fh, poll => 10, utf => 1 } );
        $formatter->prepare($test_name);
        my $parser = FakeParser->new();
        my $session = TAP::Formatter::Console::Session->new(
            {   name      => $test_name,
                formatter => $formatter,
                parser    => $parser,
            }
        );
        $session->result( FakeResult->new(1) );
        $session->tick;
    }
);
my $has_spinner = 0;
for my $frame ( @frames, '|', '/', '-', '\\' ) {
    if ( $non_tty_output =~ /\Q$frame\E/ ) {
        $has_spinner = 1;
        last;
    }
}
ok !$has_spinner, 'spinner suppressed for non-tty output';
