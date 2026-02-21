package MetaC::Codegen;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error c_escape_string parse_constraints emit_line);
use MetaC::Parser qw(collect_functions parse_function_params parse_capture_groups infer_group_type parse_function_body);

our @EXPORT_OK = qw(compile_source);

sub producer_definitely_assigns {
    my ($stmts, $target) = @_;
    my $assigned = 0;

    for my $stmt (@$stmts) {
        if (($stmt->{kind} eq 'typed_assign' || $stmt->{kind} eq 'assign') && $stmt->{name} eq $target) {
            $assigned = 1;
            last;
        }

        if ($stmt->{kind} eq 'if' && defined $stmt->{else_body}) {
            my $then_ok = producer_definitely_assigns($stmt->{then_body}, $target);
            my $else_ok = producer_definitely_assigns($stmt->{else_body}, $target);
            if ($then_ok && $else_ok) {
                $assigned = 1;
                last;
            }
        }
    }

    return $assigned;
}


sub block_definitely_returns {
    my ($stmts) = @_;
    for my $stmt (@$stmts) {
        return 1 if $stmt->{kind} eq 'return';
        if ($stmt->{kind} eq 'if' && defined $stmt->{else_body}) {
            my $then_returns = block_definitely_returns($stmt->{then_body});
            my $else_returns = block_definitely_returns($stmt->{else_body});
            return 1 if $then_returns && $else_returns;
        }
    }
    return 0;
}


sub param_c_type {
    my ($param) = @_;
    return 'int64_t' if $param->{type} eq 'number';
    return 'int' if $param->{type} eq 'bool';
    return 'const char *' if $param->{type} eq 'string';
    compile_error("Unsupported parameter type: $param->{type}");
}


sub render_c_params {
    my ($params) = @_;
    return 'void' if !@$params;
    return join(', ', map { param_c_type($_) . ' ' . $_->{c_in_name} } @$params);
}


sub new_scope {
    my ($ctx) = @_;
    push @{ $ctx->{scopes} }, {};
    push @{ $ctx->{fact_scopes} }, {};
}


sub pop_scope {
    my ($ctx) = @_;
    pop @{ $ctx->{scopes} };
    pop @{ $ctx->{fact_scopes} };
}


sub lookup_var {
    my ($ctx, $name) = @_;
    for (my $i = $#{ $ctx->{scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{scopes}[$i];
        return $scope->{$name} if exists $scope->{$name};
    }
    return undef;
}


sub declare_var {
    my ($ctx, $name, $info) = @_;
    my $scope = $ctx->{scopes}[-1];
    compile_error("Variable already declared in this scope: $name") if exists $scope->{$name};
    $info->{c_name} = $name if !exists $info->{c_name};
    $info->{immutable} = 0 if !exists $info->{immutable};
    $scope->{$name} = $info;
}


sub set_list_len_fact {
    my ($ctx, $key, $len) = @_;
    my $scope = $ctx->{fact_scopes}[-1];
    $scope->{$key} = $len;
}


sub lookup_list_len_fact {
    my ($ctx, $key) = @_;
    for (my $i = $#{ $ctx->{fact_scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{fact_scopes}[$i];
        return $scope->{$key} if exists $scope->{$key};
    }
    return undef;
}


sub expr_is_stable_for_facts {
    my ($expr, $ctx) = @_;
    return 1 if $expr->{kind} eq 'num' || $expr->{kind} eq 'str' || $expr->{kind} eq 'bool';

    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        return 0 if !defined $info;
        return $info->{immutable} ? 1 : 0;
    }

    if ($expr->{kind} eq 'unary') {
        return expr_is_stable_for_facts($expr->{expr}, $ctx);
    }

    if ($expr->{kind} eq 'binop') {
        return 0 if !expr_is_stable_for_facts($expr->{left}, $ctx);
        return 0 if !expr_is_stable_for_facts($expr->{right}, $ctx);
        return 1;
    }

    if ($expr->{kind} eq 'method_call') {
        return 0 if $expr->{method} ne 'size' && $expr->{method} ne 'chunk';
        return 0 if !expr_is_stable_for_facts($expr->{recv}, $ctx);
        for my $arg (@{ $expr->{args} }) {
            return 0 if !expr_is_stable_for_facts($arg, $ctx);
        }
        return 1;
    }

    return 0;
}


sub expr_fact_key {
    my ($expr, $ctx) = @_;
    if ($expr->{kind} eq 'num') {
        return "num:$expr->{value}";
    }
    if ($expr->{kind} eq 'str') {
        return 'str:' . (defined $expr->{raw} ? $expr->{raw} : $expr->{value});
    }
    if ($expr->{kind} eq 'bool') {
        return "bool:$expr->{value}";
    }
    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable in arity analysis: $expr->{name}") if !defined $info;
        return "id:$info->{c_name}";
    }
    if ($expr->{kind} eq 'unary') {
        return "unary:$expr->{op}(" . expr_fact_key($expr->{expr}, $ctx) . ")";
    }
    if ($expr->{kind} eq 'binop') {
        return "binop:$expr->{op}(" . expr_fact_key($expr->{left}, $ctx) . ',' . expr_fact_key($expr->{right}, $ctx) . ")";
    }
    if ($expr->{kind} eq 'method_call') {
        my @args = map { expr_fact_key($_, $ctx) } @{ $expr->{args} };
        return "method:$expr->{method}(" . expr_fact_key($expr->{recv}, $ctx) . ';' . join(',', @args) . ")";
    }
    compile_error("Unsupported expression in arity analysis: $expr->{kind}");
}


