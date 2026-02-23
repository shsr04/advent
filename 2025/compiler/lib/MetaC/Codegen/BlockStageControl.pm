package MetaC::Codegen;
use strict;
use warnings;

sub _compile_block_stage_control {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'if') {
            my $size_check = size_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_check = nullable_number_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_nonnull_on_false = nullable_number_names_non_null_on_false_expr($stmt->{cond}, $ctx);
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("if condition must evaluate to bool, got $cond_type") if $cond_type ne 'bool';

            emit_line($out, $indent, "if ($cond_code) {");
            new_scope($ctx);
            if (defined $size_check && $size_check->{op} eq '==') {
                set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
            }
            if (defined $nullable_check && $nullable_check->{op} eq '!=') {
                declare_not_null_number_shadow($ctx, $nullable_check->{name});
            }
            compile_block($stmt->{then_body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');

            if (defined $stmt->{else_body}) {
                emit_line($out, $indent, 'else {');
                new_scope($ctx);
                if (defined $size_check && $size_check->{op} eq '!=') {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $nullable_check && $nullable_check->{op} eq '==') {
                    declare_not_null_number_shadow($ctx, $nullable_check->{name});
                }
                compile_block($stmt->{else_body}, $ctx, $out, $indent + 2, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent, '}');
            }

            if (defined $size_check) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;

                if (!defined $stmt->{else_body} && $size_check->{op} eq '!=' && $then_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $stmt->{else_body} && $size_check->{op} eq '==' && $else_returns && !$then_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $stmt->{else_body} && $size_check->{op} eq '!=' && $then_returns && !$else_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
            }

            if (defined $nullable_check) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;

                if (!defined $stmt->{else_body} && $nullable_check->{op} eq '==' && $then_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
                if (defined $stmt->{else_body} && $nullable_check->{op} eq '==' && $then_returns && !$else_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
                if (defined $stmt->{else_body} && $nullable_check->{op} eq '!=' && $else_returns && !$then_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
            }

            if (defined $nullable_nonnull_on_false && @$nullable_nonnull_on_false) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;
                if (!defined $stmt->{else_body} && $then_returns) {
                    for my $name (@$nullable_nonnull_on_false) {
                        set_nonnull_fact_for_var_name($ctx, $name);
                    }
                }
                if (defined $stmt->{else_body} && $then_returns && !$else_returns) {
                    for my $name (@$nullable_nonnull_on_false) {
                        set_nonnull_fact_for_var_name($ctx, $name);
                    }
                }
            }
            return 1;
        }

        if ($stmt->{kind} eq 'return') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($current_fn_return eq 'number_or_error') {
                if ($expr_type eq 'number') {
                    emit_line($out, $indent, "return ok_number($expr_code);");
                } elsif ($expr_type eq 'indexed_number') {
                    my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                    emit_line($out, $indent, "return ok_number($num_expr);");
                } elsif ($expr_type eq 'error') {
                    emit_line($out, $indent, "return $expr_code;");
                } else {
                    compile_error("return type mismatch: expected number or error for number|error function");
                }
            } elsif ($current_fn_return eq 'number') {
                my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                emit_line($out, $indent, "return $num_expr;");
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                emit_line($out, $indent, "return $expr_code;");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            return 1;
        }

        if ($stmt->{kind} eq 'expr_stmt') {
            my $expr = $stmt->{expr};
            if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'insert' && $expr->{recv}{kind} eq 'ident') {
                my $recv_name = $expr->{recv}{name};
                my $recv_info = lookup_var($ctx, $recv_name);
                compile_error("Unknown variable: $recv_name")
                  if !defined $recv_info;
                compile_error("Cannot mutate immutable variable '$recv_name'")
                  if $recv_info->{immutable};

                my $recv_type = $recv_info->{type};
                compile_error("Method 'insert(...)' statement receiver must be matrix(...), got $recv_type")
                  if !is_matrix_type($recv_type);
                my $meta = matrix_type_meta($recv_type);

                my $actual = scalar @{ $expr->{args} };
                compile_error("Method 'insert(...)' expects 2 args, got $actual")
                  if $actual != 2;

                my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
                my ($coord_code, $coord_type) = compile_expr($expr->{args}[1], $ctx);
                compile_error("Method 'insert(...)' requires number[] coordinates, got $coord_type")
                  if $coord_type ne 'number_list';
                compile_error("Method 'insert(...)' is fallible on unconstrained matrix; handle it with '?'")
                  if !$meta->{has_size};

                my $target = $recv_info->{c_name};
                my ($insert_die, $value_arg);
                if ($meta->{elem} eq 'number') {
                    $insert_die = 'metac_matrix_number_insert_or_die';
                    $value_arg = number_like_to_c_expr($value_code, $value_type, "Method 'insert(...)' statement form");
                } elsif ($meta->{elem} eq 'string') {
                    compile_error("Method 'insert(...)' on matrix(string) expects string value, got $value_type")
                      if $value_type ne 'string';
                    $insert_die = 'metac_matrix_string_insert_or_die';
                    $value_arg = $value_code;
                } else {
                    compile_error("matrix insert statement form is unsupported for element type '$meta->{elem}'");
                }

                emit_line($out, $indent, "$target = $insert_die($target, $value_arg, $coord_code);");
                return 1;
            }

            my ($expr_code, undef) = compile_expr($stmt->{expr}, $ctx);
            emit_line($out, $indent, "(void)($expr_code);");
            return 1;
        }

        if ($stmt->{kind} eq 'expr_stmt_try') {
            compile_error("try expression statement with '?' is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

            my $expr = $stmt->{expr};
            if ($expr->{kind} eq 'method_call'
                && $expr->{method} eq 'insert'
                && $expr->{recv}{kind} eq 'ident')
            {
                my $recv_name = $expr->{recv}{name};
                my $recv_info = lookup_var($ctx, $recv_name);
                compile_error("Unknown variable: $recv_name")
                  if !defined $recv_info;
                compile_error("Cannot mutate immutable variable '$recv_name'")
                  if $recv_info->{immutable};

                my $recv_type = $recv_info->{type};
                compile_error("Method 'insert(...)' statement receiver must be matrix(...), got $recv_type")
                  if !is_matrix_type($recv_type);
                my $meta = matrix_type_meta($recv_type);

                my $actual = scalar @{ $expr->{args} };
                compile_error("Method 'insert(...)' expects 2 args, got $actual")
                  if $actual != 2;

                my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
                my ($coord_code, $coord_type) = compile_expr($expr->{args}[1], $ctx);
                compile_error("Method 'insert(...)' requires number[] coordinates, got $coord_type")
                  if $coord_type ne 'number_list';

                my $target = $recv_info->{c_name};
                my ($result_type, $insert_try, $value_arg);
                if ($meta->{elem} eq 'number') {
                    $result_type = 'ResultMatrixNumber';
                    $insert_try = 'metac_matrix_number_insert_try';
                    $value_arg = number_like_to_c_expr($value_code, $value_type, "Method 'insert(...)' statement try-form");
                } elsif ($meta->{elem} eq 'string') {
                    compile_error("Method 'insert(...)' on matrix(string) expects string value, got $value_type")
                      if $value_type ne 'string';
                    $result_type = 'ResultMatrixString';
                    $insert_try = 'metac_matrix_string_insert_try';
                    $value_arg = $value_code;
                } else {
                    compile_error("matrix insert statement try-form is unsupported for element type '$meta->{elem}'");
                }

                my $tmp = '__metac_matrix_insert' . $ctx->{tmp_counter}++;
                emit_line($out, $indent, "$result_type $tmp = $insert_try($target, $value_arg, $coord_code);");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                emit_line($out, $indent + 2, "return err_number($tmp.message, __metac_line_no, \"\");");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "$target = $tmp.value;");
                return 1;
            }

            # Reuse the existing try-expression assignment lowering for all other fallible forms.
            my $supported_stmt_try = 0;
            if ($expr->{kind} eq 'call' && ($expr->{name} eq 'split' || $expr->{name} eq 'parseNumber')) {
                $supported_stmt_try = 1;
            } elsif ($expr->{kind} eq 'method_call'
                && ($expr->{method} eq 'map' || $expr->{method} eq 'filter' || $expr->{method} eq 'assert'))
            {
                $supported_stmt_try = 1;
            }
            compile_error("Unsupported try expression in statement context")
              if !$supported_stmt_try;

            # Reuse existing const_try_expr lowering for supported non-mutating try-forms.
            my $tmp_name = '__metac_stmt_try' . $ctx->{tmp_counter}++;
            my $tmp_stmt = {
                kind => 'const_try_expr',
                name => $tmp_name,
                expr => $expr,
                line => $stmt->{line},
            };
            new_scope($ctx);
            compile_block([ $tmp_stmt ], $ctx, $out, $indent, $current_fn_return);
            pop_scope($ctx);
            return 1;
        }

        if ($stmt->{kind} eq 'raw') {
            compile_error("Unsupported statement in day1 subset: $stmt->{text}");
        }

        compile_error("Unsupported statement kind: $stmt->{kind}");
    return 0;
}

1;
