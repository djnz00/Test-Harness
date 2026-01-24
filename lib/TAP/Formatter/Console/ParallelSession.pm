package TAP::Formatter::Console::ParallelSession;

use strict;
use warnings;
use File::Spec;
use File::Path;
use Carp;

use base 'TAP::Formatter::Console::Session';

my %shared;

sub _initialize {
    my ( $self, $arg_for ) = @_;

    $self->SUPER::_initialize($arg_for);
    my $formatter = $self->formatter;

    # Horrid bodge. This creates our shared context per harness. Maybe
    # TAP::Harness should give us this?
    my $context = $shared{$formatter} ||= $self->_create_shared_context;
    push @{ $context->{active} }, $self;

    return $self;
}

sub _create_shared_context {
    my $self = shift;
    return {
        active        => [],
        tests         => 0,
        fails         => 0,
        ruler_active  => 0,
        spinner_index => 0,
    };
}

sub active_sessions {
    my ( $class, $formatter ) = @_;
    my $context = $shared{$formatter};
    return $context ? $context->{active} : [];
}

=head1 NAME

TAP::Formatter::Console::ParallelSession - Harness output delegate for parallel console output

=head1 VERSION

Version 3.51_01

=cut

our $VERSION = '3.51_01';

=head1 DESCRIPTION

This provides console orientated output formatting for L<TAP::Harness>
when run with multiple L<TAP::Harness/jobs>.

=head1 SYNOPSIS

=cut

=head1 METHODS

=head2 Class Methods

=head3 C<header>

Output test preamble

=cut

sub header {
}

sub tick {
    my $self = shift;
    my $formatter = $self->formatter;
    my $context = $shared{$formatter} || return;

    return unless $formatter->poll && $formatter->_is_interactive;

    my $active = $context->{active} || [];
    return unless @$active && $active->[0] == $self;

    if ( @$active == 1 ) {
        $self->SUPER::tick;
        return;
    }

    $self->_output_ruler( 1, 1 );
}

sub _ruler_width {
    my $self = shift;
    my $formatter = $self->formatter;
    my $width = $formatter->_effective_width;
    if ( !defined $width ) {
        $width = $formatter->_resolve_width;
        $formatter->_effective_width($width);
    }
    return $width - 1;
}

sub _clear_ruler {
    my $self = shift;
    my $width = $self->_ruler_width;
    $self->formatter->_output( "\r" . ( ' ' x $width ) . "\r" );
}

my $now = 0;
my $start;

my $trailer = '... )===';

sub _output_ruler {
    my ( $self, $refresh, $advance_spinner, $suppress_spinner ) = @_;
    my $new_now = time;
    return if $new_now == $now and !$refresh;
    $now = $new_now;
    $start ||= $now;
    my $formatter = $self->formatter;
    return if $formatter->really_quiet;

    my $context = $shared{$formatter};

    my $ruler = sprintf '===( %7d;%d  ', $context->{tests}, $now - $start;

    for my $active ( @{ $context->{active} } ) {
        my $parser  = $active->parser;
        my $tests   = $parser->tests_run;
        my $planned = $parser->tests_planned || '?';

        $ruler .= sprintf '%' . length($planned) . "d/$planned  ", $tests;
    }
    chop $ruler;    # Remove a trailing space
    $ruler .= ')===';

    my $width = $self->_ruler_width;
    my $chop_length = $width - length $trailer;
    $chop_length = 0 if $chop_length < 0;

    if ( length $ruler > $width ) {
        if ($chop_length) {
            $ruler =~ s/(.{$chop_length}).*/$1$trailer/o;
        }
        else {
            $ruler = substr( $trailer, 0, $width );
        }
    }
    else {
        $ruler .= '=' x ( $width - length($ruler) );
    }
    my $spinner = '';
    if ( !$suppress_spinner && $formatter->poll && $formatter->_is_interactive )
    {
        my $frames = $formatter->_spinner_frames;
        if (@$frames) {
            if ($advance_spinner) {
                $context->{spinner_index}
                  = ( $context->{spinner_index} + 1 ) % @$frames;
            }
            $spinner = $frames->[ $context->{spinner_index} % @$frames ];
        }
    }

    if ( length $spinner ) {
        my $base = substr( $ruler, 0, -1 );
        $formatter->_render_spinner_line(
            text    => $base,
            spinner => $spinner,
        );
    }
    else {
        $formatter->_render_spinner_line( text => $ruler );
    }
    $context->{ruler_active} = 1;
}

