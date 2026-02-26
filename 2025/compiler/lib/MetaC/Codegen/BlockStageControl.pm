package MetaC::Codegen;
use strict;
use warnings;

sub _emit_stmt_try_failure {
    my ($ctx, $out, $indent, $current_fn_return, $message_expr) = @_;
    my $message_tmp = "__metac_errmsg" . $ctx->{tmp_counter}++;
    emit_line($out, $indent, "const char *$message_tmp = $message_expr;");
    if (defined $ctx->{active_temp_cleanups}) {
        for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
            emit_line($out, $indent, $ctx->{active_temp_cleanups}[$i] . ';');
        }
    }
    emit_all_owned_cleanups($ctx, $out, $indent);
    if (type_is_number_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_number($message_tmp, __metac_line_no, \"\");");
        return;
    }
    if (type_is_bool_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_bool($message_tmp, __metac_line_no, \"\");");
        return;
    }
    if (type_is_string_or_error($current_fn_return)) {
        emit_line($out, $indent, "return err_string_value($message_tmp, __metac_line_no, \"\");");
        return;
    }
    if (is_supported_generic_union_return($current_fn_return) && union_contains_member($current_fn_return, 'error')) {
        emit_line($out, $indent, "return metac_value_error($message_tmp, __metac_line_no, \"\");");
        return;
    }
    emit_line($out, $indent, "fprintf(stderr, \"%s\\n\", $message_tmp);");
    emit_line($out, $indent, "exit(2);");
}

sub _emit_return_stmt {
    my ($ctx, $out, $indent, $return_expr, $current_fn_return) = @_;
    my $return_c_type = _return_c_type_from_fn_return($current_fn_return);
    my $return_tmp = "__metac_return" . $ctx->{tmp_counter}++;
    emit_line($out, $indent, "$return_c_type $return_tmp = $return_expr;");
    if (defined $ctx->{active_temp_cleanups}) {
        for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
            emit_line($out, $indent, $ctx->{active_temp_cleanups}[$i] . ';');
        }
    }
    emit_all_owned_cleanups($ctx, $out, $indent);
    emit_line($out, $indent, "return $return_tmp;");
}

sub _return_c_type_from_fn_return {
    my ($current_fn_return) = @_;
    return 'ResultNumber' if type_is_number_or_error($current_fn_return);
    return 'ResultBool' if type_is_bool_or_error($current_fn_return);
    return 'ResultStringValue' if type_is_string_or_error($current_fn_return);
    return 'MetaCValue' if is_supported_generic_union_return($current_fn_return);
    return 'int64_t' if $current_fn_return eq 'number';
    return 'int' if $current_fn_return eq 'bool';
    return 'const char *' if $current_fn_return eq 'string';
    return 'NullableNumber' if $current_fn_return eq 'number_or_null';
    return 'NumberList' if $current_fn_return eq 'number_list';
    return 'NumberListList' if $current_fn_return eq 'number_list_list';
    return 'StringList' if $current_fn_return eq 'string_list';
    return 'BoolList' if $current_fn_return eq 'bool_list';
    return 'AnyList' if is_array_type($current_fn_return);
    if (is_matrix_type($current_fn_return)) {
        my $meta = matrix_type_meta($current_fn_return);
        return 'MatrixNumber' if $meta->{elem} eq 'number';
        return 'MatrixString' if $meta->{elem} eq 'string';
        return 'MatrixOpaque';
    }
    compile_error("Unsupported function return mode for return emission: $current_fn_return");
}

