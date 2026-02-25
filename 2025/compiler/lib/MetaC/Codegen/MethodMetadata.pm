package MetaC::Codegen;
use strict;
use warnings;

sub method_specs {
    return {
        size => {
            receivers     => { string => 1, string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1, indexed_number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        chunk => {
            receivers     => { string => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        chars => {
            receivers     => { string => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        isBlank => {
            receivers     => { string => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        split => {
            receivers     => { string => 1 },
            arity         => 1,
            expr_callable => 0,
            fallibility   => 'always',
        },
        slice => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        max => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        sort => {
            receivers     => { number_list => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        sortBy => {
            receivers     => { number_list_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        compareTo => {
            receivers     => { number => 1, indexed_number => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        andThen => {
            receivers     => { number => 1, indexed_number => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        index => {
            receivers     => { indexed_number => 1 },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        log => {
            receivers     => {
                string              => 1,
                number              => 1,
                bool                => 1,
                indexed_number      => 1,
                string_list         => 1,
                number_list         => 1,
                bool_list           => 1,
                indexed_number_list => 1,
            },
            arity         => 0,
            expr_callable => 1,
            fallibility   => 'never',
        },
        map => {
            receivers     => { string_list => 1 },
            arity         => 1,
            expr_callable => 0,
            fallibility   => 'mapper',
        },
        filter => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 1,
            expr_callable => 0,
            fallibility   => 'never',
        },
        any => {
            receivers     => { string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
        reduce => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 2,
            expr_callable => 1,
            fallibility   => 'never',
        },
        assert => {
            receivers     => { string_list => 1, number_list => 1 },
            arity         => 2,
            expr_callable => 0,
            fallibility   => 'always',
        },
        push => {
            receivers     => { string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1 },
            arity         => 1,
            expr_callable => 1,
            fallibility   => 'never',
        },
    };
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
