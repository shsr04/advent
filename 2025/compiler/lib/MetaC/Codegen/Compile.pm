package MetaC::Codegen;
use strict;
use warnings;

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

1;
