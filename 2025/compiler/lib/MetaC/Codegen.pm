package MetaC::Codegen;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error c_escape_string parse_constraints emit_line trim);
use MetaC::Parser qw(collect_functions parse_function_params parse_capture_groups infer_group_type parse_function_body parse_expr);
use MetaC::CodegenType qw(
    param_c_type
    render_c_params
    is_number_like_type
    number_like_to_c_expr
    type_matches_expected
    number_or_null_to_c_expr
);
use MetaC::CodegenScope qw(
    new_scope
    pop_scope
    lookup_var
    declare_var
    set_list_len_fact
    lookup_list_len_fact
    set_nonnull_fact_by_c_name
    clear_nonnull_fact_by_c_name
    has_nonnull_fact_by_c_name
    set_nonnull_fact_for_var_name
    clear_nonnull_fact_for_var_name
);
use MetaC::CodegenRuntime qw(runtime_prelude_for_code);

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
    return undef if $target_type ne 'string_list' && $target_type ne 'number_list' && $target_type ne 'indexed_number_list';

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


sub method_specs {
    return {
        size => {
            receivers     => { string => 1, string_list => 1, number_list => 1, indexed_number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        chunk => {
            receivers     => { string => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        chars => {
            receivers     => { string => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        slice => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        max => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        sort => {
            receivers     => { number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        index => {
            receivers     => { indexed_number => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        log => {
            receivers     => {
                string         => 1,
                number         => 1,
                bool           => 1,
                indexed_number => 1,
                string_list    => 1,
                number_list    => 1,
                indexed_number_list => 1,
            },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        map => {
            receivers     => { string_list => 1 },
            arity         => 1,
            expr_callable => 0,
            fallibility   => 'mapper',
        },
        filter => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 1,
            expr_callable => 0,
            fallibility   => 'never',
        },
        reduce => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 2,
            expr_callable => 1,
            fallibility   => 'never',
        },
        assert => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 2,
            expr_callable => 0,
            fallibility   => 'always',
        },
        push => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
    };
}


sub map_mapper_info {
    my ($expr, $ctx) = @_;
    my $actual = scalar @{ $expr->{args} };
    compile_error("map(...) expects exactly 1 function arg, got $actual")
      if $actual != 1;

    my $mapper = $expr->{args}[0];
    compile_error("map(...) expects function identifier argument")
      if $mapper->{kind} ne 'ident';
    my $mapper_name = $mapper->{name};

    if ($mapper_name eq 'parseNumber') {
        return {
            name        => $mapper_name,
            return_mode => 'number_or_error',
            builtin     => 1,
        };
    }

    my $functions = $ctx->{functions} // {};
    my $sig = $functions->{$mapper_name};
    compile_error("Unknown mapper function '$mapper_name' in map(...)")
      if !defined $sig;
    my $expected = scalar @{ $sig->{params} };
    compile_error("map(...) mapper '$mapper_name' must accept exactly 1 arg")
      if $expected != 1;
    compile_error("map(...) mapper '$mapper_name' arg type must be string")
      if $sig->{params}[0]{type} ne 'string';

    if ($sig->{return_type} eq 'number') {
        return {
            name        => $mapper_name,
            return_mode => 'number',
            builtin     => 0,
        };
    }
    if ($sig->{return_type} eq 'number | error') {
        return {
            name        => $mapper_name,
            return_mode => 'number_or_error',
            builtin     => 0,
        };
    }

    compile_error("map(...) mapper '$mapper_name' must return number or number | error");
}


sub method_fallibility_diagnostic {
    my ($expr, $recv_type, $ctx) = @_;
    my $method = $expr->{method};
    my $spec = method_specs()->{$method};
    return undef if !defined $spec;
    return undef if !exists $spec->{receivers}{$recv_type};

    if ($spec->{fallibility} eq 'always') {
        return "Method '$method(...)' is fallible; handle it with '?' (or an explicit error handler)";
    }
    if ($spec->{fallibility} eq 'mapper') {
        my $mapper = map_mapper_info($expr, $ctx);
        if ($mapper->{return_mode} eq 'number_or_error') {
            return "Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)";
        }
    }
    return undef;
}


sub propagate_list_len_fact_from_recv {
    my ($recv_expr, $target_name, $ctx) = @_;
    return if !expr_is_stable_for_facts($recv_expr, $ctx);
    my $recv_key = expr_fact_key($recv_expr, $ctx);
    my $known_len = lookup_list_len_fact($ctx, $recv_key);
    return if !defined $known_len;
    my $new_key = expr_fact_key({ kind => 'ident', name => $target_name }, $ctx);
    set_list_len_fact($ctx, $new_key, $known_len);
}


sub emit_map_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $propagate_errors = $args{propagate_errors} ? 1 : 0;

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("map(...) receiver must be string_list, got $recv_type")
      if $recv_type ne 'string_list';

    my $mapper = map_mapper_info($expr, $ctx);
    if (!$propagate_errors && $mapper->{return_mode} eq 'number_or_error') {
        compile_error("Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)");
    }

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
    if ($propagate_errors) {
        emit_line($out, $indent + 2, "return err_number(\"out of memory in map\", __metac_line_no, \"\");");
    } else {
        emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in map\\n\");");
        emit_line($out, $indent + 2, "exit(1);");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
    if ($mapper->{builtin}) {
        emit_line($out, $indent + 2, "int64_t $tmp_num = 0;");
        emit_line($out, $indent + 2, "if (!metac_parse_int($source.items[$idx], &$tmp_num)) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 4, "return err_number(\"Invalid number\", __metac_line_no, $source.items[$idx]);");
        } else {
            emit_line($out, $indent + 4, "fprintf(stderr, \"Invalid number: %s\\n\", $source.items[$idx]);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_num;");
    } elsif ($mapper->{return_mode} eq 'number') {
        emit_line($out, $indent + 2, "${out_items}[$idx] = $mapper->{name}($source.items[$idx]);");
    } else {
        emit_line($out, $indent + 2, "ResultNumber $tmp_res = $mapper->{name}($source.items[$idx]);");
        emit_line($out, $indent + 2, "if ($tmp_res.is_error) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 4, "return err_number($tmp_res.message, __metac_line_no, $source.items[$idx]);");
        } else {
            emit_line($out, $indent + 4, "fprintf(stderr, \"%s\\n\", $tmp_res.message);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_res.value;");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "NumberList $name;");
    emit_line($out, $indent, "$name.count = $count;");
    emit_line($out, $indent, "$name.items = $out_items;");

    declare_var(
        $ctx,
        $name,
        {
            type      => 'number_list',
            immutable => 1,
            c_name    => $name,
        }
    );
    propagate_list_len_fact_from_recv($expr->{recv}, $name, $ctx);
}


sub emit_filter_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $propagate_errors = $args{propagate_errors} ? 1 : 0;

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("filter(...) receiver must be string_list or number_list, got $recv_type")
      if $recv_type ne 'string_list' && $recv_type ne 'number_list';
    my $actual = scalar @{ $expr->{args} };
    compile_error("filter(...) expects exactly 1 predicate arg")
      if $actual != 1;
    my $predicate = $expr->{args}[0];
    compile_error("filter(...) predicate must be a single-parameter lambda, e.g. x => x > 0")
      if $predicate->{kind} ne 'lambda1';

    my $source = '__metac_filter_src' . $ctx->{tmp_counter}++;
    my $count = '__metac_filter_count' . $ctx->{tmp_counter}++;
    my $idx = '__metac_filter_i' . $ctx->{tmp_counter}++;
    my $out_count = '__metac_filter_out_count' . $ctx->{tmp_counter}++;

    my $elem_type = $recv_type eq 'string_list' ? 'string' : 'number';
    my $elem_expr = $source . ".items[$idx]";
    my ($pred_code, $pred_type);
    new_scope($ctx);
    declare_var(
        $ctx,
        $predicate->{param},
        {
            type      => $elem_type,
            immutable => 1,
            c_name    => $elem_expr,
        }
    );
    ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
    pop_scope($ctx);
    compile_error("filter(...) predicate must evaluate to bool")
      if $pred_type ne 'bool';

    if ($recv_type eq 'string_list') {
        my $out_items = '__metac_filter_items' . $ctx->{tmp_counter}++;
        emit_line($out, $indent, "StringList $source = $recv_code;");
        emit_line($out, $indent, "size_t $count = $source.count;");
        emit_line($out, $indent, "char **$out_items = (char **)calloc($count == 0 ? 1 : $count, sizeof(char *));");
        emit_line($out, $indent, "if ($out_items == NULL) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 2, "return err_number(\"out of memory in filter\", __metac_line_no, \"\");");
        } else {
            emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in filter\\n\");");
            emit_line($out, $indent + 2, "exit(1);");
        }
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "size_t $out_count = 0;");
        emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
        emit_line($out, $indent + 2, "if ($pred_code) {");
        emit_line($out, $indent + 4, "${out_items}[$out_count++] = $source.items[$idx];");
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "StringList $name;");
        emit_line($out, $indent, "$name.count = $out_count;");
        emit_line($out, $indent, "$name.items = $out_items;");
    } else {
        my $out_items = '__metac_filter_items' . $ctx->{tmp_counter}++;
        emit_line($out, $indent, "NumberList $source = $recv_code;");
        emit_line($out, $indent, "size_t $count = $source.count;");
        emit_line($out, $indent, "int64_t *$out_items = (int64_t *)calloc($count == 0 ? 1 : $count, sizeof(int64_t));");
        emit_line($out, $indent, "if ($out_items == NULL) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 2, "return err_number(\"out of memory in filter\", __metac_line_no, \"\");");
        } else {
            emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in filter\\n\");");
            emit_line($out, $indent + 2, "exit(1);");
        }
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "size_t $out_count = 0;");
        emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
        emit_line($out, $indent + 2, "if ($pred_code) {");
        emit_line($out, $indent + 4, "${out_items}[$out_count++] = $source.items[$idx];");
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "NumberList $name;");
        emit_line($out, $indent, "$name.count = $out_count;");
        emit_line($out, $indent, "$name.items = $out_items;");
    }

    declare_var(
        $ctx,
        $name,
        {
            type      => $recv_type,
            immutable => 1,
            c_name    => $name,
        }
    );
}


sub compile_reduce_lambda_helper {
    my (%args) = @_;
    my $lambda = $args{lambda};
    my $recv_type = $args{recv_type};
    my $ctx = $args{ctx};

    compile_error("reduce(...) second arg must be a two-parameter lambda, e.g. (acc, item) => acc + item")
      if $lambda->{kind} ne 'lambda2';

    my $item_type = $recv_type eq 'number_list' ? 'number' : 'string';
    my $item_c_type = $item_type eq 'number' ? 'int64_t' : 'const char *';
    my $param1 = $lambda->{param1};
    my $param2 = $lambda->{param2};

    my $lambda_ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        nonnull_scopes => [ {} ],
        tmp_counter => $ctx->{tmp_counter},
        functions   => $ctx->{functions},
        loop_depth  => 0,
        helper_defs => $ctx->{helper_defs},
        helper_counter => $ctx->{helper_counter},
        current_function => $ctx->{current_function},
    };

    declare_var(
        $lambda_ctx,
        $param1,
        {
            type      => 'number',
            immutable => 1,
            c_name    => $param1,
        }
    );
    declare_var(
        $lambda_ctx,
        $param2,
        {
            type      => $item_type,
            immutable => 1,
            c_name    => $param2,
        }
    );

    my ($body_code, $body_type) = compile_expr($lambda->{body}, $lambda_ctx);
    $ctx->{helper_counter} = $lambda_ctx->{helper_counter};
    my $body_num = number_like_to_c_expr($body_code, $body_type, "reduce(...) reducer lambda");

    my $helper_counter = $ctx->{helper_counter} // 0;
    my $helper_name = '__metac_reduce_' . ($ctx->{current_function} // 'fn') . '_' . $helper_counter;
    $ctx->{helper_counter} = $helper_counter + 1;

    my @helper_lines;
    push @helper_lines, "static int64_t $helper_name(int64_t $param1, $item_c_type $param2) {";
    push @helper_lines, "  return $body_num;";
    push @helper_lines, '}';
    push @{ $ctx->{helper_defs} }, join("\n", @helper_lines);

    return $helper_name;
}


sub compile_reduce_call {
    my (%args) = @_;
    my $expr = $args{expr};
    my $ctx = $args{ctx};

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("reduce(...) receiver must be string_list or number_list, got $recv_type")
      if $recv_type ne 'string_list' && $recv_type ne 'number_list';

    my $actual = scalar @{ $expr->{args} };
    compile_error("reduce(...) expects exactly 2 args: reduce(initial, (acc, item) => expr)")
      if $actual != 2;
    $ctx->{helper_defs} = [] if !defined $ctx->{helper_defs};

    my ($init_code, $init_type) = compile_expr($expr->{args}[0], $ctx);
    my $init_num = number_like_to_c_expr($init_code, $init_type, "reduce(...) initial value");
    my $helper_name = compile_reduce_lambda_helper(
        lambda    => $expr->{args}[1],
        recv_type => $recv_type,
        ctx       => $ctx,
    );

    if ($recv_type eq 'number_list') {
        return ("metac_reduce_number_list($recv_code, $init_num, $helper_name)", 'number');
    }
    return ("metac_reduce_string_list($recv_code, $init_num, $helper_name)", 'number');
}


sub emit_loop_body_with_binding {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $current_fn_return = $args{current_fn_return};
    my $body = $args{body};
    my $var_name = $args{var_name};
    my $var_type = $args{var_type};
    my $var_c_expr = $args{var_c_expr};
    my $var_index_c_expr = $args{var_index_c_expr};
    my $range_min_expr = $args{range_min_expr};
    my $range_max_expr = $args{range_max_expr};

    new_scope($ctx);
    my %var_info = (
        type      => $var_type,
        immutable => 1,
        c_name    => $var_name,
    );
    if ($var_type eq 'number' && defined $range_min_expr && defined $range_max_expr) {
        $var_info{range_min_expr} = $range_min_expr;
        $var_info{range_max_expr} = $range_max_expr;
    }
    if (defined $var_index_c_expr) {
        $var_info{index_c_expr} = $var_index_c_expr;
    }
    if ($var_type eq 'string') {
        emit_line($out, $indent, "const char *$var_name = $var_c_expr;");
    } elsif ($var_type eq 'number') {
        emit_line($out, $indent, "const int64_t $var_name = $var_c_expr;");
    } elsif ($var_type eq 'indexed_number') {
        emit_line($out, $indent, "const IndexedNumber $var_name = $var_c_expr;");
    } else {
        compile_error("Unsupported loop element type '$var_type'");
    }
    declare_var($ctx, $var_name, \%var_info);

    my $prev_loop_depth = $ctx->{loop_depth} // 0;
    $ctx->{loop_depth} = $prev_loop_depth + 1;
    compile_block($body, $ctx, $out, $indent, $current_fn_return);
    $ctx->{loop_depth} = $prev_loop_depth;
    pop_scope($ctx);
}


sub compile_filter_predicate_codes {
    my (%args) = @_;
    my $predicates = $args{predicates};
    my $param_type = $args{param_type};
    my $param_c_expr = $args{param_c_expr};
    my $ctx = $args{ctx};
    my $label = $args{label};

    my @codes;
    for my $predicate (@$predicates) {
        compile_error("$label expects a single-parameter lambda predicate")
          if $predicate->{kind} ne 'lambda1';

        my ($pred_code, $pred_type);
        new_scope($ctx);
        declare_var(
            $ctx,
            $predicate->{param},
            {
                type      => $param_type,
                immutable => 1,
                c_name    => $param_c_expr,
            }
        );
        ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
        pop_scope($ctx);
        compile_error("$label predicate must evaluate to bool")
          if $pred_type ne 'bool';

        push @codes, $pred_code;
    }
    return \@codes;
}


sub expr_ast_equal {
    my ($a, $b) = @_;
    return 0 if !defined $a || !defined $b;
    return 0 if $a->{kind} ne $b->{kind};

    if ($a->{kind} eq 'num') {
        return $a->{value} eq $b->{value};
    }
    if ($a->{kind} eq 'ident') {
        return $a->{name} eq $b->{name};
    }
    if ($a->{kind} eq 'bool') {
        return $a->{value} == $b->{value};
    }
    if ($a->{kind} eq 'str') {
        my $ar = defined($a->{raw}) ? $a->{raw} : $a->{value};
        my $br = defined($b->{raw}) ? $b->{raw} : $b->{value};
        return $ar eq $br;
    }
    if ($a->{kind} eq 'unary') {
        return 0 if $a->{op} ne $b->{op};
        return expr_ast_equal($a->{expr}, $b->{expr});
    }
    if ($a->{kind} eq 'binop') {
        return 0 if $a->{op} ne $b->{op};
        return 0 if !expr_ast_equal($a->{left}, $b->{left});
        return expr_ast_equal($a->{right}, $b->{right});
    }
    if ($a->{kind} eq 'method_call') {
        return 0 if $a->{method} ne $b->{method};
        return 0 if !expr_ast_equal($a->{recv}, $b->{recv});
        my $an = scalar @{ $a->{args} };
        my $bn = scalar @{ $b->{args} };
        return 0 if $an != $bn;
        for (my $i = 0; $i < $an; $i++) {
            return 0 if !expr_ast_equal($a->{args}[$i], $b->{args}[$i]);
        }
        return 1;
    }
    if ($a->{kind} eq 'call') {
        return 0 if $a->{name} ne $b->{name};
        my $an = scalar @{ $a->{args} };
        my $bn = scalar @{ $b->{args} };
        return 0 if $an != $bn;
        for (my $i = 0; $i < $an; $i++) {
            return 0 if !expr_ast_equal($a->{args}[$i], $b->{args}[$i]);
        }
        return 1;
    }

    return 0;
}


sub expr_is_size_of_container {
    my ($expr, $recv_code, $recv_type, $ctx) = @_;
    if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'size' && scalar(@{ $expr->{args} }) == 0) {
        my ($inner_code, $inner_type) = compile_expr($expr->{recv}, $ctx);
        return 0 if $inner_type ne $recv_type;
        return $inner_code eq $recv_code;
    }
    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        return 0 if !defined $info;
        return 0 if !defined $info->{size_of_recv_code};
        return 0 if !defined $info->{size_of_recv_type};
        return 0 if $info->{size_of_recv_type} ne $recv_type;
        return $info->{size_of_recv_code} eq $recv_code;
    }
    return 0;
}


