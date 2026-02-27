package MetaC::Codegen;
use strict;
use warnings;
use MetaC::IntrinsicRegistry qw(method_base_specs method_from_op_id);

sub method_specs {
    return method_base_specs();
}

sub _map_item_type_from_receiver {
    my ($recv_type) = @_;
    return 'string' if ($recv_type // '') eq 'string_list';
    return 'number' if ($recv_type // '') eq 'number_list';
    return 'bool' if ($recv_type // '') eq 'bool_list';
    return undef;
}

sub _map_list_type_for_item_type {
    my ($item_type) = @_;
    return 'string_list' if ($item_type // '') eq 'string';
    return 'number_list' if ($item_type // '') eq 'number';
    return 'bool_list' if ($item_type // '') eq 'bool';
    return undef;
}

sub _map_lambda_return_info {
    my ($lambda, $item_type, $ctx) = @_;
    compile_error("map(...) expects mapper as function identifier or single-parameter lambda")
      if ($lambda->{kind} // '') ne 'lambda1';

    my $lambda_ctx = {
        scopes          => [ {} ],
        fact_scopes     => [ {} ],
        nonnull_scopes  => [ {} ],
        tmp_counter     => $ctx->{tmp_counter},
        functions       => $ctx->{functions},
        loop_depth      => 0,
        helper_defs     => [],
        helper_counter  => $ctx->{helper_counter},
        current_function => $ctx->{current_function},
    };
    declare_var(
        $lambda_ctx,
        $lambda->{param},
        {
            type      => $item_type,
            immutable => 1,
            c_name    => $lambda->{param},
        }
    );
    my (undef, $body_type) = compile_expr($lambda->{body}, $lambda_ctx);
    my $non_error = non_error_member_of_error_union($body_type);
    return {
        return_type       => $body_type,
        non_error_type    => $non_error,
        is_error_union    => (defined($non_error) && $body_type ne $non_error) ? 1 : 0,
    };
}

sub map_mapper_info {
    my ($expr, $ctx, $recv_type) = @_;
    my $actual = scalar @{ $expr->{args} };
    compile_error("map(...) expects exactly 1 function arg, got $actual")
      if $actual != 1;

    my $item_type = _map_item_type_from_receiver($recv_type // 'string_list');
    compile_error("map(...) receiver must be string_list, number_list, or bool_list, got $recv_type")
      if !defined $item_type;

    my $mapper = $expr->{args}[0];
    if (($mapper->{kind} // '') eq 'lambda1') {
        my $info = _map_lambda_return_info($mapper, $item_type, $ctx);
        my $out_item = $info->{return_type};
        if (defined $info->{non_error_type} && $info->{non_error_type} eq $item_type) {
            $out_item = $item_type;
        }
        my $out_list = _map_list_type_for_item_type($out_item);
        compile_error("map(...) lambda must return $item_type or $item_type | error")
          if !defined $out_list;
        compile_error("map(...) lambda must return $item_type or $item_type | error")
          if $out_item ne $item_type;
        return {
            name             => '<lambda>',
            kind             => 'lambda',
            return_mode      => $info->{is_error_union} ? 'same_or_error' : 'same',
            builtin          => 0,
            input_type       => $item_type,
            output_type      => $item_type,
            output_list_type => _map_list_type_for_item_type($item_type),
        };
    }

    compile_error("map(...) expects function identifier argument")
      if ($mapper->{kind} // '') ne 'ident';
    my $mapper_name = $mapper->{name};

    if ($mapper_name eq 'parseNumber') {
        compile_error("map(parseNumber) requires string_list receiver")
          if $item_type ne 'string';
        return {
            name        => $mapper_name,
            kind        => 'ident',
            return_mode => 'number_or_error',
            builtin     => 1,
            input_type  => 'string',
            output_type => 'number',
            output_list_type => 'number_list',
        };
    }

    my $functions = $ctx->{functions} // {};
    my $sig = $functions->{$mapper_name};
    compile_error("Unknown mapper function '$mapper_name' in map(...)")
      if !defined $sig;
    my $expected = scalar @{ $sig->{params} };
    compile_error("map(...) mapper '$mapper_name' must accept exactly 1 arg")
      if $expected != 1;
    compile_error("map(...) mapper '$mapper_name' arg type must be $item_type")
      if $sig->{params}[0]{type} ne $item_type;

    if ($sig->{return_type} eq $item_type) {
        return {
            name        => $mapper_name,
            kind        => 'ident',
            return_mode => 'same',
            builtin     => 0,
            input_type  => $item_type,
            output_type => $item_type,
            output_list_type => _map_list_type_for_item_type($item_type),
        };
    }
    if (defined(non_error_member_of_error_union($sig->{return_type}))
        && non_error_member_of_error_union($sig->{return_type}) eq $item_type)
    {
        return {
            name        => $mapper_name,
            kind        => 'ident',
            return_mode => 'same_or_error',
            builtin     => 0,
            input_type  => $item_type,
            output_type => $item_type,
            output_list_type => _map_list_type_for_item_type($item_type),
        };
    }

    if ($item_type eq 'string') {
        if ($sig->{return_type} eq 'number') {
            return {
                name        => $mapper_name,
                kind        => 'ident',
                return_mode => 'number',
                builtin     => 0,
                input_type  => 'string',
                output_type => 'number',
                output_list_type => 'number_list',
            };
        }
        if (type_is_number_or_error($sig->{return_type})) {
            return {
                name        => $mapper_name,
                kind        => 'ident',
                return_mode => 'number_or_error',
                builtin     => 0,
                input_type  => 'string',
                output_type => 'number',
                output_list_type => 'number_list',
            };
        }
    }

    compile_error("map(...) mapper '$mapper_name' must return $item_type or $item_type | error");
}

sub method_fallibility_diagnostic {
    my ($expr, $recv_type, $ctx) = @_;
    my $method = $expr->{method};
    if ((!defined($method) || $method eq '') && defined($expr->{resolved_call}) && ref($expr->{resolved_call}) eq 'HASH') {
        $method = $expr->{resolved_call}{method_name}
          if defined($expr->{resolved_call}{method_name}) && $expr->{resolved_call}{method_name} ne '';
        if ((!defined($method) || $method eq '')) {
            $method = method_from_op_id($expr->{resolved_call}{op_id} // '');
        }
    }
    return undef if !defined($method) || $method eq '';

    if (is_matrix_type($recv_type) && $method eq 'insert') {
        my $meta = matrix_type_meta($recv_type);
        if (!$meta->{has_size}) {
            return "Method 'insert(...)' is fallible on unconstrained matrix; handle it with '?'";
        }
        return undef;
    }

    my $spec = method_specs()->{$method};
    return undef if !defined $spec;
    return undef if !exists $spec->{receivers}{$recv_type};

    if ($spec->{fallibility} eq 'always') {
        return "Method '$method(...)' is fallible; handle it with '?' (or an explicit error handler)";
    }
    if ($spec->{fallibility} eq 'mapper') {
        my $mapper = map_mapper_info($expr, $ctx, $recv_type);
        if ($mapper->{return_mode} eq 'number_or_error' || $mapper->{return_mode} eq 'same_or_error') {
            return "Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)";
        }
    }
    return undef;
}

1;