sub is_size_call_expr {
    my ($expr) = @_;
    return 0 if $expr->{kind} ne 'method_call';
    return 0 if $expr->{method} ne 'size';
    return scalar(@{ $expr->{args} }) == 0;
}


sub is_size_call_on_lambda_param {
    my ($expr, $param) = @_;
    return 0 if $expr->{kind} ne 'method_call';
    return 0 if $expr->{method} ne 'size';
    return 0 if scalar(@{ $expr->{args} }) != 0;
    return 0 if $expr->{recv}{kind} ne 'ident';
    return $expr->{recv}{name} eq $param;
}


sub lambda_size_eq_fact {
    my ($lambda) = @_;
    return undef if $lambda->{kind} ne 'lambda1';
    my $param = $lambda->{param};
    my $body = $lambda->{body};
    return undef if $body->{kind} ne 'binop';
    return undef if $body->{op} ne '==';

    if (is_size_call_on_lambda_param($body->{left}, $param) && $body->{right}{kind} eq 'num') {
        return int($body->{right}{value});
    }
    if (is_size_call_on_lambda_param($body->{right}, $param) && $body->{left}{kind} eq 'num') {
        return int($body->{left}{value});
    }
    return undef;
}


sub size_check_from_condition {
    my ($cond, $ctx) = @_;
    return undef if $cond->{kind} ne 'binop';
    return undef if $cond->{op} ne '==' && $cond->{op} ne '!=';

    my ($size_expr, $num_expr);
    if (is_size_call_expr($cond->{left}) && $cond->{right}{kind} eq 'num') {
        $size_expr = $cond->{left};
        $num_expr = $cond->{right};
    } elsif (is_size_call_expr($cond->{right}) && $cond->{left}{kind} eq 'num') {
        $size_expr = $cond->{right};
        $num_expr = $cond->{left};
    } else {
        return undef;
    }

    my $target_expr = $size_expr->{recv};
    return undef if !expr_is_stable_for_facts($target_expr, $ctx);

    my (undef, $target_type) = compile_expr($target_expr, $ctx);
    return undef if $target_type ne 'string_list' && $target_type ne 'number_list';

    return {
        key => expr_fact_key($target_expr, $ctx),
        len => int($num_expr->{value}),
        op  => $cond->{op},
    };
}


sub expr_condition_flags {
    my ($expr, $ctx) = @_;
    my %flags = (
        has_comparison => 0,
        has_immutable  => 0,
        has_mutable    => 0,
    );

    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable in condition analysis: $expr->{name}")
          if !defined $info;
        if ($info->{immutable}) {
            $flags{has_immutable} = 1;
        } else {
            $flags{has_mutable} = 1;
        }
        return \%flags;
    }

    if ($expr->{kind} eq 'num' || $expr->{kind} eq 'str') {
        return \%flags;
    }

    if ($expr->{kind} eq 'unary') {
        return expr_condition_flags($expr->{expr}, $ctx);
    }

    if ($expr->{kind} eq 'call') {
        for my $arg (@{ $expr->{args} }) {
            my $sub = expr_condition_flags($arg, $ctx);
            $flags{has_comparison} ||= $sub->{has_comparison};
            $flags{has_immutable}  ||= $sub->{has_immutable};
            $flags{has_mutable}    ||= $sub->{has_mutable};
        }
        return \%flags;
    }

    if ($expr->{kind} eq 'binop') {
        my $left = expr_condition_flags($expr->{left}, $ctx);
        my $right = expr_condition_flags($expr->{right}, $ctx);

        $flags{has_comparison} = $left->{has_comparison} || $right->{has_comparison};
        $flags{has_immutable} = $left->{has_immutable} || $right->{has_immutable};
        $flags{has_mutable} = $left->{has_mutable} || $right->{has_mutable};

        if ($expr->{op} eq '==' || $expr->{op} eq '!=' || $expr->{op} eq '<' || $expr->{op} eq '>' || $expr->{op} eq '<=' || $expr->{op} eq '>=') {
            $flags{has_comparison} = 1;
        }

        return \%flags;
    }

    return \%flags;
}


sub enforce_condition_diagnostics {
    my ($expr, $ctx, $where) = @_;
    my $flags = expr_condition_flags($expr, $ctx);

    if ($flags->{has_comparison} && $flags->{has_immutable} && !$flags->{has_mutable}) {
        compile_error("Conditional comparison in $where depends only on immutable values");
    }
}


