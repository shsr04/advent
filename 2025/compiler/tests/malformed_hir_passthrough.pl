#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use MetaC::HIR::BackendC qw(codegen_from_vnf_hir);
use MetaC::HIR::NodeRegistry qw(
    backend_emitter_id_for_op
    exit_edge_tags
    exit_target_fields
    node_registry_snapshot
    statement_backend_emitter_id
    statement_recognizers
    statement_step_kind
);

sub _fixture_malformed_expr_and_exit {
    return {
        functions => [
            {
                name => 'main',
                return_type => 'number',
                params => [],
                region_schedule => ['r0'],
                regions => [
                    {
                        id => 'r0',
                        steps => [
                            {
                                payload => {
                                    node_kind => 'Stmt',
                                    stmt_kind => 'expr_stmt',
                                    line => 1,
                                    fields => {
                                        expr => { kind => 'mystery_expr' },
                                    },
                                },
                            },
                        ],
                        exit => { kind => 'WeirdExit' },
                    },
                ],
            },
        ],
    };
}

sub _fixture_malformed_stmt_kind {
    return {
        functions => [
            {
                name => 'main',
                return_type => 'number',
                params => [],
                region_schedule => ['r0'],
                regions => [
                    {
                        id => 'r0',
                        steps => [
                            {
                                payload => {
                                    node_kind => 'Stmt',
                                    stmt_kind => 'unknown_stmt',
                                    line => 1,
                                    fields => {},
                                },
                            },
                        ],
                        exit => { kind => 'Return', value => { kind => 'num', value => 0 } },
                    },
                ],
            },
        ],
    };
}

sub _run_fixture {
    my (%args) = @_;
    my $name = $args{name};
    my $hir = $args{hir};
    my @needles = @{ $args{needles} // [] };

    my $c = eval { codegen_from_vnf_hir($hir) };
    if (!defined($c) || $@) {
        my $err = $@ // 'unknown backend error';
        print "[FAIL] $name: backend rejected malformed HIR: $err\n";
        return 0;
    }

    for my $needle (@needles) {
        if (index($c, $needle) < 0) {
            print "[FAIL] $name: missing diagnostic marker '$needle'\n";
            return 0;
        }
    }

    print "[PASS] $name\n";
    return 1;
}

sub _run_registry_contracts {
    my $snapshot = node_registry_snapshot();
    my $ok = 1;

    my $statements = $snapshot->{statements} // {};
    my %recognizer_for = map { ($_->{stmt_kind} // '') => 1 } @{ statement_recognizers() };
    for my $kind (sort keys %$statements) {
        my $step = statement_step_kind($kind);
        my $emitter = statement_backend_emitter_id($kind);
        if (!defined($step) || $step eq '' || !defined($emitter) || $emitter eq '') {
            print "[FAIL] registry_contracts: statement '$kind' missing step/emitter metadata\n";
            $ok = 0;
        }
        if (!$recognizer_for{$kind}) {
            print "[FAIL] registry_contracts: statement '$kind' missing parser recognizer metadata\n";
            $ok = 0;
        }
    }

    my $exits = $snapshot->{exits} // {};
    for my $kind (sort keys %$exits) {
        my $edges = exit_edge_tags($kind);
        my $targets = exit_target_fields($kind);
        if (ref($edges) ne 'ARRAY' || ref($targets) ne 'ARRAY') {
            print "[FAIL] registry_contracts: exit '$kind' missing edge/target metadata\n";
            $ok = 0;
        }
    }

    my $ops = $snapshot->{operations} // {};
    my @op_ids = ($ops->{calls}{user}{op_id});
    push @op_ids, map { $_->{op_id} } values %{ $ops->{calls}{builtins} // {} };
    push @op_ids, map { $_->{op_id} } values %{ $ops->{methods} // {} };
    for my $op_id (grep { defined($_) && $_ ne '' } @op_ids) {
        my $emitter = backend_emitter_id_for_op($op_id);
        if (!defined($emitter) || $emitter eq '') {
            print "[FAIL] registry_contracts: op '$op_id' missing backend emitter metadata\n";
            $ok = 0;
        }
    }

    print "[PASS] registry_contracts\n" if $ok;
    return $ok;
}

sub main {
    my @fixtures = (
        {
            name => 'malformed_expr_and_exit_passthrough',
            hir => _fixture_malformed_expr_and_exit(),
            needles => [
                "Backend/F054 missing expr emitter for kind 'mystery_expr'",
                "Backend/F054 missing exit emitter for kind 'WeirdExit'",
            ],
        },
        {
            name => 'malformed_stmt_passthrough',
            hir => _fixture_malformed_stmt_kind(),
            needles => [
                "Backend/F054 missing stmt emitter for kind 'unknown_stmt'",
            ],
        },
    );

    my $pass = 0;
    my $fail = 0;
    if (_run_registry_contracts()) {
        $pass += 1;
    } else {
        $fail += 1;
    }
    for my $f (@fixtures) {
        if (_run_fixture(%$f)) {
            $pass += 1;
        } else {
            $fail += 1;
        }
    }

    print "\nSummary: $pass passed, $fail failed\n";
    return $fail == 0 ? 0 : 1;
}

exit(main());
