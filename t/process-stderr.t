#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use TAP::Parser::Iterator::Process;

if ( TAP::Parser::Iterator::Process::IS_WIN32() ) {
    plan skip_all => 'STDERR handler not supported on Win32';
}

eval { require IPC::Open3; require IO::Select; 1 }
  or plan skip_all => 'IPC::Open3/IO::Select not available';

my $stderr = '';
my $script = 'print STDERR "err\n"; print "ok 1\n";';
my $proc = TAP::Parser::Iterator::Process->new(
    {   command => [ $^X, '-e', $script ],
        stderr  => sub { $stderr .= $_[0] },
    }
);

my @got;
while ( defined( my $line = $proc->next_raw ) ) {
    push @got, $line;
}

is $stderr, "err\n", 'stderr handler receives output';
is_deeply \@got, ['ok 1'], 'stdout still captured';

done_testing;