sub build_template_format_expr {
    my ($raw, $ctx) = @_;
    my $fmt = '';
    my @args;
    my $pos = 0;

    while ($raw =~ /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g) {
        my $name = $1;
        my $start = $-[0];
        my $end = $+[0];

        my $literal = substr($raw, $pos, $start - $pos);
        $literal =~ s/%/%%/g;
        $fmt .= $literal;

        my $info = lookup_var($ctx, $name);
        compile_error("Unknown interpolation variable: $name") if !defined $info;
        if ($info->{type} eq 'string') {
            $fmt .= '%s';
            push @args, $info->{c_name};
        } elsif ($info->{type} eq 'number') {
            $fmt .= '%lld';
            push @args, "(long long)$info->{c_name}";
        } elsif ($info->{type} eq 'bool') {
            $fmt .= '%d';
            push @args, $info->{c_name};
        } else {
            compile_error("Unsupported interpolation variable type for '$name': $info->{type}");
        }

        $pos = $end;
    }

    my $tail = substr($raw, $pos);
    $tail =~ s/%/%%/g;
    $fmt .= $tail;

    my $fmt_c = c_escape_string($fmt);
    my $expr = "metac_fmt($fmt_c";
    if (@args) {
        $expr .= ', ' . join(', ', @args);
    }
    $expr .= ')';
    return $expr;
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
    if ($expr->{kind} eq 'ident') {
        if ($expr->{name} eq 'STDIN') {
            return ('metac_read_all_stdin()', 'string');
        }
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable: $expr->{name}") if !defined $info;
        return ($info->{c_name}, $info->{type});
    }
    if ($expr->{kind} eq 'unary') {
        my ($inner_code, $inner_type) = compile_expr($expr->{expr}, $ctx);
        if ($expr->{op} eq '-') {
            compile_error("Unary '-' requires number operand") if $inner_type ne 'number';
            return ("(-$inner_code)", 'number');
        }
        compile_error("Unsupported unary operator: $expr->{op}");
    }
    if ($expr->{kind} eq 'method_call') {
        my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
        my $method = $expr->{method};
        my $actual = scalar @{ $expr->{args} };

        if ($recv_type eq 'string' && $method eq 'size') {
            compile_error("Method 'size()' expects 0 args, got $actual")
              if $actual != 0;
            return ("metac_strlen($recv_code)", 'number');
        }

        if ($recv_type eq 'string' && $method eq 'chunk') {
            compile_error("Method 'chunk(...)' expects 1 arg, got $actual")
              if $actual != 1;
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'chunk(...)' expects number arg")
              if $arg_type ne 'number';
            return ("metac_chunk_string($recv_code, $arg_code)", 'string_list');
        }

        if (($recv_type eq 'string_list' || $recv_type eq 'number_list') && $method eq 'size') {
            compile_error("Method 'size()' expects 0 args, got $actual")
              if $actual != 0;
            return ("((int64_t)$recv_code.count)", 'number');
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
                compile_error("Builtin '$expr->{name}' requires number args")
                  if $a_type ne 'number' || $b_type ne 'number';
                return ("metac_$expr->{name}($a_code, $b_code)", 'number');
            }
            compile_error("Unknown function in expression: $expr->{name}");
        }

        my $return_type = $sig->{return_type};
        compile_error("Function '$expr->{name}' returning '$return_type' is not expression-callable")
          if $return_type ne 'number' && $return_type ne 'bool';

        my $expected = scalar @{ $sig->{params} };
        my $actual = scalar @{ $expr->{args} };
        compile_error("Function '$expr->{name}' expects $expected args, got $actual")
          if $expected != $actual;

        my @arg_code;
        for (my $i = 0; $i < $expected; $i++) {
            my ($arg_c, $arg_t) = compile_expr($expr->{args}[$i], $ctx);
            my $param_t = $sig->{params}[$i]{type};
            compile_error("Arg " . ($i + 1) . " to '$expr->{name}' must be $param_t, got $arg_t")
              if $arg_t ne $param_t;
            push @arg_code, $arg_c;
        }

        my $result_type = $return_type eq 'bool' ? 'bool' : 'number';
        return ("$expr->{name}(" . join(', ', @arg_code) . ")", $result_type);
    }
    if ($expr->{kind} eq 'binop') {
        my ($l_code, $l_type) = compile_expr($expr->{left}, $ctx);
        my ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);

        if ($expr->{op} eq '+' || $expr->{op} eq '-' || $expr->{op} eq '*' || $expr->{op} eq '/') {
            compile_error("Operator '$expr->{op}' requires number operands")
              if $l_type ne 'number' || $r_type ne 'number';
            return ("($l_code $expr->{op} $r_code)", 'number');
        }

        if ($expr->{op} eq '==' || $expr->{op} eq '!=') {
            my $op = $expr->{op};
            compile_error("Type mismatch in '$op': $l_type vs $r_type") if $l_type ne $r_type;
            return ("($l_code $op $r_code)", 'bool') if $l_type eq 'number';
            return ("($l_code $op $r_code)", 'bool') if $l_type eq 'bool';
            if ($l_type eq 'string') {
                return ("metac_streq($l_code, $r_code)", 'bool') if $op eq '==';
                return ("(!metac_streq($l_code, $r_code))", 'bool');
            }
            compile_error("Unsupported '$op' operand type: $l_type");
        }
        if ($expr->{op} eq '<' || $expr->{op} eq '>' || $expr->{op} eq '<=' || $expr->{op} eq '>=') {
            compile_error("Operator '$expr->{op}' requires number operands")
              if $l_type ne 'number' || $r_type ne 'number';
            return ("($l_code $expr->{op} $r_code)", 'bool');
        }

        compile_error("Unsupported binary operator: $expr->{op}");
    }

    compile_error("Unsupported expression kind: $expr->{kind}");
}


