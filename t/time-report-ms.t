#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

use TAP::Formatter::Console;
use TAP::Formatter::Console::Session;

{
    package FakeParser;

    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub start_time  { return shift->{start_time} }
    sub end_time    { return shift->{end_time} }
    sub start_times { return shift->{start_times} }
    sub end_times   { return shift->{end_times} }
}

package main;

plan tests => 6;

my $formatter = TAP::Formatter::Console->new( { timer => 1 } );
$formatter->prepare('t/sample.t');

my $parser_fast = FakeParser->new(
    start_time  => 0,
    end_time    => 0.0004,
    start_times => [ 0, 0, 0, 0 ],
    end_times   => [ 0.0014, 0.0016, 0, 0 ],
);
my $session_fast = TAP::Formatter::Console::Session->new(
    {   name       => 't/sample.t',
        formatter  => $formatter,
        parser     => $parser_fast,
        show_count => 0,
    }
);
my $report_fast = $session_fast->time_report( $formatter, $parser_fast );
like $report_fast, qr/<1ms/, 'wallclock reports <1ms';
like $report_fast, qr/1ms usr/, 'usr rounds to 1ms';
like $report_fast, qr/2ms sys/, 'sys rounds to 2ms';

my $parser_zero = FakeParser->new(
    start_time  => 0,
    end_time    => 0,
    start_times => [ 0, 0, 0, 0 ],
    end_times   => [ 0, 0, 0, 0 ],
);
my $session_zero = TAP::Formatter::Console::Session->new(
    {   name       => 't/sample.t',
        formatter  => $formatter,
        parser     => $parser_zero,
        show_count => 0,
    }
);
my $report_zero = $session_zero->time_report( $formatter, $parser_zero );
like $report_zero, qr/^\s*0ms\b/, 'wallclock reports 0ms';
like $report_zero, qr/0ms usr/, 'usr reports 0ms';
like $report_zero, qr/0ms sys/, 'sys reports 0ms';