sub _expr_contains_try {
    my ($expr) = @_;
    return 0 if !defined $expr || ref($expr) ne 'HASH';
    return 1 if ($expr->{kind} // '') eq 'try';

    if (($expr->{kind} // '') eq 'unary') {
        return _expr_contains_try($expr->{expr});
    }
    if (($expr->{kind} // '') eq 'binop') {
        return _expr_contains_try($expr->{left}) || _expr_contains_try($expr->{right});
    }
    if (($expr->{kind} // '') eq 'index') {
        return _expr_contains_try($expr->{recv}) || _expr_contains_try($expr->{index});
    }
    if (($expr->{kind} // '') eq 'method_call') {
        return 1 if _expr_contains_try($expr->{recv});
        for my $arg (@{ $expr->{args} // [] }) {
            return 1 if _expr_contains_try($arg);
        }
        return 0;
    }
    if (($expr->{kind} // '') eq 'call' || ($expr->{kind} // '') eq 'list_literal') {
        for my $arg (@{ $expr->{args} // $expr->{items} // [] }) {
            return 1 if _expr_contains_try($arg);
        }
        return 0;
    }
    if (($expr->{kind} // '') eq 'lambda1') {
        return _expr_contains_try($expr->{body});
    }
    if (($expr->{kind} // '') eq 'lambda2') {
        return _expr_contains_try($expr->{body});
    }
    return 0;
}

sub _rewrite_expr_hoist_try {
    my (%args) = @_;
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $current_fn_return = $args{current_fn_return};

    return $expr if !defined $expr || ref($expr) ne 'HASH';
    my $rewrite = sub {
        return _rewrite_expr_hoist_try(
            expr              => $_[0],
            ctx               => $ctx,
            out               => $out,
            indent            => $indent,
            current_fn_return => $current_fn_return,
        );
    };

    if (($expr->{kind} // '') eq 'try') {
        my $tmp_name = '__metac_inline_try' . $ctx->{tmp_counter}++;
        my $tmp_stmt = {
            kind => 'const_try_expr',
            name => $tmp_name,
            expr => $expr->{expr},
        };
        compile_block([ $tmp_stmt ], $ctx, $out, $indent, $current_fn_return);
        return { kind => 'ident', name => $tmp_name };
    }

    if (($expr->{kind} // '') eq 'unary') {
        return { %$expr, expr => $rewrite->($expr->{expr}) };
    }
    if (($expr->{kind} // '') eq 'binop') {
        return { %$expr, left => $rewrite->($expr->{left}), right => $rewrite->($expr->{right}) };
    }
    if (($expr->{kind} // '') eq 'index') {
        return { %$expr, recv => $rewrite->($expr->{recv}), index => $rewrite->($expr->{index}) };
    }
    if (($expr->{kind} // '') eq 'method_call') {
        my @args;
        for my $arg (@{ $expr->{args} // [] }) {
            push @args, $rewrite->($arg);
        }
        return { %$expr, recv => $rewrite->($expr->{recv}), args => \@args };
    }
    if (($expr->{kind} // '') eq 'call') {
        my @args;
        for my $arg (@{ $expr->{args} // [] }) {
            push @args, $rewrite->($arg);
        }
        return { %$expr, args => \@args };
    }
    if (($expr->{kind} // '') eq 'list_literal') {
        my @items;
        for my $item (@{ $expr->{items} // [] }) {
            push @items, $rewrite->($item);
        }
        return { %$expr, items => \@items };
    }

    return $expr;
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
            my ($cond_code, $cond_type, $cond_prelude, $cond_cleanups) = compile_expr_with_temp_scope(
                ctx  => $ctx,
                expr => $stmt->{cond},
            );
            compile_error("if condition must evaluate to bool, got $cond_type") if $cond_type ne 'bool';
            emit_expr_temp_prelude($out, $indent, $cond_prelude);
            my $cond_tmp = "__metac_if_cond" . $ctx->{tmp_counter}++;
            emit_line($out, $indent, "int $cond_tmp = $cond_code;");
            emit_expr_temp_cleanups($out, $indent, $cond_cleanups);
            emit_line($out, $indent, "if ($cond_tmp) {");
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
            close_codegen_scope($ctx, $out, $indent + 2);
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
                close_codegen_scope($ctx, $out, $indent + 2);
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
            my ($expr_code, $expr_type, $expr_prelude, $expr_temp_cleanups) = compile_expr_with_temp_scope(
                ctx  => $ctx,
                expr => $stmt->{expr},
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_temp_cleanups);

            if (type_is_number_or_error($current_fn_return)) {
                if ($expr_type eq 'number') {
                    _emit_return_stmt($ctx, $out, $indent, "ok_number($expr_code)", $current_fn_return);
                } elsif ($expr_type eq 'indexed_number') {
                    my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                    _emit_return_stmt($ctx, $out, $indent, "ok_number($num_expr)", $current_fn_return);
                } elsif ($expr_type eq 'error') {
                    _emit_return_stmt($ctx, $out, $indent, $expr_code, $current_fn_return);
                } else {
                    compile_error("return type mismatch: expected number or error for number|error function");
                }
            } elsif (type_is_bool_or_error($current_fn_return)) {
                if ($expr_type eq 'bool') {
                    _emit_return_stmt($ctx, $out, $indent, "ok_bool($expr_code)", $current_fn_return);
                } elsif ($expr_type eq 'error') {
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        _emit_return_stmt($ctx, $out, $indent, "err_bool($msg_code, __metac_line_no, \"\")", $current_fn_return);
                    } else {
                        compile_error("return type mismatch: bool|error function currently requires error(...) for error returns");
                    }
                } else {
                    compile_error("return type mismatch: expected bool or error for bool|error function");
                }
            } elsif (type_is_string_or_error($current_fn_return)) {
                if ($expr_type eq 'string') {
                    _emit_return_stmt($ctx, $out, $indent, "ok_string_value($expr_code)", $current_fn_return);
                } elsif ($expr_type eq 'error') {
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        _emit_return_stmt($ctx, $out, $indent, "err_string_value($msg_code, __metac_line_no, \"\")", $current_fn_return);
                    } else {
                        compile_error("return type mismatch: string|error function currently requires error(...) for error returns");
                    }
                } else {
                    compile_error("return type mismatch: expected string or error for string|error function");
                }
            } elsif (is_supported_generic_union_return($current_fn_return)) {
                if ($expr_type eq $current_fn_return) {
                    if ($stmt->{expr}{kind} eq 'ident') {
                        consume_owned_cleanup_for_var($ctx, $stmt->{expr}{name});
                    }
                    _emit_return_stmt($ctx, $out, $indent, $expr_code, $current_fn_return);
                } elsif ($expr_type eq 'error') {
                    compile_error("return type mismatch: expected $current_fn_return, got error")
                      if !union_contains_member($current_fn_return, 'error');
                    if ($stmt->{expr}{kind} eq 'call' && $stmt->{expr}{name} eq 'error') {
                        my ($msg_code, $msg_type) = compile_expr($stmt->{expr}{args}[0], $ctx);
                        compile_error("error(...) expects string message") if $msg_type ne 'string';
                        _emit_return_stmt($ctx, $out, $indent, "metac_value_error($msg_code, __metac_line_no, \"\")", $current_fn_return);
                    } else {
                        compile_error("generic union error return currently requires error(...) expression");
                    }
                } else {
                    my $as_union = generic_union_to_c_expr(
                        $expr_code,
                        $expr_type,
                        $current_fn_return,
                        "return",
                    );
                    if ($stmt->{expr}{kind} eq 'ident') {
                        consume_owned_cleanup_for_var($ctx, $stmt->{expr}{name});
                    }
                    _emit_return_stmt($ctx, $out, $indent, $as_union, $current_fn_return);
                }
            } elsif ($current_fn_return eq 'number') {
                my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                _emit_return_stmt($ctx, $out, $indent, $num_expr, $current_fn_return);
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                _emit_return_stmt($ctx, $out, $indent, $expr_code, $current_fn_return);
            } elsif ($current_fn_return eq 'string') {
                compile_error("return type mismatch: expected string return")
                  if $expr_type ne 'string';
                _emit_return_stmt($ctx, $out, $indent, $expr_code, $current_fn_return);
            } elsif ($current_fn_return eq 'number_list'
                || $current_fn_return eq 'number_list_list'
                || $current_fn_return eq 'string_list'
                || $current_fn_return eq 'bool_list'
                || is_array_type($current_fn_return)
                || is_matrix_type($current_fn_return))
            {
                compile_error("return type mismatch: expected $current_fn_return, got $expr_type")
                  if !type_matches_expected($current_fn_return, $expr_type);
                if ($stmt->{expr}{kind} eq 'ident') {
                    consume_owned_cleanup_for_var($ctx, $stmt->{expr}{name});
                }
                _emit_return_stmt($ctx, $out, $indent, $expr_code, $current_fn_return);
            } elsif ($current_fn_return eq 'void') {
                compile_error("return is not allowed in function with no return type");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
            return 1;
        }

        if ($stmt->{kind} eq 'expr_stmt') {
            my $expr = $stmt->{expr};
            if (_expr_contains_try($expr)) {
                $expr = _rewrite_expr_hoist_try(
                    expr              => $expr,
                    ctx               => $ctx,
                    out               => $out,
                    indent            => $indent,
                    current_fn_return => $current_fn_return,
                );
                $stmt->{expr} = $expr;
            }
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

                my ($value_code, $value_type, $value_prelude, $value_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{args}[0],
                );
                emit_expr_temp_prelude($out, $indent, $value_prelude);
                my ($coord_code, $coord_type, $coord_prelude, $coord_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{args}[1],
                );
                emit_expr_temp_prelude($out, $indent, $coord_prelude);
                my @insert_cleanups = (@$value_cleanups, @$coord_cleanups);
                my $insert_cleanup_count = push_active_temp_cleanups($ctx, \@insert_cleanups);
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
                emit_expr_temp_cleanups($out, $indent, \@insert_cleanups);
                pop_active_temp_cleanups($ctx, $insert_cleanup_count);
                return 1;
            }

            my ($expr_code, undef, $expr_prelude, $expr_cleanups) = compile_expr_with_temp_scope(
                ctx  => $ctx,
                expr => $stmt->{expr},
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_cleanups);
            emit_line($out, $indent, "(void)($expr_code);");
            emit_expr_temp_cleanups($out, $indent, $expr_cleanups);
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
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

                my ($value_code, $value_type, $value_prelude, $value_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{args}[0],
                );
                emit_expr_temp_prelude($out, $indent, $value_prelude);
                my ($coord_code, $coord_type, $coord_prelude, $coord_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{args}[1],
                );
                emit_expr_temp_prelude($out, $indent, $coord_prelude);
                my @insert_cleanups = (@$value_cleanups, @$coord_cleanups);
                my $insert_cleanup_count = push_active_temp_cleanups($ctx, \@insert_cleanups);
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
                _emit_stmt_try_failure($ctx, $out, $indent + 2, $current_fn_return, "$tmp.message");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "$target = $tmp.value;");
                emit_expr_temp_cleanups($out, $indent, \@insert_cleanups);
                pop_active_temp_cleanups($ctx, $insert_cleanup_count);
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
            close_codegen_scope($ctx, $out, $indent);
            return 1;
        }

        if ($stmt->{kind} eq 'expr_or_catch') {
            my $expr = $stmt->{expr};
            if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'match') {
                my $actual = scalar @{ $expr->{args} };
                compile_error("match(...) with 'or catch' expects exactly 1 pattern arg")
                  if $actual != 1;

                my ($src_code, $src_type, $src_prelude, $src_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{recv},
                );
                emit_expr_temp_prelude($out, $indent, $src_prelude);
                my ($pattern_code, $pattern_type, $pattern_prelude, $pattern_cleanups) = compile_expr_with_temp_scope(
                    ctx  => $ctx,
                    expr => $expr->{args}[0],
                );
                emit_expr_temp_prelude($out, $indent, $pattern_prelude);
                my @match_cleanups = (@$pattern_cleanups, @$src_cleanups);
                my $match_cleanup_count = push_active_temp_cleanups($ctx, \@match_cleanups);
                compile_error("match source must be string") if $src_type ne 'string';
                compile_error("match pattern must be string") if $pattern_type ne 'string';

                my $tmp = '__metac_or_stmt_match' . $ctx->{tmp_counter}++;
                emit_line($out, $indent, "ResultStringList $tmp = metac_match_string($src_code, $pattern_code);");
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
                emit_line($out, $indent, "metac_free_result_string_list($tmp);");
                emit_expr_temp_cleanups($out, $indent, \@match_cleanups);
                pop_active_temp_cleanups($ctx, $match_cleanup_count);
                return 1;
            }

            compile_error("or catch statement currently supports fallible function calls")
              if $expr->{kind} ne 'call';

            my $functions = $ctx->{functions} // {};
            my $sig = $functions->{ $expr->{name} };
            compile_error("or catch requires fallible user function call, got '$expr->{name}'")
              if !defined($sig) || !union_contains_member($sig->{return_type}, 'error');

            my $arg_info = _compile_call_args_for_sig($expr, $sig, $ctx);
            emit_expr_temp_prelude($out, $indent, $arg_info->{prelude});
            my $arg_cleanup_count = push_active_temp_cleanups($ctx, $arg_info->{cleanups});
            my $arg_code = $arg_info->{arg_code};
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
                emit_expr_temp_cleanups($out, $indent, $arg_info->{cleanups});
                pop_active_temp_cleanups($ctx, $arg_cleanup_count);
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
                emit_expr_temp_cleanups($out, $indent, $arg_info->{cleanups});
                pop_active_temp_cleanups($ctx, $arg_cleanup_count);
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
                emit_expr_temp_cleanups($out, $indent, $arg_info->{cleanups});
                pop_active_temp_cleanups($ctx, $arg_cleanup_count);
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
                emit_expr_temp_cleanups($out, $indent, $arg_info->{cleanups});
                pop_active_temp_cleanups($ctx, $arg_cleanup_count);
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