sub expr_is_size_minus_const {
    my ($expr, $recv_code, $recv_type, $ctx, $min_const) = @_;
    return 0 if $expr->{kind} ne 'binop' || $expr->{op} ne '-';
    return 0 if $expr->{right}{kind} ne 'num';
    return 0 if int($expr->{right}{value}) < $min_const;
    return expr_is_size_of_container($expr->{left}, $recv_code, $recv_type, $ctx);
}


sub prove_non_negative_expr {
    my ($expr, $ctx) = @_;
    if ($expr->{kind} eq 'num') {
        return int($expr->{value}) >= 0;
    }
    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        return 0 if !defined $info;
        return 1 if defined $info->{size_of_recv_code};
        return 0 if !defined $info->{range_min_expr};
        return prove_non_negative_expr($info->{range_min_expr}, $ctx);
    }
    if ($expr->{kind} eq 'method_call' && $expr->{method} eq 'size' && scalar(@{ $expr->{args} }) == 0) {
        my (undef, $recv_type) = compile_expr($expr->{recv}, $ctx);
        return 1 if $recv_type eq 'string' || $recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'indexed_number_list';
        return 0;
    }
    if ($expr->{kind} eq 'binop' && $expr->{op} eq '+') {
        return prove_non_negative_expr($expr->{left}, $ctx) && prove_non_negative_expr($expr->{right}, $ctx);
    }
    if ($expr->{kind} eq 'binop' && $expr->{op} eq '-') {
        if ($expr->{left}{kind} eq 'ident') {
            my $info = lookup_var($ctx, $expr->{left}{name});
            if (defined $info && defined $info->{range_min_expr}) {
                return 1 if expr_ast_equal($expr->{right}, $info->{range_min_expr});
            }
        }
        return 0;
    }
    return 0;
}


