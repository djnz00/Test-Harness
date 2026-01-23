package TAP::Formatter::Base;

use strict;
use warnings;
use base 'TAP::Base';
use POSIX qw(strftime);

my $MAX_ERRORS = 5;
my %VALIDATION_FOR;

BEGIN {
    %VALIDATION_FOR = (
        directives => sub { shift; shift },
        verbosity  => sub { shift; shift },
        normalize  => sub { shift; shift },
        timer      => sub { shift; shift },
        failures   => sub { shift; shift },
        comments   => sub { shift; shift },
        errors     => sub { shift; shift },
        color      => sub { shift; shift },
        jobs       => sub { shift; shift },
        show_count => sub { shift; shift },
        expand     => sub { shift; shift },
        poll       => sub { shift; shift },
        utf        => sub { shift; shift },
        width      => sub {
            my ( $self, $width ) = @_;
            $self->_croak("option 'width' expects a non-negative integer")
              unless defined $width && $width =~ /\A\d+\z/;
            return $width;
        },
        stdout     => sub {
            my ( $self, $ref ) = @_;

            $self->_croak("option 'stdout' needs a filehandle")
              unless $self->_is_filehandle($ref);

            return $ref;
        },
    );

    sub _is_filehandle {
        my ( $self, $ref ) = @_;

        return 0 if !defined $ref;

        return 1 if ref $ref eq 'GLOB';    # lexical filehandle
        return 1 if !ref $ref && ref \$ref eq 'GLOB'; # bare glob like *STDOUT

        return 1 if eval { $ref->can('print') };

        return 0;
    }

    my @getter_setters = qw(
      _longest
      _printed_summary_header
      _colorizer
      _effective_width
      _width_source
    );

    __PACKAGE__->mk_methods( @getter_setters, keys %VALIDATION_FOR );
}

=head1 NAME

TAP::Formatter::Base - Base class for harness output delegates

=head1 VERSION

Version 3.51_01

=cut

our $VERSION = '3.51_01';

=head1 DESCRIPTION

This provides console orientated output formatting for TAP::Harness.

=head1 SYNOPSIS

 use TAP::Formatter::Console;
 my $harness = TAP::Formatter::Console->new( \%args );

=cut

sub _initialize {
    my ( $self, $arg_for ) = @_;
    $arg_for ||= {};

    $self->SUPER::_initialize($arg_for);
    my %arg_for = %$arg_for;    # force a shallow copy

    $self->verbosity(0);

    for my $name ( keys %VALIDATION_FOR ) {
        my $property = delete $arg_for{$name};
        if ( defined $property ) {
            my $validate = $VALIDATION_FOR{$name};
            $self->$name( $self->$validate($property) );
        }
    }

    if ( my @props = keys %arg_for ) {
        $self->_croak(
            "Unknown arguments to " . __PACKAGE__ . "::new (@props)" );
    }

    $self->stdout( \*STDOUT ) unless $self->stdout;

    if ( $self->color ) {
        require TAP::Formatter::Color;
        $self->_colorizer( TAP::Formatter::Color->new );
    }

    my $interactive = $self->_is_interactive;
    if ( !defined $self->poll && $interactive ) {
        $self->poll(100);
    }
    if ( !defined $self->utf ) {
        $self->utf(1);
    }

    return $self;
}

sub verbose      { shift->verbosity >= 1 }
sub quiet        { shift->verbosity <= -1 }
sub really_quiet { shift->verbosity <= -2 }
sub silent       { shift->verbosity <= -3 }

=head1 METHODS

=head2 Class Methods

=head3 C<new>

 my %args = (
    verbose => 1,
 )
 my $harness = TAP::Formatter::Console->new( \%args );

The constructor returns a new C<TAP::Formatter::Console> object. If
a L<TAP::Harness> is created with no C<formatter> a
C<TAP::Formatter::Console> is automatically created. If any of the
following options were given to TAP::Harness->new they well be passed to
this constructor which accepts an optional hashref whose allowed keys are:

=over 4

=item * C<verbosity>

Set the verbosity level.

=item * C<verbose>

Printing individual test results to STDOUT.

=item * C<timer>

