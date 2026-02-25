package MetaC::Codegen;
use strict;
use warnings;

sub _emit_map_error_return {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $message_expr = $args{message_expr};
    my $source_cleanup = $args{source_cleanup};
    my $free_expr = $args{free_expr};

    emit_line($out, $indent, "$free_expr;") if defined $free_expr && $free_expr ne '';
    emit_line($out, $indent, "$source_cleanup;") if defined $source_cleanup && $source_cleanup ne '';
    if (defined $ctx->{active_temp_cleanups}) {
        for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
            emit_line($out, $indent, $ctx->{active_temp_cleanups}[$i] . ';');
        }
    }
    emit_all_owned_cleanups($ctx, $out, $indent);
    emit_line($out, $indent, "return err_number($message_expr, __metac_line_no, \"\");");
}

sub propagate_list_len_fact_from_recv {
    my ($recv_expr, $target_name, $ctx) = @_;
    return if !expr_is_stable_for_facts($recv_expr, $ctx);
    my $recv_key = expr_fact_key($recv_expr, $ctx);
    my $known_len = lookup_list_len_fact($ctx, $recv_key);
    return if !defined $known_len;
    my $new_key = expr_fact_key({ kind => 'ident', name => $target_name }, $ctx);
    set_list_len_fact($ctx, $new_key, $known_len);
}

sub emit_map_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $propagate_errors = $args{propagate_errors} ? 1 : 0;

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("map(...) receiver must be string_list, got $recv_type")
      if $recv_type ne 'string_list';

    my $mapper = map_mapper_info($expr, $ctx);
    if (!$propagate_errors && $mapper->{return_mode} eq 'number_or_error') {
        compile_error("Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)");
    }

    my $source = '__metac_map_src' . $ctx->{tmp_counter}++;
    my $count = '__metac_map_count' . $ctx->{tmp_counter}++;
    my $idx = '__metac_map_i' . $ctx->{tmp_counter}++;
    my $out_items = '__metac_map_items' . $ctx->{tmp_counter}++;
    my $tmp_num = '__metac_map_num' . $ctx->{tmp_counter}++;
    my $tmp_res = '__metac_map_res' . $ctx->{tmp_counter}++;
    my $source_cleanup = cleanup_call_for_temp_expr(
        var_name  => $source,
        decl_type => 'string_list',
        expr_code => $recv_code,
    );

    emit_line($out, $indent, "StringList $source = $recv_code;");
    emit_line($out, $indent, "size_t $count = $source.count;");
    emit_line($out, $indent, "int64_t *$out_items = (int64_t *)calloc($count == 0 ? 1 : $count, sizeof(int64_t));");
    emit_line($out, $indent, "if ($out_items == NULL) {");
    if ($propagate_errors) {
        _emit_map_error_return(
            ctx            => $ctx,
            out            => $out,
            indent         => $indent + 2,
            message_expr   => '"out of memory in map"',
            source_cleanup => $source_cleanup,
        );
    } else {
        emit_line($out, $indent + 2, "$source_cleanup;") if defined $source_cleanup;
        if (defined $ctx->{active_temp_cleanups}) {
            for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
                emit_line($out, $indent + 2, $ctx->{active_temp_cleanups}[$i] . ';');
            }
        }
        emit_all_owned_cleanups($ctx, $out, $indent + 2);
        emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in map\\n\");");
        emit_line($out, $indent + 2, "exit(1);");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
    if ($mapper->{builtin}) {
        emit_line($out, $indent + 2, "int64_t $tmp_num = 0;");
        emit_line($out, $indent + 2, "if (!metac_parse_int($source.items[$idx], &$tmp_num)) {");
        if ($propagate_errors) {
            _emit_map_error_return(
                ctx            => $ctx,
                out            => $out,
                indent         => $indent + 4,
                message_expr   => '"Invalid number"',
                source_cleanup => $source_cleanup,
                free_expr      => "free($out_items)",
            );
        } else {
            emit_line($out, $indent + 4, "free($out_items);");
            emit_line($out, $indent + 4, "$source_cleanup;") if defined $source_cleanup;
            if (defined $ctx->{active_temp_cleanups}) {
                for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
                    emit_line($out, $indent + 4, $ctx->{active_temp_cleanups}[$i] . ';');
                }
            }
            emit_all_owned_cleanups($ctx, $out, $indent + 4);
            emit_line($out, $indent + 4, "fprintf(stderr, \"Invalid number: %s\\n\", $source.items[$idx]);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_num;");
    } elsif ($mapper->{return_mode} eq 'number') {
        emit_line($out, $indent + 2, "${out_items}[$idx] = $mapper->{name}($source.items[$idx]);");
    } else {
        emit_line($out, $indent + 2, "ResultNumber $tmp_res = $mapper->{name}($source.items[$idx]);");
        emit_line($out, $indent + 2, "if ($tmp_res.is_error) {");
        if ($propagate_errors) {
            _emit_map_error_return(
                ctx            => $ctx,
                out            => $out,
                indent         => $indent + 4,
                message_expr   => $tmp_res . ".message",
                source_cleanup => $source_cleanup,
                free_expr      => "free($out_items)",
            );
        } else {
            emit_line($out, $indent + 4, "free($out_items);");
            emit_line($out, $indent + 4, "$source_cleanup;") if defined $source_cleanup;
            if (defined $ctx->{active_temp_cleanups}) {
                for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
                    emit_line($out, $indent + 4, $ctx->{active_temp_cleanups}[$i] . ';');
                }
            }
            emit_all_owned_cleanups($ctx, $out, $indent + 4);
            emit_line($out, $indent + 4, "fprintf(stderr, \"%s\\n\", $tmp_res.message);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_res.value;");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "NumberList $name;");
    emit_line($out, $indent, "$name.count = $count;");
    emit_line($out, $indent, "$name.items = $out_items;");
    emit_line($out, $indent, "$source_cleanup;") if defined $source_cleanup;

    declare_var(
        $ctx,
        $name,
        {
            type      => 'number_list',
            immutable => 1,
            c_name    => $name,
        }
    );
    register_owned_cleanup_for_var($ctx, $name, "metac_free_number_list($name)");
    propagate_list_len_fact_from_recv($expr->{recv}, $name, $ctx);
}

