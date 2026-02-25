package MetaC::Codegen;
use strict;
use warnings;

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
        return 1
          if $stmt->{kind} eq 'return'
          || $stmt->{kind} eq 'continue'
          || $stmt->{kind} eq 'break'
          || $stmt->{kind} eq 'rewind';
        if ($stmt->{kind} eq 'if' && defined $stmt->{else_body}) {
            my $then_returns = block_definitely_returns($stmt->{then_body});
            my $else_returns = block_definitely_returns($stmt->{else_body});
            return 1 if $then_returns && $else_returns;
        }
    }
    return 0;
}

sub loop_body_uses_rewind_current_loop {
    my ($stmts) = @_;
    for my $stmt (@$stmts) {
        my $kind = $stmt->{kind};
        return 1 if $kind eq 'rewind';

        if ($kind eq 'if') {
            return 1 if loop_body_uses_rewind_current_loop($stmt->{then_body});
            if (defined $stmt->{else_body}) {
                return 1 if loop_body_uses_rewind_current_loop($stmt->{else_body});
            }
            next;
        }

        if ($kind eq 'let_producer') {
            return 1 if loop_body_uses_rewind_current_loop($stmt->{body});
            next;
        }

        if ($kind eq 'destructure_split_or') {
            return 1 if loop_body_uses_rewind_current_loop($stmt->{handler});
            next;
        }

        if ($kind eq 'const_or_catch' || $kind eq 'expr_or_catch') {
            return 1 if loop_body_uses_rewind_current_loop($stmt->{handler});
            next;
        }
    }
    return 0;
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
        return 0 if $expr->{method} ne 'size' && $expr->{method} ne 'chunk' && $expr->{method} ne 'chars';
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


sub emit_size_constraint_check {
    my (%args) = @_;
    my $constraints = $args{constraints};
    return if !defined $constraints;
    return if constraint_size_is_wildcard($constraints);
    my $size = constraint_size_exact($constraints);
    return if !defined $size;

    my $target_expr = $args{target_expr};
    my $target_type = $args{target_type};
    my $out = $args{out};
    my $indent = $args{indent};
    my $where = $args{where} // 'value';
    my $ctx = $args{ctx};
    $size = int($size);

    my $actual_expr;
    if ($target_type eq 'string') {
        $actual_expr = "metac_strlen($target_expr)";
    } elsif ($target_type eq 'number_list'
        || $target_type eq 'number_list_list'
        || $target_type eq 'string_list'
        || $target_type eq 'bool_list'
        || $target_type eq 'indexed_number_list'
        || is_array_type($target_type))
    {
        $actual_expr = "((int64_t)$target_expr.count)";
    } else {
        compile_error("size(...) constraint is unsupported for runtime check on type '$target_type' in $where");
    }

    my $message = c_escape_string("size($size) constraint failed for $where");
    emit_line($out, $indent, "if ($actual_expr != $size) {");
    if (defined $ctx->{active_temp_cleanups}) {
        for (my $i = $#{ $ctx->{active_temp_cleanups} }; $i >= 0; $i--) {
            emit_line($out, $indent + 2, $ctx->{active_temp_cleanups}[$i] . ';');
        }
    }
    emit_all_owned_cleanups($ctx, $out, $indent + 2) if defined $ctx;
    emit_line($out, $indent + 2, "fprintf(stderr, \"%s\\n\", $message);");
    emit_line($out, $indent + 2, 'exit(2);');
    emit_line($out, $indent, '}');
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
    return undef if $target_type ne 'string_list' && $target_type ne 'number_list' && $target_type ne 'number_list_list' && $target_type ne 'bool_list' && $target_type ne 'indexed_number_list';

    return {
        key => expr_fact_key($target_expr, $ctx),
        len => int($num_expr->{value}),
        op  => $cond->{op},
    };
}


sub nullable_number_check_from_condition {
    my ($cond, $ctx) = @_;
    return undef if $cond->{kind} ne 'binop';
    return undef if $cond->{op} ne '==' && $cond->{op} ne '!=';

    my $var_name;
    if ($cond->{left}{kind} eq 'ident' && $cond->{right}{kind} eq 'null') {
        $var_name = $cond->{left}{name};
    } elsif ($cond->{right}{kind} eq 'ident' && $cond->{left}{kind} eq 'null') {
        $var_name = $cond->{right}{name};
    } else {
        return undef;
    }

    my $info = lookup_var($ctx, $var_name);
    return undef if !defined $info;
    return undef if $info->{type} ne 'number_or_null';

    return {
        name => $var_name,
        op   => $cond->{op},
    };
}


sub declare_not_null_number_shadow {
    my ($ctx, $name) = @_;
    my $info = lookup_var($ctx, $name);
    return if !defined $info;
    return if $info->{type} ne 'number_or_null';

    declare_var(
        $ctx,
        $name,
        {
            type        => 'number',
            immutable   => $info->{immutable},
            c_name      => "($info->{c_name}).value",
            constraints => $info->{constraints},
        }
    );
}


sub nullable_number_non_null_on_false_expr {
    my ($expr, $ctx) = @_;
    my $check = nullable_number_check_from_condition($expr, $ctx);
    return undef if !defined $check;
    return undef if $check->{op} ne '==';
    return $check->{name};
}

sub nullable_number_non_null_on_true_expr {
    my ($expr, $ctx) = @_;
    my $check = nullable_number_check_from_condition($expr, $ctx);
    return undef if !defined $check;
    return undef if $check->{op} ne '!=';
    return $check->{name};
}


sub nullable_number_names_non_null_on_false_expr {
    my ($expr, $ctx) = @_;
    my @names;

    if ($expr->{kind} eq 'binop' && $expr->{op} eq '||') {
        my $left = nullable_number_names_non_null_on_false_expr($expr->{left}, $ctx);
        my $right = nullable_number_names_non_null_on_false_expr($expr->{right}, $ctx);
        push @names, @$left, @$right;
        return \@names;
    }

    my $single = nullable_number_non_null_on_false_expr($expr, $ctx);
    push @names, $single if defined $single;
    return \@names;
}


sub nullable_number_names_non_null_on_true_expr {
    my ($expr, $ctx) = @_;
    my @names;

    if ($expr->{kind} eq 'binop' && $expr->{op} eq '&&') {
        my $left = nullable_number_names_non_null_on_true_expr($expr->{left}, $ctx);
        my $right = nullable_number_names_non_null_on_true_expr($expr->{right}, $ctx);
        push @names, @$left, @$right;
        return \@names;
    }

    my $single = nullable_number_non_null_on_true_expr($expr, $ctx);
    push @names, $single if defined $single;
    return \@names;
}

sub union_member_check_from_condition {
    my ($cond, $ctx) = @_;
    return undef if $cond->{kind} ne 'binop';
    return undef if $cond->{op} ne '==' && $cond->{op} ne '!=';

    my ($ident, $literal) = ($cond->{left}, $cond->{right});
    if ($ident->{kind} ne 'ident') {
        ($ident, $literal) = ($cond->{right}, $cond->{left});
    }
    return undef if $ident->{kind} ne 'ident';

    my $member;
    if ($literal->{kind} eq 'num') {
        $member = 'number';
    } elsif ($literal->{kind} eq 'bool') {
        $member = 'bool';
    } elsif ($literal->{kind} eq 'str') {
        $member = 'string';
    } elsif ($literal->{kind} eq 'null') {
        $member = 'null';
    } else {
        return undef;
    }

    my $info = lookup_var($ctx, $ident->{name});
    return undef if !defined $info;
    return undef if !is_supported_generic_union_return($info->{type});
    return undef if $info->{type} eq 'number_or_null';
    return undef if !union_contains_member($info->{type}, $member);

    return {
        name   => $ident->{name},
        member => $member,
        op     => $cond->{op},
    };
}

sub declare_union_member_shadow {
    my ($ctx, $name, $member) = @_;
    my $info = lookup_var($ctx, $name);
    return if !defined $info;
    return if !is_supported_generic_union_return($info->{type});
    return if $info->{type} eq 'number_or_null';
    return if !union_contains_member($info->{type}, $member);

    my $c_name = $info->{c_name};
    my %shadow = (
        immutable => $info->{immutable},
    );
    if ($member eq 'number') {
        $shadow{type} = 'number';
        $shadow{c_name} = "($c_name.number_value)";
    } elsif ($member eq 'bool') {
        $shadow{type} = 'bool';
        $shadow{c_name} = "($c_name.bool_value)";
    } elsif ($member eq 'string') {
        $shadow{type} = 'string';
        $shadow{c_name} = "($c_name.string_value)";
    } elsif ($member eq 'null') {
        $shadow{type} = 'null';
        $shadow{c_name} = 'metac_null_number()';
    } else {
        return;
    }

    declare_var($ctx, $name, \%shadow);
}

sub union_member_binding_on_true_expr {
    my ($expr, $ctx) = @_;
    my $check = union_member_check_from_condition($expr, $ctx);
    return undef if !defined $check;
    return undef if $check->{op} ne '==';
    return {
        name   => $check->{name},
        member => $check->{member},
    };
}

sub union_member_binding_on_false_expr {
    my ($expr, $ctx) = @_;
    my $check = union_member_check_from_condition($expr, $ctx);
    return undef if !defined $check;
    return undef if $check->{op} ne '!=';
    return {
        name   => $check->{name},
        member => $check->{member},
    };
}

sub union_member_bindings_on_true_expr {
    my ($expr, $ctx) = @_;
    my @bindings;

    if ($expr->{kind} eq 'binop' && $expr->{op} eq '&&') {
        my $left = union_member_bindings_on_true_expr($expr->{left}, $ctx);
        my $right = union_member_bindings_on_true_expr($expr->{right}, $ctx);
        push @bindings, @$left, @$right;
        return \@bindings;
    }

    my $single = union_member_binding_on_true_expr($expr, $ctx);
    push @bindings, $single if defined $single;
    return \@bindings;
}

sub union_member_bindings_on_false_expr {
    my ($expr, $ctx) = @_;
    my @bindings;

    if ($expr->{kind} eq 'binop' && $expr->{op} eq '||') {
        my $left = union_member_bindings_on_false_expr($expr->{left}, $ctx);
        my $right = union_member_bindings_on_false_expr($expr->{right}, $ctx);
        push @bindings, @$left, @$right;
        return \@bindings;
    }

    my $single = union_member_binding_on_false_expr($expr, $ctx);
    push @bindings, $single if defined $single;
    return \@bindings;
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

    while ($raw =~ /\$\{([^{}]*)\}/g) {
        my $expr_raw = trim($1);
        compile_error("Empty interpolation expression in template")
          if $expr_raw eq '';
        my $start = $-[0];
        my $end = $+[0];

        my $literal = substr($raw, $pos, $start - $pos);
        $literal =~ s/%/%%/g;
        $fmt .= $literal;

        my $expr = parse_expr($expr_raw);
        my ($expr_code, $expr_type) = compile_expr($expr, $ctx);
        if ($expr_type eq 'string') {
            $fmt .= '%s';
            push @args, $expr_code;
        } elsif (is_number_like_type($expr_type)) {
            $fmt .= '%lld';
            my $num = number_like_to_c_expr($expr_code, $expr_type, "Template interpolation");
            push @args, "(long long)$num";
        } elsif ($expr_type eq 'bool') {
            $fmt .= '%d';
            push @args, $expr_code;
        } elsif ($expr_type eq 'number_list') {
            $fmt .= '%s';
            push @args, "metac_fmt_number_list($expr_code)";
        } else {
            compile_error("Unsupported interpolation expression type: $expr_type");
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


sub compile_list_literal_expr {
    my ($expr, $ctx) = @_;
    my @items = @{ $expr->{items} // [] };
    return ('0', 'empty_list') if !@items;

    my @item_code;
    my $kind;
    for my $item (@items) {
        my ($code, $type) = compile_expr($item, $ctx);
        if (is_number_like_type($type)) {
            my $num = number_like_to_c_expr($code, $type, "List literal");
            push @item_code, $num;
            if (!defined $kind) {
                $kind = 'number';
            } elsif ($kind ne 'number') {
                compile_error("List literal items must share the same type category");
            }
            next;
        }
        if ($type eq 'string') {
            push @item_code, $code;
            if (!defined $kind) {
                $kind = 'string';
            } elsif ($kind ne 'string') {
                compile_error("List literal items must share the same type category");
            }
            next;
        }
        if ($type eq 'bool') {
            push @item_code, $code;
            if (!defined $kind) {
                $kind = 'bool';
            } elsif ($kind ne 'bool') {
                compile_error("List literal items must share the same type category");
            }
            next;
        }
        compile_error("Unsupported list literal item type: $type");
    }

    my $count = scalar @item_code;
    if ($kind eq 'number') {
        return (
            "metac_number_list_from_array((int64_t[]){ " . join(', ', @item_code) . " }, $count)",
            'number_list'
        );
    }
    if ($kind eq 'bool') {
        return (
            "metac_bool_list_from_array((int[]){ " . join(', ', @item_code) . " }, $count)",
            'bool_list'
        );
    }
    return (
        "metac_string_list_from_array((const char *[]){ " . join(', ', @item_code) . " }, $count)",
        'string_list'
    );
}



1;
