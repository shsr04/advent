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
        if (type_is_bool_or_error($fn->{return_type})) {
            push @out, "static ResultBool $name($sig_params);";
            next;
        }
        if (type_is_string_or_error($fn->{return_type})) {
            push @out, "static ResultStringValue $name($sig_params);";
            next;
        }
        if (is_union_type($fn->{return_type}) && is_supported_generic_union_return($fn->{return_type})) {
            push @out, "static MetaCValue $name($sig_params);";
            next;
        }
        if (type_is_number_or_error($fn->{return_type})) {
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
        if ($fn->{return_type} eq 'string') {
            push @out, "static const char *$name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'number_or_null') {
            push @out, "static NullableNumber $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'number_list') {
            push @out, "static NumberList $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'number_list_list') {
            push @out, "static NumberListList $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'string_list') {
            push @out, "static StringList $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'bool_list') {
            push @out, "static BoolList $name($sig_params);";
            next;
        }
        if (is_array_type($fn->{return_type})) {
            push @out, "static AnyList $name($sig_params);";
            next;
        }
        if (is_matrix_type($fn->{return_type})) {
            my $meta = matrix_type_meta($fn->{return_type});
            push @out, "static MatrixNumber $name($sig_params);" if $meta->{elem} eq 'number';
            push @out, "static MatrixString $name($sig_params);" if $meta->{elem} eq 'string';
            push @out, "static MatrixOpaque $name($sig_params);" if $meta->{elem} ne 'number' && $meta->{elem} ne 'string';
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
