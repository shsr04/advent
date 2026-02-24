package MetaC::Codegen;
use strict;
use warnings;

sub _compile_call_args_for_sig {
    my ($expr, $sig, $ctx) = @_;
    my $expected = scalar @{ $sig->{params} };
    my $actual = scalar @{ $expr->{args} };
    compile_error("Function '$expr->{name}' expects $expected args, got $actual")
      if $expected != $actual;

    my @arg_code;
    for (my $i = 0; $i < $expected; $i++) {
        my ($arg_c, $arg_t) = compile_expr($expr->{args}[$i], $ctx);
        my $param_t = $sig->{params}[$i]{type};
        if ($param_t eq 'number') {
            push @arg_code, number_like_to_c_expr($arg_c, $arg_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
            next;
        }
        if ($param_t eq 'number_or_null') {
            push @arg_code, number_or_null_to_c_expr($arg_c, $arg_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
            next;
        }
        if (is_supported_generic_union_return($param_t)) {
            push @arg_code, generic_union_to_c_expr($arg_c, $arg_t, $param_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
            next;
        }
        compile_error("Arg " . ($i + 1) . " to '$expr->{name}' must be $param_t, got $arg_t")
          if $arg_t ne $param_t;
        push @arg_code, $arg_c;
    }

    return \@arg_code;
}

sub _emit_or_catch_handler_then_fail {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $current_fn_return = $args{current_fn_return};
    my $handler = $args{handler};
    my $err_name = $args{err_name};
    my $message_expr = $args{message_expr};

    if (defined $handler) {
        new_scope($ctx);
        if (defined $err_name && $err_name ne '') {
            declare_var($ctx, $err_name, { type => 'string', immutable => 1, c_name => $message_expr });
        }
        compile_block($handler, $ctx, $out, $indent, $current_fn_return);
        pop_scope($ctx);
    }
    _emit_try_failure($out, $indent, $current_fn_return, $message_expr);
}

sub _compile_block_stage_decls_try_ops {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
    if ($stmt->{kind} eq 'const_try_tail_expr') {
        my $tmp = '__metac_chain' . $ctx->{tmp_counter}++;
        my $first_stmt = {
            kind => 'const_try_expr',
            name => $tmp,
            expr => $stmt->{first},
        };
        compile_block([ $first_stmt ], $ctx, $out, $indent, $current_fn_return);

        my $tail_expr = parse_expr("$tmp.$stmt->{tail_raw}");
        my $final_stmt = {
            kind => 'const',
            name => $stmt->{name},
            expr => $tail_expr,
        };
        compile_block([ $final_stmt ], $ctx, $out, $indent, $current_fn_return);
        return 1;
    }

    if ($stmt->{kind} eq 'const_split_try') {
        my ($src_code, $src_type) = compile_expr($stmt->{source_expr}, $ctx);
        my ($delim_code, $delim_type) = compile_expr($stmt->{delim_expr}, $ctx);
        compile_error("split source must be string") if $src_type ne 'string';
        compile_error("split delimiter must be string") if $delim_type ne 'string';

        my $tmp = '__metac_split' . $ctx->{tmp_counter}++;
        emit_line($out, $indent, "ResultStringList $tmp = metac_split_string($src_code, $delim_code);");
        emit_line($out, $indent, "if ($tmp.is_error) {");
        _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "StringList $stmt->{name} = $tmp.value;");

        declare_var(
            $ctx,
            $stmt->{name},
            {
                type      => 'string_list',
                immutable => 1,
                c_name    => $stmt->{name},
            }
        );
        return 1;
    }

    if ($stmt->{kind} eq 'const_try_expr') {
        my $expr = $stmt->{expr};

        if ($expr->{kind} eq 'call') {
            my $functions = $ctx->{functions} // {};
            my $sig = $functions->{ $expr->{name} };
            if (defined($sig) && union_contains_member($sig->{return_type}, 'error')) {
                my $expected = scalar @{ $sig->{params} };
                my $actual = scalar @{ $expr->{args} };
                compile_error("Function '$expr->{name}' expects $expected args, got $actual")
                  if $expected != $actual;

                my @arg_code;
                for (my $i = 0; $i < $expected; $i++) {
                    my ($arg_c, $arg_t) = compile_expr($expr->{args}[$i], $ctx);
                    my $param_t = $sig->{params}[$i]{type};
                    if ($param_t eq 'number') {
                        push @arg_code, number_like_to_c_expr($arg_c, $arg_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
                        next;
                    }
                    if ($param_t eq 'number_or_null') {
                        push @arg_code, number_or_null_to_c_expr($arg_c, $arg_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
                        next;
                    }
                    if (is_supported_generic_union_return($param_t)) {
                        push @arg_code, generic_union_to_c_expr($arg_c, $arg_t, $param_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
                        next;
                    }
                    compile_error("Arg " . ($i + 1) . " to '$expr->{name}' must be $param_t, got $arg_t")
                      if $arg_t ne $param_t;
                    push @arg_code, $arg_c;
                }

                my $return_type = $sig->{return_type};
                my $non_error_type = type_without_union_member($return_type, 'error');
                my $tmp = '__metac_try_call' . $ctx->{tmp_counter}++;

                if (type_is_number_or_error($return_type)) {
                    emit_line($out, $indent, "ResultNumber $tmp = $expr->{name}(" . join(', ', @arg_code) . ");");
                    emit_line($out, $indent, "if ($tmp.is_error) {");
                    _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                    emit_line($out, $indent, "}");
                    emit_line($out, $indent, "const int64_t $stmt->{name} = $tmp.value;");
                } elsif (type_is_bool_or_error($return_type)) {
                    emit_line($out, $indent, "ResultBool $tmp = $expr->{name}(" . join(', ', @arg_code) . ");");
                    emit_line($out, $indent, "if ($tmp.is_error) {");
                    _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                    emit_line($out, $indent, "}");
                    emit_line($out, $indent, "const int $stmt->{name} = $tmp.value;");
                } elsif (type_is_string_or_error($return_type)) {
                    emit_line($out, $indent, "ResultStringValue $tmp = $expr->{name}(" . join(', ', @arg_code) . ");");
                    emit_line($out, $indent, "if ($tmp.is_error) {");
                    _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                    emit_line($out, $indent, "}");
                    emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                    emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $tmp.value);");
                } elsif (is_supported_generic_union_return($return_type)) {
                    emit_line($out, $indent, "MetaCValue $tmp = $expr->{name}(" . join(', ', @arg_code) . ");");
                    emit_line($out, $indent, "if ($tmp.kind == METAC_VALUE_ERROR) {");
                    _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.error_message");
                    emit_line($out, $indent, "}");
                    if ($non_error_type eq 'number') {
                        emit_line($out, $indent, "const int64_t $stmt->{name} = $tmp.number_value;");
                    } elsif ($non_error_type eq 'bool') {
                        emit_line($out, $indent, "const int $stmt->{name} = $tmp.bool_value;");
                    } elsif ($non_error_type eq 'string') {
                        emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                        emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $tmp.string_value);");
                    } elsif (is_supported_generic_union_return($non_error_type)) {
                        emit_line($out, $indent, "const MetaCValue $stmt->{name} = $tmp;");
                    } else {
                        compile_error("Unsupported non-error try result type '$non_error_type' from '$expr->{name}'");
                    }
                } else {
                    compile_error("Unsupported fallible return type '$return_type' for '$expr->{name}'");
                }

                declare_var(
                    $ctx,
                    $stmt->{name},
                    {
                        type      => $non_error_type,
                        immutable => 1,
                        c_name    => $stmt->{name},
                    }
                );
                return 1;
            }
        }

        if ($expr->{kind} eq 'call' && $expr->{name} eq 'split') {
            my $actual = scalar @{ $expr->{args} };
            compile_error("split(...) with '?' expects exactly 2 args")
              if $actual != 2;

            my ($src_code, $src_type) = compile_expr($expr->{args}[0], $ctx);
            my ($delim_code, $delim_type) = compile_expr($expr->{args}[1], $ctx);
            compile_error("split source must be string") if $src_type ne 'string';
            compile_error("split delimiter must be string") if $delim_type ne 'string';

            my $tmp = '__metac_split' . $ctx->{tmp_counter}++;
            emit_line($out, $indent, "ResultStringList $tmp = metac_split_string($src_code, $delim_code);");
            emit_line($out, $indent, "if ($tmp.is_error) {");
            _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
            emit_line($out, $indent, "}");
            emit_line($out, $indent, "StringList $stmt->{name} = $tmp.value;");

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => 'string_list',
                    immutable => 1,
                    c_name    => $stmt->{name},
                }
            );
            return 1;
        }

        if ($expr->{kind} eq 'call' && $expr->{name} eq 'parseNumber') {
            my $actual = scalar @{ $expr->{args} };
            compile_error("parseNumber(...) with '?' expects exactly 1 arg")
              if $actual != 1;
            my ($src_code, $src_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("parseNumber(...) expects string arg")
              if $src_type ne 'string';

            my $tmp = '__metac_num' . $ctx->{tmp_counter}++;
            emit_line($out, $indent, "int64_t $tmp = 0;");
            emit_line($out, $indent, "if (!metac_parse_int($src_code, &$tmp)) {");
            _emit_try_failure($out, $indent + 2, $current_fn_return, "metac_fmt(\"Invalid number: %s\", $src_code)");
            emit_line($out, $indent, "}");
            emit_line($out, $indent, "const int64_t $stmt->{name} = $tmp;");

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => 'number',
                    immutable => 1,
                    c_name    => $stmt->{name},
                }
            );
            return 1;
        }

        if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'map') {
            emit_map_assignment(
                name             => $stmt->{name},
                expr             => $expr,
                ctx              => $ctx,
                out              => $out,
                indent           => $indent,
                propagate_errors => 1,
            );
            return 1;
        }

        if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'filter') {
            emit_filter_assignment(
                name             => $stmt->{name},
                expr             => $expr,
                ctx              => $ctx,
                out              => $out,
                indent           => $indent,
                propagate_errors => 1,
            );
            return 1;
        }

        if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'insert') {
            my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
            compile_error("insert(...)? receiver must be matrix(...), got $recv_type")
              if !is_matrix_type($recv_type);
            my $meta = matrix_type_meta($recv_type);

            my $actual = scalar @{ $expr->{args} };
            compile_error("insert(...)? expects exactly 2 args: insert(value, coords)")
              if $actual != 2;
            my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
            my ($coord_code, $coord_type) = compile_expr($expr->{args}[1], $ctx);
            compile_error("insert(...)? coordinates must be number[]")
              if $coord_type ne 'number_list';

            my $tmp = '__metac_matrix_insert' . $ctx->{tmp_counter}++;
            if ($meta->{elem} eq 'number') {
                my $value_num = number_like_to_c_expr($value_code, $value_type, "insert(...)?");
                emit_line($out, $indent, "ResultMatrixNumber $tmp = metac_matrix_number_insert_try($recv_code, $value_num, $coord_code);");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "MatrixNumber $stmt->{name} = $tmp.value;");
            } elsif ($meta->{elem} eq 'string') {
                compile_error("insert(...)? value must be string for matrix(string), got $value_type")
                  if $value_type ne 'string';
                emit_line($out, $indent, "ResultMatrixString $tmp = metac_matrix_string_insert_try($recv_code, $value_code, $coord_code);");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                _emit_try_failure($out, $indent + 2, $current_fn_return, "$tmp.message");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "MatrixString $stmt->{name} = $tmp.value;");
            } else {
                compile_error("insert(...)? is unsupported for matrix element type '$meta->{elem}'");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => $recv_type,
                    immutable => 1,
                    c_name    => $stmt->{name},
                }
            );
            return 1;
        }

        if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'assert') {
            my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
            compile_error("assert(...) receiver must be string_list or number_list, got $recv_type")
              if $recv_type ne 'string_list' && $recv_type ne 'number_list';

            my $actual = scalar @{ $expr->{args} };
            compile_error("assert(...) expects exactly 2 args: assert(x => <predicate>, message)")
              if $actual != 2;

            my $predicate = $expr->{args}[0];
            compile_error("assert(...) first arg must be a single-parameter lambda predicate, e.g. x => x.size() == 2")
              if $predicate->{kind} ne 'lambda1';

            my ($msg_code, $msg_type) = compile_expr($expr->{args}[1], $ctx);
            compile_error("assert(...) second arg must be string")
              if $msg_type ne 'string';

            my $tmp = '__metac_assert_list' . $ctx->{tmp_counter}++;
            my $lambda_param = $predicate->{param};
            my $pred_code;
            my $pred_type;
            if ($recv_type eq 'string_list') {
                emit_line($out, $indent, "StringList $tmp = $recv_code;");
            } else {
                emit_line($out, $indent, "NumberList $tmp = $recv_code;");
            }

            new_scope($ctx);
            declare_var(
                $ctx,
                $lambda_param,
                {
                    type      => $recv_type,
                    immutable => 1,
                    c_name    => $tmp,
                }
            );
            ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
            pop_scope($ctx);
            compile_error("assert(...) predicate must evaluate to bool")
              if $pred_type ne 'bool';

            emit_line($out, $indent, "if (!($pred_code)) {");
            _emit_try_failure($out, $indent + 2, $current_fn_return, $msg_code);
            emit_line($out, $indent, "}");
            if ($recv_type eq 'string_list') {
                emit_line($out, $indent, "StringList $stmt->{name} = $tmp;");
            } else {
                emit_line($out, $indent, "NumberList $stmt->{name} = $tmp;");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => $recv_type,
                    immutable => 1,
                    c_name    => $stmt->{name},
                }
            );
            my $asserted_len = lambda_size_eq_fact($predicate);
            if (defined $asserted_len) {
                my $new_key = expr_fact_key({ kind => 'ident', name => $stmt->{name} }, $ctx);
                set_list_len_fact($ctx, $new_key, $asserted_len);
            }
            return 1;
        }

        compile_error("Unsupported try expression in const assignment");
    }

    if ($stmt->{kind} eq 'const_or_catch') {
        my $expr = $stmt->{expr};
        compile_error("or catch assignment currently supports fallible function calls")
          if $expr->{kind} ne 'call';

        my $functions = $ctx->{functions} // {};
        my $sig = $functions->{ $expr->{name} };
        compile_error("or catch requires fallible user function call, got '$expr->{name}'")
          if !defined($sig) || !union_contains_member($sig->{return_type}, 'error');

        my $arg_code = _compile_call_args_for_sig($expr, $sig, $ctx);
        my $return_type = $sig->{return_type};
        my $non_error_type = type_without_union_member($return_type, 'error');
        my $tmp = '__metac_or_call' . $ctx->{tmp_counter}++;

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
            emit_line($out, $indent, "const int64_t $stmt->{name} = $tmp.value;");
        } elsif (type_is_bool_or_error($return_type)) {
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
            emit_line($out, $indent, "const int $stmt->{name} = $tmp.value;");
        } elsif (type_is_string_or_error($return_type)) {
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
            emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
            emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $tmp.value);");
        } elsif (is_supported_generic_union_return($return_type)) {
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
            if ($non_error_type eq 'number') {
                emit_line($out, $indent, "const int64_t $stmt->{name} = $tmp.number_value;");
            } elsif ($non_error_type eq 'bool') {
                emit_line($out, $indent, "const int $stmt->{name} = $tmp.bool_value;");
            } elsif ($non_error_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $tmp.string_value);");
            } elsif (is_supported_generic_union_return($non_error_type)) {
                emit_line($out, $indent, "const MetaCValue $stmt->{name} = $tmp;");
            } else {
                compile_error("Unsupported non-error or-catch result type '$non_error_type' from '$expr->{name}'");
            }
        } else {
            compile_error("Unsupported fallible return type '$return_type' for '$expr->{name}'");
        }

        declare_var(
            $ctx,
            $stmt->{name},
            {
                type      => $non_error_type,
                immutable => 1,
                c_name    => $stmt->{name},
            }
        );
        return 1;
    }
}

1;
