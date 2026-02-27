package MetaC::HIR::Lowering;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::Parser qw(collect_functions parse_function_params parse_function_body);
use MetaC::TypeSpec qw(normalize_type_annotation);
use MetaC::HIR::TypedNodes qw(stmt_to_payload step_payload_to_stmt);

our @EXPORT_OK = qw(lower_source_to_vnf_hir);

sub _new_id_alloc {
    return { fn => 0, region => 0, step => 0, fact => 0, edge => 0, loop => 0 };
}

sub _next_id {
    my ($alloc, $kind) = @_;
    my $n = $alloc->{$kind}++;
    my %prefix = (fn => 'f', region => 'r', step => 's', fact => 't', edge => 'e');
    return $prefix{$kind} . $n;
}

sub _next_loop_id {
    my ($alloc) = @_;
    return 'L' . $alloc->{loop}++;
}

sub _normalized_return_type {
    my ($fn) = @_;
    my $ret = $fn->{return_type};
    return 'number' if !defined $ret && $fn->{name} eq 'main';
    return undef if !defined $ret;
    return normalize_type_annotation($ret);
}

sub _normalize_function_map {
    my ($functions) = @_;
    compile_error("Missing required function: main") if !exists $functions->{main};

    my $main = $functions->{main};
    compile_error("main must not declare arguments") if $main->{args} ne '';
    my $main_ret = _normalized_return_type($main);
    compile_error("main return type must be number") if $main_ret ne 'number';

    my @ordered_names = sort grep { $_ ne 'main' } keys %$functions;
    push @ordered_names, 'main';

    for my $name (@ordered_names) {
        my $fn = $functions->{$name};
        $fn->{return_type} = _normalized_return_type($fn);
        $fn->{parsed_params} = parse_function_params($fn);
    }
    return \@ordered_names;
}

sub _entry_facts_from_params {
    my ($params, $alloc, $line) = @_;
    my @facts;
    for my $param (@$params) {
        push @facts, {
            id         => _next_id($alloc, 'fact'),
            kind       => 'type',
            subject    => $param->{name},
            predicate  => "type:$param->{name}:$param->{type}",
            provenance => { line => $line },
        };
    }
    return \@facts;
}

sub _step_kind_from_stmt_kind {
    my ($kind) = @_;
    return 'Declare' if $kind eq 'let' || $kind eq 'const';
    return 'Assign' if $kind eq 'assign' || $kind eq 'typed_assign' || $kind eq 'assign_op' || $kind eq 'incdec';
    return 'Destructure' if $kind =~ /^destructure_/;
    return 'Eval' if $kind eq 'expr_stmt' || $kind eq 'expr_stmt_try' || $kind eq 'const_try_expr' || $kind eq 'const_try_tail_expr';
    return 'Control';
}

