package MetaC::Codegen;
use strict;
use warnings;
use MetaC::IntrinsicRegistry qw(method_base_specs method_from_op_id);

sub method_specs {
    return method_base_specs();
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
    if (type_is_number_or_error($sig->{return_type})) {
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
        my $mapper = map_mapper_info($expr, $ctx);
        if ($mapper->{return_mode} eq 'number_or_error') {
            return "Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)";
        }
    }
    return undef;
}

1;
