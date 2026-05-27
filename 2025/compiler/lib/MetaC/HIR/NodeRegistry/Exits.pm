package MetaC::HIR::NodeRegistry::Exits;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(exit_registry_snapshot exit_spec exit_edge_tags exit_target_fields);

my %EXITS = (
    Goto => { edge_tags => [qw(goto)] },
    IfExit => { edge_tags => [qw(then else join)] },
    WhileExit => { edge_tags => [qw(body continue break rewind end)] },
    ForInExit => { edge_tags => [qw(body continue break rewind error end)] },
    TryExit => { edge_tags => [qw(ok err)] },
    Return => { edge_tags => [] },
    PropagateError => { edge_tags => [] },
);

my %EXIT_TARGET_FIELDS = (
    Goto => [qw(targetRegion target)],
    IfExit => [qw(thenRegion elseRegion joinRegion)],
    TryExit => [qw(okRegion errRegion)],
    ForInExit => [qw(bodyRegion continueRegion breakRegion rewindRegion errorRegion endRegion)],
    WhileExit => [qw(bodyRegion continueRegion breakRegion rewindRegion endRegion)],
    Return => [],
    PropagateError => [],
);

sub exit_registry_snapshot { return { exits => \%EXITS, target_fields => \%EXIT_TARGET_FIELDS }; }
sub exit_spec { my ($kind) = @_; return undef if !defined($kind) || $kind eq ''; return $EXITS{$kind}; }
sub exit_edge_tags { my ($kind) = @_; my $spec = exit_spec($kind); return [] if !defined($spec); return $spec->{edge_tags} // []; }
sub exit_target_fields { my ($kind) = @_; return [] if !defined($kind) || $kind eq ''; return $EXIT_TARGET_FIELDS{$kind} // []; }

1;
