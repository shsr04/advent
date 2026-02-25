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

    if ($recv_type eq 'string' && $method eq 'isBlank') {
        compile_error("Method 'isBlank()' expects 0 args, got $actual")
          if $actual != 0;
        return ("metac_is_blank($recv_code)", 'bool');
    }

    if ($recv_type eq 'string' && $method eq 'split') {
        compile_error("Method 'split(...)' is fallible; handle it with '?'");
    }

    if (($recv_type eq 'string_list' || $recv_type eq 'number_list' || $recv_type eq 'number_list_list' || $recv_type eq 'bool_list' || $recv_type eq 'indexed_number_list')
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

    if (($recv_type eq 'number' || $recv_type eq 'indexed_number') && $method eq 'compareTo') {
        compile_error("Method 'compareTo(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
        my $left = number_like_to_c_expr($recv_code, $recv_type, "Method 'compareTo(...)'");
        my $right = number_like_to_c_expr($arg_code, $arg_type, "Method 'compareTo(...)'");
        return ("(($left < $right) ? -1 : (($left > $right) ? 1 : 0))", 'number');
    }

    if (($recv_type eq 'number' || $recv_type eq 'indexed_number') && $method eq 'andThen') {
        compile_error("Method 'andThen(...)' expects 1 arg, got $actual")
          if $actual != 1;
        my ($arg_code, $arg_type) = compile_expr($expr->{args}[0], $ctx);
        my $left = number_like_to_c_expr($recv_code, $recv_type, "Method 'andThen(...)'");
        my $right = number_like_to_c_expr($arg_code, $arg_type, "Method 'andThen(...)'");
        return ("(($left != 0) ? $left : $right)", 'number');
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
        compile_error("Method 'push(...)' on string list expects string arg, got $arg_type")
          if $arg_type ne 'string';
        return ("metac_string_list_push(&$recv_info->{c_name}, $arg_code)", 'number');
    }

    compile_error("Unsupported method call '$method' on type '$recv_type'");
}

1;
