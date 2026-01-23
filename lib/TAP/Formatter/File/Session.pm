package TAP::Formatter::File::Session;

use strict;
use warnings;
use base 'TAP::Formatter::Session';

=head1 NAME

TAP::Formatter::File::Session - Harness output delegate for file output

=head1 VERSION

Version 3.51_01

=cut

our $VERSION = '3.51_01';

=head1 DESCRIPTION

This provides file orientated output formatting for L<TAP::Harness>.
It is particularly important when running with parallel tests, as it
ensures that test results are not interleaved, even when run
verbosely.

=cut

=head1 METHODS

=head2 result

Stores results for later output, all together.

=cut

sub result {
    my $self   = shift;
    my $result = shift;

    my $parser    = $self->parser;
    my $formatter = $self->formatter;

    if ( $result->is_bailout ) {
        $formatter->_failure_output(
                "Bailout called.  Further testing stopped:  "
              . $result->explanation
              . "\n" );
        return;
    }

    my $expand = $formatter->expand;
    if ( $expand && !$formatter->verbose ) {
        require TAP::Formatter::Console::Subtest;
        my $state = $self->{_subtest_expand};
        if ( !$state || $state->{max_depth} != $expand ) {
            $state = $self->{_subtest_expand} = {
                max_depth => $expand,
                parser    => TAP::Formatter::Console::Subtest->new(
                    { max_depth => $expand } ),
            };
        }

        my @events = $state->{parser}->consume_line( $result->raw );
        for my $event (@events) {
            next unless $event->{type} eq 'final';
            my ( undef, undef, $text )
              = $formatter->_subtest_name_parts(
                $event->{depth},
                $event->{name}
              );
            my $status = $event->{ok} ? 'ok' : 'not ok';
            $self->{results} .= $text . $status . "\n";
        }
    }

    if (!$formatter->quiet
        && (   $formatter->verbose
            || ( $result->is_test && $formatter->failures && !$result->is_ok )
            || ( $formatter->comments   && $result->is_comment )
            || ( $result->has_directive && $formatter->directives ) )
      )
    {
        $self->{results} .= $self->_format_for_output($result) . "\n";
    }
}

=head2 close_test

When the test file finishes, outputs the summary, together.

=cut

sub close_test {
    my $self = shift;

    # Avoid circular references
    $self->parser(undef);

    my $parser    = $self->parser;
    my $formatter = $self->formatter;
    my $pretty    = $formatter->_format_name( $self->name );

    return if $formatter->really_quiet;
    if ( my $skip_all = $parser->skip_all ) {
        $formatter->_output( $pretty . "skipped: $skip_all\n" );
    }
    elsif ( $parser->has_problems ) {
        $formatter->_output(
            $pretty . ( $self->{results} ? "\n" . $self->{results} : "\n" ) );
        $self->_output_test_failure($parser);
    }
    else {
        my $time_report = $self->time_report( $formatter, $parser );
        $formatter->_output(
            $pretty . ( $self->{results} ? "\n" . $self->{results} : "" ) );
        if ( $formatter->expand && !$formatter->verbose ) {
            $formatter->_output_success(
                $pretty . $self->_make_ok_line($time_report) );
        }
        else {
            $formatter->_output_success( $self->_make_ok_line($time_report) );
        }
    }
}

1;
