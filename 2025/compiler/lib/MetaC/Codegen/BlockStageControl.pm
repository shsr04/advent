package MetaC::Codegen;
use strict;
use warnings;

sub _emit_stmt_try_failure {
    my ($out, $indent, $current_fn_return, $message_expr) = @_;
    if (type_is_number_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_number($message_expr, __metac_line_no, \"\");");
        return;
    }
    if (type_is_bool_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_bool($message_expr, __metac_line_no, \"\");");
        return;
    }
    if (type_is_string_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_string_value($message_expr, __metac_line_no, \"\");");
        return;
    }
    if (is_supported_generic_union_return($current_fn_return) && union_contains_member($current_fn_return, 'error')) {
        emit_line($out, $indent, "return metac_value_error($message_expr, __metac_line_no, \"\");");
        return;
    }
    emit_line($out, $indent, "fprintf(stderr, \"%s\\n\", $message_expr);");
    emit_line($out, $indent, "exit(2);");
}

sub _compile_block_stage_control {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'if') {
            my $size_check = size_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_check = nullable_number_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_nonnull_on_false = nullable_number_names_non_null_on_false_expr($stmt->{cond}, $ctx);
            my $nullable_nonnull_on_true = nullable_number_names_non_null_on_true_expr($stmt->{cond}, $ctx);
            my $union_check = union_member_check_from_condition($stmt->{cond}, $ctx);
            my $union_true_bindings = union_member_bindings_on_true_expr($stmt->{cond}, $ctx);
            my $union_false_bindings = union_member_bindings_on_false_expr($stmt->{cond}, $ctx);
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
            if (defined $nullable_nonnull_on_true && @$nullable_nonnull_on_true) {
                for my $name (@$nullable_nonnull_on_true) {
                    declare_not_null_number_shadow($ctx, $name);
                }
            }
            if (defined $union_check && $union_check->{op} eq '==') {
                declare_union_member_shadow($ctx, $union_check->{name}, $union_check->{member});
            }
            if (defined $union_true_bindings && @$union_true_bindings) {
                for my $binding (@$union_true_bindings) {
                    declare_union_member_shadow($ctx, $binding->{name}, $binding->{member});
                }
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
                if (defined $union_check && $union_check->{op} eq '!=') {
                    declare_union_member_shadow($ctx, $union_check->{name}, $union_check->{member});
                }
                if (defined $union_false_bindings && @$union_false_bindings) {
                    for my $binding (@$union_false_bindings) {
                        declare_union_member_shadow($ctx, $binding->{name}, $binding->{member});
                    }
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

            if (type_is_number_or_error($current_fn_return)) {
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
            } elsif (type_is_bool_or_error($current_fn_return)) {
                if ($expr_type eq 'bool') {
                    emit_line($out, $indent, "return ok_bool($expr_code);");
                } elsif ($expr_type eq 'error') {
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        emit_line($out, $indent, "return err_bool($msg_code, __metac_line_no, \"\");");
                    } else {
                        compile_error("return type mismatch: bool|error function currently requires error(...) for error returns");
                    }
                } else {
                    compile_error("return type mismatch: expected bool or error for bool|error function");
                }
            } elsif (type_is_string_or_error($current_fn_return)) {
                if ($expr_type eq 'string') {
                    emit_line($out, $indent, "return ok_string_value($expr_code);");
                } elsif ($expr_type eq 'error') {
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        emit_line($out, $indent, "return err_string_value($msg_code, __metac_line_no, \"\");");
                    } else {
                        compile_error("return type mismatch: string|error function currently requires error(...) for error returns");
                    }
                } else {
                    compile_error("return type mismatch: expected string or error for string|error function");
                }
            } elsif (is_supported_generic_union_return($current_fn_return)) {
                my $members = union_member_types($current_fn_return);
                my %allowed = map { $_ => 1 } @$members;

                if ($expr_type eq $current_fn_return) {
                    emit_line($out, $indent, "return $expr_code;");
                } elsif ($expr_type eq 'number' || $expr_type eq 'indexed_number') {
                    compile_error("return type mismatch: expected $current_fn_return, got $expr_type")
                      if !$allowed{number};
                    my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                    emit_line($out, $indent, "return metac_value_number($num_expr);");
                } elsif ($expr_type eq 'bool') {
                    compile_error("return type mismatch: expected $current_fn_return, got bool")
                      if !$allowed{bool};
                    emit_line($out, $indent, "return metac_value_bool($expr_code);");
                } elsif ($expr_type eq 'string') {
                    compile_error("return type mismatch: expected $current_fn_return, got string")
                      if !$allowed{string};
                    emit_line($out, $indent, "return metac_value_string($expr_code);");
                } elsif ($expr_type eq 'null') {
                    compile_error("return type mismatch: expected $current_fn_return, got null")
                      if !$allowed{null};
                    emit_line($out, $indent, "return metac_value_null();");
                } elsif ($expr_type eq 'error') {
                    compile_error("return type mismatch: expected $current_fn_return, got error")
                      if !$allowed{error};
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        emit_line($out, $indent, "return metac_value_error($msg_code, __metac_line_no, \"\");");
                    } else {
                        compile_error("generic union error return currently requires error(...) expression");
                    }
                } else {
                    compile_error("return type mismatch: expected $current_fn_return, got $expr_type");
                }
            } elsif ($current_fn_return eq 'number') {
                my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                emit_line($out, $indent, "return $num_expr;");
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                emit_line($out, $indent, "return $expr_code;");
            } elsif ($current_fn_return eq 'void') {
                compile_error("return is not allowed in function with no return type");
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
                _emit_stmt_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "$target = $tmp.value;");
                return 1;
            }

            # Reuse existing const_try_expr lowering for non-mutating try-forms.
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

        if ($stmt->{kind} eq 'expr_or_catch') {
            my $expr = $stmt->{expr};
            compile_error("or catch statement currently supports fallible function calls")
              if $expr->{kind} ne 'call';

            my $functions = $ctx->{functions} // {};
            my $sig = $functions->{ $expr->{name} };
            compile_error("or catch requires fallible user function call, got '$expr->{name}'")
              if !defined($sig) || !union_contains_member($sig->{return_type}, 'error');

            my $arg_code = _compile_call_args_for_sig($expr, $sig, $ctx);
            my $return_type = $sig->{return_type};
            my $tmp = '__metac_or_stmt' . $ctx->{tmp_counter}++;

            if (type_is_number_or_error($return_type)) {
                emit_line($out, $indent, "ResultNumber $tmp = $expr->{name}(" . join(', ', @$arg_code) . ");");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                _emit_or_catch_handler_then_fail(
                    ctx               => $ctx,
                    out               => $out,
                    indent            => $indent + 2,
                    current_fn_return => $current_fn_return,
                    handler           => $stmt->{handler},
                    err_name          => $stmt->{err_name},
                    message_expr      => "$tmp.message",
                );
                emit_line($out, $indent, "}");
                return 1;
            }
            if (type_is_bool_or_error($return_type)) {
                emit_line($out, $indent, "ResultBool $tmp = $expr->{name}(" . join(', ', @$arg_code) . ");");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                _emit_or_catch_handler_then_fail(
                    ctx               => $ctx,
                    out               => $out,
                    indent            => $indent + 2,
                    current_fn_return => $current_fn_return,
                    handler           => $stmt->{handler},
                    err_name          => $stmt->{err_name},
                    message_expr      => "$tmp.message",
                );
                emit_line($out, $indent, "}");
                return 1;
            }
            if (type_is_string_or_error($return_type)) {
                emit_line($out, $indent, "ResultStringValue $tmp = $expr->{name}(" . join(', ', @$arg_code) . ");");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                _emit_or_catch_handler_then_fail(
                    ctx               => $ctx,
                    out               => $out,
                    indent            => $indent + 2,
                    current_fn_return => $current_fn_return,
                    handler           => $stmt->{handler},
                    err_name          => $stmt->{err_name},
                    message_expr      => "$tmp.message",
                );
                emit_line($out, $indent, "}");
                return 1;
            }
            if (is_supported_generic_union_return($return_type)) {
                emit_line($out, $indent, "MetaCValue $tmp = $expr->{name}(" . join(', ', @$arg_code) . ");");
                emit_line($out, $indent, "if ($tmp.kind == METAC_VALUE_ERROR) {");
                _emit_or_catch_handler_then_fail(
                    ctx               => $ctx,
                    out               => $out,
                    indent            => $indent + 2,
                    current_fn_return => $current_fn_return,
                    handler           => $stmt->{handler},
                    err_name          => $stmt->{err_name},
                    message_expr      => "$tmp.error_message",
                );
                emit_line($out, $indent, "}");
                return 1;
            }
            compile_error("Unsupported fallible return type '$return_type' for '$expr->{name}'");
        }

        if ($stmt->{kind} eq 'raw') {
            compile_error("Unsupported statement: $stmt->{text}");
        }

        compile_error("Unsupported statement kind: $stmt->{kind}");
    return 0;
}

1;
