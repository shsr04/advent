package MetaC::Codegen;
use strict;
use warnings;
use MetaC::IntrinsicRegistry qw(method_from_op_id intrinsic_method_codegen_template);

sub _matrix_size_axis_has_compiletime_proof {
    my (%args) = @_;
    my $axis_expr = $args{axis_expr};
    my $ctx = $args{ctx};
    my $max_axis = int($args{max_axis});

    if (($axis_expr->{kind} // '') eq 'num') {
        my $axis = int($axis_expr->{value});
        return ($axis >= 0 && $axis <= $max_axis) ? 1 : 0;
    }

    if (($axis_expr->{kind} // '') eq 'ident') {
        my $info = lookup_var($ctx, $axis_expr->{name});
        return 0 if !defined $info;
        return 0 if ($info->{type} // '') ne 'number';
        my ($min, $max) = constraint_range_bounds($info->{constraints});
        return 0 if !defined($min) || !defined($max);
        return ($min >= 0 && $max <= $max_axis) ? 1 : 0;
    }

    return 0;
}

sub _resolved_method_name {
    my ($expr) = @_;
    my $resolved = $expr->{resolved_call};
    if (defined($resolved) && ref($resolved) eq 'HASH') {
        return $resolved->{method_name}
          if defined($resolved->{method_name}) && $resolved->{method_name} ne '';
        my $from_op = method_from_op_id($resolved->{op_id} // '');
        return $from_op if defined $from_op;
    }
    return $expr->{method};
}

sub _compile_registry_method_template {
    my (%args) = @_;
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $recv_code = $args{recv_code};
    my $recv_type = $args{recv_type};
    my $method = $args{method};
    my $actual = int($args{actual});

    my $spec = intrinsic_method_codegen_template($method, $recv_type);
    return undef if !defined $spec;

    my $arity = int($spec->{arity} // 0);
    if ($actual != $arity) {
        my $sig = $arity == 0 ? "$method()" : "$method(...)";
        compile_error("Method '$sig' expects $arity arg" . ($arity == 1 ? '' : 's') . ", got $actual");
    }

    my $template = $spec->{expr_template};
    my ($arg0_code, $arg0_type, $arg0_loaded);
    if ($template =~ /%ARG0/ || $template =~ /%ARG0_NUM%/) {
        ($arg0_code, $arg0_type) = compile_expr($expr->{args}[0], $ctx);
        $arg0_loaded = 1;
    }

    if ($template =~ /%ARG0_NUM%/) {
        my $num = number_like_to_c_expr($arg0_code, $arg0_type, "Method '$method(...)'");
        $template =~ s/%ARG0_NUM%/$num/g;
    }
    if ($template =~ /%ARG0%/) {
        compile_error("Internal codegen contract error: missing arg0 for '$method'")
          if !$arg0_loaded;
        $template =~ s/%ARG0%/$arg0_code/g;
    }
    if ($template =~ /%RECV_NUM%/) {
        my $recv_num = number_like_to_c_expr($recv_code, $recv_type, "Method '$method(...)'");
        $template =~ s/%RECV_NUM%/$recv_num/g;
    }
    $template =~ s/%RECV%/$recv_code/g;
    return ($template, $spec->{result_type});
}

sub compile_expr_intrinsic_call {
    my ($expr, $ctx, $recv_code, $recv_type, $actual) = @_;
    my $method = _resolved_method_name($expr);
    compile_error("Unsupported intrinsic method call contract")
      if !defined($method) || $method eq '';
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

    if (($recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'string_list' || $recv_type eq 'bool_list')
        && $method eq 'insert')
    {
        compile_error("Method 'insert(...)' expects 2 args, got $actual")
          if $actual != 2;
        my ($value_code, $value_type) = compile_expr($expr->{args}[0], $ctx);
        my ($idx_code, $idx_type) = compile_expr($expr->{args}[1], $ctx);
        my $idx_num = number_like_to_c_expr($idx_code, $idx_type, "Method 'insert(...)' index");

        my $in_bounds = prove_container_index_in_bounds($recv_code, $recv_type, $expr->{args}[1], $ctx);
        if (!$in_bounds && $expr->{recv}{kind} eq 'ident' && $expr->{args}[1]{kind} eq 'num') {
            my $idx_const = int($expr->{args}[1]{value});
            if ($idx_const >= 0) {
                my $recv_key = expr_fact_key($expr->{recv}, $ctx);
                my $known_len = lookup_list_len_fact($ctx, $recv_key);
                if (!defined $known_len) {
                    my $recv_info = lookup_var($ctx, $expr->{recv}{name});
                    $known_len = constraint_size_exact($recv_info->{constraints})
                      if defined($recv_info) && defined($recv_info->{constraints});
                }
                $in_bounds = 1 if defined($known_len) && $idx_const < $known_len;
            }
        }
        compile_error("Method 'insert(...)' on '$recv_type' requires compile-time in-bounds proof")
          if !$in_bounds;

        if ($recv_type eq 'number_list') {
            my $value_num = number_like_to_c_expr($value_code, $value_type, "Method 'insert(...)'");
            return ("metac_number_list_insert_or_die($recv_code, $value_num, $idx_num)", 'number_list');
        }
        if ($recv_type eq 'number_list_list') {
            compile_error("Method 'insert(...)' on number-list-list expects number[] value, got $value_type")
              if $value_type ne 'number_list';
            return ("metac_number_list_list_insert_or_die($recv_code, $value_code, $idx_num)", 'number_list_list');
        }
        if ($recv_type eq 'string_list') {
            compile_error("Method 'insert(...)' on string list expects string value, got $value_type")
              if $value_type ne 'string';
            return ("metac_string_list_insert_or_die($recv_code, $value_code, $idx_num)", 'string_list');
        }
        compile_error("Method 'insert(...)' on bool list expects bool value, got $value_type")
          if $value_type ne 'bool';
        return ("metac_bool_list_insert_or_die($recv_code, $value_code, $idx_num)", 'bool_list');
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

    if (is_matrix_type($recv_type) && $method eq 'size') {
        compile_error("Method 'size(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my $meta = matrix_type_meta($recv_type);

        my $max_axis = $meta->{dim} - 1;
        my $axis_expr = $expr->{args}[0];
        my ($axis_code, $axis_type) = compile_expr($axis_expr, $ctx);
        my $axis_num = number_like_to_c_expr($axis_code, $axis_type, "Method 'size(...)'");
        compile_error("Method 'size(...)' requires compile-time axis proof in range(0, $max_axis)")
          if !_matrix_size_axis_has_compiletime_proof(
            axis_expr => $axis_expr,
            ctx       => $ctx,
            max_axis  => $max_axis,
          );
        if ($meta->{elem} eq 'number') {
            return ("metac_matrix_number_size($recv_code, $axis_num)", 'number');
        }
        if ($meta->{elem} eq 'string') {
            return ("metac_matrix_string_size($recv_code, $axis_num)", 'number');
        }
        if ($meta->{has_size}) {
            return ("((int64_t)($recv_code).size_spec[(size_t)($axis_num)])", 'number');
        }
        return ("0", 'number');
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

    my ($templated_code, $templated_type) = _compile_registry_method_template(
        expr      => $expr,
        ctx       => $ctx,
        recv_code => $recv_code,
        recv_type => $recv_type,
        method    => $method,
        actual    => $actual,
    );
    return ($templated_code, $templated_type) if defined $templated_code;

    if (is_matrix_member_list_type($recv_type) && ($method eq 'size' || $method eq 'count')) {
        compile_error("Method '$method()' expects 0 args, got $actual")
          if $actual != 0;
        return ("((int64_t)$recv_code.count)", 'number');
    }

    if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'bool_list')
        && $method eq 'map')
    {
        compile_error("Method 'map(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my $mapper = map_mapper_info($expr, $ctx, $recv_type);
        compile_error("Method 'map(...)' currently requires statement-backed expression context")
          if !expr_temp_scope_active($ctx);
        compile_error("Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)")
          if $mapper->{return_mode} eq 'number_or_error' || $mapper->{return_mode} eq 'same_or_error';

        my ($recv_c_type, $item_type, $item_decl_template);
        if ($recv_type eq 'number_list') {
            $recv_c_type = 'NumberList';
            $item_type = 'number';
            $item_decl_template = 'const int64_t %ITEM% = %RECV%.items[%IDX%];';
        } elsif ($recv_type eq 'bool_list') {
            $recv_c_type = 'BoolList';
            $item_type = 'bool';
            $item_decl_template = 'const int %ITEM% = %RECV%.items[%IDX%];';
        } else {
            $recv_c_type = 'StringList';
            $item_type = 'string';
            $item_decl_template = 'const char *%ITEM% = %RECV%.items[%IDX%];';
        }

        my ($out_c_type, $push_call_template);
        if ($mapper->{output_list_type} eq 'number_list') {
            $out_c_type = 'NumberList';
            $push_call_template = 'metac_number_list_push(&%OUT%, %VALUE%);';
        } elsif ($mapper->{output_list_type} eq 'bool_list') {
            $out_c_type = 'BoolList';
            $push_call_template = 'metac_bool_list_push(&%OUT%, %VALUE%);';
        } else {
            $out_c_type = 'StringList';
            $push_call_template = 'metac_string_list_push(&%OUT%, %VALUE%);';
        }

        my $scope = $ctx->{expr_temp_scopes}[-1];
        my $recv_tmp = '__metac_map_recv' . $ctx->{tmp_counter}++;
        my $count = '__metac_map_count' . $ctx->{tmp_counter}++;
        my $idx = '__metac_map_i' . $ctx->{tmp_counter}++;
        my $item = '__metac_map_item' . $ctx->{tmp_counter}++;
        my $out_list = '__metac_map_out' . $ctx->{tmp_counter}++;
        my $item_decl = $item_decl_template;
        $item_decl =~ s/%ITEM%/$item/g;
        $item_decl =~ s/%RECV%/$recv_tmp/g;
        $item_decl =~ s/%IDX%/$idx/g;

        my $mapped_expr_code;
        my $mapped_expr_type;
        if ($mapper->{kind} eq 'lambda') {
            my $lambda = $expr->{args}[0];
            new_scope($ctx);
            declare_var(
                $ctx,
                $lambda->{param},
                {
                    type      => $item_type,
                    immutable => 1,
                    c_name    => $item,
                }
            );
            ($mapped_expr_code, $mapped_expr_type) = compile_expr($lambda->{body}, $ctx);
            pop_scope($ctx);
            compile_error("map(...) lambda must return $mapper->{output_type}")
              if $mapped_expr_type ne $mapper->{output_type};
        } else {
            $mapped_expr_code = "$mapper->{name}($item)";
            $mapped_expr_type = $mapper->{output_type};
        }

        push @{ $scope->{prelude} }, "$recv_c_type $recv_tmp = $recv_code;";
        push @{ $scope->{prelude} }, "size_t $count = $recv_tmp.count;";
        push @{ $scope->{prelude} }, "$out_c_type $out_list;";
        push @{ $scope->{prelude} }, "$out_list.count = 0;";
        push @{ $scope->{prelude} }, "$out_list.items = NULL;";
        push @{ $scope->{prelude} }, "for (size_t $idx = 0; $idx < $count; $idx++) {";
        push @{ $scope->{prelude} }, "  $item_decl";
        if ($mapper->{output_list_type} eq 'number_list') {
            my $push_line = $push_call_template;
            $push_line =~ s/%OUT%/$out_list/g;
            $push_line =~ s/%VALUE%/$mapped_expr_code/g;
            push @{ $scope->{prelude} }, "  $push_line";
        } elsif ($mapper->{output_list_type} eq 'bool_list') {
            my $push_line = $push_call_template;
            $push_line =~ s/%OUT%/$out_list/g;
            $push_line =~ s/%VALUE%/\(\($mapped_expr_code\) \? 1 : 0\)/g;
            push @{ $scope->{prelude} }, "  $push_line";
        } else {
            my $push_line = $push_call_template;
            $push_line =~ s/%OUT%/$out_list/g;
            $push_line =~ s/%VALUE%/$mapped_expr_code/g;
            push @{ $scope->{prelude} }, "  $push_line";
        }
        push @{ $scope->{prelude} }, "}";

        return ($out_list, $mapper->{output_list_type});
    }
    if ($method eq 'map') {
        compile_error("map(...) receiver must be string_list, number_list, or bool_list, got $recv_type");
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
    if ($method eq 'filter') {
        compile_error("filter(...) receiver must be string_list, number_list, or matrix member list, got $recv_type");
    }

    if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'bool_list')
        && $method eq 'any')
    {
        compile_error("Method 'any(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my $predicate = $expr->{args}[0];
        compile_error("any(...) predicate must be a single-parameter lambda, e.g. x => x > 0")
          if $predicate->{kind} ne 'lambda1';
        compile_error("Method 'any(...)' currently requires statement-backed expression context")
          if !expr_temp_scope_active($ctx);

        my ($recv_c_type, $item_type, $item_decl_template);
        if ($recv_type eq 'number_list') {
            $recv_c_type = 'NumberList';
            $item_type = 'number';
            $item_decl_template = 'const int64_t %ITEM% = %RECV%.items[%IDX%];';
        } elsif ($recv_type eq 'string_list') {
            $recv_c_type = 'StringList';
            $item_type = 'string';
            $item_decl_template = 'const char *%ITEM% = %RECV%.items[%IDX%];';
        } elsif ($recv_type eq 'bool_list') {
            $recv_c_type = 'BoolList';
            $item_type = 'bool';
            $item_decl_template = 'const int %ITEM% = %RECV%.items[%IDX%];';
        } else {
            $recv_c_type = 'NumberListList';
            $item_type = 'number_list';
            $item_decl_template = 'const NumberList %ITEM% = %RECV%.items[%IDX%];';
        }

        my $scope = $ctx->{expr_temp_scopes}[-1];
        my $recv_tmp = '__metac_any_recv' . $ctx->{tmp_counter}++;
        my $idx = '__metac_any_i' . $ctx->{tmp_counter}++;
        my $item = '__metac_any_item' . $ctx->{tmp_counter}++;
        my $result = '__metac_any_res' . $ctx->{tmp_counter}++;
        my $item_decl = $item_decl_template;
        $item_decl =~ s/%ITEM%/$item/g;
        $item_decl =~ s/%RECV%/$recv_tmp/g;
        $item_decl =~ s/%IDX%/$idx/g;

        new_scope($ctx);
        my %param_info = (
            type      => $item_type,
            immutable => 1,
            c_name    => $item,
        );
        declare_var($ctx, $predicate->{param}, \%param_info);
        if ($recv_type eq 'number_list_list' && $expr->{recv}{kind} eq 'ident') {
            my $recv_info = lookup_var($ctx, $expr->{recv}{name});
            if (defined($recv_info) && defined($recv_info->{item_len_proof})) {
                my $param_key = expr_fact_key({ kind => 'ident', name => $predicate->{param} }, $ctx);
                set_list_len_fact($ctx, $param_key, $recv_info->{item_len_proof});
            }
        }
        my ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
        pop_scope($ctx);
        compile_error("any(...) predicate must evaluate to bool")
          if $pred_type ne 'bool';

        push @{ $scope->{prelude} }, "int $result = 0;";
        push @{ $scope->{prelude} }, "$recv_c_type $recv_tmp = $recv_code;";
        push @{ $scope->{prelude} }, "for (size_t $idx = 0; $idx < $recv_tmp.count; $idx++) {";
        push @{ $scope->{prelude} }, "  $item_decl";
        push @{ $scope->{prelude} }, "  if ($pred_code) { $result = 1; break; }";
        push @{ $scope->{prelude} }, "}";

        return ($result, 'bool');
    }

    if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'bool_list')
        && $method eq 'all')
    {
        compile_error("Method 'all(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my $predicate = $expr->{args}[0];
        compile_error("all(...) predicate must be a single-parameter lambda, e.g. x => x > 0")
          if $predicate->{kind} ne 'lambda1';
        compile_error("Method 'all(...)' currently requires statement-backed expression context")
          if !expr_temp_scope_active($ctx);

        my ($recv_c_type, $item_type, $item_decl_template);
        if ($recv_type eq 'number_list') {
            $recv_c_type = 'NumberList';
            $item_type = 'number';
            $item_decl_template = 'const int64_t %ITEM% = %RECV%.items[%IDX%];';
        } elsif ($recv_type eq 'string_list') {
            $recv_c_type = 'StringList';
            $item_type = 'string';
            $item_decl_template = 'const char *%ITEM% = %RECV%.items[%IDX%];';
        } elsif ($recv_type eq 'bool_list') {
            $recv_c_type = 'BoolList';
            $item_type = 'bool';
            $item_decl_template = 'const int %ITEM% = %RECV%.items[%IDX%];';
        } else {
            $recv_c_type = 'NumberListList';
            $item_type = 'number_list';
            $item_decl_template = 'const NumberList %ITEM% = %RECV%.items[%IDX%];';
        }

        my $scope = $ctx->{expr_temp_scopes}[-1];
        my $recv_tmp = '__metac_all_recv' . $ctx->{tmp_counter}++;
        my $idx = '__metac_all_i' . $ctx->{tmp_counter}++;
        my $item = '__metac_all_item' . $ctx->{tmp_counter}++;
        my $result = '__metac_all_res' . $ctx->{tmp_counter}++;
        my $item_decl = $item_decl_template;
        $item_decl =~ s/%ITEM%/$item/g;
        $item_decl =~ s/%RECV%/$recv_tmp/g;
        $item_decl =~ s/%IDX%/$idx/g;

        new_scope($ctx);
        my %param_info = (
            type      => $item_type,
            immutable => 1,
            c_name    => $item,
        );
        declare_var($ctx, $predicate->{param}, \%param_info);
        if ($recv_type eq 'number_list_list' && $expr->{recv}{kind} eq 'ident') {
            my $recv_info = lookup_var($ctx, $expr->{recv}{name});
            if (defined($recv_info) && defined($recv_info->{item_len_proof})) {
                my $param_key = expr_fact_key({ kind => 'ident', name => $predicate->{param} }, $ctx);
                set_list_len_fact($ctx, $param_key, $recv_info->{item_len_proof});
            }
        }
        my ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
        pop_scope($ctx);
        compile_error("all(...) predicate must evaluate to bool")
          if $pred_type ne 'bool';

        push @{ $scope->{prelude} }, "int $result = 1;";
        push @{ $scope->{prelude} }, "$recv_c_type $recv_tmp = $recv_code;";
        push @{ $scope->{prelude} }, "for (size_t $idx = 0; $idx < $recv_tmp.count; $idx++) {";
        push @{ $scope->{prelude} }, "  $item_decl";
        push @{ $scope->{prelude} }, "  if (!($pred_code)) { $result = 0; break; }";
        push @{ $scope->{prelude} }, "}";

        return ($result, 'bool');
    }

    if ($recv_type eq 'number_list_list' && $method eq 'sortBy') {
        compile_error("Method 'sortBy(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my $lambda = $expr->{args}[0];
        my $helper_name = compile_sortby_number_list_list_lambda_helper(
            lambda   => $lambda,
            recv_expr => $expr->{recv},
            ctx      => $ctx,
        );
        return ("metac_sort_number_list_list_by($recv_code, $helper_name)", 'number_list_list');
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

    if ($method eq 'log' && is_matrix_type($recv_type)) {
        compile_error("Method 'log()' expects 0 args, got $actual")
          if $actual != 0;
        my $meta = matrix_type_meta($recv_type);
        return ("metac_log_matrix_number($recv_code)", $recv_type) if $meta->{elem} eq 'number';
        return ("metac_log_matrix_string($recv_code)", $recv_type) if $meta->{elem} eq 'string';
        compile_error("Method 'log()' is unsupported for matrix element type '$meta->{elem}'");
    }

    if (($recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'string_list' || $recv_type eq 'bool_list') && $method eq 'push') {
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

        if ($recv_type eq 'number_list_list') {
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'push(...)' on number-list-list expects number[] arg, got $arg_type")
              if $arg_type ne 'number_list';
            my $required_size =
              (defined($recv_info->{constraints}) && defined($recv_info->{constraints}{nested_number_list_size}))
              ? int($recv_info->{constraints}{nested_number_list_size})
              : undef;
            my $known_len;
            if (expr_is_stable_for_facts($expr->{args}[0], $ctx)) {
                my $arg_key = expr_fact_key($expr->{args}[0], $ctx);
                $known_len = lookup_list_len_fact($ctx, $arg_key);
                if (defined $known_len) {
                    if (!defined $recv_info->{item_len_proof}) {
                        $recv_info->{item_len_proof} = $known_len;
                    } elsif ($recv_info->{item_len_proof} != $known_len) {
                        delete $recv_info->{item_len_proof};
                    }
                } else {
                    delete $recv_info->{item_len_proof} if defined $recv_info->{item_len_proof};
                }
            } else {
                delete $recv_info->{item_len_proof} if defined $recv_info->{item_len_proof};
            }
            if (!defined $known_len && $expr->{args}[0]{kind} eq 'list_literal') {
                $known_len = scalar @{ $expr->{args}[0]{items} // [] };
            }
            if (defined $known_len && !defined $required_size) {
                if (!defined $recv_info->{item_len_proof}) {
                    $recv_info->{item_len_proof} = $known_len;
                } elsif ($recv_info->{item_len_proof} != $known_len) {
                    delete $recv_info->{item_len_proof};
                }
            }
            if (defined $required_size) {
                compile_error("Method 'push(...)' on '$expr->{recv}{name}' requires pushed number[] with proven size($required_size)")
                  if !defined($known_len) || int($known_len) != $required_size;
                $recv_info->{item_len_proof} = $required_size;
            }
            return ("metac_number_list_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
        }

        if ($recv_type eq 'bool_list') {
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'push(...)' on bool list expects bool arg, got $arg_type")
              if $arg_type ne 'bool';
            return ("metac_bool_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
        }

        my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
        my $arg_str = $arg_code;
        if ($arg_type eq 'string') {
            # pass-through
        } elsif (is_matrix_member_type($arg_type)) {
            my $meta = matrix_member_meta($arg_type);
            compile_error("Method 'push(...)' on string list expects string arg, got $arg_type")
              if $meta->{elem} ne 'string';
            $arg_str = "(($arg_code).value)";
        } else {
            compile_error("Method 'push(...)' on string list expects string arg, got $arg_type");
        }
        return ("metac_string_list_push(&$recv_info->{c_name}, $arg_str)", 'number');
    }

    compile_error("Unsupported method call '$method' on type '$recv_type'");
}

1;
