#!/usr/bin/perl -w

BEGIN {
    unshift @INC, 't/lib';
}

use strict;
use warnings;
use Test::More;

{
    package FormatterWidthTest;
    use base 'TAP::Formatter::Console';

    sub _terminal_columns {
        my $self = shift;
        return $self->{_terminal_columns};
    }

    sub _is_interactive {
        my $self = shift;
        return $self->{_interactive} ? 1 : 0;
    }
}

sub expected_default_width {
    my ($longest) = @_;
    my $trailer_len = length(' not ok');
    my $width = $longest + 1 + 3 + $trailer_len;
    return $width < 28 ? 28 : $width;
}

{
    my $formatter = FormatterWidthTest->new;
    $formatter->{_interactive} = 0;

    my @tests = ( 'short', 'longername' );
    $formatter->prepare(@tests);

    my $longest = 0;
    for my $test (@tests) {
        my $len = length $test;
        $longest = $len if $len > $longest;
    }

    is(
        $formatter->_effective_width,
        expected_default_width($longest),
        'non-TTY default width clamps to minimum'
    );
}

{
    my $formatter = FormatterWidthTest->new;
    $formatter->{_interactive} = 0;

    my @tests = ( 'x' x 30, 'short' );
    $formatter->prepare(@tests);

    my $longest = 30;
    is(
        $formatter->_effective_width,
        expected_default_width($longest),
        'non-TTY default width uses longest name'
    );
}

{
    my $formatter = FormatterWidthTest->new;
    $formatter->{_interactive} = 1;
    $formatter->{_terminal_columns} = 40;

    $formatter->prepare('anything');

    is(
        $formatter->_effective_width,
        40,
        'TTY default width uses terminal columns'
    );
}

{
    my $formatter = FormatterWidthTest->new( { width => 10 } );
    $formatter->{_interactive} = 0;

    $formatter->prepare('anything');

    is(
        $formatter->_effective_width,
        28,
        'width override clamps to minimum'
    );
}

done_testing;
