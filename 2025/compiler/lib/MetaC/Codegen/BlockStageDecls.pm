package MetaC::Codegen;
use strict;
use warnings;

sub _compile_block_stage_decls {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'let') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            my $decl_type = defined($stmt->{type}) ? $stmt->{type} : $expr_type;
            if (!defined($stmt->{type}) && $expr_type eq 'empty_list') {
                compile_error("Empty list literal requires an explicit list type, e.g. let xs: number[] = []");
            }
            if (defined $stmt->{type}) {
                compile_error("Type mismatch in let '$stmt->{name}': expected $stmt->{type}, got $expr_type")
                  if !type_matches_expected($stmt->{type}, $expr_type);
            }

            my $constraints = $stmt->{constraints} // parse_constraints(undef);
            if (($constraints->{positive} || $constraints->{negative} || defined $constraints->{range} || $constraints->{wrap}) && $decl_type ne 'number') {
                compile_error("Numeric constraints require number type for variable '$stmt->{name}'");
            }

            if ($decl_type eq 'number') {
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if (defined $constraints->{range} && !$constraints->{wrap}) {
                        compile_error("range($constraints->{range}{min},$constraints->{range}{max}) variable '$stmt->{name}' initialized out of range")
                          if $v < $constraints->{range}{min} || $v > $constraints->{range}{max};
                    }
                    compile_error("Variable '$stmt->{name}' requires positive value")
                      if $constraints->{positive} && $v <= 0;
                    compile_error("Variable '$stmt->{name}' requires negative value")
                      if $constraints->{negative} && $v >= 0;
                }

                my $init_expr = number_like_to_c_expr($expr_code, $expr_type, "let '$stmt->{name}'");
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $init_expr = "metac_wrap_range($init_expr, $constraints->{range}{min}, $constraints->{range}{max})";
                }
                emit_line($out, $indent, "int64_t $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'number_or_null') {
                my $init_expr = number_or_null_to_c_expr($expr_code, $expr_type, "let '$stmt->{name}'");
                emit_line($out, $indent, "NullableNumber $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'indexed_number') {
                emit_line($out, $indent, "IndexedNumber $stmt->{name} = $expr_code;");
            } elsif ($decl_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($decl_type eq 'bool') {
                emit_line($out, $indent, "int $stmt->{name} = $expr_code;");
            } elsif ($decl_type eq 'number_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "NumberList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "NumberList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "StringList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "StringList $stmt->{name} = $expr_code;");
                }
            } elsif (is_matrix_type($decl_type)) {
                my $meta = matrix_type_meta($decl_type);
                compile_error("matrix variables are currently supported only for matrix(number)")
                  if $meta->{elem} ne 'number';
                if ($expr_type eq 'empty_list') {
                    my $size_expr = '((NumberList){0, NULL})';
                    if ($meta->{has_size}) {
                        $size_expr = "metac_number_list_from_array((int64_t[]){ " . join(', ', @{ $meta->{sizes} }) . " }, " . scalar(@{ $meta->{sizes} }) . ")";
                    }
                    emit_line($out, $indent, "MatrixNumber $stmt->{name} = metac_matrix_number_new($meta->{dim}, $size_expr);");
                } else {
                    compile_error("Type mismatch in let '$stmt->{name}': expected $decl_type, got $expr_type")
                      if $expr_type ne $decl_type;
                    emit_line($out, $indent, "MatrixNumber $stmt->{name} = $expr_code;");
                }
            } elsif (is_matrix_member_list_type($decl_type)) {
                emit_line($out, $indent, "MatrixNumberMemberList $stmt->{name} = $expr_code;");
            } elsif (is_matrix_member_type($decl_type)) {
                emit_line($out, $indent, "MatrixNumberMember $stmt->{name} = $expr_code;");
            } else {
                compile_error("Unsupported let type: $decl_type");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type        => $decl_type,
                    constraints => $constraints,
                    immutable   => 0,
                }
            );

            if ($decl_type eq 'number_or_null') {
                if ($expr_type eq 'null') {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } elsif (is_number_like_type($expr_type)) {
                    set_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } else {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                }
            }
            return 1;
        }

        if ($stmt->{kind} eq 'const') {
            if ($stmt->{expr}{kind} eq 'method_call' && $stmt->{expr}{method} eq 'map') {
                emit_map_assignment(
                    name             => $stmt->{name},
                    expr             => $stmt->{expr},
                    ctx              => $ctx,
                    out              => $out,
                    indent           => $indent,
                    propagate_errors => 0,
                );
                return 1;
            }
            if ($stmt->{expr}{kind} eq 'method_call' && $stmt->{expr}{method} eq 'filter') {
                emit_filter_assignment(
                    name             => $stmt->{name},
                    expr             => $stmt->{expr},
                    ctx              => $ctx,
                    out              => $out,
                    indent           => $indent,
                    propagate_errors => 0,
                );
                return 1;
            }

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($expr_type eq 'number') {
                emit_line($out, $indent, "const int64_t $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'number_or_null') {
                emit_line($out, $indent, "const NullableNumber $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'indexed_number') {
                emit_line($out, $indent, "const IndexedNumber $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'bool') {
                emit_line($out, $indent, "const int $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($expr_type eq 'string_list') {
                emit_line($out, $indent, "StringList $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'number_list') {
                emit_line($out, $indent, "NumberList $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'indexed_number_list') {
                emit_line($out, $indent, "IndexedNumberList $stmt->{name} = $expr_code;");
            } elsif (is_matrix_type($expr_type)) {
                emit_line($out, $indent, "MatrixNumber $stmt->{name} = $expr_code;");
            } elsif (is_matrix_member_list_type($expr_type)) {
                emit_line($out, $indent, "MatrixNumberMemberList $stmt->{name} = $expr_code;");
            } elsif (is_matrix_member_type($expr_type)) {
                emit_line($out, $indent, "MatrixNumberMember $stmt->{name} = $expr_code;");
            } else {
                compile_error("Unsupported const expression type for '$stmt->{name}': $expr_type");
            }

            my %const_info = (
                type      => $expr_type,
                immutable => 1,
            );
            if ($expr_type eq 'number'
                && $stmt->{expr}{kind} eq 'method_call'
                && $stmt->{expr}{method} eq 'size'
                && scalar(@{ $stmt->{expr}{args} }) == 0)
            {
                my ($size_recv_code, $size_recv_type) = compile_expr($stmt->{expr}{recv}, $ctx);
                if ($size_recv_type eq 'string' || $size_recv_type eq 'string_list' || $size_recv_type eq 'number_list' || $size_recv_type eq 'indexed_number_list') {
                    $const_info{size_of_recv_code} = $size_recv_code;
                    $const_info{size_of_recv_type} = $size_recv_type;
                }
            }

            declare_var(
                $ctx,
                $stmt->{name},
                \%const_info
            );
            return 1;
        }

        if ($stmt->{kind} eq 'const_try_tail_expr') {
            compile_error("try expression with '?.' is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

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
            compile_error("split(...)? is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

            my ($src_code, $src_type) = compile_expr($stmt->{source_expr}, $ctx);
            my ($delim_code, $delim_type) = compile_expr($stmt->{delim_expr}, $ctx);
            compile_error("split source must be string") if $src_type ne 'string';
            compile_error("split delimiter must be string") if $delim_type ne 'string';

            my $tmp = '__metac_split' . $ctx->{tmp_counter}++;
            emit_line($out, $indent, "ResultStringList $tmp = metac_split_string($src_code, $delim_code);");
            emit_line($out, $indent, "if ($tmp.is_error) {");
            emit_line($out, $indent + 2, "return err_number($tmp.message, __metac_line_no, \"\");");
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
            compile_error("try expression with '?' is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

            my $expr = $stmt->{expr};

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
                emit_line($out, $indent + 2, "return err_number($tmp.message, __metac_line_no, \"\");");
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
                emit_line($out, $indent + 2, "return err_number(\"Invalid number\", __metac_line_no, $src_code);");
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
                compile_error("insert(...)? receiver must be matrix(number), got $recv_type")
                  if !is_matrix_type($recv_type);
                my $meta = matrix_type_meta($recv_type);
                compile_error("insert(...)? is currently supported only for matrix(number)")
                  if $meta->{elem} ne 'number';

                my $actual = scalar @{ $expr->{args} };
                compile_error("insert(...)? expects exactly 2 args: insert(value, coords)")
                  if $actual != 2;
                my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
                my $value_num = number_like_to_c_expr($value_code, $value_type, "insert(...)?");
                my ($coord_code, $coord_type) = compile_expr($expr->{args}[1], $ctx);
                compile_error("insert(...)? coordinates must be number[]")
                  if $coord_type ne 'number_list';

                my $tmp = '__metac_matrix_insert' . $ctx->{tmp_counter}++;
                emit_line($out, $indent, "ResultMatrixNumber $tmp = metac_matrix_number_insert_try($recv_code, $value_num, $coord_code);");
                emit_line($out, $indent, "if ($tmp.is_error) {");
                emit_line($out, $indent + 2, "return err_number($tmp.message, __metac_line_no, \"\");");
                emit_line($out, $indent, "}");
                emit_line($out, $indent, "MatrixNumber $stmt->{name} = $tmp.value;");

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
                emit_line($out, $indent + 2, "return err_number($msg_code, __metac_line_no, \"\");");
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

    return 0;
}

1;
