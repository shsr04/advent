package MetaC::Codegen;
use strict;
use warnings;

sub _new_codegen_ctx {
    my ($function_sigs, $current_function) = @_;
    my @helper_defs;
    return (
        {
            scopes           => [ {} ],
            fact_scopes      => [ {} ],
            nonnull_scopes   => [ {} ],
            tmp_counter      => 0,
            functions        => $function_sigs,
            loop_depth       => 0,
            helper_defs      => \@helper_defs,
            helper_counter   => 0,
            current_function => $current_function,
        },
        \@helper_defs,
    );
}

sub compile_main_body_generic_void {
    my ($main_fn, $function_sigs) = @_;
    my $stmts = parse_function_body($main_fn);
    my @out;
    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, 'main');

    push @out, 'int main(void) {';
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';
    compile_block($stmts, $ctx, \@out, 2, 'void');
    push @out, '  return 0;';
    push @out, '}';

    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
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

        if (is_matrix_type($param->{type})) {
            my $meta = matrix_type_meta($param->{type});
            if ($meta->{elem} eq 'number') {
                emit_line($out, $indent, "const MatrixNumber $name = $in_name;");
            } elsif ($meta->{elem} eq 'string') {
                emit_line($out, $indent, "const MatrixString $name = $in_name;");
            } else {
                compile_error("Unsupported matrix parameter element type '$meta->{elem}'");
            }
            declare_var(
                $ctx,
                $name,
                {
                    type      => $param->{type},
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
      if !defined($fn->{return_type}) || !type_is_number_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultNumber $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_number($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
}

sub compile_bool_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: bool | error")
      if !defined($fn->{return_type}) || !type_is_bool_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultBool $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_bool($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
}

sub compile_string_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: string | error")
      if !defined($fn->{return_type}) || !type_is_string_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultStringValue $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_string_value($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
}

sub _default_generic_union_return_expr {
    my ($return_type) = @_;
    my $members = union_member_types($return_type);
    my $first = $members->[0];
    return "metac_value_number(0)" if $first eq 'number';
    return "metac_value_bool(0)" if $first eq 'bool';
    return "metac_value_string(\"\")" if $first eq 'string';
    return "metac_value_null()" if $first eq 'null';
    return "metac_value_error(\"Missing return\", __metac_line_no, \"\")" if $first eq 'error';
    return "metac_value_error(\"Missing return\", __metac_line_no, \"\")";
}

sub compile_generic_union_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' has unsupported generic union return type '$fn->{return_type}'")
      if !defined($fn->{return_type}) || !is_supported_generic_union_return($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static MetaCValue $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    my $fallback = _default_generic_union_return_expr($fn->{return_type});
    push @out, "  return $fallback;";
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
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

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, 'number');
    compile_block($stmts, $ctx, \@out, 2, 'number');
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
    }
    return $fn_code;
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

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, 'bool');
    compile_block($stmts, $ctx, \@out, 2, 'bool');
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = join("\n", @out) . "\n";
    if (@$helper_defs) {
        return join("\n", @$helper_defs) . "\n" . $fn_code;
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
        if (type_is_bool_or_error($fn->{return_type})) {
            push @out, "static ResultBool $name($sig_params);";
            next;
        }
        if (type_is_string_or_error($fn->{return_type})) {
            push @out, "static ResultStringValue $name($sig_params);";
            next;
        }
        if (is_supported_generic_union_return($fn->{return_type})) {
            push @out, "static MetaCValue $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'bool') {
            push @out, "static int $name($sig_params);";
            next;
        }
        if (type_is_number_or_error($fn->{return_type})) {
            push @out, "static ResultNumber $name($sig_params);";
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
    compile_error("main must not declare arguments") if $main->{args} ne '';

    my %number_error_functions;
    my %bool_error_functions;
    my %string_error_functions;
    my %generic_union_functions;
    my %number_functions;
    my %bool_functions;
    my %function_sigs;
    my @ordered_names = sort grep { $_ ne 'main' } keys %$functions;
    for my $name (@ordered_names) {
        my $fn = $functions->{$name};
        if (defined $fn->{return_type}) {
            $fn->{return_type} = normalize_type_annotation($fn->{return_type});
        }
        $fn->{parsed_params} = parse_function_params($fn);
        $function_sigs{$name} = {
            return_type => $fn->{return_type},
            params      => $fn->{parsed_params},
        };

        if (defined $fn->{return_type} && type_is_number_or_error($fn->{return_type})) {
            $number_error_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && type_is_bool_or_error($fn->{return_type})) {
            $bool_error_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && type_is_string_or_error($fn->{return_type})) {
            $string_error_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && is_supported_generic_union_return($fn->{return_type})) {
            $generic_union_functions{$name} = 1;
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
        compile_error("Unsupported function return type for '$name'; supported: number | error, bool | error, string | error, generic unions over number/bool/string/error/null, number, bool");
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
        if ($bool_error_functions{$name}) {
            $non_runtime .= compile_bool_or_error_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $non_runtime .= "\n";
            next;
        }
        if ($string_error_functions{$name}) {
            $non_runtime .= compile_string_or_error_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $non_runtime .= "\n";
            next;
        }
        if ($generic_union_functions{$name}) {
            $non_runtime .= compile_generic_union_function(
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
    my $main_code = compile_main_body_generic_void($main, \%function_sigs);
    $non_runtime .= $main_code;

    my $c = runtime_prelude_for_code($non_runtime);
    $c .= "\n";
    $c .= $non_runtime;
    return $c;
}


1;

1;
