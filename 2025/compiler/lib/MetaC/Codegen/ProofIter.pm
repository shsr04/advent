package MetaC::Codegen;
use strict;
use warnings;

sub prove_non_negative_expr {
    my ($expr, $ctx) = @_;
    if ($expr->{kind} eq 'num') {
        return int($expr->{value}) >= 0;
    }
    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        return 0 if !defined $info;
        return 1 if defined $info->{size_of_recv_code};
        if (defined($info->{constraints})) {
            my ($min, undef) = constraint_range_bounds($info->{constraints});
            return 1 if defined($min) && int($min) >= 0;
        }
        return 0 if !defined $info->{range_min_expr};
        return prove_non_negative_expr($info->{range_min_expr}, $ctx);
    }
    if ($expr->{kind} eq 'method_call'
        && ($expr->{method} eq 'size' || $expr->{method} eq 'count')
        && scalar(@{ $expr->{args} }) == 0)
    {
        my (undef, $recv_type) = compile_expr($expr->{recv}, $ctx);
        return 1 if $recv_type eq 'string' || $recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'bool_list' || $recv_type eq 'indexed_number_list';
        return 0;
    }
    if ($expr->{kind} eq 'binop' && $expr->{op} eq '+') {
        return prove_non_negative_expr($expr->{left}, $ctx) && prove_non_negative_expr($expr->{right}, $ctx);
    }
    if ($expr->{kind} eq 'binop' && $expr->{op} eq '-') {
        if ($expr->{left}{kind} eq 'ident') {
            my $info = lookup_var($ctx, $expr->{left}{name});
            if (defined $info) {
                if (defined $info->{range_min_fact_key}) {
                    my $rhs_key;
                    eval { $rhs_key = expr_fact_key($expr->{right}, $ctx); 1; };
                    return 1 if defined($rhs_key) && $rhs_key eq $info->{range_min_fact_key};
                }
                if (defined $info->{range_min_expr}) {
                    return 1 if ($info->{range_min_expr}{kind} // '') eq 'num'
                      && ($expr->{right}{kind} // '') eq 'num'
                      && int($expr->{right}{value}) <= int($info->{range_min_expr}{value});
                }
            }
        }
        return 0;
    }
    return 0;
}


sub prove_index_lt_container_size {
    my ($idx_expr, $recv_code, $recv_type, $ctx) = @_;
    if ($idx_expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $idx_expr->{name});
        return 0 if !defined $info;
        if (defined($info->{range_max_size_recv_code}) && defined($info->{range_max_size_recv_type}) && defined($info->{range_max_size_minus_const})) {
            return 0 if $info->{range_max_size_recv_code} ne $recv_code;
            return 0 if $info->{range_max_size_recv_type} ne $recv_type;
            return int($info->{range_max_size_minus_const}) >= 1 ? 1 : 0;
        }
        if (defined($info->{constraints})) {
            my (undef, $max) = constraint_range_bounds($info->{constraints});
            if (defined $max && $recv_type ne 'string') {
                my $recv_ident = undef;
                if ($recv_code =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                    $recv_ident = $recv_code;
                }
                if (defined $recv_ident) {
                    my $recv_key = expr_fact_key({ kind => 'ident', name => $recv_ident }, $ctx);
                    my $known_len = lookup_list_len_fact($ctx, $recv_key);
                    return 1 if defined($known_len) && int($max) < int($known_len);
                }
            }
        }
        return 0 if !defined $info->{range_max_expr};
        my $max_expr = $info->{range_max_expr};
        if (($max_expr->{kind} // '') eq 'binop'
            && ($max_expr->{op} // '') eq '-'
            && defined($max_expr->{right}) && ref($max_expr->{right}) eq 'HASH'
            && ($max_expr->{right}{kind} // '') eq 'num'
            && int($max_expr->{right}{value}) >= 1)
        {
            my $left = $max_expr->{left};
            if (defined($left) && ref($left) eq 'HASH'
                && ($left->{kind} // '') eq 'method_call'
                && (($left->{method} // '') eq 'size' || ($left->{method} // '') eq 'count')
                && scalar(@{ $left->{args} // [] }) == 0)
            {
                my ($inner_code, $inner_type) = compile_expr($left->{recv}, $ctx);
                return 1 if $inner_code eq $recv_code && $inner_type eq $recv_type;
            }
        }
        return 0;
    }
    if ($idx_expr->{kind} eq 'binop' && $idx_expr->{op} eq '-') {
        return 0 if !prove_index_lt_container_size($idx_expr->{left}, $recv_code, $recv_type, $ctx);
        return prove_non_negative_expr($idx_expr->{right}, $ctx);
    }
    return 0;
}


sub prove_container_index_in_bounds {
    my ($recv_code, $recv_type, $idx_expr, $ctx) = @_;
    return 0 if !prove_non_negative_expr($idx_expr, $ctx);
    return prove_index_lt_container_size($idx_expr, $recv_code, $recv_type, $ctx);
}


sub decompose_iterable_expression {
    my ($iter_expr, $ctx) = @_;

    my @predicates;
    my $base = $iter_expr;
    while ($base->{kind} eq 'method_call' && $base->{method} eq 'filter') {
        my $actual = scalar @{ $base->{args} };
        compile_error("filter(...) expects exactly 1 predicate arg")
          if $actual != 1;
        my $predicate = $base->{args}[0];
        compile_error("filter(...) expects a single-parameter lambda predicate")
          if $predicate->{kind} ne 'lambda1';
        unshift @predicates, $predicate;
        $base = $base->{recv};
    }

    if ($base->{kind} eq 'call' && $base->{name} eq 'seq') {
        my $actual = scalar @{ $base->{args} };
        compile_error("seq(...) expects exactly 2 args")
          if $actual != 2;
        return {
            kind       => 'seq',
            start_expr => $base->{args}[0],
            end_expr   => $base->{args}[1],
            predicates => \@predicates,
        };
    }

    my ($base_code, $base_type) = compile_expr($base, $ctx);
    compile_error("Iterable expression must be seq(...) or list-valued, got $base_type")
      if $base_type ne 'string_list'
      && $base_type ne 'number_list'
      && $base_type ne 'number_list_list'
      && $base_type ne 'bool_list'
      && $base_type ne 'indexed_number_list'
      && !is_matrix_member_list_type($base_type);

    return {
        kind       => 'list',
        base_expr  => $base,
        base_code  => $base_code,
        base_type  => $base_type,
        predicates => \@predicates,
    };
}


sub emit_for_each_from_iterable_expr {
    my (%args) = @_;
    my $iter_expr = $args{iter_expr};
    my $stmt = $args{stmt};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $current_fn_return = $args{current_fn_return};
    my $has_rewind = loop_body_uses_rewind_current_loop($stmt->{body});

    my $iter = decompose_iterable_expression($iter_expr, $ctx);
    my $rewind_label = $has_rewind ? ('__metac_rewind_loop' . $ctx->{tmp_counter}++) : undef;
    emit_line($out, $indent, "$rewind_label: ;") if $has_rewind;
    push @{ $ctx->{rewind_labels} }, { restart => $rewind_label } if $has_rewind;

    if ($iter->{kind} eq 'seq') {
        my ($start_code, $start_type) = compile_expr($iter->{start_expr}, $ctx);
        my ($end_code, $end_type) = compile_expr($iter->{end_expr}, $ctx);
        compile_error("seq start must be number, got $start_type")
          if !is_number_like_type($start_type);
        compile_error("seq end must be number, got $end_type")
          if !is_number_like_type($end_type);
        my $start_num = number_like_to_c_expr($start_code, $start_type, "seq start");
        my $end_num = number_like_to_c_expr($end_code, $end_type, "seq end");

        my $start_var = '__metac_seq_start' . $ctx->{tmp_counter}++;
        my $end_var = '__metac_seq_end' . $ctx->{tmp_counter}++;
        my $idx_var = '__metac_seq_i' . $ctx->{tmp_counter}++;
        my $pred_codes = compile_filter_predicate_codes(
            predicates  => $iter->{predicates},
            param_type  => 'number',
            param_c_expr => $idx_var,
            ctx         => $ctx,
            label       => 'seq(...).filter(...)',
        );

        emit_line($out, $indent, "int64_t $start_var = $start_num;");
        emit_line($out, $indent, "int64_t $end_var = $end_num;");
        emit_line($out, $indent, "if ($start_var <= $end_var) {");
        emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var <= $end_var; $idx_var++) {");
        for my $pred_code (@$pred_codes) {
            emit_line($out, $indent + 4, "if (!($pred_code)) { continue; }");
        }
        emit_loop_body_with_binding(
            ctx               => $ctx,
            out               => $out,
            indent            => $indent + 4,
            current_fn_return => $current_fn_return,
            body              => $stmt->{body},
            var_name          => $stmt->{var},
            var_type          => 'number',
            var_c_expr        => $idx_var,
            var_index_c_expr  => $idx_var,
            range_min_expr    => $iter->{start_expr},
            range_max_expr    => $iter->{end_expr},
        );
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "} else {");
        emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var >= $end_var; $idx_var--) {");
        for my $pred_code (@$pred_codes) {
            emit_line($out, $indent + 4, "if (!($pred_code)) { continue; }");
        }
        emit_loop_body_with_binding(
            ctx               => $ctx,
            out               => $out,
            indent            => $indent + 4,
            current_fn_return => $current_fn_return,
            body              => $stmt->{body},
            var_name          => $stmt->{var},
            var_type          => 'number',
            var_c_expr        => $idx_var,
            var_index_c_expr  => $idx_var,
            range_min_expr    => $iter->{start_expr},
            range_max_expr    => $iter->{end_expr},
        );
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        pop @{ $ctx->{rewind_labels} } if $has_rewind;
        return;
    }

    my $container = '__metac_iter_list' . $ctx->{tmp_counter}++;
    if ($iter->{base_type} eq 'string_list') {
        emit_line($out, $indent, "StringList $container = $iter->{base_code};");
    } elsif ($iter->{base_type} eq 'number_list_list') {
        emit_line($out, $indent, "NumberListList $container = $iter->{base_code};");
    } elsif ($iter->{base_type} eq 'bool_list') {
        emit_line($out, $indent, "BoolList $container = $iter->{base_code};");
    } elsif ($iter->{base_type} eq 'indexed_number_list') {
        emit_line($out, $indent, "IndexedNumberList $container = $iter->{base_code};");
    } elsif (is_matrix_member_list_type($iter->{base_type})) {
        my $member_meta = matrix_member_list_meta($iter->{base_type});
        if ($member_meta->{elem} eq 'number') {
            emit_line($out, $indent, "MatrixNumberMemberList $container = $iter->{base_code};");
        } elsif ($member_meta->{elem} eq 'string') {
            emit_line($out, $indent, "MatrixStringMemberList $container = $iter->{base_code};");
        } else {
            compile_error("Unsupported matrix member list iterable type '$iter->{base_type}'");
        }
    } else {
        emit_line($out, $indent, "NumberList $container = $iter->{base_code};");
    }

    my $idx_name = '__metac_i' . $ctx->{tmp_counter}++;
    my $elem_type = 'number';
    if ($iter->{base_type} eq 'string_list') {
        $elem_type = 'string';
    } elsif ($iter->{base_type} eq 'number_list_list') {
        $elem_type = 'number_list';
    } elsif ($iter->{base_type} eq 'bool_list') {
        $elem_type = 'bool';
    } elsif ($iter->{base_type} eq 'indexed_number_list') {
        $elem_type = 'indexed_number';
    } elsif (is_matrix_member_list_type($iter->{base_type})) {
        my $member_meta = matrix_member_list_meta($iter->{base_type});
        $elem_type = $iter->{base_type};
        $elem_type =~ s/^matrix_member_list</matrix_member</;
    }
    my $elem_expr = "$container.items[$idx_name]";
    my $elem_len_proof;
    if ($iter->{base_type} eq 'number_list_list' && $iter->{base_expr}{kind} eq 'ident') {
        my $base_info = lookup_var($ctx, $iter->{base_expr}{name});
        if (defined($base_info) && defined($base_info->{item_len_proof})) {
            $elem_len_proof = int($base_info->{item_len_proof});
        }
    }
    my ($member_matrix_code, $member_matrix_type);
    if (is_matrix_member_list_type($iter->{base_type})
        && $iter->{base_expr}{kind} eq 'method_call'
        && $iter->{base_expr}{method} eq 'members')
    {
        my ($src_code, $src_type) = compile_expr($iter->{base_expr}{recv}, $ctx);
        if (is_matrix_type($src_type)) {
            $member_matrix_code = $src_code;
            $member_matrix_type = $src_type;
        }
    }
    my $pred_codes = compile_filter_predicate_codes(
        predicates  => $iter->{predicates},
        param_type  => $elem_type,
        param_c_expr => $elem_expr,
        ctx         => $ctx,
        label       => 'filter(...)',
    );

    my $cleanup_expr = cleanup_call_for_temp_expr(
        var_name  => $container,
        decl_type => $iter->{base_type},
        expr_code => $iter->{base_code},
    );
    my $cleanup_label;
    my $done_label;
    if (defined $cleanup_expr && $has_rewind) {
        $cleanup_label = '__metac_rewind_cleanup' . $ctx->{tmp_counter}++;
        $done_label = '__metac_rewind_done' . $ctx->{tmp_counter}++;
        $ctx->{rewind_labels}->[-1]{cleanup} = $cleanup_label;
    }
    push @{ $ctx->{active_temp_cleanups} }, $cleanup_expr if defined $cleanup_expr;
    emit_line($out, $indent, "for (size_t $idx_name = 0; $idx_name < $container.count; $idx_name++) {");
    for my $pred_code (@$pred_codes) {
        emit_line($out, $indent + 2, "if (!($pred_code)) { continue; }");
    }
    emit_loop_body_with_binding(
        ctx               => $ctx,
        out               => $out,
        indent            => $indent + 2,
        current_fn_return => $current_fn_return,
        body              => $stmt->{body},
        var_name          => $stmt->{var},
        var_type          => $elem_type,
        var_c_expr        => $elem_expr,
        var_index_c_expr  => "((int64_t)$idx_name)",
        list_len_proof    => $elem_len_proof,
        member_matrix_code => $member_matrix_code,
        member_matrix_type => $member_matrix_type,
    );
    emit_line($out, $indent, "}");
    if (defined $cleanup_expr) {
        if ($has_rewind) {
            emit_line($out, $indent, "goto $done_label;");
            emit_line($out, $indent, "$cleanup_label: ;");
            emit_line($out, $indent, "$cleanup_expr;");
            emit_line($out, $indent, "goto $rewind_label;");
            emit_line($out, $indent, "$done_label: ;");
        }
        emit_line($out, $indent, "$cleanup_expr;");
    }
    pop @{ $ctx->{active_temp_cleanups} } if defined $cleanup_expr;
    pop @{ $ctx->{rewind_labels} } if $has_rewind;
}



1;
