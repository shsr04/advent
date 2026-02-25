package MetaC::Codegen;
use strict;
use warnings;

sub _compile_block_stage_try {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'const_try_chain') {
            my $prev_name;
            my $first_target = @{ $stmt->{steps} } ? '__metac_chain' . $ctx->{tmp_counter}++ : $stmt->{name};
            my $first_stmt = {
                kind => 'const_try_expr',
                name => $first_target,
                expr => $stmt->{first},
            };
            compile_block([ $first_stmt ], $ctx, $out, $indent, $current_fn_return);
            $prev_name = $first_target;

            for (my $i = 0; $i < @{ $stmt->{steps} }; $i++) {
                my $step = $stmt->{steps}[$i];
                my $is_last = ($i == @{ $stmt->{steps} } - 1);
                my $target = $is_last ? $stmt->{name} : ('__metac_chain' . $ctx->{tmp_counter}++);
                my $method_expr = {
                    kind   => 'method_call',
                    recv   => { kind => 'ident', name => $prev_name },
                    method => $step->{name},
                    args   => $step->{args},
                };
                my $step_stmt = {
                    kind => 'const_try_expr',
                    name => $target,
                    expr => $method_expr,
                };
                compile_block([ $step_stmt ], $ctx, $out, $indent, $current_fn_return);
                $prev_name = $target;
            }
            return 1;
        }

        if ($stmt->{kind} eq 'destructure_split_or') {
            compile_error("split ... or handler is currently only supported in number | error functions")
              if !type_is_number_or_error($current_fn_return);

            my ($src_code, $src_type, $src_prelude, $src_cleanups) = compile_expr_with_temp_scope(
                ctx  => $ctx,
                expr => $stmt->{source_expr},
            );
            emit_expr_temp_prelude($out, $indent, $src_prelude);
            my ($delim_code, $delim_type, $delim_prelude, $delim_cleanups) = compile_expr_with_temp_scope(
                ctx  => $ctx,
                expr => $stmt->{delim_expr},
            );
            emit_expr_temp_prelude($out, $indent, $delim_prelude);
            my @split_cleanups = (@$src_cleanups, @$delim_cleanups);
            my $split_cleanup_count = push_active_temp_cleanups($ctx, \@split_cleanups);
            compile_error("split source must be string") if $src_type ne 'string';
            compile_error("split delimiter must be string") if $delim_type ne 'string';

            my $expected = scalar @{ $stmt->{vars} };
            my $tmp = '__metac_split' . $ctx->{tmp_counter}++;
            my $handler_err = '__metac_handler_err' . $ctx->{tmp_counter}++;

            emit_line($out, $indent, "ResultStringList $tmp = metac_split_string($src_code, $delim_code);");
            register_owned_cleanup_for_var($ctx, $tmp, "metac_free_result_string_list($tmp)");
            emit_line($out, $indent, "if ($tmp.is_error || $tmp.value.count != (size_t)$expected) {");
            emit_line($out, $indent + 2, "const char *$handler_err = $tmp.is_error ? $tmp.message : \"Split arity mismatch\";");
            new_scope($ctx);
            if (defined $stmt->{err_name} && $stmt->{err_name} ne '') {
                declare_var($ctx, $stmt->{err_name}, { type => 'string', immutable => 1, c_name => $handler_err });
            }
            compile_block($stmt->{handler}, $ctx, $out, $indent + 2, $current_fn_return);
            close_codegen_scope($ctx, $out, $indent + 2);
            emit_line($out, $indent + 2, "return err_number($handler_err, __metac_line_no, \"\");");
            emit_line($out, $indent, "}");

            for (my $i = 0; $i < $expected; $i++) {
                my $name = $stmt->{vars}[$i];
                emit_line($out, $indent, "const char *$name = $tmp.value.items[$i];");
                declare_var($ctx, $name, { type => 'string', immutable => 1, c_name => $name });
            }
            emit_expr_temp_cleanups($out, $indent, \@split_cleanups);
            pop_active_temp_cleanups($ctx, $split_cleanup_count);
            return 1;
        }

        if ($stmt->{kind} eq 'destructure_list') {
            my ($expr_code, $expr_type, $expr_prelude, $expr_cleanups) = compile_expr_with_temp_scope(
                ctx                     => $ctx,
                expr                    => $stmt->{expr},
                transfer_root_ownership => 1,
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_cleanups);
            compile_error("Destructuring assignment requires list expression, got $expr_type")
              if $expr_type ne 'string_list' && $expr_type ne 'number_list' && $expr_type ne 'bool_list';

            my $expected = scalar @{ $stmt->{vars} };
            compile_error("Cannot prove destructuring arity of $expected for a non-stable expression")
              if !expr_is_stable_for_facts($stmt->{expr}, $ctx);
            my $proof_key = expr_fact_key($stmt->{expr}, $ctx);
            my $known_len = lookup_list_len_fact($ctx, $proof_key);
            compile_error("Cannot prove destructuring arity of $expected for this expression; add a guard like: if <expr>.size() != $expected { return ... }")
              if !defined $known_len;
            compile_error("Destructuring arity mismatch: expected $expected, but proven size is $known_len")
              if $known_len != $expected;

            my $tmp = '__metac_list' . $ctx->{tmp_counter}++;
            if ($expr_type eq 'string_list') {
                emit_line($out, $indent, "StringList $tmp = $expr_code;");
                for (my $i = 0; $i < @{ $stmt->{vars} }; $i++) {
                    my $name = $stmt->{vars}[$i];
                    emit_line($out, $indent, "const char *$name = $tmp.items[$i];");
                    declare_var($ctx, $name, { type => 'string', immutable => 1, c_name => $name });
                }
            } elsif ($expr_type eq 'number_list') {
                emit_line($out, $indent, "NumberList $tmp = $expr_code;");
                for (my $i = 0; $i < @{ $stmt->{vars} }; $i++) {
                    my $name = $stmt->{vars}[$i];
                    emit_line($out, $indent, "const int64_t $name = $tmp.items[$i];");
                    declare_var($ctx, $name, { type => 'number', immutable => 1, c_name => $name });
                }
            } else {
                emit_line($out, $indent, "BoolList $tmp = $expr_code;");
                for (my $i = 0; $i < @{ $stmt->{vars} }; $i++) {
                    my $name = $stmt->{vars}[$i];
                    emit_line($out, $indent, "const int $name = $tmp.items[$i];");
                    declare_var($ctx, $name, { type => 'bool', immutable => 1, c_name => $name });
                }
            }
            my $tmp_cleanup = cleanup_call_for_temp_expr(
                var_name  => $tmp,
                decl_type => $expr_type,
                expr_code => $expr_code,
            );
            register_owned_cleanup_for_var($ctx, $tmp, $tmp_cleanup) if defined $tmp_cleanup;
            emit_expr_temp_cleanups($out, $indent, $expr_cleanups);
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
            return 1;
        }
    return 0;
}

1;