sub compile_block {
    my ($stmts, $ctx, $out, $indent, $current_fn_return) = @_;

    for my $stmt (@$stmts) {
        if ($stmt->{kind} eq 'let') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            my $decl_type = defined($stmt->{type}) ? $stmt->{type} : $expr_type;
            if (defined $stmt->{type}) {
                compile_error("Type mismatch in let '$stmt->{name}': expected $stmt->{type}, got $expr_type")
                  if $expr_type ne $stmt->{type};
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

                my $init_expr = $expr_code;
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $init_expr = "metac_wrap_range($init_expr, $constraints->{range}{min}, $constraints->{range}{max})";
                }
                emit_line($out, $indent, "int64_t $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($decl_type eq 'bool') {
                emit_line($out, $indent, "int $stmt->{name} = $expr_code;");
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
            next;
        }

        if ($stmt->{kind} eq 'const') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($expr_type eq 'number') {
                emit_line($out, $indent, "const int64_t $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'bool') {
                emit_line($out, $indent, "const int $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($expr_type eq 'string_list') {
                emit_line($out, $indent, "StringList $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'number_list') {
                emit_line($out, $indent, "NumberList $stmt->{name} = $expr_code;");
            } else {
                compile_error("Unsupported const expression type for '$stmt->{name}': $expr_type");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => $expr_type,
                    immutable => 1,
                }
            );
            next;
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
            next;
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
                next;
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
                next;
            }

            if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'map') {
                my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
                compile_error("map(...) receiver must be string_list, got $recv_type")
                  if $recv_type ne 'string_list';
                my $actual = scalar @{ $expr->{args} };
                compile_error("map(...) expects exactly 1 function arg, got $actual")
                  if $actual != 1;

                my $mapper = $expr->{args}[0];
                compile_error("map(...) expects function identifier argument")
                  if $mapper->{kind} ne 'ident';
                my $mapper_name = $mapper->{name};

                my $source = '__metac_map_src' . $ctx->{tmp_counter}++;
                my $count = '__metac_map_count' . $ctx->{tmp_counter}++;
                my $idx = '__metac_map_i' . $ctx->{tmp_counter}++;
                my $out_items = '__metac_map_items' . $ctx->{tmp_counter}++;
                my $tmp_num = '__metac_map_num' . $ctx->{tmp_counter}++;
                my $tmp_res = '__metac_map_res' . $ctx->{tmp_counter}++;

                emit_line($out, $indent, "StringList $source = $recv_code;");
                emit_line($out, $indent, "size_t $count = $source.count;");
                emit_line($out, $indent, "int64_t *$out_items = (int64_t *)calloc($count == 0 ? 1 : $count, sizeof(int64_t));");
                emit_line($out, $indent, "if ($out_items == NULL) {");
                emit_line($out, $indent + 2, "return err_number(\"out of memory in map\", __metac_line_no, \"\");");
                emit_line($out, $indent, "}");

                my $functions = $ctx->{functions} // {};
                my $sig = $functions->{$mapper_name};

                emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
                if ($mapper_name eq 'parseNumber') {
                    emit_line($out, $indent + 2, "int64_t $tmp_num = 0;");
                    emit_line($out, $indent + 2, "if (!metac_parse_int($source.items[$idx], &$tmp_num)) {");
                    emit_line($out, $indent + 4, "return err_number(\"Invalid number\", __metac_line_no, $source.items[$idx]);");
                    emit_line($out, $indent + 2, "}");
                    emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_num;");
                } else {
                    compile_error("Unknown mapper function '$mapper_name' in map(...)")
                      if !defined $sig;
                    my $expected = scalar @{ $sig->{params} };
                    compile_error("map(...) mapper '$mapper_name' must accept exactly 1 arg")
                      if $expected != 1;
                    compile_error("map(...) mapper '$mapper_name' arg type must be string")
                      if $sig->{params}[0]{type} ne 'string';

                    if ($sig->{return_type} eq 'number') {
                        emit_line($out, $indent + 2, "${out_items}[$idx] = $mapper_name($source.items[$idx]);");
                    } elsif ($sig->{return_type} eq 'number | error') {
                        emit_line($out, $indent + 2, "ResultNumber $tmp_res = $mapper_name($source.items[$idx]);");
                        emit_line($out, $indent + 2, "if ($tmp_res.is_error) {");
                        emit_line($out, $indent + 4, "return err_number($tmp_res.message, __metac_line_no, $source.items[$idx]);");
                        emit_line($out, $indent + 2, "}");
                        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_res.value;");
                    } else {
                        compile_error("map(...) mapper '$mapper_name' must return number or number | error");
                    }
                }
                emit_line($out, $indent, "}");

                emit_line($out, $indent, "NumberList $stmt->{name};");
                emit_line($out, $indent, "$stmt->{name}.count = $count;");
                emit_line($out, $indent, "$stmt->{name}.items = $out_items;");

                declare_var(
                    $ctx,
                    $stmt->{name},
                    {
                        type      => 'number_list',
                        immutable => 1,
                        c_name    => $stmt->{name},
                    }
                );
                if (expr_is_stable_for_facts($expr->{recv}, $ctx)) {
                    my $recv_key = expr_fact_key($expr->{recv}, $ctx);
                    my $known_len = lookup_list_len_fact($ctx, $recv_key);
                    if (defined $known_len) {
                        my $new_key = expr_fact_key({ kind => 'ident', name => $stmt->{name} }, $ctx);
                        set_list_len_fact($ctx, $new_key, $known_len);
                    }
                }
                next;
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
                next;
            }

            compile_error("Unsupported try expression in const assignment");
        }

        if ($stmt->{kind} eq 'const_try_chain') {
            compile_error("try-chain with '?' is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

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
            next;
        }

        if ($stmt->{kind} eq 'destructure_split_or') {
            compile_error("split ... or handler is currently only supported in number | error functions")
              if $current_fn_return ne 'number_or_error';

            my ($src_code, $src_type) = compile_expr($stmt->{source_expr}, $ctx);
            my ($delim_code, $delim_type) = compile_expr($stmt->{delim_expr}, $ctx);
            compile_error("split source must be string") if $src_type ne 'string';
            compile_error("split delimiter must be string") if $delim_type ne 'string';

            my $expected = scalar @{ $stmt->{vars} };
            my $tmp = '__metac_split' . $ctx->{tmp_counter}++;
            my $handler_err = '__metac_handler_err' . $ctx->{tmp_counter}++;

            emit_line($out, $indent, "ResultStringList $tmp = metac_split_string($src_code, $delim_code);");
            emit_line($out, $indent, "if ($tmp.is_error || $tmp.value.count != (size_t)$expected) {");
            emit_line($out, $indent + 2, "const char *$handler_err = $tmp.is_error ? $tmp.message : \"Split arity mismatch\";");
            new_scope($ctx);
            declare_var($ctx, $stmt->{err_name}, { type => 'string', immutable => 1, c_name => $handler_err });
            compile_block($stmt->{handler}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent + 2, "return err_number($handler_err, __metac_line_no, \"\");");
            emit_line($out, $indent, "}");

            for (my $i = 0; $i < $expected; $i++) {
                my $name = $stmt->{vars}[$i];
                emit_line($out, $indent, "const char *$name = $tmp.value.items[$i];");
                declare_var($ctx, $name, { type => 'string', immutable => 1, c_name => $name });
            }
            next;
        }

        if ($stmt->{kind} eq 'destructure_list') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Destructuring assignment requires list expression, got $expr_type")
              if $expr_type ne 'string_list' && $expr_type ne 'number_list';

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
            } else {
                emit_line($out, $indent, "NumberList $tmp = $expr_code;");
                for (my $i = 0; $i < @{ $stmt->{vars} }; $i++) {
                    my $name = $stmt->{vars}[$i];
                    emit_line($out, $indent, "const int64_t $name = $tmp.items[$i];");
                    declare_var($ctx, $name, { type => 'number', immutable => 1, c_name => $name });
                }
            }
            next;
        }

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
            next;
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
              if $expr_type ne $stmt->{type};

            my $target = $info->{c_name};
            if ($stmt->{type} eq 'number') {
                my $constraints = $stmt->{constraints} // parse_constraints(undef);
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if (defined $constraints->{range} && !$constraints->{wrap}) {
                        compile_error("typed assignment range($constraints->{range}{min},$constraints->{range}{max}) violation for '$stmt->{name}'")
                          if $v < $constraints->{range}{min} || $v > $constraints->{range}{max};
                    }
                    compile_error("Typed assignment for '$stmt->{name}' requires positive value")
                      if $constraints->{positive} && $v <= 0;
                    compile_error("Typed assignment for '$stmt->{name}' requires negative value")
                      if $constraints->{negative} && $v >= 0;
                }

                my $rhs = $expr_code;
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $rhs = "metac_wrap_range($rhs, $constraints->{range}{min}, $constraints->{range}{max})";
                }
                emit_line($out, $indent, "$target = $rhs;");
            } elsif ($stmt->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
            } elsif ($stmt->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } else {
                compile_error("Unsupported typed assignment type: $stmt->{type}");
            }
            next;
        }

        if ($stmt->{kind} eq 'assign') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Assign to undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'") if $info->{immutable};
            my $target = $info->{c_name};

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Type mismatch in assignment to '$stmt->{name}': expected $info->{type}, got $expr_type")
              if $expr_type ne $info->{type};

            if ($info->{type} eq 'number') {
                my $constraints = $info->{constraints} // parse_constraints(undef);
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($expr_code, $constraints->{range}{min}, $constraints->{range}{max});");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
            } elsif ($info->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($info->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
            } else {
                compile_error("Unsupported assignment target type for '$stmt->{name}': $info->{type}");
            }
            next;
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
                compile_error("'+=' requires numeric expression for '$stmt->{name}'")
                  if $expr_type ne 'number';

                my $combined = "($target + $expr_code)";
                my $constraints = $info->{constraints} // parse_constraints(undef);
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($combined, $constraints->{range}{min}, $constraints->{range}{max});");
                } else {
                    emit_line($out, $indent, "$target = $combined;");
                }
                next;
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
            if (defined $constraints->{range} && $constraints->{wrap}) {
                emit_line($out, $indent,
                    "$target = metac_wrap_range($combined, $constraints->{range}{min}, $constraints->{range}{max});");
            } else {
                emit_line($out, $indent, "$target = $combined;");
            }
            next;
        }

        if ($stmt->{kind} eq 'for_lines') {
            emit_line($out, $indent, '{');
            emit_line($out, $indent + 2, 'char ' . $stmt->{var} . '[512];');
            emit_line($out, $indent + 2, "while (fgets($stmt->{var}, sizeof($stmt->{var}), stdin) != NULL) {");
            emit_line($out, $indent + 4, '__metac_line_no++;');

            new_scope($ctx);
            declare_var($ctx, $stmt->{var}, { type => 'string', immutable => 1 });
            compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
            pop_scope($ctx);

            emit_line($out, $indent + 2, '}');
            emit_line($out, $indent + 2,
                'if (ferror(stdin)) { return err_number("I/O read failure", __metac_line_no, ""); }');
            emit_line($out, $indent, '}');
            next;
        }

        if ($stmt->{kind} eq 'for_each') {
            my $iter = $stmt->{iterable};

            if ($iter->{kind} eq 'var') {
                my $container = lookup_var($ctx, $iter->{name});
                compile_error("Unknown iterable variable '$iter->{name}'") if !defined $container;
                compile_error("Unsupported iterable variable type '$container->{type}' for '$iter->{name}'")
                  if $container->{type} ne 'string_list';

                my $idx_name = '__metac_i' . $ctx->{tmp_counter}++;
                my $container_c = $container->{c_name};

                emit_line($out, $indent, "for (size_t $idx_name = 0; $idx_name < $container_c.count; $idx_name++) {");
                new_scope($ctx);
                emit_line($out, $indent + 2, "const char *$stmt->{var} = $container_c.items[$idx_name];");
                declare_var($ctx, $stmt->{var}, { type => 'string', immutable => 1, c_name => $stmt->{var} });
                compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent, "}");
                next;
            }

            if ($iter->{kind} eq 'seq') {
                my ($start_code, $start_type) = compile_expr($iter->{start}, $ctx);
                my ($end_code, $end_type) = compile_expr($iter->{end}, $ctx);
                my $start_var = '__metac_seq_start' . $ctx->{tmp_counter}++;
                my $end_var = '__metac_seq_end' . $ctx->{tmp_counter}++;
                my $idx_var = '__metac_seq_i' . $ctx->{tmp_counter}++;

                compile_error("seq start must be number, got $start_type")
                  if $start_type ne 'number';
                compile_error("seq end must be number, got $end_type")
                  if $end_type ne 'number';

                emit_line($out, $indent, "int64_t $start_var = $start_code;");
                emit_line($out, $indent, "int64_t $end_var = $end_code;");

                emit_line($out, $indent, "if ($start_var <= $end_var) {");
                emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var <= $end_var; $idx_var++) {");
                new_scope($ctx);
                emit_line($out, $indent + 4, "const int64_t $stmt->{var} = $idx_var;");
                declare_var($ctx, $stmt->{var}, { type => 'number', immutable => 1, c_name => $stmt->{var} });
                compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent + 2, "}");
                emit_line($out, $indent, "} else {");
                emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var >= $end_var; $idx_var--) {");
                new_scope($ctx);
                emit_line($out, $indent + 4, "const int64_t $stmt->{var} = $idx_var;");
                declare_var($ctx, $stmt->{var}, { type => 'number', immutable => 1, c_name => $stmt->{var} });
                compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent + 2, "}");
                emit_line($out, $indent, "}");
                next;
            }

            compile_error("Unsupported iterable kind in for-loop: $iter->{kind}");
        }

        if ($stmt->{kind} eq 'while') {
            enforce_condition_diagnostics($stmt->{cond}, $ctx, "while condition");
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("while condition must evaluate to bool, got $cond_type")
              if $cond_type ne 'bool';

            emit_line($out, $indent, "while ($cond_code) {");
            new_scope($ctx);
            compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');
            next;
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
            next;
        }

        if ($stmt->{kind} eq 'if') {
            my $size_check = size_check_from_condition($stmt->{cond}, $ctx);
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("if condition must evaluate to bool, got $cond_type") if $cond_type ne 'bool';

            emit_line($out, $indent, "if ($cond_code) {");
            new_scope($ctx);
            if (defined $size_check && $size_check->{op} eq '==') {
                set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
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
            next;
        }

        if ($stmt->{kind} eq 'return') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($current_fn_return eq 'number_or_error') {
                if ($expr_type eq 'number') {
                    emit_line($out, $indent, "return ok_number($expr_code);");
                } elsif ($expr_type eq 'error') {
                    emit_line($out, $indent, "return $expr_code;");
                } else {
                    compile_error("return type mismatch: expected number or error for number|error function");
                }
            } elsif ($current_fn_return eq 'number') {
                compile_error("return type mismatch: expected number return")
                  if $expr_type ne 'number';
                emit_line($out, $indent, "return $expr_code;");
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                emit_line($out, $indent, "return $expr_code;");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            next;
        }

        if ($stmt->{kind} eq 'raw') {
            compile_error("Unsupported statement in day1 subset: $stmt->{text}");
        }

        compile_error("Unsupported statement kind: $stmt->{kind}");
    }
}