Append run time for each test to output. Uses L<Time::HiRes> if available.

=item * C<failures>

Show test failures (this is a no-op if C<verbose> is selected).

=item * C<comments>

Show test comments (this is a no-op if C<verbose> is selected).

=item * C<quiet>

Suppressing some test output (mostly failures while tests are running).

=item * C<really_quiet>

Suppressing everything but the tests summary.

=item * C<silent>

Suppressing all output.

=item * C<errors>

If parse errors are found in the TAP output, a note of this will be made
in the summary report.  To see all of the parse errors, set this argument to
true:

  errors => 1

=item * C<directives>

If set to a true value, only test results with directives will be displayed.
This overrides other settings such as C<verbose>, C<failures>, or C<comments>.

=item * C<stdout>

A filehandle for catching standard output.

=item * C<color>

If defined specifies whether color output is desired. If C<color> is not
defined it will default to color output if color support is available on
the current platform and output is not being redirected.

=item * C<jobs>

The number of concurrent jobs this formatter will handle.

=item * C<show_count>

Boolean value.  If false, disables the C<X/Y> test count which shows up while
tests are running.

=item * C<expand>

Integer value.  If true, expands subtests in console output to the given
maximum depth.

=back

Any keys for which the value is C<undef> will be ignored.

=cut

# new supplied by TAP::Base

=head3 C<prepare>

Called by Test::Harness before any test output is generated. 

This is an advisory and may not be called in the case where tests are
being supplied to Test::Harness by an iterator.

=cut

sub prepare {
    my ( $self, @tests ) = @_;

    my $longest = 0;

    for my $test (@tests) {
        $longest = length $test if length $test > $longest;
    }

    $self->_longest($longest);
    $self->_effective_width( $self->_resolve_width(@tests) );
}

sub _format_now { strftime "[%H:%M:%S]", localtime }

sub _min_width { 28 }

sub _terminal_columns {
    my $self = shift;

    require Term::ReadKey;
    my ($cols) = Term::ReadKey::GetTerminalSize( $self->stdout );
    return $cols if defined $cols && $cols =~ /\A\d+\z/;

    return $ENV{COLUMNS}
      if defined $ENV{COLUMNS} && $ENV{COLUMNS} =~ /\A\d+\z/;

    return;
}

sub _clamp_width {
    my ( $self, $width ) = @_;
    my $min = $self->_min_width;
    return $width < $min ? $min : $width;
}

sub _count_trailer_enabled {
    my $self = shift;
    return 0 unless $self->show_count;
    return 0 if $self->verbose;
    return $self->_is_interactive;
}

sub _max_trailer_len {
    my ( $self, $context ) = @_;
    if ($self->_count_trailer_enabled) {
	my $count_len = length(' MMMM/NNNN');
	$count_len += length(' X') if $self->_is_interactive;
	return $count_len;
    }
    return $self->utf ? length(' x') : length(' not ok');
}

sub _dot_count {
    my ( $self, $header_len, $trailer_len ) = @_;
    my $width = $self->_effective_width;
    $width = $self->_min_width unless defined $width;
    my $dots = $width - $header_len - $trailer_len - 1;
    $dots = 3 if $dots < 3;
    return $dots;
}

sub _truncate_name {
    my ( $self, $name, $max_len ) = @_;
    return $name unless defined $max_len;
    $max_len = 8 if $max_len < 8;
    return $name if length $name <= $max_len;
    return substr( $name, 0, $max_len - 3 ) . '...';
}

sub _subtest_name_parts {
    my ( $self, $depth, $name ) = @_;

    my $indent = '  ' x $depth;
    my $effective = $self->_ensure_effective_width();
    my $trailer_len = $self->_max_trailer_len('subtest');

    my $header_prefix_len = length($indent) + 1;
    my $available
      = $effective - $trailer_len - 4 - $header_prefix_len;
    $name = $self->_truncate_name( $name, $available );

    my $header_len = $header_prefix_len + length($name);
    my $dots = '.' x $self->_dot_count( $header_len, $trailer_len );
    my $periods = " $dots ";
    my $prefix = $indent . $name;
    my $text = $prefix . $periods;

    return ( $prefix, $periods, $text );
}

