#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

eval { require IO::Pty; 1 } or plan skip_all => 'IO::Pty not installed';

use TAP::Formatter::Console;
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
        my ( $class, $number ) = @_;
        return bless { number => $number }, $class;
    }

    sub is_bailout    {0}
    sub is_test       {1}
    sub number        { return shift->{number} }
    sub is_ok         {1}
    sub is_comment    {0}
    sub has_directive {0}
    sub raw           { return '' }
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

plan tests => 10;

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

my $utf_output = capture_output(
    sub {
        my ( $pty, $tty ) = make_tty_handle();
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $tty, show_count => 0, utf => 1 } );
        $formatter->prepare($test_name);
        my $parser = FakeParser->new();
        my $session = TAP::Formatter::Console::Session->new(
            {   name       => $test_name,
                formatter  => $formatter,
                parser     => $parser,
                show_count => 0,
            }
        );
        $session->close_test;
    }
);
like $utf_output, qr/\x{2713}/, 'UTF checkmark appears on TTY';

my $ascii_output = capture_output(
    sub {
        my ( $pty, $tty ) = make_tty_handle();
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $tty, show_count => 0, utf => 0 } );
        $formatter->prepare($test_name);
        my $parser = FakeParser->new();
        my $session = TAP::Formatter::Console::Session->new(
            {   name       => $test_name,
                formatter  => $formatter,
                parser     => $parser,
                show_count => 0,
            }
        );
        $session->close_test;
    }
);
like $ascii_output, qr/\bok\b/, 'ASCII ok appears with --noutf';

my $spinner_output = capture_output(
    sub {
        my ( $pty, $tty ) = make_tty_handle();
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $tty, poll => 10, utf => 1 } );
        $formatter->_colorizer( Colorizer->new );
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

my $color_output = capture_output(
    sub {
        my ( $pty, $tty ) = make_tty_handle();
        my $formatter = TAP::Formatter::Console->new(
            { stdout => $tty, timer => 1, utf => 1 } );
        $formatter->_colorizer( Colorizer->new );
        $formatter->prepare($test_name);
        my $parser = FakeParser->new(
            start_time  => 0,
            end_time    => 0.0014,
            start_times => [ 0, 0, 0, 0 ],
            end_times   => [ 0.0014, 0.0016, 0, 0 ],
        );
        my $session = TAP::Formatter::Console::Session->new(
            {   name       => $test_name,
                formatter  => $formatter,
                parser     => $parser,
                show_count => 0,
            }
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
