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
            ownership_scopes => [ [] ],
            tmp_counter      => 0,
            functions        => $function_sigs,
            loop_depth       => 0,
            rewind_labels    => [],
            helper_defs      => \@helper_defs,
            helper_counter   => 0,
            current_function => $current_function,
            active_temp_cleanups => [],
        },
        \@helper_defs,
    );
}

sub _helper_def_name {
    my ($block) = @_;
    return undef if !defined $block;
    my ($first_line) = split /\n/, $block, 2;
    return undef if !defined $first_line;
    if ($first_line =~ /^\s*static\b.*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/) {
        return $1;
    }
    return undef;
}

sub _prune_unused_helper_defs {
    my ($helper_defs, $consumer_code) = @_;
    return [] if !defined $helper_defs || ref($helper_defs) ne 'ARRAY' || !@$helper_defs;
    $consumer_code = '' if !defined $consumer_code;

    my @ordered_named;
    my %block_by_name;
    my @always_keep;
    for my $block (@$helper_defs) {
        my $name = _helper_def_name($block);
        if (!defined $name) {
            push @always_keep, $block;
            next;
        }
        next if exists $block_by_name{$name};
        $block_by_name{$name} = $block;
        push @ordered_named, $name;
    }

    my %deps;
    for my $name (@ordered_named) {
        my $body = $block_by_name{$name};
        my @calls;
        for my $callee (@ordered_named) {
            next if $callee eq $name;
            push @calls, $callee if $body =~ /\b\Q$callee\E\b/;
        }
        $deps{$name} = \@calls;
    }

    my @roots;
    for my $name (@ordered_named) {
        push @roots, $name if $consumer_code =~ /\b\Q$name\E\b/;
    }

    my %keep = map { $_ => 1 } @roots;
    my @stack = @roots;
    while (@stack) {
        my $name = pop @stack;
        for my $callee (@{ $deps{$name} // [] }) {
            next if $keep{$callee};
            $keep{$callee} = 1;
            push @stack, $callee;
        }
    }

    my @kept = @always_keep;
    for my $name (@ordered_named) {
        next if !$keep{$name};
        push @kept, $block_by_name{$name};
    }
    return \@kept;
}

sub _prepend_helper_defs {
    my ($helper_defs, $fn_code) = @_;
    my $kept = _prune_unused_helper_defs($helper_defs, $fn_code);
    return $fn_code if !@$kept;
    return join("\n", @$kept) . "\n" . $fn_code;
}

sub _function_code_with_usage_tracked_locals {
    my ($lines) = @_;
    my @out = @$lines;
    my $fn_code = join("\n", @out) . "\n";
    my $uses_line_no = $fn_code =~ /\b__metac_line_no\b/ ? 1 : 0;
    my $uses_err = $fn_code =~ /\b__metac_err\b/ ? 1 : 0;

    my @locals;
    push @locals, '  int __metac_line_no = 0;' if $uses_line_no;
    push @locals, '  char __metac_err[160];' if $uses_err;
    splice @out, 1, 0, @locals if @locals;

    return join("\n", @out) . "\n";
}

sub compile_main_body_generic_number {
    my ($main_fn, $function_sigs) = @_;
    my $stmts = parse_function_body($main_fn);
    my @out;
    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, 'main');

    push @out, 'int main(void) {';
    compile_block($stmts, $ctx, \@out, 2, 'number');
    emit_scope_owned_cleanups($ctx, \@out, 2);
    push @out, '  return 0;';
    push @out, '}';

    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
}



sub compile_number_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number | error")
      if !defined($fn->{return_type}) || !type_is_number_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultNumber $fn->{name}($sig_params) {";

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    emit_scope_owned_cleanups($ctx, \@out, 2);
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_number($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
}

sub compile_bool_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: bool | error")
      if !defined($fn->{return_type}) || !type_is_bool_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultBool $fn->{name}($sig_params) {";

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    emit_scope_owned_cleanups($ctx, \@out, 2);
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_bool($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
}

sub compile_string_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: string | error")
      if !defined($fn->{return_type}) || !type_is_string_or_error($fn->{return_type});

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultStringValue $fn->{name}($sig_params) {";

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    emit_scope_owned_cleanups($ctx, \@out, 2);
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_string_value($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
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

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, $fn->{return_type});
    compile_block($stmts, $ctx, \@out, 2, $fn->{return_type});
    emit_scope_owned_cleanups($ctx, \@out, 2);
    my $fallback = _default_generic_union_return_expr($fn->{return_type});
    push @out, "  return $fallback;";
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
}


sub compile_number_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static int64_t $fn->{name}($sig_params) {";

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, 'number');
    compile_block($stmts, $ctx, \@out, 2, 'number');
    emit_scope_owned_cleanups($ctx, \@out, 2);
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
}


sub compile_bool_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: bool")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'bool';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static int $fn->{name}($sig_params) {";

    my ($ctx, $helper_defs) = _new_codegen_ctx($function_sigs, $fn->{name});

    emit_param_bindings($params, $ctx, \@out, 2, 'bool');
    compile_block($stmts, $ctx, \@out, 2, 'bool');
    emit_scope_owned_cleanups($ctx, \@out, 2);
    push @out, '  return 0;';
    push @out, '}';
    my $fn_code = _function_code_with_usage_tracked_locals(\@out);
    return _prepend_helper_defs($helper_defs, $fn_code);
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
    my ($c_code, undef) = compile_source_via_vnf_hir($source);
    return $c_code;
}

sub compile_source_with_hir_dump {
    my ($source) = @_;
    return compile_source_via_vnf_hir($source);
}


1;

1;