sub prove_index_lt_container_size {
    my ($idx_expr, $recv_code, $recv_type, $ctx) = @_;
    if ($idx_expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $idx_expr->{name});
        return 0 if !defined $info;
        return 0 if !defined $info->{range_max_expr};
        return expr_is_size_minus_const($info->{range_max_expr}, $recv_code, $recv_type, $ctx, 1);
    }
    if ($idx_expr->{kind} eq 'binop' && $idx_expr->{op} eq '-') {
        return 0 if !prove_index_lt_container_size($idx_expr->{left}, $recv_code, $recv_type, $ctx);
        return prove_non_negative_expr($idx_expr->{right}, $ctx);
    }
    return 0;
}


sub prove_container_index_in_bounds {
    my ($recv_code, $recv_type, $idx_expr, $ctx) = @_;
    return 0 if !prove_non_negative_expr($idx_expr, $ctx);
    return prove_index_lt_container_size($idx_expr, $recv_code, $recv_type, $ctx);
}


sub decompose_iterable_expression {
    my ($iter_expr, $ctx) = @_;

    my @predicates;
    my $base = $iter_expr;
    while ($base->{kind} eq 'method_call' && $base->{method} eq 'filter') {
        my $actual = scalar @{ $base->{args} };
        compile_error("filter(...) expects exactly 1 predicate arg")
          if $actual != 1;
        my $predicate = $base->{args}[0];
        compile_error("filter(...) expects a single-parameter lambda predicate")
          if $predicate->{kind} ne 'lambda1';
        unshift @predicates, $predicate;
        $base = $base->{recv};
    }

    if ($base->{kind} eq 'call' && $base->{name} eq 'seq') {
        my $actual = scalar @{ $base->{args} };
        compile_error("seq(...) expects exactly 2 args")
          if $actual != 2;
        return {
            kind       => 'seq',
            start_expr => $base->{args}[0],
            end_expr   => $base->{args}[1],
            predicates => \@predicates,
        };
    }

    my ($base_code, $base_type) = compile_expr($base, $ctx);
    compile_error("Iterable expression must be seq(...) or list-valued, got $base_type")
      if $base_type ne 'string_list' && $base_type ne 'number_list' && $base_type ne 'indexed_number_list';

    return {
        kind       => 'list',
        base_code  => $base_code,
        base_type  => $base_type,
        predicates => \@predicates,
    };
}


