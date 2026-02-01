package TAP::Formatter::Console::Session;

use strict;
use warnings;

use base 'TAP::Formatter::Session';

my @ACCESSOR;

BEGIN {
    my @CLOSURE_BINDING
      = qw( header result clear_for_close close_test tick stderr_output );

    for my $method (@CLOSURE_BINDING) {
        no strict 'refs';
        *$method = sub {
            my $self = shift;
            return ( $self->{_closures} ||= $self->_closures )->{$method}
              ->(@_);
        };
    }
}

=head1 NAME

TAP::Formatter::Console::Session - Harness output delegate for default console output

=head1 VERSION

Version 4.01

=cut

our $VERSION = '4.01';

=head1 DESCRIPTION

This provides console orientated output formatting for TAP::Harness.

=cut

sub _get_output_result {
    my $self = shift;

    my @color_map = (
        {   test => sub { $_->is_test && !$_->is_ok },
            colors => ['red'],
        },
        {   test => sub { $_->is_test && $_->has_skip },
            colors => [
                'white',
                'on_blue'
            ],
        },
        {   test => sub { $_->is_test && $_->has_todo },
            colors => ['yellow'],
        },
    );

    my $formatter = $self->formatter;
    my $parser    = $self->parser;

    return $formatter->_colorizer
      ? sub {
        my $result = shift;
        for my $col (@color_map) {
            local $_ = $result;
            if ( $col->{test}->() ) {
                $formatter->_set_colors( @{ $col->{colors} } );
                last;
            }
        }
        $formatter->_output( $self->_format_for_output($result) );
        $formatter->_set_colors('reset');
      }
      : sub {
        $formatter->_output( $self->_format_for_output(shift) );
      };
}

