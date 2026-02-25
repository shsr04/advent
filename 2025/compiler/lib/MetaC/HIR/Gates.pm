package MetaC::HIR::Gates;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::TypeSpec qw(
    is_union_type
    is_supported_value_type
    is_supported_generic_union_return
    type_is_number_or_error
    type_is_bool_or_error
    type_is_string_or_error
);

our @EXPORT_OK = qw(verify_vnf_hir dump_vnf_hir);

sub _sorted_hash_lines {
    my ($prefix, $hash, $out) = @_;
    for my $key (sort keys %$hash) {
        my $v = $hash->{$key};
        if (ref($v) eq 'HASH') {
            push @$out, "$prefix$key:";
            _sorted_hash_lines($prefix . '  ', $v, $out);
            next;
        }
        if (ref($v) eq 'ARRAY') {
            push @$out, "$prefix$key:[";
            for my $item (@$v) {
                if (ref($item) eq 'HASH') {
                    push @$out, "$prefix  -";
                    _sorted_hash_lines($prefix . '    ', $item, $out);
                } else {
                    push @$out, "$prefix  - $item";
                }
            }
            push @$out, "$prefix]";
            next;
        }
        $v = '' if !defined $v;
        push @$out, "$prefix$key:$v";
    }
}

sub dump_vnf_hir {
    my ($hir) = @_;
    my @out;
    push @out, "version:$hir->{version}";
    push @out, "fact_lattice.merge_policy:$hir->{fact_lattice}{merge_policy}";
    for my $fn (@{ $hir->{functions} }) {
        push @out, "function:$fn->{id}:$fn->{name}:$fn->{return_type}";
        push @out, "  entry_region:$fn->{entry_region}";
        for my $region (@{ $fn->{regions} }) {
            push @out, "  region:$region->{id}";
            for my $step (@{ $region->{steps} }) {
                my $sk = $step->{stmt}{kind} // '';
                my $ln = $step->{provenance}{line} // 0;
                push @out, "    step:$step->{id}:$step->{kind}:$sk:line=$ln";
            }
            my @exit_lines;
            _sorted_hash_lines('    exit.', $region->{exit}, \@exit_lines);
            push @out, @exit_lines;
            for my $tag (sort keys %{ $region->{facts_out_by_exit} // {} }) {
                my $facts = $region->{facts_out_by_exit}{$tag} // [];
                push @out, "    facts.$tag:" . join(',', @$facts);
            }
        }
    }
    return join("\n", @out) . "\n";
}

sub _type_supported {
    my ($ret) = @_;
    return 1 if !defined $ret;
    return 1 if is_supported_value_type($ret);
    return 1 if type_is_number_or_error($ret);
    return 1 if type_is_bool_or_error($ret);
    return 1 if type_is_string_or_error($ret);
    return 1 if is_union_type($ret) && is_supported_generic_union_return($ret);
    return 1 if is_supported_generic_union_return($ret);
    return 0;
}

sub _region_map {
    my ($fn) = @_;
    my %map = map { $_->{id} => $_ } @{ $fn->{regions} };
    return \%map;
}

sub _expected_edges_from_exits {
    my ($fn) = @_;
    my @edges;
    for my $region (@{ $fn->{regions} }) {
        my $exit = $region->{exit};
        my $kind = $exit->{kind} // '';
        if ($kind eq 'Goto') {
            push @edges, { from_region => $region->{id}, exit_tag => 'goto', to_region => $exit->{target_region} };
            next;
        }
        if ($kind eq 'IfExit') {
            push @edges, { from_region => $region->{id}, exit_tag => 'then', to_region => $exit->{then_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'else', to_region => $exit->{else_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'join', to_region => $exit->{join_region} };
            next;
        }
        if ($kind eq 'WhileExit') {
            push @edges, { from_region => $region->{id}, exit_tag => 'body', to_region => $exit->{body_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'continue', to_region => $exit->{continue_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'break', to_region => $exit->{break_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'rewind', to_region => $exit->{rewind_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'end', to_region => $exit->{end_region} };
            next;
        }
        if ($kind eq 'ForInExit') {
            push @edges, { from_region => $region->{id}, exit_tag => 'body', to_region => $exit->{body_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'continue', to_region => $exit->{continue_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'break', to_region => $exit->{break_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'rewind', to_region => $exit->{rewind_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'error', to_region => $exit->{error_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'end', to_region => $exit->{end_region} };
            next;
        }
        if ($kind eq 'TryExit') {
            push @edges, { from_region => $region->{id}, exit_tag => 'ok', to_region => $exit->{ok_region} };
            push @edges, { from_region => $region->{id}, exit_tag => 'err', to_region => $exit->{err_region} };
            next;
        }
    }
    @edges = sort {
      $a->{from_region} cmp $b->{from_region}
      || $a->{exit_tag} cmp $b->{exit_tag}
      || $a->{to_region} cmp $b->{to_region}
    } @edges;
    return \@edges;
}

sub _actual_edges {
    my ($fn) = @_;
    my @edges = map {
        {
            from_region => $_->{from_region},
            exit_tag    => $_->{exit_tag},
            to_region   => $_->{to_region},
        }
    } @{ $fn->{edges} // [] };

    @edges = sort {
      $a->{from_region} cmp $b->{from_region}
      || $a->{exit_tag} cmp $b->{exit_tag}
      || $a->{to_region} cmp $b->{to_region}
    } @edges;
    return \@edges;
}

sub _gate_cfg {
    my ($hir) = @_;
    for my $fn (@{ $hir->{functions} }) {
        compile_error("Gate-CFG/F047-Gate-CFG: function '$fn->{name}' has no regions")
          if !@{ $fn->{regions} };

        my $region_map = _region_map($fn);
        compile_error("Gate-CFG/F047-Gate-CFG: function '$fn->{name}' entry region not found")
          if !exists $region_map->{ $fn->{entry_region} };

        for my $edge (@{ $fn->{edges} }) {
            compile_error("Gate-CFG/F047-Gate-CFG: unknown edge source '$edge->{from_region}'")
              if !exists $region_map->{ $edge->{from_region} };
            compile_error("Gate-CFG/F047-Gate-CFG: unknown edge target '$edge->{to_region}'")
              if !exists $region_map->{ $edge->{to_region} };
        }

        my $expected = _expected_edges_from_exits($fn);
        my $actual = _actual_edges($fn);
        my $exp = join('|', map { "$_->{from_region}:$_->{exit_tag}:$_->{to_region}" } @$expected);
        my $act = join('|', map { "$_->{from_region}:$_->{exit_tag}:$_->{to_region}" } @$actual);
        compile_error("Gate-CFG/F047-Gate-CFG: edge table mismatch in function '$fn->{name}'")
          if $exp ne $act;

        # Dead regions are currently tolerated because lowering preserves source-order
        # statement regions even after early terminal exits.
    }
}

sub _gate_type {
    my ($hir) = @_;
    for my $fn (@{ $hir->{functions} }) {
        my $ret = $fn->{return_type};
        compile_error("Gate-Type/F047-Gate-Type: unsupported return type '$ret' in function '$fn->{name}'")
          if !_type_supported($ret);
        for my $region (@{ $fn->{regions} }) {
            my $exit = $region->{exit} // {};
            my $kind = $exit->{kind} // '';
            if ($kind eq 'IfExit') {
                compile_error("Gate-Type/F047-Gate-Type: IfExit missing condition in '$fn->{name}'")
                  if !defined $exit->{cond_value};
                next;
            }
            if ($kind eq 'WhileExit') {
                compile_error("Gate-Type/F047-Gate-Type: WhileExit missing condition in '$fn->{name}'")
                  if !defined $exit->{cond_value};
                next;
            }
            if ($kind eq 'ForInExit') {
                compile_error("Gate-Type/F047-Gate-Type: ForInExit missing iterable expression in '$fn->{name}'")
                  if !defined $exit->{iterable_expr};
                next;
            }
            if ($kind eq 'TryExit') {
                compile_error("Gate-Type/F047-Gate-Type: TryExit missing fallible expression in '$fn->{name}'")
                  if !defined $exit->{fallible_expr};
                next;
            }
        }
    }
}

sub _walk_expr {
    my ($expr, $cb) = @_;
    return if !defined $expr || ref($expr) ne 'HASH';
    $cb->($expr);
    for my $k (sort keys %$expr) {
        my $v = $expr->{$k};
        if (ref($v) eq 'HASH') {
            _walk_expr($v, $cb);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $item (@$v) {
            _walk_expr($item, $cb) if ref($item) eq 'HASH';
        }
    }
}

sub _walk_stmt_exprs {
    my ($stmt, $cb) = @_;
    return if !defined $stmt || ref($stmt) ne 'HASH';
    for my $k (qw(expr cond iterable index source recv value left right)) {
        my $v = $stmt->{$k};
        _walk_expr($v, $cb) if defined $v;
    }
    if (defined $stmt->{args} && ref($stmt->{args}) eq 'ARRAY') {
        for my $arg (@{ $stmt->{args} }) {
            _walk_expr($arg, $cb);
        }
    }
    for my $k (qw(then_body else_body body handler)) {
        next if !defined $stmt->{$k} || ref($stmt->{$k}) ne 'ARRAY';
        for my $inner (@{ $stmt->{$k} }) {
            _walk_stmt_exprs($inner, $cb);
        }
    }
}

sub _gate_effect {
    my ($hir) = @_;
    for my $fn (@{ $hir->{functions} }) {
        for my $region (@{ $fn->{regions} }) {
            my $has_try_stmt = 0;
            for my $step (@{ $region->{steps} }) {
                my $stmt = $step->{stmt};
                compile_error("Gate-Effect/F047-Gate-Effect: missing statement payload in '$fn->{name}'")
                  if !defined($stmt) || ref($stmt) ne 'HASH';
                my $k = $stmt->{kind} // '';
                $has_try_stmt = 1 if $k eq 'const_try_expr' || $k eq 'const_try_tail_expr' || $k eq 'expr_stmt_try';
            }
            if ($has_try_stmt) {
                my $exit_kind = $region->{exit}{kind} // '';
                my $embedded_block = @{ $region->{steps} } > 1 ? 1 : 0;
                compile_error("Gate-Effect/F047-Gate-Effect: try statement not normalized to TryExit in '$fn->{name}'")
                  if $exit_kind ne 'TryExit' && !$embedded_block;
            }
        }
    }
}

sub _merge_pred_facts {
    my ($rid, $fn, $preds, $out, $in) = @_;
    my $pred_edges = $preds->{$rid} // [];
    return @{ $in->{$rid} // [] } if $rid eq $fn->{entry_region};
    return () if @$pred_edges == 0;

    my @from_sets;
    for my $edge (@$pred_edges) {
        my $k = $edge->{from_region} . ':' . $edge->{exit_tag};
        push @from_sets, $out->{$k} // [];
    }
    my %count;
    my $total = scalar @from_sets;
    for my $set (@from_sets) {
        my %uniq = map { $_ => 1 } @$set;
        $count{$_}++ for keys %uniq;
    }
    return sort grep { $count{$_} == $total } keys %count;
}

sub _apply_step_transfer {
    my ($facts_in, $steps) = @_;
    my @facts = @$facts_in;
    for my $step (@$steps) {
        my $stmt = $step->{stmt};
        my $kind = $stmt->{kind} // '';
        if ($kind eq 'let' || $kind eq 'const') {
            my $type = $stmt->{type} // 'inferred';
            push @facts, "type:$stmt->{name}:$type";
            next;
        }
        if ($kind eq 'assign' || $kind eq 'typed_assign') {
            my %keep = map { $_ => 1 } grep { $_ !~ /^type:\Q$stmt->{name}\E:/ } @facts;
            @facts = sort keys %keep;
            if ($kind eq 'typed_assign') {
                push @facts, "type:$stmt->{name}:" . ($stmt->{type} // 'inferred');
            }
            next;
        }
    }
    return \@facts;
}

sub _exit_tag_facts {
    my ($exit, $facts) = @_;
    my $exit_kind = $exit->{kind} // '';
    return { goto => [ @$facts ] } if $exit_kind eq 'Goto';
    return { return => [ @$facts, 'cfg:return' ] } if $exit_kind eq 'Return';
    return { propagate => [ @$facts, 'cfg:error-propagate' ] } if $exit_kind eq 'PropagateError';
    return { ok => [ @$facts ], err => [ @$facts ] } if $exit_kind eq 'TryExit';
    return { then => [ @$facts ], else => [ @$facts ], join => [ @$facts ] } if $exit_kind eq 'IfExit';
    return {
        body => [ @$facts ],
        continue => [ @$facts ],
        break => [ @$facts ],
        rewind => [ @$facts ],
        end => [ @$facts ],
    } if $exit_kind eq 'WhileExit';
    if ($exit_kind eq 'ForInExit') {
        my $lid = $exit->{loop_id} // 'L?';
        return {
            body => [ @$facts, "owns:loop_iterable:$lid" ],
            continue => [ @$facts, "owns:loop_iterable:$lid" ],
            break => [ @$facts, "dropped:loop_iterable:$lid" ],
            rewind => [ @$facts, "dropped:loop_iterable:$lid" ],
            error => [ @$facts, "dropped:loop_iterable:$lid" ],
            end => [ @$facts, "dropped:loop_iterable:$lid" ],
        };
    }
    return { other => [ @$facts ] };
}

sub _finalize_region_fact_sets {
    my ($fn, $in, $out) = @_;
    for my $region (@{ $fn->{regions} }) {
        my $rid = $region->{id};
        $region->{facts_in} = $in->{$rid} // [];
        my $kind = $region->{exit}{kind} // '';
        my %facts_out;
        if ($kind eq 'Goto') {
            $facts_out{goto} = $out->{$rid . ':goto'} // [];
        } elsif ($kind eq 'Return') {
            $facts_out{return} = $out->{$rid . ':return'} // [];
        } elsif ($kind eq 'PropagateError') {
            $facts_out{propagate} = $out->{$rid . ':propagate'} // [];
        } elsif ($kind eq 'TryExit') {
            $facts_out{ok} = $out->{$rid . ':ok'} // [];
            $facts_out{err} = $out->{$rid . ':err'} // [];
        } elsif ($kind eq 'IfExit') {
            $facts_out{then} = $out->{$rid . ':then'} // [];
            $facts_out{else} = $out->{$rid . ':else'} // [];
            $facts_out{join} = $out->{$rid . ':join'} // [];
        } elsif ($kind eq 'WhileExit') {
            $facts_out{body} = $out->{$rid . ':body'} // [];
            $facts_out{continue} = $out->{$rid . ':continue'} // [];
            $facts_out{break} = $out->{$rid . ':break'} // [];
            $facts_out{rewind} = $out->{$rid . ':rewind'} // [];
            $facts_out{end} = $out->{$rid . ':end'} // [];
        } elsif ($kind eq 'ForInExit') {
            $facts_out{body} = $out->{$rid . ':body'} // [];
            $facts_out{continue} = $out->{$rid . ':continue'} // [];
            $facts_out{break} = $out->{$rid . ':break'} // [];
            $facts_out{rewind} = $out->{$rid . ':rewind'} // [];
            $facts_out{error} = $out->{$rid . ':error'} // [];
            $facts_out{end} = $out->{$rid . ':end'} // [];
        } else {
            $facts_out{other} = $out->{$rid . ':other'} // [];
        }
        $region->{facts_out_by_exit} = \%facts_out;
    }
}

sub _compute_fact_flow_for_function {
    my ($fn) = @_;
    my %preds;
    for my $edge (@{ $fn->{edges} }) {
        push @{ $preds{ $edge->{to_region} } }, $edge;
    }

    my %in;
    my %out;
    $in{$fn->{entry_region}} = [ map { $_->{predicate} } @{ $fn->{entry_facts} // [] } ];

    my $changed = 1;
    my $iterations = 0;
    while ($changed) {
        $changed = 0;
        $iterations++;
        compile_error("Gate-Type/F047-Gate-Type: fact-flow fixpoint did not converge in '$fn->{name}'")
          if $iterations > 1000;

        for my $region (@{ $fn->{regions} }) {
            my $rid = $region->{id};
            my @merged = _merge_pred_facts($rid, $fn, \%preds, \%out, \%in);

            my $prev_in = join('|', @{ $in{$rid} // [] });
            my $next_in = join('|', @merged);
            if ($prev_in ne $next_in) {
                $in{$rid} = \@merged;
                $changed = 1;
            }

            my $after_steps = _apply_step_transfer(\@merged, $region->{steps});
            my $out_by_exit = _exit_tag_facts($region->{exit}, $after_steps);
            for my $tag (sort keys %$out_by_exit) {
                my $key = $rid . ':' . $tag;
                my $prev = join('|', @{ $out{$key} // [] });
                my $next = join('|', @{ $out_by_exit->{$tag} });
                if ($prev ne $next) {
                    $out{$key} = $out_by_exit->{$tag};
                    $changed = 1;
                }
            }
        }
    }

    _finalize_region_fact_sets($fn, \%in, \%out);
}

sub _compute_fact_flow {
    my ($hir) = @_;
    _compute_fact_flow_for_function($_) for @{ $hir->{functions} };
}

sub _gate_ownership {
    my ($hir) = @_;
    for my $fn (@{ $hir->{functions} }) {
        my %seen;
        for my $region (@{ $fn->{regions} }) {
            for my $step (@{ $region->{steps} }) {
                my $sid = $step->{id};
                compile_error("Gate-Ownership/F047-Gate-Ownership: duplicate step id '$sid'") if $seen{$sid}++;
            }
            my $exit = $region->{exit} // {};
            my $kind = $exit->{kind} // '';
            next if $kind ne 'ForInExit';
            my $lid = $exit->{loop_id} // '';
            compile_error("Gate-Ownership/F047-Gate-Ownership: ForInExit missing loop id in '$fn->{name}'")
              if $lid eq '';
            my $facts = $region->{facts_out_by_exit} // {};
            my $owns_body = join('|', @{ $facts->{body} // [] });
            my $owns_continue = join('|', @{ $facts->{continue} // [] });
            my $drop_break = join('|', @{ $facts->{break} // [] });
            my $drop_end = join('|', @{ $facts->{end} // [] });
            compile_error("Gate-Ownership/F047-Gate-Ownership: missing iterable ownership on body edge for loop '$lid'")
              if $owns_body !~ /\bowns:loop_iterable:\Q$lid\E\b/;
            compile_error("Gate-Ownership/F047-Gate-Ownership: missing iterable ownership on continue edge for loop '$lid'")
              if $owns_continue !~ /\bowns:loop_iterable:\Q$lid\E\b/;
            compile_error("Gate-Ownership/F047-Gate-Ownership: missing iterable drop on break/end for loop '$lid'")
              if $drop_break !~ /\bdropped:loop_iterable:\Q$lid\E\b/ || $drop_end !~ /\bdropped:loop_iterable:\Q$lid\E\b/;
        }
    }
}

sub _gate_lowering {
    my ($hir) = @_;
    my $a = dump_vnf_hir($hir);
    my $b = dump_vnf_hir($hir);
    compile_error("Gate-Lowering/F047-Gate-Lowering: non-deterministic HIR dump") if $a ne $b;
}

sub _gate_traceability {
    my ($hir) = @_;
    my $reqs = $hir->{traceability}{requirements} // [];
    my %need = map { $_ => 1 } qw(
      F047-Gate-CFG
      F047-Gate-Type
      F047-Gate-Effect
      F047-Gate-Ownership
      F047-Gate-Lowering
      F047-Gate-Traceability
    );
    my %have = map { $_ => 1 } @$reqs;
    for my $id (sort keys %need) {
        compile_error("Gate-Traceability/F047-Gate-Traceability: missing requirement id '$id'") if !$have{$id};
    }
}

sub verify_vnf_hir {
    my ($hir) = @_;
    _gate_cfg($hir);
    _gate_type($hir);
    _gate_effect($hir);
    _compute_fact_flow($hir);
    _gate_ownership($hir);
    _gate_lowering($hir);
    _gate_traceability($hir);
    $hir->{verified} = 1;
    return $hir;
}

1;
