package MetaC::Codegen;
use strict;
use warnings;

sub _emit_try_failure {
    my ($ctx, $out, $indent, $current_fn_return, $message_expr) = @_;
    if (defined $ctx->{active_temp_cleanups}) {
        for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
            emit_line($out, $indent, $ctx->{active_temp_cleanups}[$i] . ';');
        }
    }
    emit_all_owned_cleanups($ctx, $out, $indent);
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

sub _infer_number_list_list_item_len_proof_from_expr {
    my ($expr, $ctx) = @_;
    return undef if !defined $expr;

    if (($expr->{kind} // '') eq 'ident') {
        my $src = lookup_var($ctx, $expr->{name});
        return undef if !defined($src) || !defined($src->{item_len_proof});
        return int($src->{item_len_proof});
    }
    if (($expr->{kind} // '') eq 'method_call' && ($expr->{method} // '') eq 'sortBy') {
        return _infer_number_list_list_item_len_proof_from_expr($expr->{recv}, $ctx);
    }
    return undef;
}

sub _compile_block_stage_decls {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'let') {
            my ($expr_code, $expr_type, $expr_prelude, $expr_temp_cleanups) = compile_expr_with_temp_scope(
                ctx                     => $ctx,
                expr                    => $stmt->{expr},
                transfer_root_ownership => 1,
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_temp_cleanups);
            my $decl_type = defined($stmt->{type}) ? $stmt->{type} : $expr_type;
            if (!defined($stmt->{type}) && $expr_type eq 'empty_list') {
                compile_error("Empty list literal requires an explicit list type, e.g. let xs: number[] = []");
            }
            if (defined $stmt->{type}) {
                compile_error("Type mismatch in let '$stmt->{name}': expected $stmt->{type}, got $expr_type")
                  if !type_matches_expected($stmt->{type}, $expr_type);
            }

            my $constraints = $stmt->{constraints} // parse_constraints(undef);
            if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $decl_type ne 'number') {
                compile_error("Numeric constraints require number type for variable '$stmt->{name}'");
            }

            if ($decl_type eq 'number') {
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                my $has_wrap = constraints_has_kind($constraints, 'wrap');
                my $needs_positive = constraints_has_kind($constraints, 'positive');
                my $needs_negative = constraints_has_kind($constraints, 'negative');
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if ((defined($range_min) || defined($range_max)) && !$has_wrap) {
                        my $range_text = "range(" . (defined($range_min) ? $range_min : '*') . "," . (defined($range_max) ? $range_max : '*') . ")";
                        compile_error("$range_text variable '$stmt->{name}' initialized out of range")
                          if (defined($range_min) && $v < $range_min) || (defined($range_max) && $v > $range_max);
                    }
                    compile_error("Variable '$stmt->{name}' requires positive value")
                      if $needs_positive && $v <= 0;
                    compile_error("Variable '$stmt->{name}' requires negative value")
                      if $needs_negative && $v >= 0;
                }

                my $init_expr = number_like_to_c_expr($expr_code, $expr_type, "let '$stmt->{name}'");
                if ($has_wrap) {
                    $init_expr = "metac_wrap_range($init_expr, $range_min, $range_max)";
                }
                emit_line($out, $indent, "int64_t $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'number_or_null') {
                my $init_expr = number_or_null_to_c_expr($expr_code, $expr_type, "let '$stmt->{name}'");
                emit_line($out, $indent, "NullableNumber $stmt->{name} = $init_expr;");
            } elsif (is_supported_generic_union_return($decl_type)) {
                my $init_expr = generic_union_to_c_expr($expr_code, $expr_type, $decl_type, "let '$stmt->{name}'");
                emit_line($out, $indent, "MetaCValue $stmt->{name} = $init_expr;");
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
            } elsif ($decl_type eq 'number_list_list') {
                if (defined $constraints->{nested_number_list_size} && $expr_type ne 'empty_list') {
                    compile_error("variable '$stmt->{name}' cannot prove nested element size($constraints->{nested_number_list_size}) from initializer; initialize with [] and push proven elements");
                }
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "NumberListList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "NumberListList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "StringList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "StringList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'bool_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "BoolList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "BoolList $stmt->{name} = $expr_code;");
                }
            } elsif (is_array_type($decl_type)) {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "AnyList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "AnyList $stmt->{name} = $expr_code;");
                }
            } elsif (is_matrix_type($decl_type)) {
                my $meta = matrix_type_meta($decl_type);
                if ($expr_type eq 'empty_list') {
                    my $size_expr = '((NumberList){0, NULL})';
                    if ($meta->{has_size}) {
                        $size_expr = "metac_number_list_from_array((int64_t[]){ " . join(', ', @{ $meta->{sizes} }) . " }, " . scalar(@{ $meta->{sizes} }) . ")";
                    }
                    if ($meta->{elem} eq 'number') {
                        emit_line($out, $indent, "MatrixNumber $stmt->{name} = metac_matrix_number_new($meta->{dim}, $size_expr);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_number(&$stmt->{name})");
                    } elsif ($meta->{elem} eq 'string') {
                        emit_line($out, $indent, "MatrixString $stmt->{name} = metac_matrix_string_new($meta->{dim}, $size_expr);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_string(&$stmt->{name})");
                    } else {
                        emit_line($out, $indent, "MatrixOpaque $stmt->{name} = metac_matrix_opaque_new($meta->{dim}, NULL);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_opaque(&$stmt->{name})");
                    }
                } else {
                    compile_error("Type mismatch in let '$stmt->{name}': expected $decl_type, got $expr_type")
                      if $expr_type ne $decl_type;
                    if ($meta->{elem} eq 'number') {
                        emit_line($out, $indent, "MatrixNumber $stmt->{name} = $expr_code;");
                    } elsif ($meta->{elem} eq 'string') {
                        emit_line($out, $indent, "MatrixString $stmt->{name} = $expr_code;");
                    } else {
                        emit_line($out, $indent, "MatrixOpaque $stmt->{name} = $expr_code;");
                    }
                }
            } elsif (is_matrix_member_list_type($decl_type)) {
                my $meta = matrix_member_list_meta($decl_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMemberList $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMemberList $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member list type: $decl_type");
                }
            } elsif (is_matrix_member_type($decl_type)) {
                my $meta = matrix_member_meta($decl_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMember $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMember $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member type: $decl_type");
                }
            } else {
                compile_error("Unsupported let type: $decl_type");
            }

            my %decl_info = (
                type        => $decl_type,
                constraints => $constraints,
                immutable   => 0,
            );
            if ($decl_type eq 'number_list_list' && defined $constraints->{nested_number_list_size}) {
                $decl_info{item_len_proof} = int($constraints->{nested_number_list_size});
            } elsif ($decl_type eq 'number_list_list') {
                my $proof = _infer_number_list_list_item_len_proof_from_expr($stmt->{expr}, $ctx);
                $decl_info{item_len_proof} = $proof if defined $proof;
            }
            declare_var($ctx, $stmt->{name}, \%decl_info);
            maybe_register_owned_cleanup_for_decl(
                ctx       => $ctx,
                var_name  => $stmt->{name},
                decl_type => $decl_type,
                expr_code => $expr_code,
            );
            if (is_supported_generic_union_return($decl_type)) {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_value(&$stmt->{name})");
            }
            if (is_array_type($decl_type)) {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_any_list($stmt->{name})");
            }
            if ($decl_type eq 'number_list_list' && $expr_type eq 'empty_list') {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_number_list_list($stmt->{name})");
            }
            emit_size_constraint_check(
                ctx         => $ctx,
                constraints => $constraints,
                target_expr => $stmt->{name},
                target_type => $decl_type,
                out         => $out,
                indent      => $indent,
                where       => "variable '$stmt->{name}'",
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
            emit_expr_temp_cleanups($out, $indent, $expr_temp_cleanups);
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
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

            my ($expr_code, $expr_type, $expr_prelude, $expr_temp_cleanups) = compile_expr_with_temp_scope(
                ctx                     => $ctx,
                expr                    => $stmt->{expr},
                transfer_root_ownership => 1,
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_temp_cleanups);

            if ($expr_type eq 'number') {
                emit_line($out, $indent, "const int64_t $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'number_or_null') {
                emit_line($out, $indent, "const NullableNumber $stmt->{name} = $expr_code;");
            } elsif (is_supported_generic_union_return($expr_type)) {
                emit_line($out, $indent, "const MetaCValue $stmt->{name} = $expr_code;");
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
            } elsif ($expr_type eq 'number_list_list') {
                emit_line($out, $indent, "NumberListList $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'bool_list') {
                emit_line($out, $indent, "BoolList $stmt->{name} = $expr_code;");
            } elsif (is_array_type($expr_type)) {
                emit_line($out, $indent, "AnyList $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'indexed_number_list') {
                emit_line($out, $indent, "IndexedNumberList $stmt->{name} = $expr_code;");
            } elsif (is_matrix_type($expr_type)) {
                my $meta = matrix_type_meta($expr_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumber $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixString $stmt->{name} = $expr_code;");
                } else {
                    emit_line($out, $indent, "MatrixOpaque $stmt->{name} = $expr_code;");
                }
            } elsif (is_matrix_member_list_type($expr_type)) {
                my $meta = matrix_member_list_meta($expr_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMemberList $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMemberList $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member list expression type: $expr_type");
                }
            } elsif (is_matrix_member_type($expr_type)) {
                my $meta = matrix_member_meta($expr_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMember $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMember $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member expression type: $expr_type");
                }
            } else {
                compile_error("Unsupported const expression type for '$stmt->{name}': $expr_type");
            }

            my %const_info = (
                type      => $expr_type,
                immutable => 1,
            );
            if ($expr_type eq 'number'
                && $stmt->{expr}{kind} eq 'method_call'
                && ($stmt->{expr}{method} eq 'size' || $stmt->{expr}{method} eq 'count')
                && scalar(@{ $stmt->{expr}{args} }) == 0)
            {
                my ($size_recv_code, $size_recv_type) = compile_expr($stmt->{expr}{recv}, $ctx);
                if ($size_recv_type eq 'string' || $size_recv_type eq 'string_list' || $size_recv_type eq 'number_list' || $size_recv_type eq 'number_list_list' || $size_recv_type eq 'bool_list' || $size_recv_type eq 'indexed_number_list') {
                    $const_info{size_of_recv_code} = $size_recv_code;
                    $const_info{size_of_recv_type} = $size_recv_type;
                }
            }
            if ($expr_type eq 'number_list_list') {
                my $proof = _infer_number_list_list_item_len_proof_from_expr($stmt->{expr}, $ctx);
                $const_info{item_len_proof} = $proof if defined $proof;
            }

            declare_var(
                $ctx,
                $stmt->{name},
                \%const_info
            );
            maybe_register_owned_cleanup_for_decl(
                ctx       => $ctx,
                var_name  => $stmt->{name},
                decl_type => $expr_type,
                expr_code => $expr_code,
            );
            emit_expr_temp_cleanups($out, $indent, $expr_temp_cleanups);
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
            return 1;
        }

        if ($stmt->{kind} eq 'const_typed') {
            my ($expr_code, $expr_type, $expr_prelude, $expr_temp_cleanups) = compile_expr_with_temp_scope(
                ctx                     => $ctx,
                expr                    => $stmt->{expr},
                transfer_root_ownership => 1,
            );
            emit_expr_temp_prelude($out, $indent, $expr_prelude);
            my $expr_cleanup_count = push_active_temp_cleanups($ctx, $expr_temp_cleanups);
            my $decl_type = $stmt->{type};
            compile_error("Type mismatch in const '$stmt->{name}': expected $decl_type, got $expr_type")
              if !type_matches_expected($decl_type, $expr_type);

            my $constraints = $stmt->{constraints} // parse_constraints(undef);
            if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $decl_type ne 'number') {
                compile_error("Numeric constraints require number type for constant '$stmt->{name}'");
            }

            if ($decl_type eq 'number') {
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                my $has_wrap = constraints_has_kind($constraints, 'wrap');
                my $needs_positive = constraints_has_kind($constraints, 'positive');
                my $needs_negative = constraints_has_kind($constraints, 'negative');
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if ((defined($range_min) || defined($range_max)) && !$has_wrap) {
                        my $range_text = "range(" . (defined($range_min) ? $range_min : '*') . "," . (defined($range_max) ? $range_max : '*') . ")";
                        compile_error("$range_text constant '$stmt->{name}' initialized out of range")
                          if (defined($range_min) && $v < $range_min) || (defined($range_max) && $v > $range_max);
                    }
                    compile_error("Constant '$stmt->{name}' requires positive value")
                      if $needs_positive && $v <= 0;
                    compile_error("Constant '$stmt->{name}' requires negative value")
                      if $needs_negative && $v >= 0;
                }

                my $init_expr = number_like_to_c_expr($expr_code, $expr_type, "const '$stmt->{name}'");
                if ($has_wrap) {
                    $init_expr = "metac_wrap_range($init_expr, $range_min, $range_max)";
                }
                emit_line($out, $indent, "const int64_t $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'number_or_null') {
                my $init_expr = number_or_null_to_c_expr($expr_code, $expr_type, "const '$stmt->{name}'");
                emit_line($out, $indent, "const NullableNumber $stmt->{name} = $init_expr;");
            } elsif (is_supported_generic_union_return($decl_type)) {
                my $init_expr = generic_union_to_c_expr($expr_code, $expr_type, $decl_type, "const '$stmt->{name}'");
                emit_line($out, $indent, "const MetaCValue $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'indexed_number') {
                emit_line($out, $indent, "const IndexedNumber $stmt->{name} = $expr_code;");
            } elsif ($decl_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($decl_type eq 'bool') {
                emit_line($out, $indent, "const int $stmt->{name} = $expr_code;");
            } elsif ($decl_type eq 'number_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "NumberList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "NumberList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'number_list_list') {
                if (defined $constraints->{nested_number_list_size} && $expr_type ne 'empty_list') {
                    compile_error("constant '$stmt->{name}' cannot prove nested element size($constraints->{nested_number_list_size}) from initializer");
                }
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "NumberListList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "NumberListList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "StringList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "StringList $stmt->{name} = $expr_code;");
                }
            } elsif ($decl_type eq 'bool_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "BoolList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "BoolList $stmt->{name} = $expr_code;");
                }
            } elsif (is_array_type($decl_type)) {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "AnyList $stmt->{name};");
                    emit_line($out, $indent, "$stmt->{name}.count = 0;");
                    emit_line($out, $indent, "$stmt->{name}.items = NULL;");
                } else {
                    emit_line($out, $indent, "AnyList $stmt->{name} = $expr_code;");
                }
            } elsif (is_matrix_type($decl_type)) {
                my $meta = matrix_type_meta($decl_type);
                if ($expr_type eq 'empty_list') {
                    my $size_expr = '((NumberList){0, NULL})';
                    if ($meta->{has_size}) {
                        $size_expr = "metac_number_list_from_array((int64_t[]){ " . join(', ', @{ $meta->{sizes} }) . " }, " . scalar(@{ $meta->{sizes} }) . ")";
                    }
                    if ($meta->{elem} eq 'number') {
                        emit_line($out, $indent, "MatrixNumber $stmt->{name} = metac_matrix_number_new($meta->{dim}, $size_expr);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_number(&$stmt->{name})");
                    } elsif ($meta->{elem} eq 'string') {
                        emit_line($out, $indent, "MatrixString $stmt->{name} = metac_matrix_string_new($meta->{dim}, $size_expr);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_string(&$stmt->{name})");
                    } else {
                        emit_line($out, $indent, "MatrixOpaque $stmt->{name} = metac_matrix_opaque_new($meta->{dim}, NULL);");
                        register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_matrix_opaque(&$stmt->{name})");
                    }
                } else {
                    if ($meta->{elem} eq 'number') {
                        emit_line($out, $indent, "MatrixNumber $stmt->{name} = $expr_code;");
                    } elsif ($meta->{elem} eq 'string') {
                        emit_line($out, $indent, "MatrixString $stmt->{name} = $expr_code;");
                    } else {
                        emit_line($out, $indent, "MatrixOpaque $stmt->{name} = $expr_code;");
                    }
                }
            } elsif (is_matrix_member_list_type($decl_type)) {
                my $meta = matrix_member_list_meta($decl_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMemberList $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMemberList $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member list const type: $decl_type");
                }
            } elsif (is_matrix_member_type($decl_type)) {
                my $meta = matrix_member_meta($decl_type);
                if ($meta->{elem} eq 'number') {
                    emit_line($out, $indent, "MatrixNumberMember $stmt->{name} = $expr_code;");
                } elsif ($meta->{elem} eq 'string') {
                    emit_line($out, $indent, "MatrixStringMember $stmt->{name} = $expr_code;");
                } else {
                    compile_error("Unsupported matrix member const type: $decl_type");
                }
            } else {
                compile_error("Unsupported const type: $decl_type");
            }

            my %decl_info = (
                type        => $decl_type,
                constraints => $constraints,
                immutable   => 1,
            );
            if ($decl_type eq 'number_list_list' && defined $constraints->{nested_number_list_size}) {
                $decl_info{item_len_proof} = int($constraints->{nested_number_list_size});
            } elsif ($decl_type eq 'number_list_list') {
                my $proof = _infer_number_list_list_item_len_proof_from_expr($stmt->{expr}, $ctx);
                $decl_info{item_len_proof} = $proof if defined $proof;
            }
            declare_var($ctx, $stmt->{name}, \%decl_info);
            maybe_register_owned_cleanup_for_decl(
                ctx       => $ctx,
                var_name  => $stmt->{name},
                decl_type => $decl_type,
                expr_code => $expr_code,
            );
            if (is_supported_generic_union_return($decl_type)) {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_value(&$stmt->{name})");
            }
            if (is_array_type($decl_type)) {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_any_list($stmt->{name})");
            }
            if ($decl_type eq 'number_list_list' && $expr_type eq 'empty_list') {
                register_owned_cleanup_for_var($ctx, $stmt->{name}, "metac_free_number_list_list($stmt->{name})");
            }
            emit_size_constraint_check(
                ctx         => $ctx,
                constraints => $constraints,
                target_expr => $stmt->{name},
                target_type => $decl_type,
                out         => $out,
                indent      => $indent,
                where       => "constant '$stmt->{name}'",
            );
            emit_expr_temp_cleanups($out, $indent, $expr_temp_cleanups);
            pop_active_temp_cleanups($ctx, $expr_cleanup_count);
            return 1;
        }

        return 1 if _compile_block_stage_decls_try_ops($stmt, $ctx, $out, $indent, $current_fn_return);

    return 0;
}

1;