sub emit_for_each_from_iterable_expr {
    my (%args) = @_;
    my $iter_expr = $args{iter_expr};
    my $stmt = $args{stmt};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $current_fn_return = $args{current_fn_return};

    my $iter = decompose_iterable_expression($iter_expr, $ctx);

    if ($iter->{kind} eq 'seq') {
        my ($start_code, $start_type) = compile_expr($iter->{start_expr}, $ctx);
        my ($end_code, $end_type) = compile_expr($iter->{end_expr}, $ctx);
        compile_error("seq start must be number, got $start_type")
          if !is_number_like_type($start_type);
        compile_error("seq end must be number, got $end_type")
          if !is_number_like_type($end_type);
        my $start_num = number_like_to_c_expr($start_code, $start_type, "seq start");
        my $end_num = number_like_to_c_expr($end_code, $end_type, "seq end");

        my $start_var = '__metac_seq_start' . $ctx->{tmp_counter}++;
        my $end_var = '__metac_seq_end' . $ctx->{tmp_counter}++;
        my $idx_var = '__metac_seq_i' . $ctx->{tmp_counter}++;
        my $pred_codes = compile_filter_predicate_codes(
            predicates  => $iter->{predicates},
            param_type  => 'number',
            param_c_expr => $idx_var,
            ctx         => $ctx,
            label       => 'seq(...).filter(...)',
        );

        emit_line($out, $indent, "int64_t $start_var = $start_num;");
        emit_line($out, $indent, "int64_t $end_var = $end_num;");
        emit_line($out, $indent, "if ($start_var <= $end_var) {");
        emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var <= $end_var; $idx_var++) {");
        for my $pred_code (@$pred_codes) {
            emit_line($out, $indent + 4, "if (!($pred_code)) { continue; }");
        }
        emit_loop_body_with_binding(
            ctx               => $ctx,
            out               => $out,
            indent            => $indent + 4,
            current_fn_return => $current_fn_return,
            body              => $stmt->{body},
            var_name          => $stmt->{var},
            var_type          => 'number',
            var_c_expr        => $idx_var,
            var_index_c_expr  => $idx_var,
            range_min_expr    => $iter->{start_expr},
            range_max_expr    => $iter->{end_expr},
        );
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "} else {");
        emit_line($out, $indent + 2, "for (int64_t $idx_var = $start_var; $idx_var >= $end_var; $idx_var--) {");
        for my $pred_code (@$pred_codes) {
            emit_line($out, $indent + 4, "if (!($pred_code)) { continue; }");
        }
        emit_loop_body_with_binding(
            ctx               => $ctx,
            out               => $out,
            indent            => $indent + 4,
            current_fn_return => $current_fn_return,
            body              => $stmt->{body},
            var_name          => $stmt->{var},
            var_type          => 'number',
            var_c_expr        => $idx_var,
            var_index_c_expr  => $idx_var,
            range_min_expr    => $iter->{start_expr},
            range_max_expr    => $iter->{end_expr},
        );
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        return;
    }

    my $container = '__metac_iter_list' . $ctx->{tmp_counter}++;
    if ($iter->{base_type} eq 'string_list') {
        emit_line($out, $indent, "StringList $container = $iter->{base_code};");
    } elsif ($iter->{base_type} eq 'indexed_number_list') {
        emit_line($out, $indent, "IndexedNumberList $container = $iter->{base_code};");
    } else {
        emit_line($out, $indent, "NumberList $container = $iter->{base_code};");
    }

    my $idx_name = '__metac_i' . $ctx->{tmp_counter}++;
    my $elem_type = $iter->{base_type} eq 'string_list' ? 'string'
      : ($iter->{base_type} eq 'indexed_number_list' ? 'indexed_number' : 'number');
    my $elem_expr = "$container.items[$idx_name]";
    my $pred_codes = compile_filter_predicate_codes(
        predicates  => $iter->{predicates},
        param_type  => $elem_type,
        param_c_expr => $elem_expr,
        ctx         => $ctx,
        label       => 'filter(...)',
    );

    emit_line($out, $indent, "for (size_t $idx_name = 0; $idx_name < $container.count; $idx_name++) {");
    for my $pred_code (@$pred_codes) {
        emit_line($out, $indent + 2, "if (!($pred_code)) { continue; }");
    }
    emit_loop_body_with_binding(
        ctx               => $ctx,
        out               => $out,
        indent            => $indent + 2,
        current_fn_return => $current_fn_return,
        body              => $stmt->{body},
        var_name          => $stmt->{var},
        var_type          => $elem_type,
        var_c_expr        => $elem_expr,
        var_index_c_expr  => "((int64_t)$idx_name)",
    );
    emit_line($out, $indent, "}");
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
        my $count = scalar @{ $expr->{items} };
        if ($count == 0) {
            return ('0', 'empty_list');
        }
        compile_error("Non-empty list literals are not supported yet");
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

        if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'indexed_number_list') && $method eq 'size') {
            compile_error("Method 'size()' expects 0 args, got $actual")
              if $actual != 0;
            return ("((int64_t)$recv_code.count)", 'number');
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
                compile_error("Builtin 'log' does not support argument type '$arg_type'");
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

        my $result_type = $return_type eq 'bool' ? 'bool' : 'number';
        return ("$expr->{name}(" . join(', ', @arg_code) . ")", $result_type);
    }
    if ($expr->{kind} eq 'binop') {
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
            next;
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
                next;
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
                next;
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
            next;
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
                emit_map_assignment(
                    name             => $stmt->{name},
                    expr             => $expr,
                    ctx              => $ctx,
                    out              => $out,
                    indent           => $indent,
                    propagate_errors => 1,
                );
                next;
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
              if !type_matches_expected($stmt->{type}, $expr_type);

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

                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "typed assignment for '$stmt->{name}'");
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $rhs = "metac_wrap_range($rhs, $constraints->{range}{min}, $constraints->{range}{max})";
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
            } elsif ($stmt->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($stmt->{type} eq 'number_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
            } elsif ($stmt->{type} eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
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
              if !type_matches_expected($info->{type}, $expr_type);

            if ($info->{type} eq 'number') {
                my $constraints = $info->{constraints} // parse_constraints(undef);
                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "assignment to '$stmt->{name}'");
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($rhs, $constraints->{range}{min}, $constraints->{range}{max});");
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
            } elsif ($info->{type} eq 'number_list' || $info->{type} eq 'string_list') {
                if ($expr_type eq 'empty_list') {
                    emit_line($out, $indent, "$target.count = 0;");
                    emit_line($out, $indent, "$target.items = NULL;");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
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
                my $rhs = number_like_to_c_expr($expr_code, $expr_type, "'+=' for '$stmt->{name}'");

                my $combined = "($target + $rhs)";
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
            my $prev_loop_depth = $ctx->{loop_depth} // 0;
            $ctx->{loop_depth} = $prev_loop_depth + 1;
            compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
            $ctx->{loop_depth} = $prev_loop_depth;
            pop_scope($ctx);

            emit_line($out, $indent + 2, '}');
            emit_line($out, $indent + 2,
                'if (ferror(stdin)) { return err_number("I/O read failure", __metac_line_no, ""); }');
            emit_line($out, $indent, '}');
            next;
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
            next;
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
            next;
        }

        if ($stmt->{kind} eq 'break') {
            compile_error("break is only valid inside a loop")
              if ($ctx->{loop_depth} // 0) <= 0;
            emit_line($out, $indent, 'break;');
            next;
        }

        if ($stmt->{kind} eq 'continue') {
            compile_error("continue is only valid inside a loop")
              if ($ctx->{loop_depth} // 0) <= 0;
            emit_line($out, $indent, 'continue;');
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
            my $nullable_check = nullable_number_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_nonnull_on_false = nullable_number_names_non_null_on_false_expr($stmt->{cond}, $ctx);
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
            next;
        }

        if ($stmt->{kind} eq 'return') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($current_fn_return eq 'number_or_error') {
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
            } elsif ($current_fn_return eq 'number') {
                my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                emit_line($out, $indent, "return $num_expr;");
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                emit_line($out, $indent, "return $expr_code;");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            next;
        }

        if ($stmt->{kind} eq 'expr_stmt') {
            my ($expr_code, undef) = compile_expr($stmt->{expr}, $ctx);
            emit_line($out, $indent, "(void)($expr_code);");
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

        if ($param->{type} eq 'number_or_null') {
            emit_line($out, $indent, "const NullableNumber $name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'number_or_null',
                    immutable => 1,
                    c_name    => $name,
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
    my @helper_defs;
    my $sig_params = render_c_params($params);
    push @out, "static ResultNumber $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        nonnull_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
        loop_depth  => 0,
        helper_defs => \@helper_defs,
        helper_counter => 0,
        current_function => $fn->{name},
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number_or_error');
    compile_block($stmts, $ctx, \@out, 2, 'number_or_error');
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_number($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@helper_defs) {
        return join("\n", @helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
}


sub compile_number_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number';

    my $stmts = parse_function_body($fn);
    my @out;
    my @helper_defs;
    my $sig_params = render_c_params($params);
    push @out, "static int64_t $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        nonnull_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
        loop_depth  => 0,
        helper_defs => \@helper_defs,
        helper_counter => 0,
        current_function => $fn->{name},
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number');
    compile_block($stmts, $ctx, \@out, 2, 'number');
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@helper_defs) {
        return join("\n", @helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
}


sub compile_bool_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: bool")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'bool';

    my $stmts = parse_function_body($fn);
    my @out;
    my @helper_defs;
    my $sig_params = render_c_params($params);
    push @out, "static int $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        fact_scopes => [ {} ],
        nonnull_scopes => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
        loop_depth  => 0,
        helper_defs => \@helper_defs,
        helper_counter => 0,
        current_function => $fn->{name},
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'bool');
    compile_block($stmts, $ctx, \@out, 2, 'bool');
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@helper_defs) {
        return join("\n", @helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
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

    my $non_runtime = '';
    $non_runtime .= emit_function_prototypes(\@ordered_names, $functions);
    $non_runtime .= "\n\n";
    for my $name (@ordered_names) {
        if ($number_error_functions{$name}) {
            $non_runtime .= compile_number_or_error_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $non_runtime .= "\n";
            next;
        }
        if ($number_functions{$name}) {
            $non_runtime .= compile_number_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $non_runtime .= "\n";
            next;
        }
        if ($bool_functions{$name}) {
            $non_runtime .= compile_bool_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $non_runtime .= "\n";
            next;
        }
        compile_error("Internal: unclassified function '$name'");
    }
    $non_runtime .= compile_main_body($main, \%number_error_functions);

    my $c = runtime_prelude_for_code($non_runtime);
    $c .= "\n";
    $c .= $non_runtime;
    return $c;
}


1;
