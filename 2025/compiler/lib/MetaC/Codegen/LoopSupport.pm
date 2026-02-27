package MetaC::Codegen;
use strict;
use warnings;

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

sub compile_sortby_number_list_list_lambda_helper {
    my (%args) = @_;
    my $lambda = $args{lambda};
    my $recv_expr = $args{recv_expr};
    my $ctx = $args{ctx};

    compile_error("sortBy(...) argument must be a two-parameter lambda, e.g. (a, b) => ...")
      if $lambda->{kind} ne 'lambda2';

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
            type      => 'number_list',
            immutable => 1,
            c_name    => $param1,
        }
    );
    declare_var(
        $lambda_ctx,
        $param2,
        {
            type      => 'number_list',
            immutable => 1,
            c_name    => $param2,
        }
    );

    if (defined($recv_expr) && ($recv_expr->{kind} // '') eq 'ident') {
        my $recv_info = lookup_var($ctx, $recv_expr->{name});
        if (defined($recv_info) && defined($recv_info->{item_len_proof})) {
            my $len = int($recv_info->{item_len_proof});
            my $key1 = expr_fact_key({ kind => 'ident', name => $param1 }, $lambda_ctx);
            my $key2 = expr_fact_key({ kind => 'ident', name => $param2 }, $lambda_ctx);
            set_list_len_fact($lambda_ctx, $key1, $len);
            set_list_len_fact($lambda_ctx, $key2, $len);
        }
    }

    my ($body_code, $body_type) = compile_expr($lambda->{body}, $lambda_ctx);
    $ctx->{helper_counter} = $lambda_ctx->{helper_counter};
    my $body_num = number_like_to_c_expr($body_code, $body_type, "sortBy(...) comparator lambda");

    my $helper_counter = $ctx->{helper_counter} // 0;
    my $helper_name = '__metac_sortby_' . ($ctx->{current_function} // 'fn') . '_' . $helper_counter;
    $ctx->{helper_counter} = $helper_counter + 1;

    my @helper_lines;
    push @helper_lines, "static int64_t $helper_name(NumberList $param1, NumberList $param2) {";
    push @helper_lines, "  return $body_num;";
    push @helper_lines, '}';
    push @{ $ctx->{helper_defs} }, join("\n", @helper_lines);

    return $helper_name;
}

sub compile_filter_lambda_helper {
    my (%args) = @_;
    my $lambda = $args{lambda};
    my $recv_type = $args{recv_type};
    my $ctx = $args{ctx};

    compile_error("filter(...) argument must be a single-parameter lambda, e.g. x => x > 0")
      if $lambda->{kind} ne 'lambda1';

    my ($item_type, $item_c_type);
    if ($recv_type eq 'number_list') {
        $item_type = 'number';
        $item_c_type = 'int64_t';
    } elsif ($recv_type eq 'string_list') {
        $item_type = 'string';
        $item_c_type = 'const char *';
    } elsif (is_matrix_member_list_type($recv_type)) {
        my $member_meta = matrix_member_list_meta($recv_type);
        $item_type = $recv_type;
        $item_type =~ s/^matrix_member_list</matrix_member</;
        if ($member_meta->{elem} eq 'number') {
            $item_c_type = 'MatrixNumberMember';
        } elsif ($member_meta->{elem} eq 'string') {
            $item_c_type = 'MatrixStringMember';
        } else {
            compile_error("filter(...) is unsupported for matrix member element type '$member_meta->{elem}'");
        }
    } else {
        compile_error("filter(...) receiver must be string_list, number_list, or matrix member list, got $recv_type");
    }
    my $param = $lambda->{param};

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
        $param,
        {
            type      => $item_type,
            immutable => 1,
            c_name    => $param,
        }
    );

    my ($body_code, $body_type) = compile_expr($lambda->{body}, $lambda_ctx);
    $ctx->{helper_counter} = $lambda_ctx->{helper_counter};
    compile_error("filter(...) lambda must return bool")
      if $body_type ne 'bool';

    my $helper_counter = $ctx->{helper_counter} // 0;
    my $helper_name = '__metac_filter_' . ($ctx->{current_function} // 'fn') . '_' . $helper_counter;
    $ctx->{helper_counter} = $helper_counter + 1;

    my @helper_lines;
    push @helper_lines, "static int $helper_name($item_c_type $param) {";
    push @helper_lines, "  return $body_code;";
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
    my $member_matrix_code = $args{member_matrix_code};
    my $member_matrix_type = $args{member_matrix_type};
    my $list_len_proof = $args{list_len_proof};

    new_scope($ctx);
    my %var_info = (
        type      => $var_type,
        immutable => 1,
        c_name    => $var_name,
    );
    if ($var_type eq 'number' && defined $range_min_expr && defined $range_max_expr) {
        $var_info{range_min_expr} = $range_min_expr;
        $var_info{range_max_expr} = $range_max_expr;
        my $min_key;
        eval { $min_key = expr_fact_key($range_min_expr, $ctx); 1; };
        $var_info{range_min_fact_key} = $min_key if defined $min_key;

        if (($range_max_expr->{kind} // '') eq 'binop' && ($range_max_expr->{op} // '') eq '-'
            && defined($range_max_expr->{left}) && ref($range_max_expr->{left}) eq 'HASH'
            && defined($range_max_expr->{right}) && ref($range_max_expr->{right}) eq 'HASH'
            && ($range_max_expr->{right}{kind} // '') eq 'num')
        {
            my $left = $range_max_expr->{left};
            my $minus_const = int($range_max_expr->{right}{value});
            if (($left->{kind} // '') eq 'method_call'
                && (($left->{method} // '') eq 'size' || ($left->{method} // '') eq 'count')
                && scalar(@{ $left->{args} // [] }) == 0)
            {
                my ($recv_code, $recv_type) = compile_expr($left->{recv}, $ctx);
                $var_info{range_max_size_recv_code} = $recv_code;
                $var_info{range_max_size_recv_type} = $recv_type;
                $var_info{range_max_size_minus_const} = $minus_const;
            } elsif (($left->{kind} // '') eq 'ident') {
                my $bound_info = lookup_var($ctx, $left->{name});
                if (defined($bound_info) && defined($bound_info->{size_of_recv_code}) && defined($bound_info->{size_of_recv_type})) {
                    $var_info{range_max_size_recv_code} = $bound_info->{size_of_recv_code};
                    $var_info{range_max_size_recv_type} = $bound_info->{size_of_recv_type};
                    $var_info{range_max_size_minus_const} = $minus_const;
                }
            }
        }
    }
    if (is_matrix_member_type($var_type) && defined($member_matrix_code) && defined($member_matrix_type)) {
        $var_info{member_matrix_code} = $member_matrix_code;
        $var_info{member_matrix_type} = $member_matrix_type;
    }
    if (defined $var_index_c_expr) {
        $var_info{index_c_expr} = $var_index_c_expr;
    }
    if ($var_type eq 'string') {
        emit_line($out, $indent, "const char *$var_name = $var_c_expr;");
    } elsif ($var_type eq 'number_list') {
        emit_line($out, $indent, "const NumberList $var_name = $var_c_expr;");
    } elsif ($var_type eq 'number') {
        emit_line($out, $indent, "const int64_t $var_name = $var_c_expr;");
    } elsif ($var_type eq 'bool') {
        emit_line($out, $indent, "const int $var_name = $var_c_expr;");
    } elsif ($var_type eq 'indexed_number') {
        emit_line($out, $indent, "const IndexedNumber $var_name = $var_c_expr;");
    } elsif (is_matrix_member_type($var_type)) {
        my $member_meta = matrix_member_meta($var_type);
        if ($member_meta->{elem} eq 'number') {
            emit_line($out, $indent, "const MatrixNumberMember $var_name = $var_c_expr;");
        } elsif ($member_meta->{elem} eq 'string') {
            emit_line($out, $indent, "const MatrixStringMember $var_name = $var_c_expr;");
        } else {
            compile_error("Unsupported matrix member loop type '$var_type'");
        }
    } else {
        compile_error("Unsupported loop element type '$var_type'");
    }
    declare_var($ctx, $var_name, \%var_info);
    if (defined $list_len_proof && $var_type eq 'number_list') {
        my $key = expr_fact_key({ kind => 'ident', name => $var_name }, $ctx);
        set_list_len_fact($ctx, $key, int($list_len_proof));
    }

    my $prev_loop_depth = $ctx->{loop_depth} // 0;
    $ctx->{loop_depth} = $prev_loop_depth + 1;
    compile_block($body, $ctx, $out, $indent, $current_fn_return);
    $ctx->{loop_depth} = $prev_loop_depth;
    close_codegen_scope($ctx, $out, $indent);
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



1;