sub _default_width_for_longest {
    my ( $self, $longest ) = @_;
    $longest ||= 0;
    my $header_len = $longest + 1;
    my $width
      = $header_len + 4 + $self->_max_trailer_len('top');
    return $self->_clamp_width($width);
}

sub _resolve_width {
    my ( $self, @tests ) = @_;
    if ( defined( my $width = $self->width ) ) {
        $self->_width_source('width');
        return $self->_clamp_width($width);
    }

    my $longest = 0;
    for my $test (@tests) {
        my $len = length $test;
        $longest = $len if $len > $longest;
    }

    if ( $self->_is_interactive ) {
        my $cols = $self->_terminal_columns;
        if ( defined $cols ) {
            if ( !$self->expand ) {
                my $computed = $self->_default_width_for_longest($longest);
                my $width = $cols < $computed ? $cols : $computed;
                $self->_width_source(
                      $width == $computed
                    ? 'computed'
                    : 'terminal'
                );
                return $self->_clamp_width($width);
            }
            $self->_width_source('terminal');
            return $self->_clamp_width($cols);
        }
    }

    $self->_width_source('computed');
    return $self->_default_width_for_longest($longest);
}

sub _ensure_effective_width {
    my ( $self, $test ) = @_;
    if ( defined( my $width = $self->width ) ) {
        my $effective = $self->_clamp_width($width);
        $self->_effective_width($effective)
          unless defined $self->_effective_width;
        $self->_width_source('width') unless $self->_width_source;
        return $self->_effective_width;
    }

    if ( $self->_is_interactive ) {
        return $self->_effective_width if defined $self->_effective_width;

        my $cols = $self->_terminal_columns;
        if ( defined $cols ) {
            if ( !$self->expand ) {
                my $longest = $self->_longest || 0;
                if ( defined $test ) {
                    my $len = length $test;
                    $longest = $len if $len > $longest;
                    $self->_longest($longest);
                }
                my $computed = $self->_default_width_for_longest($longest);
                my $width = $cols < $computed ? $cols : $computed;
                my $effective = $self->_clamp_width($width);
                $self->_effective_width($effective);
                $self->_width_source(
                      $width == $computed
                    ? 'computed'
                    : 'terminal'
                );
                return $effective;
            }

            my $effective = $self->_clamp_width($cols);
            $self->_effective_width($effective);
            $self->_width_source('terminal');
            return $effective;
        }

        my $longest = $self->_longest || 0;
        if ( defined $test ) {
            my $len = length $test;
            $longest = $len if $len > $longest;
            $self->_longest($longest);
        }
        my $effective = $self->_default_width_for_longest($longest);
        $self->_effective_width($effective)
          unless defined $self->_effective_width;
        $self->_width_source('computed') unless $self->_width_source;
        return $self->_effective_width;
    }

    my $longest = $self->_longest || 0;
    if ( defined $test ) {
        my $len = length $test;
        $longest = $len if $len > $longest;
        $self->_longest($longest);
    }
    my $candidate = $self->_default_width_for_longest($longest);
    if ( !defined $self->_effective_width
        || $candidate > $self->_effective_width )
    {
        $self->_effective_width($candidate);
        $self->_width_source('computed');
    }

    return $self->_effective_width;
}

sub _format_name {
    my ( $self, $test ) = @_;
    my $name = $test;
    my $prefix = '';
    my $prefix_len = 0;

    my $effective = $self->_ensure_effective_width($test);
    my $trailer_len = $self->_max_trailer_len('top');

    if ( $self->timer ) {
        my $stamp = $self->_format_now();
        $prefix     = "$stamp ";
        $prefix_len = length($stamp) + 1;
    }

    my $header_prefix_len = $prefix_len + 1;
    my $allow_truncate
      = $self->_is_interactive || defined $self->width;
    if ($allow_truncate) {
        my $available
          = $effective - $trailer_len - 4 - $header_prefix_len;
        $name = $self->_truncate_name( $name, $available );
    }

    my $header_len = $header_prefix_len + length($name);
    my $dots = '.' x $self->_dot_count( $header_len, $trailer_len );
    my $periods = " $dots ";

    return $prefix . $name . $periods;

}

