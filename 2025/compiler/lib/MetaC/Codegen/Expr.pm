package MetaC::Codegen;
use strict;
use warnings;

sub compile_expr {
    my ($expr, $ctx) = @_;

    if ($expr->{kind} eq 'num') {
        return ($expr->{value}, 'number');
    }
    if ($expr->{kind} eq 'str') {
        if (defined($expr->{raw}) && $expr->{raw} =~ /\$\{/) {
            return (build_template_format_expr($expr->{raw}, $ctx), 'string');
        }
        return ($expr->{value}, 'string');
    }
    if ($expr->{kind} eq 'bool') {
        return ($expr->{value}, 'bool');
    }
    if ($expr->{kind} eq 'null') {
        return ("metac_null_number()", 'null');
    }
    if ($expr->{kind} eq 'list_literal') {
        return compile_list_literal_expr($expr, $ctx);
    }
    if ($expr->{kind} eq 'ident') {
        if ($expr->{name} eq 'STDIN') {
            return ('metac_read_all_stdin()', 'string');
        }
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable: $expr->{name}") if !defined $info;
        if ($info->{type} eq 'number_or_null' && has_nonnull_fact_by_c_name($ctx, $info->{c_name})) {
            return ("($info->{c_name}).value", 'number');
        }
        return ($info->{c_name}, $info->{type});
    }
    if ($expr->{kind} eq 'unary') {
        my ($inner_code, $inner_type) = compile_expr($expr->{expr}, $ctx);
        if ($expr->{op} eq '-') {
            my $num_expr = number_like_to_c_expr($inner_code, $inner_type, "Unary '-'");
            return ("(-$num_expr)", 'number');
        }
        compile_error("Unsupported unary operator: $expr->{op}");
    }
    if ($expr->{kind} eq 'index') {
        my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
        my ($idx_code, $idx_type) = compile_expr($expr->{index}, $ctx);
        my $idx_num = number_like_to_c_expr($idx_code, $idx_type, "Index operator");
        compile_error("Unsupported index receiver type: $recv_type")
          if $recv_type ne 'string' && $recv_type ne 'string_list' && $recv_type ne 'number_list' && $recv_type ne 'indexed_number_list';

        compile_error("Index on '$recv_type' requires compile-time in-bounds proof")
          if !prove_container_index_in_bounds($recv_code, $recv_type, $expr->{index}, $ctx);

        if ($recv_type eq 'string') {
            return ("metac_char_at($recv_code, $idx_num)", 'number');
        }
        if ($recv_type eq 'string_list') {
            return ("$recv_code.items[$idx_num]", 'string');
        }
        if ($recv_type eq 'indexed_number_list') {
            return ("$recv_code.items[$idx_num]", 'indexed_number');
        }
        return ("$recv_code.items[$idx_num]", 'number');
    }
    if ($expr->{kind} eq 'method_call') {
        my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
        my $method = $expr->{method};
        my $actual = scalar @{ $expr->{args} };

        my $fallibility_error = method_fallibility_diagnostic($expr, $recv_type, $ctx);
        compile_error($fallibility_error) if defined $fallibility_error;

        if (is_matrix_type($recv_type) && $method eq 'members') {
            compile_error("Method 'members()' expects 0 args, got $actual")
              if $actual != 0;
            my $meta = matrix_type_meta($recv_type);
            if ($meta->{elem} eq 'number') {
                return ("metac_matrix_number_members($recv_code)", matrix_member_list_type($recv_type));
            }
            if ($meta->{elem} eq 'string') {
                return ("metac_matrix_string_members($recv_code)", matrix_member_list_type($recv_type));
            }
            compile_error("matrix members are unsupported for element type '$meta->{elem}'");
        }

        if (is_matrix_type($recv_type) && $method eq 'insert') {
            compile_error("Method 'insert(...)' expects 2 args, got $actual")
              if $actual != 2;
            my $meta = matrix_type_meta($recv_type);

            my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
            my ($coord_code, $coord_type) = compile_expr($expr->{args}[1], $ctx);
            compile_error("Method 'insert(...)' requires number[] coordinates, got $coord_type")
              if $coord_type ne 'number_list';

            if ($meta->{elem} eq 'number') {
                my $value_num = number_like_to_c_expr($value_code, $value_type, "Method 'insert(...)'");
                return ("metac_matrix_number_insert_or_die($recv_code, $value_num, $coord_code)", $recv_type);
            }
            if ($meta->{elem} eq 'string') {
                compile_error("Method 'insert(...)' on matrix(string) expects string value, got $value_type")
                  if $value_type ne 'string';
                return ("metac_matrix_string_insert_or_die($recv_code, $value_code, $coord_code)", $recv_type);
            }
            compile_error("matrix insert is unsupported for element type '$meta->{elem}'");
        }

        if (is_matrix_type($recv_type) && $method eq 'neighbours') {
            compile_error("Method 'neighbours(...)' expects 1 arg, got $actual")
              if $actual != 1;
            my $meta = matrix_type_meta($recv_type);

            my ($coord_code, $coord_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'neighbours(...)' requires number[] coordinates, got $coord_type")
              if $coord_type ne 'number_list';

            if ($meta->{elem} eq 'number') {
                return ("metac_matrix_number_neighbours($recv_code, $coord_code)", matrix_neighbor_list_type($recv_type));
            }
            if ($meta->{elem} eq 'string') {
                return ("metac_matrix_string_neighbours($recv_code, $coord_code)", matrix_neighbor_list_type($recv_type));
            }
            compile_error("matrix neighbours are unsupported for element type '$meta->{elem}'");
        }

        if (is_matrix_member_type($recv_type) && $method eq 'index') {
            compile_error("Method 'index()' expects 0 args, got $actual")
              if $actual != 0;
            return ("(($recv_code).index)", 'number_list');
        }

        if (is_matrix_member_type($recv_type) && $method eq 'neighbours') {
            compile_error("Method 'neighbours()' expects 0 args, got $actual")
              if $actual != 0;
            my $meta = matrix_member_meta($recv_type);

            if ($meta->{elem} eq 'number') {
                return ("metac_matrix_number_neighbours(($recv_code).matrix, ($recv_code).index)", 'number_list');
            }
            if ($meta->{elem} eq 'string') {
                return ("metac_matrix_string_neighbours(($recv_code).matrix, ($recv_code).index)", 'string_list');
            }
            compile_error("Method 'neighbours()' is unsupported for matrix element type '$meta->{elem}'");
        }

        if ($recv_type eq 'string' && $method eq 'size') {
            compile_error("Method 'size()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_strlen($recv_code)", 'number');
        }

        if ($recv_type eq 'string' && $method eq 'chunk') {
            compile_error("Method 'chunk(...)' expects 1 arg, got $actual")
              if $actual != 1;
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            my $arg_num = number_like_to_c_expr($arg_code, $arg_type, "Method 'chunk(...)'");
            return ("metac_chunk_string($recv_code, $arg_num)", 'string_list');
        }

        if ($recv_type eq 'string' && $method eq 'chars') {
            compile_error("Method 'chars()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_chars_string($recv_code)", 'string_list');
        }

        if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'indexed_number_list')
            && ($method eq 'size' || $method eq 'count'))
        {
            compile_error("Method '$method()' expects 0 args, got $actual")
              if $actual != 0;
            return ("((int64_t)$recv_code.count)", 'number');
        }
        if (is_matrix_member_list_type($recv_type) && ($method eq 'size' || $method eq 'count')) {
            compile_error("Method '$method()' expects 0 args, got $actual")
              if $actual != 0;
            return ("((int64_t)$recv_code.count)", 'number');
        }

        if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || is_matrix_member_list_type($recv_type))
            && $method eq 'filter')
        {
            compile_error("Method 'filter(...)' expects 1 arg, got $actual")
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
                return ("metac_filter_string_list($recv_code, $helper_name)", 'string_list');
            }
            if ($recv_type eq 'number_list') {
                return ("metac_filter_number_list($recv_code, $helper_name)", 'number_list');
            }
            my $member_meta = matrix_member_list_meta($recv_type);
            if ($member_meta->{elem} eq 'number') {
                return ("metac_filter_matrix_number_member_list($recv_code, $helper_name)", $recv_type);
            }
            if ($member_meta->{elem} eq 'string') {
                return ("metac_filter_matrix_string_member_list($recv_code, $helper_name)", $recv_type);
            }
            compile_error("Method 'filter(...)' is unsupported for matrix member element type '$member_meta->{elem}'");
        }

        if (($recv_type eq 'string_list' || $recv_type eq 'number_list') && $method eq 'slice') {
            compile_error("Method 'slice(...)' expects 1 arg, got $actual")
              if $actual != 1;
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            my $arg_num = number_like_to_c_expr($arg_code, $arg_type, "Method 'slice(...)'");
            if ($recv_type eq 'string_list') {
                return ("metac_slice_string_list($recv_code, $arg_num)", 'string_list');
            }
            return ("metac_slice_number_list($recv_code, $arg_num)", 'number_list');
        }

        if ($recv_type eq 'number_list' && $method eq 'max') {
            compile_error("Method 'max()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_list_max_number($recv_code)", 'indexed_number');
        }

        if ($recv_type eq 'string_list' && $method eq 'max') {
            compile_error("Method 'max()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_list_max_string_number($recv_code)", 'indexed_number');
        }

        if ($recv_type eq 'number_list' && $method eq 'sort') {
            compile_error("Method 'sort()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_sort_number_list($recv_code)", 'indexed_number_list');
        }

        if ($recv_type eq 'indexed_number' && $method eq 'index') {
            compile_error("Method 'index()' expects 0 args, got $actual")
              if $actual != 0;
            return ("(($recv_code).index)", 'number');
        }

        if (($recv_type eq 'string' || $recv_type eq 'number' || $recv_type eq 'bool') && $method eq 'index') {
            compile_error("Method 'index()' expects 0 args, got $actual")
              if $actual != 0;
            if ($expr->{recv}{kind} eq 'ident') {
                my $recv_info = lookup_var($ctx, $expr->{recv}{name});
                if (defined $recv_info && defined $recv_info->{index_c_expr}) {
                    return ($recv_info->{index_c_expr}, 'number');
                }
            }
            compile_error("Method 'index()' requires value with source index metadata");
        }

        if (($recv_type eq 'number_list' || $recv_type eq 'string_list') && $method eq 'reduce') {
            return compile_reduce_call(
                expr => $expr,
                ctx  => $ctx,
            );
        }

        if ($method eq 'log') {
            compile_error("Method 'log()' expects 0 args, got $actual")
              if $actual != 0;
            if ($recv_type eq 'number') {
                return ("metac_log_number($recv_code)", 'number');
            }
            if ($recv_type eq 'string') {
                return ("metac_log_string($recv_code)", 'string');
            }
            if ($recv_type eq 'bool') {
                return ("metac_log_bool($recv_code)", 'bool');
            }
            if ($recv_type eq 'indexed_number') {
                return ("metac_log_indexed_number($recv_code)", 'indexed_number');
            }
            if ($recv_type eq 'string_list') {
                return ("metac_log_string_list($recv_code)", 'string_list');
            }
            if ($recv_type eq 'number_list') {
                return ("metac_log_number_list($recv_code)", 'number_list');
            }
            if ($recv_type eq 'indexed_number_list') {
                return ("metac_log_indexed_number_list($recv_code)", 'indexed_number_list');
            }
            if (is_matrix_type($recv_type)) {
                my $meta = matrix_type_meta($recv_type);
                return ("metac_log_matrix_number($recv_code)", $recv_type) if $meta->{elem} eq 'number';
                return ("metac_log_matrix_string($recv_code)", $recv_type) if $meta->{elem} eq 'string';
                compile_error("Method 'log()' is unsupported for matrix element type '$meta->{elem}'");
            }
        }

        if (($recv_type eq 'number_list' || $recv_type eq 'string_list') && $method eq 'push') {
            compile_error("Method 'push(...)' expects 1 arg, got $actual")
              if $actual != 1;
            compile_error("Method 'push(...)' receiver must be a mutable list variable")
              if $expr->{recv}{kind} ne 'ident';

            my $recv_info = lookup_var($ctx, $expr->{recv}{name});
            compile_error("Unknown variable: $expr->{recv}{name}") if !defined $recv_info;
            compile_error("Cannot mutate immutable variable '$expr->{recv}{name}'")
              if $recv_info->{immutable};

            if ($recv_type eq 'number_list') {
                my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
                my $arg_num = number_like_to_c_expr($arg_code, $arg_type, "Method 'push(...)'");
                return ("metac_number_list_push(&$recv_info->{c_name}, $arg_num)", 'number');
            }

            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'push(...)' on string list expects string arg, got $arg_type")
              if $arg_type ne 'string';
            return ("metac_string_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
        }

        compile_error("Unsupported method call '$method' on type '$recv_type'");
    }
    if ($expr->{kind} eq 'call') {
        if ($expr->{name} eq 'error') {
            my $actual = scalar @{ $expr->{args} };
            compile_error("error(...) expects exactly 1 arg, got $actual")
              if $actual != 1;
            my ($msg_code, $msg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("error(...) expects string message") if $msg_type ne 'string';
            return ("err_number($msg_code, __metac_line_no, \"\")", 'error');
        }

        my $functions = $ctx->{functions} // {};
        my $sig = $functions->{ $expr->{name} };
        if (!defined $sig) {
            if ($expr->{name} eq 'parseNumber') {
                compile_error("parseNumber(...) is fallible; use parseNumber(...)? or map(parseNumber)?");
            }
            if ($expr->{name} eq 'max' || $expr->{name} eq 'min') {
                my $actual = scalar @{ $expr->{args} };
                compile_error("Builtin '$expr->{name}' expects 2 args, got $actual")
                  if $actual != 2;
                my ($a_code, $a_type) = compile_expr($expr->{args}[0], $ctx);
                my ($b_code, $b_type) = compile_expr($expr->{args}[1], $ctx);
                my $a_num = number_like_to_c_expr($a_code, $a_type, "Builtin '$expr->{name}'");
                my $b_num = number_like_to_c_expr($b_code, $b_type, "Builtin '$expr->{name}'");
                return ("metac_$expr->{name}($a_num, $b_num)", 'number');
            }
            if ($expr->{name} eq 'last') {
                my $actual = scalar @{ $expr->{args} };
                compile_error("Builtin 'last' expects 1 arg, got $actual")
                  if $actual != 1;
                my ($a_code, $a_type) = compile_expr($expr->{args}[0], $ctx);
                if ($a_type eq 'string_list') {
                    return ("metac_last_index_string_list($a_code)", 'number');
                }
                if ($a_type eq 'number_list') {
                    return ("metac_last_index_number_list($a_code)", 'number');
                }
                compile_error("Builtin 'last' requires string_list or number_list arg");
            }
            if ($expr->{name} eq 'log') {
                my $actual = scalar @{ $expr->{args} };
                compile_error("Builtin 'log' expects 1 arg, got $actual")
                  if $actual != 1;
                my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
                if ($arg_type eq 'number') {
                    return ("metac_log_number($arg_code)", 'number');
                }
                if ($arg_type eq 'string') {
                    return ("metac_log_string($arg_code)", 'string');
                }
                if ($arg_type eq 'bool') {
                    return ("metac_log_bool($arg_code)", 'bool');
                }
                if ($arg_type eq 'indexed_number') {
                    return ("metac_log_indexed_number($arg_code)", 'indexed_number');
                }
                if ($arg_type eq 'string_list') {
                    return ("metac_log_string_list($arg_code)", 'string_list');
                }
                if ($arg_type eq 'number_list') {
                    return ("metac_log_number_list($arg_code)", 'number_list');
                }
                if ($arg_type eq 'indexed_number_list') {
                    return ("metac_log_indexed_number_list($arg_code)", 'indexed_number_list');
                }
                if (is_matrix_type($arg_type)) {
                    my $meta = matrix_type_meta($arg_type);
                    return ("metac_log_matrix_number($arg_code)", $arg_type) if $meta->{elem} eq 'number';
                    return ("metac_log_matrix_string($arg_code)", $arg_type) if $meta->{elem} eq 'string';
                    compile_error("Builtin 'log' does not support matrix element type '$meta->{elem}'");
                }
                compile_error("Builtin 'log' does not support argument type '$arg_type'");
            }
            compile_error("Unknown function in expression: $expr->{name}");
        }

        my $return_type = $sig->{return_type};
        compile_error("Function '$expr->{name}' returning '$return_type' is not expression-callable")
          if $return_type ne 'number'
          && $return_type ne 'bool'
          && !type_is_number_or_error($return_type)
          && !type_is_bool_or_error($return_type)
          && !type_is_string_or_error($return_type)
          && !is_supported_generic_union_return($return_type);

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
            compile_error("Arg " . ($i + 1) . " to '$expr->{name}' must be $param_t, got $arg_t")
              if $arg_t ne $param_t;
            push @arg_code, $arg_c;
        }

        if ($return_type eq 'bool') {
            return ("$expr->{name}(" . join(', ', @arg_code) . ")", 'bool');
        }
        if ($return_type eq 'number') {
            return ("$expr->{name}(" . join(', ', @arg_code) . ")", 'number');
        }
        return ("$expr->{name}(" . join(', ', @arg_code) . ")", $return_type);
    }
    if ($expr->{kind} eq 'binop') {
        if ($expr->{op} eq '&&') {
            my ($l_code, $l_type) = compile_expr($expr->{left}, $ctx);
            compile_error("Operator '&&' requires bool operands, got $l_type and <unknown>")
              if $l_type ne 'bool';

            my ($r_code, $r_type);
            my $narrow_name = nullable_number_non_null_on_true_expr($expr->{left}, $ctx);
            if (defined $narrow_name) {
                new_scope($ctx);
                declare_not_null_number_shadow($ctx, $narrow_name);
                ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);
                pop_scope($ctx);
            } else {
                ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);
            }
            compile_error("Operator '&&' requires bool operands, got $l_type and $r_type")
              if $r_type ne 'bool';
            return ("($l_code && $r_code)", 'bool');
        }

        if ($expr->{op} eq '||') {
            my ($l_code, $l_type) = compile_expr($expr->{left}, $ctx);
            compile_error("Operator '||' requires bool operands, got $l_type and <unknown>")
              if $l_type ne 'bool';

            my ($r_code, $r_type);
            my $narrow_name = nullable_number_non_null_on_false_expr($expr->{left}, $ctx);
            if (defined $narrow_name) {
                new_scope($ctx);
                declare_not_null_number_shadow($ctx, $narrow_name);
                ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);
                pop_scope($ctx);
            } else {
                ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);
            }
            compile_error("Operator '||' requires bool operands, got $l_type and $r_type")
              if $r_type ne 'bool';
            return ("($l_code || $r_code)", 'bool');
        }

        my ($l_code, $l_type) = compile_expr($expr->{left}, $ctx);
        my ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);

        if ($expr->{op} eq '+' || $expr->{op} eq '-' || $expr->{op} eq '*' || $expr->{op} eq '/' || $expr->{op} eq '%') {
            my $l_num = number_like_to_c_expr($l_code, $l_type, "Operator '$expr->{op}'");
            my $r_num = number_like_to_c_expr($r_code, $r_type, "Operator '$expr->{op}'");
            return ("($l_num $expr->{op} $r_num)", 'number');
        }

        if ($expr->{op} eq '==' || $expr->{op} eq '!=') {
            my $op = $expr->{op};
            my $l_is_string_like = $l_type eq 'string'
              || (is_matrix_member_type($l_type) && matrix_member_meta($l_type)->{elem} eq 'string');
            my $r_is_string_like = $r_type eq 'string'
              || (is_matrix_member_type($r_type) && matrix_member_meta($r_type)->{elem} eq 'string');
            my $l_string_code = $l_type eq 'string' ? $l_code : "(($l_code).value)";
            my $r_string_code = $r_type eq 'string' ? $r_code : "(($r_code).value)";
            if (($l_type eq 'number_or_null' && $r_type eq 'null') || ($l_type eq 'null' && $r_type eq 'number_or_null')) {
                my $nullable_code = $l_type eq 'number_or_null' ? $l_code : $r_code;
                if ($op eq '==') {
                    return ("(($nullable_code).is_null)", 'bool');
                }
                return ("(!($nullable_code).is_null)", 'bool');
            }
            if ($l_type eq 'number_or_null' && $r_type eq 'number_or_null') {
                my $cmp = "((($l_code).is_null && ($r_code).is_null) || (!($l_code).is_null && !($r_code).is_null && ($l_code).value == ($r_code).value))";
                return ($cmp, 'bool') if $op eq '==';
                return ("(!($cmp))", 'bool');
            }
            if (($l_type eq 'number_or_null' && is_number_like_type($r_type))
                || ($r_type eq 'number_or_null' && is_number_like_type($l_type)))
            {
                my $nullable_code = $l_type eq 'number_or_null' ? $l_code : $r_code;
                my $num_code_raw = $l_type eq 'number_or_null' ? $r_code : $l_code;
                my $num_type = $l_type eq 'number_or_null' ? $r_type : $l_type;
                my $num_code = number_like_to_c_expr($num_code_raw, $num_type, "Operator '$op'");
                my $cmp = "(!($nullable_code).is_null && ($nullable_code).value == $num_code)";
                return ($cmp, 'bool') if $op eq '==';
                return ("(!($cmp))", 'bool');
            }
            if ($l_type eq 'null' && $r_type eq 'null') {
                return ($op eq '==' ? '1' : '0', 'bool');
            }
            if (is_number_like_type($l_type) && is_number_like_type($r_type)) {
                my $l_num = number_like_to_c_expr($l_code, $l_type, "Operator '$op'");
                my $r_num = number_like_to_c_expr($r_code, $r_type, "Operator '$op'");
                return ("($l_num $op $r_num)", 'bool');
            }
            if ($l_is_string_like && $r_is_string_like) {
                return ("metac_streq($l_string_code, $r_string_code)", 'bool') if $op eq '==';
                return ("(!metac_streq($l_string_code, $r_string_code))", 'bool');
            }
            compile_error("Type mismatch in '$op': $l_type vs $r_type") if $l_type ne $r_type;
            return ("($l_code $op $r_code)", 'bool') if $l_type eq 'bool';
            if ($l_type eq 'string') {
                return ("metac_streq($l_code, $r_code)", 'bool') if $op eq '==';
                return ("(!metac_streq($l_code, $r_code))", 'bool');
            }
            compile_error("Unsupported '$op' operand type: $l_type");
        }
        if ($expr->{op} eq '<' || $expr->{op} eq '>' || $expr->{op} eq '<=' || $expr->{op} eq '>=') {
            my $l_num = number_like_to_c_expr($l_code, $l_type, "Operator '$expr->{op}'");
            my $r_num = number_like_to_c_expr($r_code, $r_type, "Operator '$expr->{op}'");
            return ("($l_num $expr->{op} $r_num)", 'bool');
        }

        compile_error("Unsupported binary operator: $expr->{op}");
    }

    compile_error("Unsupported expression kind: $expr->{kind}");
}


sub compile_block {
    my ($stmts, $ctx, $out, $indent, $current_fn_return) = @_;

    for my $stmt (@$stmts) {
        set_error_line($stmt->{line});
        next if _compile_block_stage_decls($stmt, $ctx, $out, $indent, $current_fn_return);
        next if _compile_block_stage_try($stmt, $ctx, $out, $indent, $current_fn_return);
        next if _compile_block_stage_assign_loops($stmt, $ctx, $out, $indent, $current_fn_return);
        next if _compile_block_stage_control($stmt, $ctx, $out, $indent, $current_fn_return);
        compile_error("Unsupported statement kind: $stmt->{kind}");
    }
    clear_error_line();
}



1;