sub emit_filter_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("filter(...) receiver must be string_list, number_list, or matrix member list, got $recv_type")
      if $recv_type ne 'string_list'
      && $recv_type ne 'number_list'
      && !is_matrix_member_list_type($recv_type);
    my $actual = scalar @{ $expr->{args} };
    compile_error("filter(...) expects exactly 1 predicate arg")
      if $actual != 1;
    my $predicate = $expr->{args}[0];
    compile_error("filter(...) predicate must be a single-parameter lambda, e.g. x => x > 0")
      if $predicate->{kind} ne 'lambda1';
    $ctx->{helper_defs} = [] if !defined $ctx->{helper_defs};
    my $helper_name = compile_filter_lambda_helper(
        lambda    => $predicate,
        recv_type => $recv_type,
        ctx       => $ctx,
    );

    if ($recv_type eq 'string_list') {
        emit_line($out, $indent, "StringList $name = metac_filter_string_list($recv_code, $helper_name);");
    } elsif ($recv_type eq 'number_list') {
        emit_line($out, $indent, "NumberList $name = metac_filter_number_list($recv_code, $helper_name);");
    } else {
        my $member_meta = matrix_member_list_meta($recv_type);
        if ($member_meta->{elem} eq 'number') {
            emit_line($out, $indent, "MatrixNumberMemberList $name = metac_filter_matrix_number_member_list($recv_code, $helper_name);");
        } elsif ($member_meta->{elem} eq 'string') {
            emit_line($out, $indent, "MatrixStringMemberList $name = metac_filter_matrix_string_member_list($recv_code, $helper_name);");
        } else {
            compile_error("filter(...) is unsupported for matrix member element type '$member_meta->{elem}'");
        }
    }

    declare_var(
        $ctx,
        $name,
        {
            type      => $recv_type,
            immutable => 1,
            c_name    => $name,
        }
    );
    if ($recv_type eq 'string_list') {
        register_owned_cleanup_for_var($ctx, $name, "metac_free_string_list($name, 0)");
    } elsif ($recv_type eq 'number_list') {
        register_owned_cleanup_for_var($ctx, $name, "metac_free_number_list($name)");
    } else {
        my $member_meta = matrix_member_list_meta($recv_type);
        if ($member_meta->{elem} eq 'number') {
            register_owned_cleanup_for_var($ctx, $name, "metac_free_matrix_number_member_list($name)");
        } elsif ($member_meta->{elem} eq 'string') {
            register_owned_cleanup_for_var($ctx, $name, "metac_free_matrix_string_member_list($name)");
        }
    }
}

1;