sub _expand_subtest {
    my ( $self, $result, $context ) = @_;
    my $formatter = $self->formatter;
    return if $formatter->really_quiet;
    return if $formatter->verbose;

    my $expand = $formatter->expand;
    return unless $expand;

    my $state = $self->{_subtest_expand};
    if ( !$state || $state->{max_depth} != $expand ) {
        require TAP::Formatter::Console::Subtest;
        $state = $self->{_subtest_expand} = {
            max_depth => $expand,
            parser    => TAP::Formatter::Console::Subtest->new(
                { max_depth => $expand } ),
            output_started => 0,
        };
    }

    my @events = $state->{parser}->consume_line( $result->raw );
    return unless @events;

    for my $event (@events) {
        # Avoid noisy, interleaved progress lines in parallel output.
        next if $event->{type} eq 'progress';
        my $depth = $event->{depth};
        my $name  = $event->{name};
        my ( $pretty, $name_segments )
          = $formatter->_subtest_name_data( $state, $depth, $name );

        if ( $context->{ruler_active} ) {
            $self->_output_ruler( 1, 0, 1 );
            $formatter->_output("\n");
            $context->{ruler_active} = 0;
        }
        my $status = $formatter->_status_token( $event->{ok} );
        my $color  = $event->{ok}
          ? $formatter->_success_color
          : $formatter->_failure_color;
        $formatter->_render_segments(
            @{$name_segments},
            { text => $status, color => $color },
        );
        $formatter->_output("\n");
        $state->{output_started} = 1;
    }

    return;
}

=head3 C<result>

  Called by the harness for each line of TAP it receives .

=cut

sub result {
    my ( $self, $result ) = @_;
    my $formatter = $self->formatter;
    my $context   = $shared{$formatter};
    my $active    = $context->{active};

    # my $really_quiet = $formatter->really_quiet;
    # my $show_count   = $self->_should_show_count;

    if ( @$active == 1 ) {
        $context->{tests}++ if $result->is_test;

        # There is only one test, so use the serial output format.
        return $self->SUPER::result($result);
    }

    $self->_expand_subtest( $result, $context );

    if ( $result->is_test ) {
        $context->{tests}++;
        $self->_output_ruler( $self->parser->tests_run == 1, 0 );
    }
    elsif ( $result->is_bailout ) {
        $formatter->_failure_output(
                "Bailout called.  Further testing stopped:  "
              . $result->explanation
              . "\n" );
    }
}

=head3 C<clear_for_close>

=cut

sub clear_for_close {
    my $self      = shift;
    my $formatter = $self->formatter;
    return if $formatter->really_quiet;
    my $context = $shared{$formatter};
    if ( @{ $context->{active} } == 1 ) {
        $self->SUPER::clear_for_close;
    }
    else {
        $self->_clear_ruler;
    }
}

=head3 C<close_test>

=cut

sub close_test {
    my $self      = shift;
    my $name      = $self->name;
    my $parser    = $self->parser;
    my $formatter = $self->formatter;
    my $context   = $shared{$formatter};

    $self->SUPER::close_test;

    my $active = $context->{active};

    my @pos = grep { $active->[$_]->name eq $name } 0 .. $#$active;

    die "Can't find myself" unless @pos;
    splice @$active, $pos[0], 1;

    if ( @$active > 1 ) {
        $self->_output_ruler( 1, 0 );
    }
    elsif ( @$active == 1 ) {

        # Print out "test/name.t ...."
        $active->[0]->SUPER::header;
    }
    else {

        # $self->formatter->_output("\n");
        delete $shared{$formatter};
        $formatter->_show_cursor if $formatter->can('_show_cursor');
        if ( $formatter->{_current_session}
            && $formatter->{_current_session} == $self )
        {
            $formatter->{_current_session} = undef;
        }
    }
}

1;
