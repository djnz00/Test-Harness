package TAP::Formatter::Console::Subtest;

use strict;
use warnings;

use base 'TAP::Object';

=head1 NAME

TAP::Formatter::Console::Subtest - Parse subtest TAP for console expansion

=head1 VERSION

Version 3.51_01

=cut

our $VERSION = '3.51_01';

sub _initialize {
    my ( $self, $arg_for ) = @_;
    $arg_for ||= {};

    $self->{max_depth} = $arg_for->{max_depth} || 0;
    $self->{stack}     = [];

    return $self;
}

sub max_depth { shift->{max_depth} }

sub consume_line {
    my ( $self, $raw ) = @_;
    return () unless defined $raw;

    my $line = $raw;
    $line =~ s/\r?\n\z//;

    my ($spaces) = ( $line =~ /^( *)/ );
    my $indent = length $spaces;
    return () if $indent % 4;

    my $level   = $indent / 4;
    my $content = substr( $line, $indent );

    my $max_depth = $self->max_depth;
    my $stack     = $self->{stack};

    if ( $content =~ /^#\s*Subtest:\s*(.*?)\s*$/ ) {
        my $depth = $level + 1;
        if ( $max_depth && $depth <= $max_depth ) {
            if ( !@$stack || $depth == $stack->[-1]{depth} + 1 ) {
                push @$stack,
                  {
                    depth   => $depth,
                    name    => $1,
                    planned => undef,
                    run     => 0,
                    failed  => 0,
                  };
            }
        }
        return ();
    }

    return () unless @$stack;

    if ( $content =~ /^1\.\.(\d+)/ ) {
        if ( my $subtest = _find_depth( $stack, $level ) ) {
            $subtest->{planned} = $1;
        }
        return ();
    }

    if ( $content =~ /^(not )?ok\b/i ) {
        my $is_ok = _is_ok_from_line($content);
        my @events;

        if ( $stack->[-1]{depth} == $level + 1 ) {
            my $subtest = pop @$stack;
            push @events,
              {
                type  => 'final',
                depth => $subtest->{depth},
                name  => $subtest->{name},
                ok    => $is_ok,
              };
        }

        if ( my $subtest = _find_depth( $stack, $level ) ) {
            $subtest->{run}++;
            my $planned = defined $subtest->{planned}
              ? $subtest->{planned}
              : '?';
            if ( $planned eq '?' || $subtest->{run} < $planned ) {
                push @events,
                  {
                    type    => 'progress',
                    depth   => $subtest->{depth},
                    name    => $subtest->{name},
                    run     => $subtest->{run},
                    planned => $planned,
                  };
            }
        }

        return @events;
    }

    return ();
}

sub _find_depth {
    my ( $stack, $depth ) = @_;
    for ( my $i = $#$stack ; $i >= 0 ; $i-- ) {
        return $stack->[$i] if $stack->[$i]{depth} == $depth;
    }
    return;
}

sub _is_ok_from_line {
    my ($line) = @_;
    return 1 if $line =~ /#\s*(?:TODO|SKIP)\b/i;
    return $line !~ /^not\s+ok\b/i;
}

1;

__END__

=head1 DESCRIPTION

Consumes raw TAP lines and emits events for subtest progress and final
status. Intended for console subtest expansion.

=cut
