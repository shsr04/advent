package MetaC::Codegen;
use strict;
use warnings;

sub compile_expr_method_call {
    my ($expr, $ctx, $recv_code, $recv_type, $method, $actual) = @_;
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

    if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'bool_list' || $recv_type eq 'indexed_number_list')
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
        if ($recv_type eq 'bool_list') {
            return ("metac_log_bool_list($recv_code)", 'bool_list');
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

    if (($recv_type eq 'number_list' || $recv_type eq 'string_list' || $recv_type eq 'bool_list') && $method eq 'push') {
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

        if ($recv_type eq 'bool_list') {
            my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
            compile_error("Method 'push(...)' on bool list expects bool arg, got $arg_type")
              if $arg_type ne 'bool';
            return ("metac_bool_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
        }

        my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
        compile_error("Method 'push(...)' on string list expects string arg, got $arg_type")
          if $arg_type ne 'string';
        return ("metac_string_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
    }

    compile_error("Unsupported method call '$method' on type '$recv_type'");
}

1;
