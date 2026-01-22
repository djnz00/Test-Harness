package TAP::Formatter::Console;

use strict;
use warnings;
use base 'TAP::Formatter::Base';
use POSIX qw(strftime);

=head1 NAME

TAP::Formatter::Console - Harness output delegate for default console output

=head1 VERSION

Version 3.51_01

=cut

our $VERSION = '3.51_01';

=head1 DESCRIPTION

This provides console orientated output formatting for TAP::Harness.

=head1 SYNOPSIS

 use TAP::Formatter::Console;
 my $harness = TAP::Formatter::Console->new( \%args );

=head2 C<< open_test >>

See L<TAP::Formatter::Base>

=cut

sub _initialize {
    my ( $self, $arg_for ) = @_;

    $self->SUPER::_initialize($arg_for);

    if ( $self->utf ) {
        eval { binmode( $self->stdout, ':encoding(UTF-8)' ) };
    }

    return $self;
}

sub open_test {
    my ( $self, $test, $parser ) = @_;

    my $class
      = $self->jobs > 1
      ? 'TAP::Formatter::Console::ParallelSession'
      : 'TAP::Formatter::Console::Session';

    eval "require $class";
    $self->_croak($@) if $@;

    my $session = $class->new(
        {   name       => $test,
            formatter  => $self,
            parser     => $parser,
            show_count => $self->show_count,
        }
    );

    $self->{_current_session} = $session;

    $session->header;

    return $session;
}

sub _summary_runtime_line {
    my ( $self, $files, $total, $runtime ) = @_;

    unless ( $self->_colorizer ) {
        return $self->SUPER::_summary_runtime_line( $files, $total, $runtime );
    }

    my @segments = (
        { text => 'Files=', color => $self->_muted_colors },
        { text => $files,   color => $self->_count_color },
        { text => ', ',     color => $self->_muted_colors },
        { text => 'Tests=', color => $self->_muted_colors },
        { text => $total,   color => $self->_count_color },
        { text => ', ',     color => $self->_muted_colors },
        $self->_time_report_segments($runtime),
    );
    $self->_render_segments(@segments);
    $self->_output("\n");
}

sub _output_result_status {
    my ( $self, $status ) = @_;
    return $self->SUPER::_output_result_status($status) unless $self->_colorizer;

    my $color;
    if ( $status eq 'PASS' ) {
        $color = $self->_success_color;
    }
    elsif ( $status eq 'FAIL' ) {
        $color = $self->_failure_color;
    }

    $self->_output('Result: ');
    if ($color) {
        $self->_set_colors($color);
        $self->_output($status);
        $self->_set_colors('reset');
    }
    else {
        $self->_output($status);
    }
    $self->_output("\n");
}

sub tick {
    my $self = shift;

    if ( $self->jobs > 1 ) {
        eval { require TAP::Formatter::Console::ParallelSession; 1 } or return;
        my $sessions
          = TAP::Formatter::Console::ParallelSession->active_sessions($self);
        for my $session ( @{$sessions} ) {
            $session->tick if $session->can('tick');
        }
        return;
    }

    my $session = $self->{_current_session};
    return unless $session;
    $session->tick if $session->can('tick');
}

# Use _colorizer delegate to set output color. NOP if we have no delegate
sub _set_colors {
    my ( $self, @colors ) = @_;
    if ( my $colorizer = $self->_colorizer ) {
        my $output_func = $self->{_output_func} ||= sub {
            $self->_output(@_);
        };
        $colorizer->set_color( $output_func, $_ ) for @colors;
    }
}

sub _failure_color {
    my ($self) = @_;

    return $ENV{'HARNESS_SUMMARY_COLOR_FAIL'} || 'red';
}

sub _success_color {
    my ($self) = @_;

    return $ENV{'HARNESS_SUMMARY_COLOR_SUCCESS'} || 'green';
}

sub _use_utf {
    my $self = shift;
    return $self->utf;
}

sub _status_token {
    my ( $self, $ok ) = @_;
    return $ok ? "\x{2713}" : "\x{00D7}" if $self->_use_utf;
    return $ok ? 'ok' : 'not ok';
}

sub _spinner_frames {
    my $self = shift;
    return [ '|', '/', '-', '\\' ] unless $self->_use_utf;
    return [
        "\x{2807}", "\x{280B}", "\x{2819}", "\x{2838}",
        "\x{28B0}", "\x{28A0}", "\x{28C4}", "\x{2846}",
    ];
}

sub _color_supported {
    my ( $self, $color ) = @_;
    return 0 unless $self->_colorizer;
    return $self->{_color_support}->{$color}
      if exists $self->{_color_support}->{$color};
    my $ok = eval {
        require Term::ANSIColor;
        Term::ANSIColor::color($color);
        1;
    } ? 1 : 0;
    $self->{_color_support}->{$color} = $ok;
    return $ok;
}

sub _muted_colors {
    my $self = shift;
    return ['white', 'dark'] if $self->_color_supported('white');
    return ['white'];
}

sub _name_color {
    my $self = shift;
    return 'white';
}

sub _count_color {
    my $self = shift;
    return 'white';
}

sub _ms_digits_color {
    my $self = shift;
    return 'yellow' if $self->_color_supported('yellow');
    return 'bright_yellow' if $self->_color_supported('bright_yellow');
    return 'white';
}