sub _step_from_stmt {
    my ($stmt, $alloc) = @_;
    return {
        id         => _next_id($alloc, 'step'),
        kind       => _step_kind_from_stmt_kind($stmt->{kind} // ''),
        payload    => stmt_to_payload($stmt),
        provenance => { line => $stmt->{line} },
    };
}

sub _edges_from_regions {
    my ($regions, $alloc) = @_;
    my @edges;
    for my $region (@$regions) {
        my $exit = $region->{exit};
        my $kind = $exit->{kind} // '';
        my @targets;
        if ($kind eq 'Goto') {
            @targets = ([ goto => $exit->{target_region} ]);
        } elsif ($kind eq 'IfExit') {
            @targets = (
                [ then => $exit->{then_region} ],
                [ else => $exit->{else_region} ],
                [ join => $exit->{join_region} ],
            );
        } elsif ($kind eq 'WhileExit') {
            @targets = (
                [ body => $exit->{body_region} ],
                [ continue => $exit->{continue_region} ],
                [ break => $exit->{break_region} ],
                [ rewind => $exit->{rewind_region} ],
                [ end => $exit->{end_region} ],
            );
        } elsif ($kind eq 'ForInExit') {
            @targets = (
                [ body => $exit->{body_region} ],
                [ continue => $exit->{continue_region} ],
                [ break => $exit->{break_region} ],
                [ rewind => $exit->{rewind_region} ],
                [ error => $exit->{error_region} ],
                [ end => $exit->{end_region} ],
            );
        } elsif ($kind eq 'TryExit') {
            @targets = (
                [ ok => $exit->{ok_region} ],
                [ err => $exit->{err_region} ],
            );
        } else {
            next if $kind eq 'Return' || $kind eq 'PropagateError' || $kind eq '';
            compile_error("Lowering internal error: unsupported exit kind '$kind'");
        }
        for my $target (@targets) {
            my ($tag, $to) = @$target;
            push @edges, {
                id          => _next_id($alloc, 'edge'),
                from_region => $region->{id},
                exit_tag    => $tag,
                to_region   => $to,
            };
        }
    }
    return \@edges;
}

sub _flat_body_steps {
    my ($body, $alloc) = @_;
    my @steps = map { _step_from_stmt($_, $alloc) } @{ $body // [] };
    return \@steps;
}

sub _new_region {
    my (%args) = @_;
    return {
        id                => $args{id},
        steps             => $args{steps},
        exit              => $args{exit},
        facts_in          => [],
        facts_out_by_exit => {},
        provenance        => { line => $args{line} // 0 },
    };
}

sub _expand_if_exit {
    my ($region, $stmt, $next, $alloc) = @_;
    my $then_r = _next_id($alloc, 'region');
    my $else_r = _next_id($alloc, 'region');
    $region->{exit} = {
        kind        => 'IfExit',
        cond_value  => $stmt->{cond},
        then_region => $then_r,
        else_region => $else_r,
        join_region => $next,
    };
    return (
        _new_region(
            id    => $then_r,
            steps => _flat_body_steps($stmt->{then_body}, $alloc),
            exit  => { kind => 'Goto', target_region => $next },
            line  => $stmt->{line},
        ),
        _new_region(
            id    => $else_r,
            steps => _flat_body_steps($stmt->{else_body} // [], $alloc),
            exit  => { kind => 'Goto', target_region => $next },
            line  => $stmt->{line},
        ),
    );
}

sub _expand_loop_exit {
    my (%args) = @_;
    my $region = $args{region};
    my $stmt = $args{stmt};
    my $next = $args{next};
    my $alloc = $args{alloc};
    my $for_mode = $args{for_mode} ? 1 : 0;

    my $body_r = _next_id($alloc, 'region');
    my $loop_id = _next_loop_id($alloc);
    my $body = _new_region(
        id    => $body_r,
        steps => _flat_body_steps($stmt->{body}, $alloc),
        exit  => { kind => 'Goto', target_region => $region->{id} },
        line  => $stmt->{line},
    );

    if ($for_mode) {
        $region->{exit} = {
            kind            => 'ForInExit',
            loop_id         => $loop_id,
            item_name       => $stmt->{var},
            iterable_expr   => $stmt->{iterable},
            body_region     => $body_r,
            continue_region => $region->{id},
            break_region    => $next,
            rewind_region   => $region->{id},
            error_region    => $next,
            end_region      => $next,
        };
    } else {
        $region->{exit} = {
            kind            => 'WhileExit',
            loop_id         => $loop_id,
            cond_value      => $stmt->{cond},
            body_region     => $body_r,
            continue_region => $region->{id},
            break_region    => $next,
            rewind_region   => $region->{id},
            end_region      => $next,
        };
    }
    return ($body);
}

sub _expand_try_exit {
    my ($region, $stmt, $next, $alloc) = @_;
    my $ok_r = _next_id($alloc, 'region');
    my $err_r = _next_id($alloc, 'region');
    $region->{exit} = {
        kind          => 'TryExit',
        result_id     => $region->{steps}[0]{id},
        fallible_expr => $stmt->{expr} // $stmt->{tail_expr} // { kind => 'unknown_try' },
        ok_region     => $ok_r,
        err_region    => $err_r,
    };
    return (
        _new_region(
            id    => $ok_r,
            steps => [],
            exit  => { kind => 'Goto', target_region => $next },
            line  => $stmt->{line},
        ),
        _new_region(
            id    => $err_r,
            steps => [],
            exit  => { kind => 'PropagateError', error_value => '__try_error' },
            line  => $stmt->{line},
        ),
    );
}

sub _inject_structured_exit_regions {
    my ($regions, $alloc) = @_;
    my $i = 0;
    while ($i <= $#$regions) {
        my $region = $regions->[$i];
        $i++;
        next if !@{ $region->{steps} };

        my $stmt = step_payload_to_stmt($region->{steps}[0]{payload});
        next if !defined $stmt;
        my $kind = $stmt->{kind} // '';
        my $next = ($region->{exit}{kind} // '') eq 'Goto' ? $region->{exit}{target_region} : undef;
        my @extra;

        @extra = _expand_if_exit($region, $stmt, $next, $alloc) if $kind eq 'if';
        @extra = _expand_loop_exit(region => $region, stmt => $stmt, next => $next, alloc => $alloc)
          if $kind eq 'while';
        @extra = _expand_loop_exit(region => $region, stmt => $stmt, next => $next, alloc => $alloc, for_mode => 1)
          if $kind eq 'for_each' || $kind eq 'for_each_try';
        @extra = _expand_try_exit($region, $stmt, $next, $alloc)
          if $kind eq 'const_try_expr' || $kind eq 'const_try_tail_expr' || $kind eq 'expr_stmt_try';

        push @$regions, @extra if @extra;
    }
}

sub _regions_for_statement_chain {
    my ($stmts, $alloc, $base_line) = @_;
    my @regions;
    my @region_schedule;

    for my $i (0 .. $#$stmts) {
        my $stmt = $stmts->[$i];
        my $rid = _next_id($alloc, 'region');
        my $next_rid = '__PENDING__';
        push @region_schedule, $rid;

        my $exit;
        if (($stmt->{kind} // '') eq 'return') {
            $exit = { kind => 'Return', value => $stmt->{expr} };
        } else {
            $exit = { kind => 'Goto', target_region => $next_rid };
        }

        push @regions, {
            id                => $rid,
            steps             => [ _step_from_stmt($stmt, $alloc) ],
            exit              => $exit,
            facts_in          => [],
            facts_out_by_exit => {},
            provenance        => { line => $stmt->{line} // $base_line },
        };
    }

    my $terminal = {
        id                => _next_id($alloc, 'region'),
        steps             => [],
        exit              => { kind => 'Return', value => undef },
        facts_in          => [],
        facts_out_by_exit => {},
        provenance        => { line => $base_line },
    };
    push @regions, $terminal;

    for my $i (0 .. $#regions - 1) {
        my $exit = $regions[$i]{exit};
        next if $exit->{kind} ne 'Goto';
        if (!defined($exit->{target_region}) || ($exit->{target_region} // '') eq '__PENDING__') {
            $exit->{target_region} = $regions[$i + 1]{id};
        }
    }

    _inject_structured_exit_regions(\@regions, $alloc);
    return {
        regions => \@regions,
        schedule => \@region_schedule,
    };
}

sub _lower_function_hir {
    my ($fn, $alloc) = @_;
    my $fid = _next_id($alloc, 'fn');
    my $stmts = parse_function_body($fn);
    my $lowered = _regions_for_statement_chain($stmts, $alloc, $fn->{body_start_line_no});
    my $regions = $lowered->{regions};
    my $edges = _edges_from_regions($regions, $alloc);
    my $entry_facts = _entry_facts_from_params($fn->{parsed_params}, $alloc, $fn->{header_line_no});

    return {
        id           => $fid,
        name         => $fn->{name},
        params       => $fn->{parsed_params},
        return_type  => $fn->{return_type},
        regions      => $regions,
        region_schedule => $lowered->{schedule},
        edges        => $edges,
        entry_region => $regions->[0]{id},
        entry_facts  => $entry_facts,
        provenance   => { line => $fn->{header_line_no} },
    };
}

sub lower_source_to_vnf_hir {
    my ($source) = @_;
    my $functions = collect_functions($source);
    my $order = _normalize_function_map($functions);
    my $alloc = _new_id_alloc();

    my @hir_functions;
    for my $name (@$order) {
        push @hir_functions, _lower_function_hir($functions->{$name}, $alloc);
    }

    return {
        version      => 'f047-vnf-hir-v2',
        functions    => \@hir_functions,
        fact_lattice => {
            merge_policy => 'weaken_only',
            rationale    => 'normative-reference-2.3',
        },
        traceability => {
            requirements => [
                'F047-Gate-CFG',
                'F047-Gate-Type',
                'F047-Gate-Effect',
                'F047-Gate-Ownership',
                'F047-Gate-Lowering',
                'F047-Gate-Traceability',
            ],
        },
    };
}

1;
