package MetaC::Codegen;
use strict;
use warnings;

sub _compile_block_stage_assign_loops {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'let_producer') {
            compile_error("Producer for '$stmt->{name}' does not assign target on all recognized paths")
              if !producer_definitely_assigns($stmt->{body}, $stmt->{name});

            if ($stmt->{type} eq 'number') {
                emit_line($out, $indent, "int64_t $stmt->{name} = 0;");
            } elsif ($stmt->{type} eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "$stmt->{name}[0] = '\\0';");
            } else {
                compile_error("Unsupported producer variable type: $stmt->{type}");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type        => $stmt->{type},
                    immutable   => 0,
                    constraints => parse_constraints(undef),
                }
            );

            emit_line($out, $indent, '{');
            new_scope($ctx);
            compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');
            return 1;
        }

        if ($stmt->{kind} eq 'typed_assign') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Typed assignment to undeclared variable '$stmt->{name}'")
              if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'")
              if $info->{immutable};
            compile_error("Typed assignment type mismatch for '$stmt->{name}': expected $info->{type}, got $stmt->{type}")
              if $info->{type} ne $stmt->{type};

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Typed assignment expression mismatch for '$stmt->{name}': expected $stmt->{type}, got $expr_type")
              if !type_matches_expected($stmt->{type}, $expr_type);

            my $target = $info->{c_name};
            my $constraints = $stmt->{constraints} // parse_constraints(undef);
            if ($stmt->{type} eq 'number') {
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                my $has_wrap = constraints_has_kind($constraints, 'wrap');
                my $needs_positive = constraints_has_kind($constraints, 'positive');
                my $needs_negative = constraints_has_kind($constraints, 'negative');
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if ((defined($range_min) || defined($range_max)) && !$has_wrap) {
                        my $range_text = "range(" . (defined($range_min) ? $range_min : '*') . "," . (defined($range_max) ? $range_max : '*') . ")";
                        compile_error("typed assignment $range_text violation for '$stmt->{name}'")
                          if (defined($range_min) && $v < $range_min) || (defined($range_max) && $v > $range_max);
                    }
                    compile_error("Typed assignment for '$stmt->{name}' requires positive value")
                      if $needs_positive && $v <= 0;
                    compile_error("Typed assignment for '$stmt->{name}' requires negative value")
                      if $needs_negative && $v >= 0;
                }

                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "typed assignment for '$stmt->{name}'");
                if ($has_wrap) {
                    $rhs = "metac_wrap_range($rhs, $range_min, $range_max)";
                }
                emit_line($out, $indent, "$target = $rhs;");
            } elsif ($stmt->{type} eq 'number_or_null') {
                my $rhs = number_or_null_to_c_expr($expr_code, $expr_type, "typed assignment for '$stmt->{name}'");
                emit_line($out, $indent, "$target = $rhs;");
                if ($expr_type eq 'null') {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } elsif (is_number_like_type($expr_type)) {
                    set_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } else {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                }
            } elsif ($stmt->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
                emit_size_constraint_check(
                    constraints => $constraints,
                    target_expr => $target,
                    target_type => 'string',
                    out         => $out,
                    indent      => $indent,
                    where       => "typed assignment for '$stmt->{name}'",
                );
            } elsif ($stmt->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($stmt->{type} eq 'number_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
                emit_size_constraint_check(
                    constraints => $constraints,
                    target_expr => $target,
                    target_type => 'number_list',
                    out         => $out,
                    indent      => $indent,
                    where       => "typed assignment for '$stmt->{name}'",
                );
            } elsif ($stmt->{type} eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
                emit_size_constraint_check(
                    constraints => $constraints,
                    target_expr => $target,
                    target_type => 'string_list',
                    out         => $out,
                    indent      => $indent,
                    where       => "typed assignment for '$stmt->{name}'",
                );
            } elsif ($stmt->{type} eq 'bool_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
                emit_size_constraint_check(
                    constraints => $constraints,
                    target_expr => $target,
                    target_type => 'bool_list',
                    out         => $out,
                    indent      => $indent,
                    where       => "typed assignment for '$stmt->{name}'",
                );
            } elsif (is_matrix_type($stmt->{type}) || is_matrix_member_list_type($stmt->{type}) || is_matrix_member_type($stmt->{type})) {
                if ($expr_type eq 'empty_list') {
                    compile_error("Matrix reassignment from [] is not supported; initialize matrix variables in their declaration");
                }
                emit_line($out, $indent, "$target = $expr_code;");
            } else {
                compile_error("Unsupported typed assignment type: $stmt->{type}");
            }
            return 1;
        }

        if ($stmt->{kind} eq 'assign') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Assign to undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'") if $info->{immutable};
            my $target = $info->{c_name};

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Type mismatch in assignment to '$stmt->{name}': expected $info->{type}, got $expr_type")
              if !type_matches_expected($info->{type}, $expr_type);

            if ($info->{type} eq 'number') {
                my $constraints = $info->{constraints} // parse_constraints(undef);
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                my $has_wrap = constraints_has_kind($constraints, 'wrap');
                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "assignment to '$stmt->{name}'");
                if ($has_wrap) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($rhs, $range_min, $range_max);");
                } else {
                    emit_line($out, $indent, "$target = $rhs;");
                }
            } elsif ($info->{type} eq 'number_or_null') {
                my $rhs = number_or_null_to_c_expr($expr_code, $expr_type, "assignment to '$stmt->{name}'");
                emit_line($out, $indent, "$target = $rhs;");
                if ($expr_type eq 'null') {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } elsif (is_number_like_type($expr_type)) {
                    set_nonnull_fact_for_var_name($ctx, $stmt->{name});
                } else {
                    clear_nonnull_fact_for_var_name($ctx, $stmt->{name});
                }
            } elsif ($info->{type} eq 'indexed_number') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($info->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($info->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
                emit_size_constraint_check(
                    constraints => ($info->{constraints} // parse_constraints(undef)),
                    target_expr => $target,
                    target_type => 'string',
                    out         => $out,
                    indent      => $indent,
                    where       => "assignment to '$stmt->{name}'",
                );
            } elsif ($info->{type} eq 'number_list' || $info->{type} eq 'string_list' || $info->{type} eq 'bool_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
                emit_size_constraint_check(
                    constraints => ($info->{constraints} // parse_constraints(undef)),
                    target_expr => $target,
                    target_type => $info->{type},
                    out         => $out,
                    indent      => $indent,
                    where       => "assignment to '$stmt->{name}'",
                );
            } elsif (is_matrix_type($info->{type}) || is_matrix_member_list_type($info->{type}) || is_matrix_member_type($info->{type})) {
                if ($expr_type eq 'empty_list') {
                    compile_error("Matrix reassignment from [] is not supported; initialize matrix variables in their declaration");
                }
                emit_line($out, $indent, "$target = $expr_code;");
            } else {
                compile_error("Unsupported assignment target type for '$stmt->{name}': $info->{type}");
            }
            return 1;
        }

        if ($stmt->{kind} eq 'assign_op') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Assign to undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'") if $info->{immutable};
            my $target = $info->{c_name};

            if ($stmt->{op} eq '+=') {
                compile_error("'+=' requires numeric target '$stmt->{name}'")
                  if $info->{type} ne 'number';
                my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "'+=' for '$stmt->{name}'");

                my $combined = "($target + $rhs)";
                my $constraints = $info->{constraints} // parse_constraints(undef);
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                if (constraints_has_kind($constraints, 'wrap')) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($combined, $range_min, $range_max);");
                } else {
                    emit_line($out, $indent, "$target = $combined;");
                }
                return 1;
            }

            compile_error("Unsupported compound assignment operator: $stmt->{op}");
        }

        if ($stmt->{kind} eq 'incdec') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Inc/dec on undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot modify immutable variable '$stmt->{name}'") if $info->{immutable};
            compile_error("Inc/dec requires numeric variable '$stmt->{name}'")
              if $info->{type} ne 'number';

            my $target = $info->{c_name};
            my $constraints = $info->{constraints} // parse_constraints(undef);
            my $delta = $stmt->{op} eq '++' ? '1' : '-1';
            my $combined = "($target + $delta)";
            my ($range_min, $range_max) = constraint_range_bounds($constraints);
            if (constraints_has_kind($constraints, 'wrap')) {
                emit_line($out, $indent,
                    "$target = metac_wrap_range($combined, $range_min, $range_max);");
            } else {
                emit_line($out, $indent, "$target = $combined;");
            }
            return 1;
        }

        if ($stmt->{kind} eq 'for_lines') {
            emit_line($out, $indent, '{');
            emit_line($out, $indent + 2, 'char ' . $stmt->{var} . '[512];');
            emit_line($out, $indent + 2, "while (fgets($stmt->{var}, sizeof($stmt->{var}), stdin) != NULL) {");
            emit_line($out, $indent + 4, '__metac_line_no++;');

            new_scope($ctx);
            declare_var($ctx, $stmt->{var}, { type => 'string', immutable => 1 });
            my $prev_loop_depth = $ctx->{loop_depth} // 0;
            $ctx->{loop_depth} = $prev_loop_depth + 1;
            compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
            $ctx->{loop_depth} = $prev_loop_depth;
            pop_scope($ctx);

            emit_line($out, $indent + 2, '}');
            emit_line($out, $indent + 2,
                'if (ferror(stdin)) { return err_number("I/O read failure", __metac_line_no, ""); }');
            emit_line($out, $indent, '}');
            return 1;
        }

        if ($stmt->{kind} eq 'for_each') {
            emit_for_each_from_iterable_expr(
                iter_expr          => $stmt->{iterable},
                stmt               => $stmt,
                ctx                => $ctx,
                out                => $out,
                indent             => $indent,
                current_fn_return  => $current_fn_return,
            );
            return 1;
        }

        if ($stmt->{kind} eq 'while') {
            enforce_condition_diagnostics($stmt->{cond}, $ctx, "while condition");
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("while condition must evaluate to bool, got $cond_type")
              if $cond_type ne 'bool';

            emit_line($out, $indent, "while ($cond_code) {");
            new_scope($ctx);
            my $prev_loop_depth = $ctx->{loop_depth} // 0;
            $ctx->{loop_depth} = $prev_loop_depth + 1;
            compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
            $ctx->{loop_depth} = $prev_loop_depth;
            pop_scope($ctx);
            emit_line($out, $indent, '}');
            return 1;
        }

        if ($stmt->{kind} eq 'break') {
            compile_error("break is only valid inside a loop")
              if ($ctx->{loop_depth} // 0) <= 0;
            emit_line($out, $indent, 'break;');
            return 1;
        }

        if ($stmt->{kind} eq 'continue') {
            compile_error("continue is only valid inside a loop")
              if ($ctx->{loop_depth} // 0) <= 0;
            emit_line($out, $indent, 'continue;');
            return 1;
        }

        if ($stmt->{kind} eq 'destructure_match') {
            my $src = lookup_var($ctx, $stmt->{source_var});
            compile_error("match() source must be an existing string variable: $stmt->{source_var}")
              if !defined($src) || $src->{type} ne 'string';

            my $groups = parse_capture_groups($stmt->{pattern});
            my $expected = scalar @{ $stmt->{vars} };
            my $actual = scalar @$groups;
            compile_error("Destructuring expects $expected captures but regex provides $actual")
              if $expected != $actual;

            my $tmp_id = $ctx->{tmp_counter}++;
            my @tmp_buffers;
            for (my $i = 0; $i < $expected; $i++) {
                my $tmp = "__metac_m${tmp_id}_g$i";
                push @tmp_buffers, $tmp;
                emit_line($out, $indent, "char $tmp\[256\];");
            }

            my $outs_name = "__metac_m${tmp_id}_outs";
            my $outs_list = join(', ', map { $_ } @tmp_buffers);
            emit_line($out, $indent, "char *$outs_name\[$expected\] = { $outs_list };" );

            my $pattern_c = c_escape_string($stmt->{pattern});
            emit_line($out, $indent,
                "if (!metac_match_groups($stmt->{source_var}, $pattern_c, $expected, $outs_name, 256, __metac_err, sizeof(__metac_err))) {");
            emit_line($out, $indent + 2,
                "return err_number(__metac_err, __metac_line_no, $stmt->{source_var});");
            emit_line($out, $indent, '}');

            for (my $i = 0; $i < $expected; $i++) {
                my $name = $stmt->{vars}[$i];
                my $kind = infer_group_type($groups->[$i]);

                if ($kind eq 'number') {
                    emit_line($out, $indent, "int64_t $name;");
                    emit_line($out, $indent, "if (!metac_parse_int($tmp_buffers[$i], &$name)) {");
                    emit_line($out, $indent + 2,
                        "return err_number(\"Expected numeric capture\", __metac_line_no, $stmt->{source_var});");
                    emit_line($out, $indent, '}');
                } else {
                    emit_line($out, $indent, "char $name\[256\];");
                    emit_line($out, $indent, "metac_copy_str($name, sizeof($name), $tmp_buffers[$i]);");
                }

                declare_var($ctx, $name, { type => $kind, immutable => 1 });
            }
            return 1;
        }
    return 0;
}

1;