sub compile_main_body {
    my ($main_fn, $number_error_functions) = @_;
    my $body = join "\n", @{ $main_fn->{body_lines} };

    my ($result_fmt, $callee, $err_var) =
      $body =~ /printf\(\s*(\"(?:\\.|[^\"\\])*\")\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s+or\s+\(([A-Za-z_][A-Za-z0-9_]*)\)\s*=>\s*\{/m;
    compile_error("main must include: printf(<fmt>, <fn>() or (<e>) => { ... })")
      if !defined $callee;

    compile_error("Function '$callee' is not available as number | error")
      if !exists $number_error_functions->{$callee};

    my ($error_fmt) =
      $body =~ /printf\(\s*(\"(?:\\.|[^\"\\])*\")\s*,\s*\Q$err_var\E\.message\s*\)/m;
    compile_error("main error handler must print $err_var.message")
      if !defined $error_fmt;

    my $widened_result_fmt = $result_fmt;
    $widened_result_fmt =~ s/(?<!%)%d/%lld/g;
    $widened_result_fmt =~ s/(?<!%)%i/%lli/g;

    my $c = "int main(void) {\n";
    $c .= "  ResultNumber result = $callee();\n";
    $c .= "  if (result.is_error) {\n";
    $c .= "    printf($error_fmt, result.message);\n";
    $c .= "    return 1;\n";
    $c .= "  }\n";
    $c .= "  printf($widened_result_fmt, (long long)result.value);\n";
    $c .= "  return 0;\n";
    $c .= "}\n";
    return $c;
}


sub emit_param_bindings {
    my ($params, $ctx, $out, $indent, $return_mode) = @_;

    for my $param (@$params) {
        my $name = $param->{name};
        my $in_name = $param->{c_in_name};
        my $constraints = $param->{constraints};

        if ($param->{type} eq 'number') {
            my $expr = $in_name;
            if (defined $constraints->{range} && $constraints->{wrap}) {
                $expr = "metac_wrap_range($expr, $constraints->{range}{min}, $constraints->{range}{max})";
            }
            emit_line($out, $indent, "const int64_t $name = $expr;");
            declare_var(
                $ctx,
                $name,
                {
                    type        => 'number',
                    immutable   => 1,
                    c_name      => $name,
                    constraints => $constraints,
                }
            );
            next;
        }

        if ($param->{type} eq 'bool') {
            emit_line($out, $indent, "const int $name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'bool',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if ($param->{type} eq 'string') {
            emit_line($out, $indent, "const char *$name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'string',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        compile_error("Unsupported parameter type binding: $param->{type}");
    }
}


sub compile_number_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number | error")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number | error';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultNumber $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number_or_error');
    compile_block($stmts, $ctx, \@out, 2, 'number_or_error');
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_number($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    return join("\n", @out) . "\n";
}


sub compile_number_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static int64_t $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number');
    compile_block($stmts, $ctx, \@out, 2, 'number');
    push @out, '  return 0;';
    push @out, '}';
    return join("\n", @out) . "\n";
}


sub compile_bool_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: bool")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'bool';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static int $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'bool');
    compile_block($stmts, $ctx, \@out, 2, 'bool');
    push @out, '  return 0;';
    push @out, '}';
    return join("\n", @out) . "\n";
}


sub emit_function_prototypes {
    my ($ordered_names, $functions) = @_;
    my @out;

    for my $name (@$ordered_names) {
        my $fn = $functions->{$name};
        my $params = $fn->{parsed_params};
        my $sig_params = render_c_params($params);

        if ($fn->{return_type} eq 'number | error') {
            push @out, "static ResultNumber $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'number') {
            push @out, "static int64_t $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'bool') {
            push @out, "static int $name($sig_params);";
            next;
        }
        compile_error("Unsupported function return type for '$name': $fn->{return_type}");
    }

    return join("\n", @out) . "\n";
}


sub runtime_prelude {
    return <<'C_RUNTIME';
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <regex.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int is_error;
  int64_t value;
  char message[160];
} ResultNumber;

typedef struct {
  size_t count;
  char **items;
} StringList;

typedef struct {
  size_t count;
  int64_t *items;
} NumberList;

typedef struct {
  int is_error;
  StringList value;
  char message[160];
} ResultStringList;

static ResultNumber ok_number(int64_t value) {
  ResultNumber out;
  out.is_error = 0;
  out.value = value;
  out.message[0] = '\0';
  return out;
}

static ResultNumber err_number(const char *message, int line_no, const char *line_text) {
  ResultNumber out;
  out.is_error = 1;
  out.value = 0;
  snprintf(out.message, sizeof(out.message), "%s (line %d: %s)", message, line_no, line_text);
  return out;
}

static const char *metac_fmt(const char *fmt, ...) {
  static char out[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(out, sizeof(out), fmt, ap);
  va_end(ap);
  return out;
}

static char *metac_strdup_local(const char *s) {
  size_t n = strlen(s);
  char *out = (char *)malloc(n + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, s, n + 1);
  return out;
}

static char *metac_read_all_stdin(void) {
  size_t cap = 4096;
  size_t len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) {
    return NULL;
  }

  int ch = 0;
  while ((ch = fgetc(stdin)) != EOF) {
    if (len + 1 >= cap) {
      size_t next = cap * 2;
      char *grown = (char *)realloc(buf, next);
      if (grown == NULL) {
        free(buf);
        return NULL;
      }
      buf = grown;
      cap = next;
    }
    buf[len++] = (char)ch;
  }
  buf[len] = '\0';
  return buf;
}

static int64_t metac_strlen(const char *s) {
  if (s == NULL) {
    return 0;
  }
  size_t n = strlen(s);
  if (n > (size_t)INT64_MAX) {
    return INT64_MAX;
  }
  return (int64_t)n;
}

static StringList metac_chunk_string(const char *input, int64_t chunk_size) {
  StringList out;
  out.count = 0;
  out.items = NULL;

  if (input == NULL) {
    return out;
  }

  if (chunk_size <= 0) {
    return out;
  }

  size_t len = strlen(input);
  if (len == 0) {
    return out;
  }

  size_t n = (size_t)chunk_size;
  size_t count = (len + n - 1) / n;
  char **items = (char **)calloc(count, sizeof(char *));
  if (items == NULL) {
    return out;
  }

  for (size_t i = 0; i < count; i++) {
    size_t start = i * n;
    size_t seg_len = n;
    if (start + seg_len > len) {
      seg_len = len - start;
    }
    char *tok = (char *)malloc(seg_len + 1);
    if (tok == NULL) {
      return out;
    }
    memcpy(tok, input + start, seg_len);
    tok[seg_len] = '\0';
    items[i] = tok;
  }

  out.count = count;
  out.items = items;
  return out;
}

static ResultStringList metac_split_string(const char *input, const char *delim) {
  ResultStringList out;
  out.is_error = 0;
  out.value.count = 0;
  out.value.items = NULL;
  out.message[0] = '\0';

  if (input == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "split input is null");
    return out;
  }
  if (delim == NULL || delim[0] == '\0') {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "split delimiter is empty");
    return out;
  }

  size_t delim_len = strlen(delim);
  size_t count = 1;
  const char *scan = input;
  while (1) {
    const char *p = strstr(scan, delim);
    if (p == NULL) {
      break;
    }
    count++;
    scan = p + delim_len;
  }

  char **items = (char **)calloc(count, sizeof(char *));
  if (items == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "out of memory allocating split items");
    return out;
  }

  size_t idx = 0;
  const char *start = input;
  while (1) {
    const char *p = strstr(start, delim);
    size_t len = (p == NULL) ? strlen(start) : (size_t)(p - start);
    char *tok = (char *)malloc(len + 1);
    if (tok == NULL) {
      out.is_error = 1;
      snprintf(out.message, sizeof(out.message), "out of memory allocating split token");
      return out;
    }
    memcpy(tok, start, len);
    tok[len] = '\0';
    items[idx++] = tok;

    if (p == NULL) {
      break;
    }
    start = p + delim_len;
  }

  out.value.count = idx;
  out.value.items = items;
  return out;
}

static void metac_copy_str(char *dst, size_t dst_sz, const char *src) {
  if (dst_sz == 0) {
    return;
  }
  strncpy(dst, src, dst_sz - 1);
  dst[dst_sz - 1] = '\0';
}

static int metac_streq(const char *a, const char *b) {
  return strcmp(a, b) == 0;
}

static int64_t metac_max(int64_t a, int64_t b) {
  return (a > b) ? a : b;
}

static int64_t metac_min(int64_t a, int64_t b) {
  return (a < b) ? a : b;
}

static int64_t metac_wrap_range(int64_t value, int64_t min, int64_t max) {
  int64_t span = (max - min) + 1;
  int64_t shifted = value - min;
  int64_t r = shifted % span;
  if (r < 0) {
    r += span;
  }
  return min + r;
}

static int metac_parse_int(const char *text, int64_t *out) {
  char *end = NULL;
  errno = 0;
  long long value = strtoll(text, &end, 10);
  if (text[0] == '\0' || *end != '\0' || errno == ERANGE) {
    return 0;
  }
  *out = (int64_t)value;
  return 1;
}

static void metac_rstrip_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
    s[len - 1] = '\0';
    len--;
  }
}