=head3 C<open_test>

Called to create a new test session. A test session looks like this:

    my $session = $formatter->open_test( $test, $parser );
    while ( defined( my $result = $parser->next ) ) {
        $session->result($result);
        exit 1 if $result->is_bailout;
    }
    $session->close_test;

=cut

sub open_test {
    die "Unimplemented.";
}

sub tick {
    return;
}

sub _is_interactive {
    my $self = shift;
    return -t $self->stdout && !$ENV{HARNESS_NOTTY};
}

sub _output_success {
    my ( $self, $msg ) = @_;
    $self->_output($msg);
}

=head3 C<summary>

  $harness->summary( $aggregate );

C<summary> prints the summary report after all tests are run. The first
argument is an aggregate to summarise. An optional second argument may
be set to a true value to indicate that the summary is being output as a
result of an interrupted test run.

=cut

sub summary {
    my ( $self, $aggregate, $interrupted ) = @_;

    return if $self->silent;

    my @t     = $aggregate->descriptions;
    my $tests = \@t;

    my $elapsed = $aggregate->elapsed;
    my ( $real, $usr, $sys ) = @{$elapsed}[ 0 .. 2 ];
    if ( $aggregate->can('wallclock_elapsed') ) {
        my $wallclock = $aggregate->wallclock_elapsed;
        $real = $wallclock if defined $wallclock;
    }
    my $wall = $self->_format_time_ms($real);
    my $usr_ms = $self->_format_time_ms($usr);
    my $sys_ms = $self->_format_time_ms($sys);
    my $cpu_ms = $self->_format_time_ms( $usr + $sys );
    my @runtime_parts = (
        { kind => 'ms',   text => $wall },
        { kind => 'text', text => ' wallclock (' },
        { kind => 'ms',   text => $usr_ms },
        { kind => 'text', text => ' usr + ' },
        { kind => 'ms',   text => $sys_ms },
        { kind => 'text', text => ' sys = ' },
        { kind => 'ms',   text => $cpu_ms },
        { kind => 'text', text => ' CPU)' },
    );

    my $total  = $aggregate->total;
    my $passed = $aggregate->passed;

    if ( $self->timer ) {
        $self->_output( $self->_format_now(), "\n" );
    }

    $self->_failure_output("Test run interrupted!\n")
      if $interrupted;

    # TODO: Check this condition still works when all subtests pass but
    # the exit status is nonzero

    if ( $aggregate->all_passed ) {
        $self->_output_success("All tests successful.\n");
    }

    # ~TODO option where $aggregate->skipped generates reports
    if ( $total != $passed or $aggregate->has_problems ) {
        $self->_output("\nTest Summary Report");
        $self->_output("\n-------------------\n");
        for my $test (@$tests) {
            $self->_printed_summary_header(0);
            my ($parser) = $aggregate->parsers($test);
            $self->_output_summary_failure(
                'failed',
                [ '  Failed test:  ', '  Failed tests:  ' ],
                $test, $parser
            );
            $self->_output_summary_failure(
                'todo_passed',
                "  TODO passed:   ", $test, $parser
            );

            # ~TODO this cannot be the default
            #$self->_output_summary_failure( 'skipped', "  Tests skipped: " );

            if ( my $exit = $parser->exit ) {
                $self->_summary_test_header( $test, $parser );
                $self->_failure_output("  Non-zero exit status: $exit\n");
            }
            elsif ( my $wait = $parser->wait ) {
                $self->_summary_test_header( $test, $parser );
                $self->_failure_output("  Non-zero wait status: $wait\n");
            }

            if ( my @errors = $parser->parse_errors ) {
                my $explain;
                if ( @errors > $MAX_ERRORS && !$self->errors ) {
                    $explain
                      = "Displayed the first $MAX_ERRORS of "
                      . scalar(@errors)
                      . " TAP syntax errors.\n"
                      . "Re-run prove with the -p option to see them all.\n";
                    splice @errors, $MAX_ERRORS;
                }
                $self->_summary_test_header( $test, $parser );
                $self->_failure_output(
                    sprintf "  Parse errors: %s\n",
                    shift @errors
                );
                for my $error (@errors) {
                    my $spaces = ' ' x 16;
                    $self->_failure_output("$spaces$error\n");
                }
                $self->_failure_output($explain) if $explain;
            }
        }
    }
    my $files = @$tests;
    $self->_summary_runtime_line( $files, $total, \@runtime_parts );
    my $status = $aggregate->get_status;
    $self->_output_result_status($status);
}

