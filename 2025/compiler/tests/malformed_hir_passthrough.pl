#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use MetaC::HIR::BackendC qw(codegen_from_vnf_hir);

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