static int metac_match_groups(
    const char *input,
    const char *pattern,
    int expected_groups,
    char **outs,
    size_t out_cap,
    char *err,
    size_t err_sz) {
  regex_t re;
  regmatch_t matches[16];
  char anchored[512];
  char line[512];

  if (expected_groups <= 0 || expected_groups > 15) {
    snprintf(err, err_sz, "Unsupported capture count");
    return 0;
  }

  snprintf(anchored, sizeof(anchored), "^%s$", pattern);
  metac_copy_str(line, sizeof(line), input);
  metac_rstrip_newline(line);

  if (regcomp(&re, anchored, REG_EXTENDED) != 0) {
    snprintf(err, err_sz, "Invalid regex pattern");
    return 0;
  }

  int rc = regexec(&re, line, (size_t)expected_groups + 1, matches, 0);
  if (rc != 0) {
    regfree(&re);
    snprintf(err, err_sz, "Pattern match failed");
    return 0;
  }

  for (int i = 0; i < expected_groups; i++) {
    regmatch_t m = matches[i + 1];
    if (m.rm_so < 0 || m.rm_eo < m.rm_so) {
      regfree(&re);
      snprintf(err, err_sz, "Missing capture group");
      return 0;
    }

    size_t len = (size_t)(m.rm_eo - m.rm_so);
    if (len >= out_cap) {
      regfree(&re);
      snprintf(err, err_sz, "Capture too long");
      return 0;
    }

    memcpy(outs[i], line + m.rm_so, len);
    outs[i][len] = '\0';
  }

  regfree(&re);
  return 1;
}
C_RUNTIME
}