sub _summary_runtime_line {
    my ( $self, $files, $total, $runtime ) = @_;
    if ( ref $runtime eq 'ARRAY' ) {
        my $text = join '', map { $_->{text} } @{$runtime};
        $self->_output("Files=$files, Tests=$total, $text\n");
        return;
    }
    $self->_output("Files=$files, Tests=$total, $runtime\n");
}

sub _output_result_status {
    my ( $self, $status ) = @_;
    $self->_output("Result: $status\n");
}

sub _output_summary_failure {
    my ( $self, $method, $name, $test, $parser ) = @_;

    # ugly hack.  Must rethink this :(
    my $output = $method eq 'failed' ? '_failure_output' : '_output';

    if ( my @r = $parser->$method() ) {
        $self->_summary_test_header( $test, $parser );
        my ( $singular, $plural )
          = 'ARRAY' eq ref $name ? @$name : ( $name, $name );
        $self->$output( @r == 1 ? $singular : $plural );
        my @results = $self->_balanced_range( 40, @r );
        $self->$output( sprintf "%s\n" => shift @results );
        my $spaces = ' ' x 16;
        while (@results) {
            $self->$output( sprintf "$spaces%s\n" => shift @results );
        }
    }
}

sub _summary_test_header {
    my ( $self, $test, $parser ) = @_;
    return if $self->_printed_summary_header;
    my $spaces = ' ' x ( $self->_longest - length $test );
    $spaces = ' ' unless $spaces;
    my $output = $self->_get_output_method($parser);
    my $wait   = $parser->wait;

    if (defined $wait) {
        my $signum = $wait & 0x7f;

        my $description;

        if ($signum) {
            require Config;
            my @names = split ' ', $Config::Config{'sig_name'};
            $description = "Signal: $names[$signum]";

            my $dumped = $wait & 0x80;
            $description .= ', dumped core' if $dumped;
        }
        elsif ($wait != 0) {
            $description = sprintf 'exited %d', ($wait >> 8);
        }

        $wait .= " ($description)" if $wait != 0;
    }
    else {
        $wait = '(none)';
    }

    $self->$output(
        sprintf "$test$spaces(Wstat: %s Tests: %d Failed: %d)\n",
        $wait, $parser->tests_run, scalar $parser->failed
    );
    $self->_printed_summary_header(1);
}

sub _output {
    print { shift->stdout } @_;
}

sub _failure_output {
    my $self = shift;

    $self->_output(@_);
}

sub _balanced_range {
    my ( $self, $limit, @range ) = @_;
    @range = $self->_range(@range);
    my $line = "";
    my @lines;
    my $curr = 0;
    while (@range) {
        if ( $curr < $limit ) {
            my $range = ( shift @range ) . ", ";
            $line .= $range;
            $curr += length $range;
        }
        elsif (@range) {
            $line =~ s/, $//;
            push @lines => $line;
            $line = '';
            $curr = 0;
        }
    }
    if ($line) {
        $line =~ s/, $//;
        push @lines => $line;
    }
    return @lines;
}

sub _range {
    my ( $self, @numbers ) = @_;

    # shouldn't be needed, but subclasses might call this
    @numbers = sort { $a <=> $b } @numbers;
    my ( $min, @range );

    for my $i ( 0 .. $#numbers ) {
        my $num  = $numbers[$i];
        my $next = $numbers[ $i + 1 ];
        if ( defined $next && $next == $num + 1 ) {
            if ( !defined $min ) {
                $min = $num;
            }
        }
        elsif ( defined $min ) {
            push @range => "$min-$num";
            undef $min;
        }
        else {
            push @range => $num;
        }
    }
    return @range;
}

sub _get_output_method {
    my ( $self, $parser ) = @_;
    return $parser->has_problems ? '_failure_output' : '_output';
}

1;
