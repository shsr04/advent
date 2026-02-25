package MetaC::Codegen;
use strict;
use warnings;

sub _declare_union_member_bindings {
    my ($ctx, $bindings) = @_;
    return if !defined $bindings || !@$bindings;
    for my $binding (@$bindings) {
        declare_union_member_shadow($ctx, $binding->{name}, $binding->{member});
    }
}

sub _compile_union_scalar_comparison {
    my (%args) = @_;
    my $union_code = $args{union_code};
    my $union_type = $args{union_type};
    my $other_code = $args{other_code};
    my $other_type = $args{other_type};
    my $op = $args{op};

    my ($match_code, $member);
    if ($other_type eq 'number' || $other_type eq 'indexed_number') {
        my $num = number_like_to_c_expr($other_code, $other_type, "Operator '$op'");
        $member = 'number';
        $match_code = "(($union_code.kind == METAC_VALUE_NUMBER) && ($union_code.number_value == $num))";
    } elsif ($other_type eq 'bool') {
        $member = 'bool';
        $match_code = "(($union_code.kind == METAC_VALUE_BOOL) && ($union_code.bool_value == $other_code))";
    } elsif ($other_type eq 'string') {
        $member = 'string';
        $match_code = "(($union_code.kind == METAC_VALUE_STRING) && metac_streq($union_code.string_value, $other_code))";
    } elsif ($other_type eq 'null') {
        $member = 'null';
        $match_code = "($union_code.kind == METAC_VALUE_NULL)";
    } else {
        compile_error("Type mismatch in '$op': $union_type vs $other_type");
    }

    compile_error("Type mismatch in '$op': $union_type does not contain $member")
      if !union_contains_member($union_type, $member);
    return $op eq '==' ? $match_code : "(!($match_code))";
}

sub _is_empty_list_comparable_type {
    my ($type) = @_;
    return 1 if $type eq 'string_list';
    return 1 if $type eq 'number_list';
    return 1 if $type eq 'number_list_list';
    return 1 if $type eq 'bool_list';
    return 1 if $type eq 'indexed_number_list';
    return 1 if is_matrix_member_list_type($type);
    return 0;
}

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
          if $recv_type ne 'string' && $recv_type ne 'string_list' && $recv_type ne 'number_list' && $recv_type ne 'bool_list' && $recv_type ne 'indexed_number_list';

        my $in_bounds = prove_container_index_in_bounds($recv_code, $recv_type, $expr->{index}, $ctx);
        if (!$in_bounds && $expr->{recv}{kind} eq 'ident' && $expr->{index}{kind} eq 'num') {
            my $idx_const = int($expr->{index}{value});
            if ($idx_const >= 0) {
                my $recv_key = expr_fact_key($expr->{recv}, $ctx);
                my $known_len = lookup_list_len_fact($ctx, $recv_key);
                $in_bounds = 1 if defined($known_len) && $idx_const < $known_len;
            }
        }
        compile_error("Index on '$recv_type' requires compile-time in-bounds proof")
          if !$in_bounds;

        if ($recv_type eq 'string') {
            return ("metac_char_at($recv_code, $idx_num)", 'number');
        }
        if ($recv_type eq 'string_list') {
            return ("$recv_code.items[$idx_num]", 'string');
        }
        if ($recv_type eq 'indexed_number_list') {
            return ("$recv_code.items[$idx_num]", 'indexed_number');
        }
        if ($recv_type eq 'bool_list') {
            return ("$recv_code.items[$idx_num]", 'bool');
        }
        return ("$recv_code.items[$idx_num]", 'number');
    }
    if ($expr->{kind} eq 'try') {
        compile_error("Postfix '?' is only supported after hoisting in statement lowering");
    }
    if ($expr->{kind} eq 'method_call') {
        my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
        my $method = $expr->{method};
        my $actual = scalar @{ $expr->{args} };
        my ($method_code, $method_type) = compile_expr_method_call($expr, $ctx, $recv_code, $recv_type, $method, $actual);
        return maybe_materialize_owned_expr_result(
            ctx       => $ctx,
            expr_code => $method_code,
            expr_type => $method_type,
        );
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
                if ($arg_type eq 'bool_list') {
                    return ("metac_log_bool_list($arg_code)", 'bool_list');
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
            if (is_supported_generic_union_return($param_t)) {
                push @arg_code, generic_union_to_c_expr($arg_c, $arg_t, $param_t, "Arg " . ($i + 1) . " to '$expr->{name}'");
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
            my $union_bindings = union_member_bindings_on_true_expr($expr->{left}, $ctx);
            if (defined $narrow_name || (defined $union_bindings && @$union_bindings)) {
                new_scope($ctx);
                declare_not_null_number_shadow($ctx, $narrow_name) if defined $narrow_name;
                _declare_union_member_bindings($ctx, $union_bindings);
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
            my $union_bindings = union_member_bindings_on_false_expr($expr->{left}, $ctx);
            if (defined $narrow_name || (defined $union_bindings && @$union_bindings)) {
                new_scope($ctx);
                declare_not_null_number_shadow($ctx, $narrow_name) if defined $narrow_name;
                _declare_union_member_bindings($ctx, $union_bindings);
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
            if (is_supported_generic_union_return($l_type) && $l_type ne 'number_or_null' && !is_union_type($r_type)) {
                my $cmp = _compile_union_scalar_comparison(
                    union_code => $l_code,
                    union_type => $l_type,
                    other_code => $r_code,
                    other_type => $r_type,
                    op         => $op,
                );
                return ($cmp, 'bool');
            }
            if (is_supported_generic_union_return($r_type) && $r_type ne 'number_or_null' && !is_union_type($l_type)) {
                my $cmp = _compile_union_scalar_comparison(
                    union_code => $r_code,
                    union_type => $r_type,
                    other_code => $l_code,
                    other_type => $l_type,
                    op         => $op,
                );
                return ($cmp, 'bool');
            }
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
            if ($l_type eq 'empty_list' && $r_type eq 'empty_list') {
                return ($op eq '==' ? '1' : '0', 'bool');
            }
            if (($l_type eq 'empty_list' && _is_empty_list_comparable_type($r_type))
                || ($r_type eq 'empty_list' && _is_empty_list_comparable_type($l_type)))
            {
                my $list_code = $l_type eq 'empty_list' ? $r_code : $l_code;
                my $cmp = "(($list_code).count == 0)";
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