sub _closures {
    my $self = shift;

    my $parser     = $self->parser;
    my $formatter  = $self->formatter;
    my @pretty_segments = $formatter->_name_segments( $self->name );
    my $pretty_text = $formatter->_segments_text(@pretty_segments);
    my $show_count = $self->show_count;

    my $really_quiet = $formatter->really_quiet;
    my $quiet        = $formatter->quiet;
    my $verbose      = $formatter->verbose;
    my $directives   = $formatter->directives;
    my $failures     = $formatter->failures;
    my $comments     = $formatter->comments;
    my $expand       = $formatter->expand;

    my $output_result = $self->_get_output_result;

    my $output          = '_output';
    my $plan            = '';
    my $newline_printed = 0;
    my $subtest_output_started = 0;

    my $last_status_printed = 0;
    my $last_seen_test      = 0;
    my $last_printed_test   = 0;

    my $spinner_enabled = $formatter->poll && $formatter->_is_interactive;
    my $spinner_frames  = $formatter->_spinner_frames;
    my $spinner_index   = 0;
    my $last_progress_text;
    my $last_progress_tail;
    my $last_progress_len;

    my $subtest_state;

    if ( $expand && !$verbose ) {
        require TAP::Formatter::Console::Subtest;
        $subtest_state = $self->{_subtest_expand};
        if ( !$subtest_state || $subtest_state->{max_depth} != $expand ) {
            $subtest_state = {
                max_depth => $expand,
                parser    => TAP::Formatter::Console::Subtest->new(
                    { max_depth => $expand } ),
                output_started => 0,
            };
            $self->{_subtest_expand} = $subtest_state;
        }
        $subtest_output_started = $subtest_state->{output_started} || 0;
    }

    my $current_spinner = sub {
        return '' unless $spinner_enabled;
        return $spinner_frames->[ $spinner_index % @$spinner_frames ];
    };

    my $advance_spinner = sub {
        return '' unless $spinner_enabled;
        $spinner_index = ( $spinner_index + 1 ) % @$spinner_frames;
        return $spinner_frames->[$spinner_index];
    };

    my $render_line = sub {
        my ( $text, $spinner, $len_ref, $segments, $tail ) = @_;
        my $line = $text . $spinner;
        my $pad = '';
        if ( defined $$len_ref && length $line < $$len_ref ) {
            $pad = ' ' x ( $$len_ref - length $line );
        }
        $formatter->_render_spinner_line(
            text     => $text,
            segments => $segments,
            tail     => $tail,
            spinner  => $spinner,
            pad      => $pad,
            output   => $output,
        );
        $$len_ref = length $line;
    };

    my $print_status = sub {
        my ( $number, $now ) = @_;
        $output = $formatter->_get_output_method($parser);
        my $tail = "$number$plan";
        my $text = $pretty_text . $tail;
        $last_progress_text = $text;
        $last_progress_tail = $tail;
        $render_line->(
            $text, $current_spinner->(), \$last_progress_len,
            \@pretty_segments, $tail
        );
        $last_status_printed = $now;
        $last_printed_test   = $number;
    };

    my $finalize_progress_line = sub {
        return unless defined $last_progress_len || defined $last_progress_text;
        my $text = $last_progress_text // '';
        my $len  = length $text;
        my $pad  = '';
        if ( defined $last_progress_len && $len < $last_progress_len ) {
            $pad = ' ' x ( $last_progress_len - $len );
        }
        $formatter->$output("\r");
        $formatter->_render_segments(@pretty_segments);
        $formatter->_output($last_progress_tail // '');
        $formatter->$output($pad) if length $pad;
        $formatter->$output("\n");
        $last_progress_len  = undef;
        $last_progress_text = undef;
        $last_progress_tail = undef;
    };

    my $finalize_progress_if_needed = sub {
        return 0
          unless defined $last_progress_len || defined $last_progress_text;
        $finalize_progress_line->();
        return 1;
    };

    my $finalize_subtest_progress = sub {
        return 0 unless $subtest_state && $subtest_state->{progress_active};
        my $text = $subtest_state->{last_text} || '';
        my $len  = length $text;
        my $pad  = '';
        if ( defined $subtest_state->{last_len}
            && $len < $subtest_state->{last_len} )
        {
            $pad = ' ' x ( $subtest_state->{last_len} - $len );
        }
        $formatter->_render_spinner_line(
            text => $text,
            pad  => $pad,
        );
        $formatter->_output("\n");
        $subtest_state->{last_len}        = undef;
        $subtest_state->{last_text}       = undef;
        $subtest_state->{progress_active} = 0;
        return 1;
    };

    my $subtest_name_data = sub {
        my ( $depth, $name ) = @_;
        return $formatter->_subtest_name_data( $subtest_state, $depth, $name );
    };

    my $format_subtest_name = sub {
        my ( $depth, $name ) = @_;
        my ( $text ) = $subtest_name_data->( $depth, $name );
        return $text;
    };

    my $start_subtest_output = sub {
        unless ($newline_printed) {
            $finalize_progress_if_needed->()
              or $formatter->_output("\n");
            $newline_printed = 1;
        }
        $subtest_output_started = 1;
        $subtest_state->{output_started} = 1 if $subtest_state;
    };

    my $emit_subtest_progress = sub {
        my ($text) = @_;
        $start_subtest_output->();
        my $spinner = $current_spinner->();
        $spinner = ' ' . $spinner if length $spinner;
        my $line = $text . $spinner;
        my $len = length $line;
        my $pad = '';
        if ( defined $subtest_state->{last_len}
            && $len < $subtest_state->{last_len} )
        {
            $pad = ' ' x ( $subtest_state->{last_len} - $len );
        }
        $formatter->_render_spinner_line(
            text    => $text,
            spinner => $spinner,
            pad     => $pad,
        );
        $subtest_state->{last_len} = $len;
        $subtest_state->{last_text} = $text;
        $subtest_state->{progress_active} = 1;
    };

    my $emit_subtest_final = sub {
        my ( $text, $segments, $ok ) = @_;
        $start_subtest_output->();
        my $status = $formatter->_status_token($ok);
        my $line   = $text . $status;
        my $len    = length $line;
        my $pad = '';
        if ( defined $subtest_state->{last_len}
            && $len < $subtest_state->{last_len} )
        {
            $pad = ' ' x ( $subtest_state->{last_len} - $len );
        }
        $formatter->_output("\r");
        my $color = $ok
          ? $formatter->_success_color
          : $formatter->_failure_color;
        $formatter->_render_segments(
            @{$segments},
            { text => $status, color => $color },
        );
        $formatter->_output($pad) if length $pad;
        $formatter->_output("\n");
        $subtest_state->{last_len}        = undef;
        $subtest_state->{last_text}       = undef;
        $subtest_state->{progress_active} = 0;
    };

    return {
        header => sub {
            return if $really_quiet;
            if ( @pretty_segments ) {
                $formatter->_render_segments(@pretty_segments);
            }
            else {
                $formatter->_output($pretty_text);
            }
        },

        result => sub {
            my $result = shift;

            if ( $result->is_bailout ) {
                $formatter->_failure_output(
                        "Bailout called.  Further testing stopped:  "
                      . $result->explanation
                      . "\n" );
            }

            return if $really_quiet;

            my $is_test = $result->is_test;

            # These are used in close_test - but only if $really_quiet
            # is false - so it's safe to only set them here unless that
            # relationship changes.

            if ( !$plan || ( $plan eq '/? ' && defined $parser->tests_planned ) )
            {
                my $planned = $parser->tests_planned || '?';
                $plan = "/$planned ";
            }

            if ($subtest_state) {
                my @events
                  = $subtest_state->{parser}->consume_line( $result->raw );
                for my $event (@events) {
                    if ( $event->{type} eq 'progress' ) {
                        my $pretty
                          = $format_subtest_name->( $event->{depth},
                            $event->{name} );
                        $emit_subtest_progress->(
                            $pretty
                              . $event->{run} . '/'
                              . $event->{planned}
                        );
                    }
                    elsif ( $event->{type} eq 'final' ) {
                        my ( $pretty, $segments )
                          = $subtest_name_data->( $event->{depth},
                            $event->{name} );
                        $emit_subtest_final->(
                            $pretty, $segments, $event->{ok} );
                    }
                }
            }

            if ( $show_count && !$subtest_output_started ) {
                my $now = CORE::time;

                if ( $is_test ) {
                    $last_seen_test = $result->number;

                    # Print status roughly once per second.
                    # We will always get the first number as a side effect of
                    # $last_status_printed starting with the value 0, which $now
                    # will never be. (Unless someone sets their clock to 1970)
                    if ( $last_status_printed != $now ) {
                        $print_status->( $last_seen_test, $now );
                    }
                }
                elsif ( $last_seen_test > $last_printed_test ) {
                    $print_status->( $last_seen_test, $now );
                }
            }

            if (!$quiet
                && (   $verbose
                    || ( $is_test && $failures && !$result->is_ok )
                    || ( $comments   && $result->is_comment )
                    || ( $directives && $result->has_directive ) )
              )
            {
                if ( !$finalize_progress_if_needed->()
                    && !$newline_printed )
                {
                    $formatter->_output("\n");
                }
                $newline_printed = 1;
                $output_result->($result);
                $formatter->_output("\n");
            }
        },

        clear_for_close => sub {
            my $len = $last_progress_len;
            if ( !defined $len ) {
                $len = length( '.' . $pretty_text . $plan . $parser->tests_run );
                $len++ if $spinner_enabled;
            }
            my $spaces = ' ' x $len;
            $formatter->$output("\r$spaces");
        },

        close_test => sub {
            if ( $show_count && !$really_quiet ) {
                $self->clear_for_close;
                $formatter->$output("\r");
            }

            # Avoid circular references
            $self->parser(undef);
            $self->{_closures} = {};

            return if $really_quiet;

            if ( my $skip_all = $parser->skip_all ) {
                $formatter->_output("skipped: $skip_all\n");
            }
            elsif ( $parser->has_problems ) {
                $self->_output_test_failure($parser);
            }
            else {
                my @time_parts
                  = $self->time_report_parts( $formatter, $parser );
                my $status = $formatter->_status_token(1);
                if ( $formatter->_is_interactive ) {
                    my @segments = (
                        $formatter->_name_segments( $self->name ),
                        {   text  => $status,
                            color => $formatter->_success_color
                        },
                        $formatter->_time_report_segments( \@time_parts ),
                    );
                    $formatter->_output("\r") unless $really_quiet;
                    $formatter->_render_segments(@segments);
                }
                else {
                    my @segments = (
                        {   text  => $status,
                            color => $formatter->_success_color
                        },
                        $formatter->_time_report_segments( \@time_parts ),
                    );
                    $formatter->_render_segments(@segments);
                }
                $formatter->_output("\n");
            }

            $formatter->_show_cursor if $formatter->can('_show_cursor');
            if ( $formatter->{_current_session}
                && $formatter->{_current_session} == $self )
            {
                $formatter->{_current_session} = undef;
            }
        },

        tick => sub {
            return unless $spinner_enabled;

            my $spinner = $advance_spinner->();
            if ( $subtest_state && $subtest_state->{progress_active} ) {
                my $spinner_sub = $spinner;
                $spinner_sub = ' ' . $spinner_sub if length $spinner_sub;
                my $text = $subtest_state->{last_text} || '';
                return unless length $text;
                my $line = $text . $spinner_sub;
                my $len  = length $line;
                my $pad  = '';
                if ( defined $subtest_state->{last_len}
                    && $len < $subtest_state->{last_len} )
                {
                    $pad = ' ' x ( $subtest_state->{last_len} - $len );
                }
                $formatter->_render_spinner_line(
                    text    => $text,
                    spinner => $spinner_sub,
                    pad     => $pad,
                );
                $subtest_state->{last_len} = $len;
                return;
            }

            return unless $show_count && !$subtest_output_started;
            return unless defined $last_progress_text;

            $render_line->(
                $last_progress_text, $spinner, \$last_progress_len,
                \@pretty_segments, $last_progress_tail
            );
        },

        stderr_output => sub {
            my ($chunk) = @_;
            return unless defined $chunk && length $chunk;
            my $finalized = $finalize_subtest_progress->();
            $finalized ||= $finalize_progress_if_needed->();
            $newline_printed = 1 if $finalized;
            print STDERR $chunk;
        },
    };
}

=head2 C<< 	clear_for_close >>

=head2 C<< 	close_test >>

=head2 C<< 	header >>

=head2 C<< 	result >>

=cut

1;