sub _ms_suffix_colors {
    my $self = shift;
    return [ 'yellow', 'dark' ] if $self->_color_supported('yellow');
    my $digits = $self->_ms_digits_color;
    return [ $digits, 'dark' ];
}

sub _spinner_colors {
    my $self = shift;
    return ['bright_white'] if $self->_color_supported('bright_white');
    return ['white'];
}

sub _hide_cursor {
    my $self = shift;
    return if !$self->_is_interactive || $self->{_cursor_hidden};
    $self->_output("\e[?25l");
    $self->{_cursor_hidden} = 1;
}

sub _show_cursor {
    my $self = shift;
    return unless $self->{_cursor_hidden};
    $self->_output("\e[?25h");
    $self->{_cursor_hidden} = 0;
}

sub _render_segments {
    my ( $self, @segments ) = @_;
    for my $segment (@segments) {
        next unless defined $segment->{text} && length $segment->{text};
        if ( $self->_colorizer && $segment->{color} ) {
            my @colors
              = ref $segment->{color} eq 'ARRAY'
              ? @{ $segment->{color} }
              : ( $segment->{color} );
            $self->_set_colors(@colors);
            $self->_output( $segment->{text} );
            $self->_set_colors('reset');
        }
        else {
            $self->_output( $segment->{text} );
        }
    }
}

sub _segments_text {
    my ( $self, @segments ) = @_;
    return join '', map { $_->{text} // '' } @segments;
}

sub _segments_from_parts {
    my ( $self, $parts ) = @_;
    my @segments;
    for my $part ( @{$parts} ) {
        my $text = $part->{text};
        next unless defined $text && length $text;
        if ( $part->{kind} && $part->{kind} eq 'ms' ) {
            push @segments, $self->_ms_segments($text);
        }
        else {
            push @segments, { text => $text, color => $self->_muted_colors };
        }
    }
    return @segments;
}

sub _render_spinner_line {
    my ( $self, %args ) = @_;
    my $spinner = $args{spinner} // '';
    my $pad     = $args{pad} // '';
    my $tail    = $args{tail} // '';
    my $segments = $args{segments};
    my $text = $args{text} // '';
    my $out = $args{output} || '_output';

    if ( $segments && @{$segments} ) {
        $self->$out("\r");
        $self->_render_segments( @{$segments} );
        $self->_output($tail) if length $tail;
    }
    else {
        $self->$out("\r$text");
    }

    if ( length $spinner ) {
        $self->_hide_cursor;
        if ( $self->_colorizer ) {
            $self->_set_colors( @{ $self->_spinner_colors } );
            $self->_output($spinner);
            $self->_set_colors('reset');
        }
        else {
            $self->_output($spinner);
        }
    }

    $self->_output($pad) if length $pad;
}

sub _name_segments {
    my ( $self, $test ) = @_;
    my $name = $test;
    my $periods = '.' x ( $self->_longest + 2 - length $test );
    $periods = " $periods ";

    my @segments;
    if ( $self->timer ) {
        push @segments,
          { text => $self->_format_now() . ' ', color => $self->_muted_colors };
    }
    push @segments, { text => $name, color => $self->_name_color };
    push @segments, { text => $periods, color => $self->_muted_colors };
    return @segments;
}

sub _subtest_name_data {
    my ( $self, $state, $depth, $name ) = @_;
    my $len = length $name;
    my $longest = $state->{longest};
    $longest->[$depth] = $len
      if !defined $longest->[$depth] || $len > $longest->[$depth];
    my $periods = '.' x ( $longest->[$depth] + 2 - $len );
    my $prefix = ( '  ' x $depth ) . $name;
    my $dots   = ' ' . $periods . ' ';
    my $text   = $prefix . $dots;
    my @segments = (
        { text => $prefix, color => $self->_name_color },
        { text => $dots,   color => $self->_muted_colors },
    );
    return ( $text, \@segments );
}

sub _ms_segments {
    my ( $self, $token ) = @_;
    return { text => $token, color => $self->_ms_digits_color }
      unless $token =~ /\A(.+?)(ms)\z/;
    return (
        { text => $1, color => $self->_ms_digits_color },
        { text => $2, color => $self->_ms_suffix_colors },
    );
}

sub _time_report_segments {
    my ( $self, $text ) = @_;
    return unless defined $text;

    if ( ref $text eq 'ARRAY' ) {
        return $self->_segments_from_parts($text);
    }
    return unless length $text;

    my @segments;
    for my $part ( split /(<?\d+ms)/, $text ) {
        next if $part eq '';
        if ( $part =~ /\A<?\d+ms\z/ ) {
            push @segments, $self->_ms_segments($part);
        }
        else {
            push @segments, { text => $part, color => $self->_muted_colors };
        }
    }
    return @segments;
}

sub _output_success {
    my ( $self, $msg ) = @_;
    $self->_set_colors( $self->_success_color() );
    $self->_output($msg);
    $self->_set_colors('reset');
}

sub _failure_output {
    my $self = shift;
    $self->_set_colors( $self->_failure_color() );
    my $out = join '', @_;
    my $has_newline = chomp $out;
    $self->_output($out);
    $self->_set_colors('reset');
    $self->_output($/)
      if $has_newline;
}

1;