sub compile_source {
    my ($source) = @_;
    my $functions = collect_functions($source);

    compile_error("Missing required function: main") if !exists $functions->{main};

    my $main = $functions->{main};
    compile_error("main must not declare arguments in this subset") if $main->{args} ne '';

    my %number_error_functions;
    my %number_functions;
    my %bool_functions;
    my %function_sigs;
    my @ordered_names = sort grep { $_ ne 'main' } keys %$functions;
    for my $name (@ordered_names) {
        my $fn = $functions->{$name};
        if (defined $fn->{return_type}) {
            my $rt = $fn->{return_type};
            $rt = 'bool' if $rt eq 'boolean';
            $rt = 'number | error' if $rt =~ /^number\s*\|\s*error$/;
            $fn->{return_type} = $rt;
        }
        $fn->{parsed_params} = parse_function_params($fn);
        $function_sigs{$name} = {
            return_type => $fn->{return_type},
            params      => $fn->{parsed_params},
        };

        if (defined $fn->{return_type} && $fn->{return_type} eq 'number | error') {
            $number_error_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && $fn->{return_type} eq 'number') {
            $number_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && $fn->{return_type} eq 'bool') {
            $bool_functions{$name} = 1;
            next;
        }
        compile_error("Unsupported function return type for '$name'; supported: number | error, number, bool");
    }

    my $c = runtime_prelude();
    $c .= "\n";
    $c .= emit_function_prototypes(\@ordered_names, $functions);
    $c .= "\n\n";
    for my $name (@ordered_names) {
        if ($number_error_functions{$name}) {
            $c .= compile_number_or_error_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $c .= "\n";
            next;
        }
        if ($number_functions{$name}) {
            $c .= compile_number_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $c .= "\n";
            next;
        }
        if ($bool_functions{$name}) {
            $c .= compile_bool_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $c .= "\n";
            next;
        }
        compile_error("Internal: unclassified function '$name'");
    }
    $c .= compile_main_body($main, \%number_error_functions);
    return $c;
}


1;
