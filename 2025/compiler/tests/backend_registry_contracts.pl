#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use MetaC::HIR::NodeRegistry qw(
    backend_emitter_id_for_op
    node_registry_snapshot
);

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "io error: unable to read '$path': $!\n";
    local $/;
    return <$fh>;
}

sub _op_specs {
    my ($snapshot) = @_;
    my $ops = $snapshot->{operations} // {};
    my @specs;
    push @specs, $ops->{calls}{user} if ref($ops->{calls}{user}) eq 'HASH';
    push @specs, values %{ $ops->{calls}{builtins} // {} };
    push @specs, values %{ $ops->{methods} // {} };
    return @specs;
}

sub _expr_emitter_ids {
    my ($text) = @_;
    my %ids;
    while ($text =~ /'([^']+\.v1)'\s*=>\s*\\&/g) {
        $ids{$1} = 1;
    }
    return \%ids;
}

sub _expr_table_exempt {
    my ($op_id) = @_;
    return 1 if !defined($op_id) || $op_id eq '';
    return 1 if $op_id eq 'call.user.v1';
    return 1 if $op_id =~ /\.unknown\.v1$/;
    return 0;
}

sub main {
    my $snapshot = node_registry_snapshot();
    my $ok = 1;

    for my $spec (_op_specs($snapshot)) {
        next if ref($spec) ne 'HASH';
        my $op_id = $spec->{op_id} // '';
        next if $op_id eq '';
        my $emitter = $spec->{backend_emitter} // '';
        if ($emitter eq '') {
            print "[FAIL] backend_registry_contracts: op '$op_id' missing backend_emitter\n";
            $ok = 0;
            next;
        }
        my $resolved = backend_emitter_id_for_op($op_id) // '';
        if ($resolved ne $emitter) {
            print "[FAIL] backend_registry_contracts: op '$op_id' resolves '$resolved', expected '$emitter'\n";
            $ok = 0;
        }
    }

    my $unknown = backend_emitter_id_for_op('call.synthetic.unknown.v1');
    if (defined($unknown)) {
        print "[FAIL] backend_registry_contracts: unknown op id resolved via fallback\n";
        $ok = 0;
    }

    my $root = "$FindBin::Bin/..";
    my $expr_table = _expr_emitter_ids(_slurp("$root/lib/MetaC/Backend/ExprEmitters.pm"));
    for my $spec (_op_specs($snapshot)) {
        next if ref($spec) ne 'HASH';
        my $op_id = $spec->{op_id} // '';
        next if _expr_table_exempt($op_id);
        my $emitter = $spec->{backend_emitter} // '';
        if (!$expr_table->{$emitter}) {
            print "[FAIL] backend_registry_contracts: emitter '$emitter' for op '$op_id' missing from backend table\n";
            $ok = 0;
        }
    }

    my $expr_backend = _slurp("$root/lib/MetaC/Backend/BackendCExprPart.pm");
    if ($expr_backend =~ /\$op_id\s+eq/) {
        print "[FAIL] backend_registry_contracts: backend expression dispatch branches on op_id\n";
        $ok = 0;
    }
    if ($expr_backend =~ /\$emitter_id\s+eq/ || $expr_backend =~ /_emit_expr_by_backend_emitter\('/) {
        print "[FAIL] backend_registry_contracts: backend expression dispatch bypasses emitter table lookup\n";
        $ok = 0;
    }

    print "[PASS] backend_registry_contracts\n" if $ok;
    print "\nSummary: " . ($ok ? '1 passed, 0 failed' : '0 passed, 1 failed') . "\n";
    return $ok ? 0 : 1;
}

exit(main());
