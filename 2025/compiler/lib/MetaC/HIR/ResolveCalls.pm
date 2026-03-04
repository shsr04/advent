package MetaC::HIR::ResolveCalls;
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(refaddr);
use MetaC::Support qw(
    compile_error
    set_error_line
    clear_error_line
);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt stmt_to_payload);
use MetaC::HIR::OpRegistry qw(
    user_call_op_id
    user_method_style_allowed
    builtin_is_known
    builtin_op_id
    builtin_result_type
    builtin_param_contract
    method_is_known
    method_receiver_supported
    method_op_id
    method_result_type
    method_dynamic_result_policy
    method_fallibility_hint
    method_traceability_hint
    method_requires_matrix_axis_argument
    method_callback_contract
    method_param_contract
);
use MetaC::HIR::TypeRegistry qw(
    canonical_scalar_base
    scalar_is_boolean
    scalar_is_comparison
    scalar_is_numeric
    scalar_is_string
);

use MetaC::TypeSpec qw(
    is_union_type
    union_contains_member
    union_member_types
    is_supported_value_type
    is_supported_generic_union_return
    is_array_type
    is_sequence_type
    is_matrix_member_type
    is_matrix_member_list_type
    sequence_element_type
    sequence_type_for_element
    sequence_member_type
    is_sequence_member_type
    sequence_member_meta
    is_matrix_type
    matrix_type_meta
    matrix_member_meta
);

our @EXPORT_OK = qw(resolve_hir_calls);

sub _single_non_error_member_from_error_union {
    my ($type) = @_;
    return undef if !defined($type);
    return undef if !is_union_type($type);
    return undef if !union_contains_member($type, 'error');
    my @members = grep { $_ ne 'error' } @{ union_member_types($type) };
    return undef if @members != 1;
    return $members[0];
}

sub _type_without_error_union_member {
    my ($type) = @_;
    return undef if !defined($type) || !is_union_type($type) || !union_contains_member($type, 'error');
    my %uniq = map { $_ => 1 } grep { $_ ne 'error' } @{ union_member_types($type) };
    return undef if !%uniq;
    my @members = sort keys %uniq;
    return $members[0] if @members == 1;
    return join(' | ', @members);
}

sub _function_sigs {
    my ($hir) = @_;
    my %sigs;
    for my $fn (@{ $hir->{functions} // [] }) {
        $sigs{ $fn->{name} } = {
            return_type => $fn->{return_type},
            params      => $fn->{params},
        };
    }
    return \%sigs;
}

sub _env_from_params {
    my ($params) = @_;
    my %env;
    $env{STDIN} = 'string';
    for my $p (@{ $params // [] }) {
        my $name = $p->{name};
        my $type = $p->{type};
        next if !defined($name) || $name eq '';
        $env{$name} = $type if defined($type) && $type ne '';
    }
    return \%env;
}

sub _clone_env {
    my ($env) = @_;
    return { %{ $env // {} } };
}

sub _iterable_item_type_hint {
    my ($iterable_type) = @_;
    my $elem = sequence_element_type($iterable_type);
    return undef if !defined($elem);
    return $elem if is_matrix_member_type($elem);
    return sequence_member_type($elem);
}

sub _sequence_member_base_type {
    my ($type) = @_;
    return $type if !defined($type) || $type eq '';
    if (is_union_type($type)) {
        my %uniq;
        for my $m (@{ union_member_types($type) }) {
            if (is_sequence_member_type($m)) {
                my $meta = sequence_member_meta($m);
                $m = $meta->{elem} if defined($meta) && defined($meta->{elem});
            }
            if (is_matrix_member_type($m)) {
                my $meta = matrix_member_meta($m);
                $m = $meta->{elem} if defined($meta) && defined($meta->{elem});
            }
            $uniq{$m} = 1 if defined($m) && $m ne '';
        }
        return join(' | ', sort keys %uniq);
    }
    if (is_sequence_member_type($type)) {
        my $meta = sequence_member_meta($type);
        $type = defined($meta) ? $meta->{elem} : $type;
    }
    if (is_matrix_member_type($type)) {
        my $meta = matrix_member_meta($type);
        $type = defined($meta) ? $meta->{elem} : $type;
    }
    return $type;
}

sub _list_literal_item_type_category {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    my $base = _sequence_member_base_type($type);
    my $scalar_base = canonical_scalar_base($base);
    return $scalar_base if defined($scalar_base) && $scalar_base ne '';
    return $base;
}

sub _callback_type_valid {
    my ($type) = @_;
    return 0 if !defined($type) || $type eq '' || $type eq 'unknown' || $type eq 'inferred' || $type eq 'empty_list';
    return 1 if scalar_is_comparison($type);
    return 1 if is_supported_value_type($type);
    return 1 if is_supported_generic_union_return($type);
    return 1 if is_array_type($type) || is_matrix_type($type) || is_matrix_member_type($type) || is_matrix_member_list_type($type);
    if (is_union_type($type)) {
        my $members = union_member_types($type);
        for my $m (@$members) {
            return 0 if !_callback_type_valid($m);
        }
        return 1;
    }
    return 0;
}

sub _matches_base_or_error {
    my ($actual, $base) = @_;
    return 1 if defined($base) && $base eq 'any' && defined($actual) && $actual ne '';
    return 1 if defined($actual) && $actual eq $base;
    return 0 if !defined($actual) || !is_union_type($actual) || !union_contains_member($actual, 'error');
    return 1 if defined($base) && $base eq 'any';
    my @rest = grep { $_ ne 'error' } @{ union_member_types($actual) };
    return @rest == 1 && $rest[0] eq $base ? 1 : 0;
}

sub _resolve_callback_type_symbol {
    my (%args) = @_;
    my $symbol = $args{symbol};
    my $ctx = $args{ctx} // {};
    my $method = $args{method} // '';
    my $part = $args{part} // 'type';
    return undef if !defined($symbol) || $symbol eq '';
    return $symbol if scalar_is_boolean($symbol) || scalar_is_comparison($symbol) || $symbol eq 'any';
    return $ctx->{$symbol} if exists $ctx->{$symbol};
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has unknown $part symbol '$symbol'");
}

sub _method_param_type_compatible {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || $actual eq 'unknown';
    return 0 if !defined($expected) || $expected eq '' || $expected eq 'unknown';
    $actual = _sequence_member_base_type($actual);
    my $actual_non_error = _single_non_error_member_from_error_union($actual);
    $actual = $actual_non_error if defined($actual_non_error) && $actual_non_error ne '';

    my @actual_members = is_union_type($actual) ? @{ union_member_types($actual) } : ($actual);
    my @expected_members = is_union_type($expected) ? @{ union_member_types($expected) } : ($expected);

    for my $a (@actual_members) {
        my $ok = 0;
        for my $e (@expected_members) {
            if ($e eq 'any') {
                $ok = 1;
                last;
            }
            if ($a eq $e) {
                $ok = 1;
                last;
            }
            if ($e eq 'number' && scalar_is_numeric($a)) {
                $ok = 1;
                last;
            }
        }
        return 0 if !$ok;
    }
    return 1;
}

sub _expected_param_type_valid {
    my ($expected) = @_;
    return 1 if defined($expected) && $expected eq 'any';
    return _callback_type_valid($expected);
}

sub _verify_callback_signature {
    my (%args) = @_;
    my $method = $args{method};
    my $role = $args{role};
    my $expr = $args{expr};
    my $arity = int($args{arity} // 0);
    my $param_types = $args{param_types} // [];
    my $return_base = $args{return_base};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $has_bad_param = scalar(grep { !_callback_type_valid($_) } @$param_types) > 0 ? 1 : 0;

    compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role has invalid expected type contract")
      if !$arity || @$param_types != $arity || $has_bad_param || (!defined($return_base) || ($return_base ne 'any' && !_callback_type_valid($return_base)));
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role must be provided")
      if !defined($expr) || ref($expr) ne 'HASH';

    my $kind = $expr->{kind} // '';
    my $return_t;
    if ($kind eq 'lambda1' || $kind eq 'lambda2') {
        my @params = $kind eq 'lambda1' ? (($expr->{param} // '')) : (($expr->{param1} // ''), ($expr->{param2} // ''));
        compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role expects $arity parameter(s)")
          if @params != $arity || grep { $_ eq '' } @params;
        my $lambda_env = _clone_env($env);
        for my $i (0 .. $#params) {
            $lambda_env->{$params[$i]} = $param_types->[$i];
        }
        $return_t = _infer_expr_type_hint($expr->{body}, $lambda_env, $sigs, {});
    } elsif ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        my $sig = $sigs->{$name};
        if (defined($sig) && ref($sig) eq 'HASH') {
            my $params = $sig->{params} // [];
            compile_error("ResolveCalls/F050-Callback-Signature: callback function '$name' for '$method' $role expects $arity parameter(s)")
              if ref($params) ne 'ARRAY' || @$params != $arity;
            for my $i (0 .. $arity - 1) {
                my $decl = $params->[$i]{type};
                my $expect = $param_types->[$i];
                compile_error("ResolveCalls/F050-Callback-Signature: callback function '$name' parameter " . ($i + 1) . " type must be '$expect'")
                  if !_callback_type_valid($decl) || $decl ne $expect;
            }
            $return_t = $sig->{return_type};
        } elsif (builtin_is_known($name)) {
            my $param_contract = builtin_param_contract($name);
            compile_error("ResolveCalls/F050-Callback-Signature: builtin callback '$name' has invalid parameter policy")
              if !defined($param_contract) || ref($param_contract) ne 'HASH';
            my $policy = $param_contract->{policy} // 'unknown';
            my $decl_types = $param_contract->{param_types} // [];
            compile_error("ResolveCalls/F050-Callback-Signature: builtin callback '$name' for '$method' $role expects fixed arity")
              if $policy ne 'fixed' || ref($decl_types) ne 'ARRAY' || @$decl_types != $arity;
            for my $i (0 .. $arity - 1) {
                my $expect = $decl_types->[$i];
                my $actual = $param_types->[$i];
                compile_error("ResolveCalls/F050-Callback-Signature: builtin callback '$name' parameter " . ($i + 1) . " type mismatch")
                  if !_method_param_type_compatible($actual, $expect);
            }
            my %pt;
            my @args;
            for my $i (0 .. $arity - 1) {
                my $an = "__cb_arg_$i";
                $pt{$an} = $param_types->[$i];
                push @args, { kind => 'ident', name => $an };
            }
            $return_t = builtin_result_type(
                $name,
                \@args,
                sub {
                    my ($arg_expr) = @_;
                    return undef if !defined($arg_expr) || ref($arg_expr) ne 'HASH';
                    return $pt{ $arg_expr->{name} // '' };
                },
            );
        } else {
            compile_error("ResolveCalls/F050-Callback-Signature: unknown callback function '$name' for '$method' $role");
        }
    } else {
        compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role must be a lambda or named function reference");
    }

    compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role return type is unresolved")
      if !defined($return_t) || $return_t eq '' || $return_t eq 'unknown';
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role return type '$return_t' is invalid")
      if !_callback_type_valid($return_t);
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' $role must return '$return_base' or '$return_base | error' (got '$return_t')")
      if !_matches_base_or_error($return_t, $return_base);
}

sub _verify_method_callback_contract {
    my (%args) = @_;
    my $method = $args{method} // '';
    my $recv_type = $args{recv_type};
    my $arg_exprs = $args{arg_exprs} // [];
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $contract = method_callback_contract($method);
    return if !defined($contract);

    my $arg_count = int($contract->{total_arg_count} // 0);
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has invalid arg count")
      if $arg_count <= 0;
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' expects exactly $arg_count argument(s)")
      if @$arg_exprs != $arg_count;

    my $elem_t = sequence_element_type($recv_type);
    compile_error("ResolveCalls/F050-Callback-Signature: cannot infer sequence element type for '$method' receiver '$recv_type'")
      if !defined($elem_t) || !_callback_type_valid($elem_t);
    my %ctx = (elem => $elem_t, receiver => $recv_type);

    if (defined($contract->{initial_arg_index})) {
        my $initial_idx = int($contract->{initial_arg_index});
        compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has invalid initial argument index")
          if $initial_idx < 0 || $initial_idx >= @$arg_exprs;
        my $initial_t = _infer_expr_type_hint($arg_exprs->[$initial_idx], $env, $sigs, {});
        compile_error("ResolveCalls/F050-Callback-Signature: '$method' initial value type is unresolved")
          if !defined($initial_t) || !_callback_type_valid($initial_t);
        my $initial_policy = $contract->{initial_type_policy} // 'any_valid';
        if ($initial_policy eq 'elem' && $initial_t ne $elem_t) {
            compile_error("ResolveCalls/F050-Callback-Signature: '$method' initial value must have element type '$elem_t' (got '$initial_t')");
        }
        compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has invalid initial policy '$initial_policy'")
          if $initial_policy ne 'any_valid' && $initial_policy ne 'elem';
        $ctx{initial} = $initial_t;
    }

    my $callback_idx = int($contract->{callback_arg_index} // -1);
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has invalid callback argument index")
      if $callback_idx < 0 || $callback_idx >= @$arg_exprs;
    my $callback_arity = int($contract->{callback_arity} // 0);
    my $param_symbols = $contract->{param_type_symbols} // [];
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has invalid parameter symbols")
      if ref($param_symbols) ne 'ARRAY' || $callback_arity <= 0 || @$param_symbols != $callback_arity;
    my @params = map {
        _resolve_callback_type_symbol(
            symbol => $_,
            ctx => \%ctx,
            method => $method,
            part => 'parameter',
        );
    } @$param_symbols;
    my $return_base = _resolve_callback_type_symbol(
        symbol => $contract->{return_type_symbol},
        ctx => \%ctx,
        method => $method,
        part => 'return',
    );

    _verify_callback_signature(
        method      => $method,
        role        => 'callback',
        expr        => $arg_exprs->[$callback_idx],
        arity       => $callback_arity,
        param_types => \@params,
        return_base => $return_base,
        env         => $env,
        sigs        => $sigs,
    );
}

sub _verify_method_parameter_contract {
    my (%args) = @_;
    my $method = $args{method} // '';
    my $recv_type = $args{recv_type};
    my $arg_exprs = $args{arg_exprs} // [];
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $contract = method_param_contract($method, $recv_type);
    compile_error("ResolveCalls/F050-Param-Policy: method '$method' has invalid parameter policy")
      if !defined($contract) || ref($contract) ne 'HASH';
    my $traceability = method_traceability_hint($method) // '';
    if ($traceability eq 'requires_source_matrix_member_metadata' && defined($recv_type) && is_matrix_type($recv_type)) {
        my $actual = (ref($arg_exprs) eq 'ARRAY' && @$arg_exprs)
          ? _infer_expr_type_hint($arg_exprs->[0], $env, $sigs, {})
          : undef;
        my $expected = sequence_type_for_element('number');
        compile_error("ResolveCalls/F050-Param-Policy: Method '$method(...)' requires value with source matrix-member metadata")
          if !_method_param_type_compatible($actual, $expected);
    }

    return _verify_param_contract(
        label => "method '$method'",
        policy => $contract->{policy},
        arity => $contract->{arity},
        param_types => $contract->{param_types},
        arg_exprs => $arg_exprs,
        env => $env,
        sigs => $sigs,
        allow_callback_contract => 1,
    );
}

sub _traceability_requirement_applies_for_receiver {
    my ($hint, $recv_type) = @_;
    return 0 if !defined($hint) || $hint eq '';
    return 1 if $hint eq 'requires_source_index_metadata';
    return (defined($recv_type) && is_matrix_type($recv_type)) ? 1 : 0
      if $hint eq 'requires_source_matrix_member_metadata';
    return 0;
}

sub _traceability_requirement_diagnostic {
    my ($method, $hint) = @_;
    return undef if !defined($hint) || $hint eq '';
    return "ResolveCalls/F050-Traceability: method '$method' requires value with source index metadata"
      if $hint eq 'requires_source_index_metadata';
    return "ResolveCalls/F050-Traceability: method '$method' requires value with source matrix-member metadata"
      if $hint eq 'requires_source_matrix_member_metadata';
    return undef;
}

sub _verify_param_contract {
    my (%args) = @_;
    my $label = $args{label} // 'call';
    my $policy = $args{policy} // 'unknown';
    my $arity = int($args{arity} // -1);
    my $param_types = $args{param_types} // [];
    my $arg_exprs = $args{arg_exprs} // [];
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $allow_callback_contract = $args{allow_callback_contract} ? 1 : 0;

    compile_error("ResolveCalls/F050-Param-Policy: $label has unknown parameter policy")
      if $policy eq 'unknown';
    if ($policy eq 'callback_contract') {
        compile_error("ResolveCalls/F050-Param-Policy: $label has unsupported callback parameter policy")
          if !$allow_callback_contract;
        return 'callback_contract';
    }
    compile_error("ResolveCalls/F050-Param-Policy: $label parameter contract is invalid")
      if ($policy ne 'none' && $policy ne 'fixed') || $arity < 0 || ref($param_types) ne 'ARRAY' || @$param_types != $arity;
    compile_error("ResolveCalls/F050-Param-Policy: $label expects exactly $arity argument(s)")
      if @$arg_exprs != $arity;

    for my $i (0 .. $arity - 1) {
        my $actual = _infer_expr_type_hint($arg_exprs->[$i], $env, $sigs, {});
        my $expected = $param_types->[$i];
        compile_error("ResolveCalls/F050-Param-Policy: $label has invalid expected parameter type '$expected'")
          if !_expected_param_type_valid($expected);
        compile_error("ResolveCalls/F050-Param-Policy: $label argument " . ($i + 1) . " type is unresolved")
          if !defined($actual) || $actual eq '' || $actual eq 'unknown';
        compile_error("ResolveCalls/F050-Param-Policy: $label argument " . ($i + 1) . " type must be '$expected' (got '$actual')")
          if !_method_param_type_compatible($actual, $expected);
    }
    return 'checked';
}

sub _verify_named_call_parameter_contract {
    my (%args) = @_;
    my $name = $args{name} // '';
    my $arg_exprs = $args{arg_exprs} // [];
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $contract = $args{contract};
    my $call_kind = $args{call_kind} // 'call';
    compile_error("ResolveCalls/F050-Param-Policy: $call_kind '$name' has invalid parameter policy")
      if !defined($contract) || ref($contract) ne 'HASH';

    if ($call_kind eq 'builtin' && $name eq 'log') {
        my $actual = _infer_expr_type_hint($arg_exprs->[0], $env, $sigs, {});
        if (defined($actual) && is_union_type($actual) && @{ union_member_types($actual) } > 1) {
            compile_error("ResolveCalls/F050-Param-Policy: Builtin 'log' does not support argument type '$actual'");
        }
    }

    _verify_param_contract(
        label => "$call_kind '$name'",
        policy => $contract->{param_policy},
        arity => $contract->{param_arity},
        param_types => $contract->{param_type_contract},
        arg_exprs => $arg_exprs,
        env => $env,
        sigs => $sigs,
    );
}

sub _canonical_call_expr {
    my (%args) = @_;
    my $contract = $args{contract};
    my $kind = $contract->{call_kind} // '';
    my $canonical_kind = $kind eq 'intrinsic_method' ? 'intrinsic' : $kind;
    my $call_kind = $kind eq 'intrinsic_method' ? 'intrinsic_method' : $canonical_kind;
    my $result_type = $contract->{result_type};
    compile_error("ResolveCalls/F050-Result-Type: unresolved call result type for op '$contract->{op_id}'")
      if !defined($result_type) || $result_type eq '' || $result_type eq 'unknown';
    my $call = {
        node_kind   => 'CallExpr',
        kind        => $canonical_kind,
        call_kind   => $call_kind,
        op_id       => $contract->{op_id},
        arity       => int($contract->{arity} // 0),
        result_type => $result_type,
    };
    $call->{target_name} = $contract->{target_name} if defined $contract->{target_name};
    $call->{receiver_type_hint} = $contract->{receiver_type_hint}
      if defined $contract->{receiver_type_hint};
    return $call;
}

sub _call_result_type {
    my ($expr, $env, $sigs, $seen) = @_;
    my $name = $expr->{name} // '';
    if (exists $sigs->{$name}) {
        return $sigs->{$name}{return_type};
    }
    return builtin_result_type(
        $name,
        $expr->{args},
        sub {
            my ($arg_expr) = @_;
            return _infer_expr_type_hint($arg_expr, $env, $sigs, $seen);
        },
    );
}

sub _infer_mapped_sequence_type_hint {
    my (%args) = @_;
    my $expr = $args{expr};
    my $recv_t = $args{recv_t};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $seen = $args{seen};
    return undef if !defined($recv_t) || !is_sequence_type($recv_t);

    my $elem_t = sequence_element_type($recv_t);
    my $cb = $expr->{args}[0];
    my $cb_ret;
    if (defined($cb) && ref($cb) eq 'HASH' && (($cb->{kind} // '') eq 'ident')) {
        my $name = $cb->{name} // '';
        if (exists $sigs->{$name}) {
            $cb_ret = $sigs->{$name}{return_type};
        } elsif (builtin_is_known($name)) {
            my %pt = ('__cb_arg_0' => $elem_t);
            my @args = ({ kind => 'ident', name => '__cb_arg_0' });
            $cb_ret = builtin_result_type(
                $name,
                \@args,
                sub {
                    my ($arg_expr) = @_;
                    return undef if !defined($arg_expr) || ref($arg_expr) ne 'HASH';
                    return $pt{ $arg_expr->{name} // '' };
                },
            );
        }
    } elsif (defined($cb) && ref($cb) eq 'HASH' && (($cb->{kind} // '') eq 'lambda1')) {
        my $param = $cb->{param} // '__cb_arg_0';
        my %lambda_env = (%{ $env // {} }, $param => $elem_t);
        $cb_ret = _infer_expr_type_hint($cb->{body}, \%lambda_env, $sigs, $seen);
    }
    return undef if !defined($cb_ret) || $cb_ret eq '';

    my $base = _single_non_error_member_from_error_union($cb_ret);
    $base = $cb_ret if !defined($base);
    $base = _sequence_member_base_type($base);
    my $mapped = sequence_type_for_element($base);
    return $mapped . ' | error' if is_union_type($cb_ret) && union_contains_member($cb_ret, 'error');
    return $mapped;
}

sub _infer_method_dynamic_result_type_hint {
    my (%args) = @_;
    my $policy = $args{policy} // '';
    my $expr = $args{expr};
    my $recv_t = $args{recv_t};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $seen = $args{seen};

    if ($policy eq 'initial') {
        my $init_t = _infer_expr_type_hint($expr->{args}[0], $env, $sigs, $seen);
        return $init_t if defined($init_t) && $init_t ne '';
        return undef;
    }
    if ($policy eq 'sequence_of_initial') {
        my $init_t = _infer_expr_type_hint($expr->{args}[0], $env, $sigs, $seen);
        return sequence_type_for_element($init_t) if defined($init_t) && $init_t ne '';
        return undef;
    }
    if ($policy eq 'receiver') {
        return $recv_t if defined($recv_t) && $recv_t ne '';
        return undef;
    }
    if ($policy eq 'receiver_with_error') {
        return ($recv_t // '') eq '' ? undef : ($recv_t . ' | error');
    }
    if ($policy eq 'mapped_sequence') {
        return _infer_mapped_sequence_type_hint(
            expr   => $expr,
            recv_t => $recv_t,
            env    => $env,
            sigs   => $sigs,
            seen   => $seen,
        );
    }
    return undef;
}

sub _user_call_contract {
    my (%args) = @_;
    my $name = $args{name};
    my $arg_type_hints = $args{arg_type_hints} // [];
    my $sigs = $args{sigs};
    my $sig = $sigs->{$name};
    return undef if !defined($sig) || ref($sig) ne 'HASH';
    my $result_type = $sig->{return_type};
    compile_error("ResolveCalls/F050-Result-Type: function '$name' has unresolved return type")
      if !defined($result_type) || $result_type eq '' || $result_type eq 'unknown';

    my $param_types = [ map { $_->{type} } @{ $sig->{params} // [] } ];
    return {
        schema           => 'f050-call-contract-v1',
        call_kind        => 'user',
        op_id            => user_call_op_id(),
        target_name      => $name,
        arity            => scalar(@$arg_type_hints),
        result_type      => $result_type,
        param_policy     => 'fixed',
        param_arity      => scalar(@$param_types),
        arg_type_hints   => $arg_type_hints,
        param_type_contract => $param_types,
    };
}

sub _infer_expr_type_hint {
    my ($expr, $env, $sigs, $seen) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    $seen //= {};
    my $addr = refaddr($expr);
    return undef if defined($addr) && $seen->{$addr}++;

    my $kind = $expr->{kind} // '';
    return 'number' if $kind eq 'num';
    return 'string' if $kind eq 'str';
    return 'bool' if $kind eq 'bool';
    return 'null' if $kind eq 'null';
    return $env->{ $expr->{name} } if $kind eq 'ident';

    if ($kind eq 'list_literal') {
        my $items = $expr->{items} // [];
        return 'empty_list' if !@$items;
        my @types = map { _infer_expr_type_hint($_, $env, $sigs, $seen) } @$items;
        return undef if grep { !defined $_ } @types;
        my @cats = map { _list_literal_item_type_category($_) } @types;
        return undef if grep { !defined($_) || $_ eq '' } @cats;
        my %uniq = map { $_ => 1 } @cats;
        return sequence_type_for_element($cats[0]) if keys(%uniq) == 1;
        return undef;
    }

    if ($kind eq 'unary') {
        return 'number' if ($expr->{op} // '') eq '-';
        return undef;
    }

    if ($kind eq 'binop') {
        my $op = $expr->{op} // '';
        return 'number' if $op eq '+' || $op eq '-' || $op eq '*' || $op eq '/' || $op eq '~/' || $op eq '%';
        return 'bool' if $op eq '&&' || $op eq '||';
        return 'bool' if $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=';
        return undef;
    }

    if ($kind eq 'index') {
        my $recv_t = _infer_expr_type_hint($expr->{recv}, $env, $sigs, $seen);
        return 'number' if scalar_is_string($recv_t);
        my $elem = sequence_element_type($recv_t);
        return undef if !defined $elem;
        return sequence_member_type($elem);
    }

    if ($kind eq 'try') {
        my $inner_t = _infer_expr_type_hint($expr->{expr}, $env, $sigs, $seen);
        return undef if !defined $inner_t;
        my $non_error = _type_without_error_union_member($inner_t);
        return defined($non_error) ? $non_error : $inner_t;
    }

    if ($kind eq 'member_access') {
        my $recv_t = _infer_expr_type_hint($expr->{recv}, $env, $sigs, $seen);
        my $member = $expr->{member} // '';
        return 'string' if defined($recv_t) && $recv_t eq 'error' && $member eq 'message';
        return undef;
    }

    if ($kind eq 'call') {
        my $resolved = $expr->{resolved_call};
        if (defined $resolved && ref($resolved) eq 'HASH') {
            my $resolved_type = $resolved->{result_type};
            compile_error("ResolveCalls/F050-Result-Type: resolved call missing strict result_type")
              if !defined($resolved_type) || $resolved_type eq '';
            return $resolved_type if defined($resolved_type) && $resolved_type ne '' && $resolved_type ne 'unknown';
        }
        return _call_result_type($expr, $env, $sigs, $seen);
    }

    if ($kind eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        if (defined $resolved && ref($resolved) eq 'HASH') {
            my $resolved_type = $resolved->{result_type};
            compile_error("ResolveCalls/F050-Result-Type: resolved method call missing strict result_type")
              if !defined($resolved_type) || $resolved_type eq '';
            return $resolved_type if defined($resolved_type) && $resolved_type ne '' && $resolved_type ne 'unknown';
        }
        my $recv_t = _infer_expr_type_hint($expr->{recv}, $env, $sigs, $seen);
        my $method = $expr->{method} // '';
        my $dynamic_policy = method_dynamic_result_policy($method);
        if (defined($dynamic_policy) && $dynamic_policy ne '') {
            my $dynamic = _infer_method_dynamic_result_type_hint(
                policy => $dynamic_policy,
                expr   => $expr,
                recv_t => $recv_t,
                env    => $env,
                sigs   => $sigs,
                seen   => $seen,
            );
            return $dynamic if defined($dynamic) && $dynamic ne '';
        }
        return method_result_type($method, $recv_t);
    }

    return undef;
}

sub _resolve_expr {
    my (%args) = @_;
    my $expr = $args{expr};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $seen = $args{seen};
    return if !defined($expr) || ref($expr) ne 'HASH';

    my $addr = refaddr($expr);
    return if defined($addr) && $seen->{$addr}++;
    my $kind = $expr->{kind} // '';

    for my $k (sort keys %$expr) {
        next if ($kind eq 'lambda1' || $kind eq 'lambda2') && $k eq 'body';
        my $v = $expr->{$k};
        if (ref($v) eq 'HASH') {
            _resolve_expr(expr => $v, env => $env, sigs => $sigs, seen => $seen);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $item (@$v) {
            _resolve_expr(expr => $item, env => $env, sigs => $sigs, seen => $seen)
              if ref($item) eq 'HASH';
        }
    }

    if ($kind eq 'method_call') {
        my $method = $expr->{method} // '';
        my $recv_type = _infer_expr_type_hint($expr->{recv}, $env, $sigs, {});
        my @arg_hints = map {
            my $t = _infer_expr_type_hint($_, $env, $sigs, {});
            defined($t) ? $t : 'unknown'
        } @{ $expr->{args} // [] };

        my $user_sig = $sigs->{$method};
        if (defined($user_sig) && user_method_style_allowed($user_sig)) {
            my @canonical_args = ($expr->{recv}, @{ $expr->{args} // [] });
            my @full_arg_hints = (defined($recv_type) ? $recv_type : 'unknown', @arg_hints);
            my $contract = _user_call_contract(
                name           => $method,
                arg_type_hints => \@full_arg_hints,
                sigs           => $sigs,
            );
            _verify_named_call_parameter_contract(
                name     => $method,
                call_kind => 'function',
                contract => $contract,
                arg_exprs => \@canonical_args,
                env      => $env,
                sigs     => $sigs,
            );
            $expr->{kind} = 'call';
            $expr->{name} = $method;
            $expr->{args} = \@canonical_args;
            delete $expr->{method};
            delete $expr->{recv};
            $expr->{resolved_call} = $contract;
            $expr->{canonical_call} = _canonical_call_expr(expr => $expr, contract => $contract);
            return;
        }

        compile_error("ResolveCalls/F050-Call-Registry: unknown intrinsic method '$method'")
          if !method_is_known($method);
        compile_error("ResolveCalls/F050-Call-Registry: cannot resolve receiver type for intrinsic method '$method'")
          if !defined($recv_type) || $recv_type eq '' || $recv_type eq 'unknown';
        my $receiver_supported = method_receiver_supported($method, $recv_type);
        if (!$receiver_supported) {
            my $traceability = method_traceability_hint($method);
            if (_traceability_requirement_applies_for_receiver($traceability, $recv_type)) {
                my $diag = _traceability_requirement_diagnostic($method, $traceability);
                compile_error($diag) if defined($diag) && $diag ne '';
            }
        }
        compile_error("ResolveCalls/F050-Call-Registry: method '$method' is not defined for receiver type '$recv_type'")
          if !$receiver_supported;
        _verify_method_parameter_contract(
            method    => $method,
            recv_type => $recv_type,
            arg_exprs => $expr->{args} // [],
            env       => $env,
            sigs      => $sigs,
        );
        _verify_method_callback_contract(
            method    => $method,
            recv_type => $recv_type,
            arg_exprs => $expr->{args} // [],
            env       => $env,
            sigs      => $sigs,
        );
        my $resolved_result_type = _infer_expr_type_hint($expr, $env, $sigs, {});
        compile_error("ResolveCalls/F050-Result-Type: method '$method' has unresolved result type for receiver '$recv_type'")
          if !defined($resolved_result_type) || $resolved_result_type eq '' || $resolved_result_type eq 'unknown';

        my $contract = {
            schema              => 'f050-call-contract-v1',
            call_kind           => 'intrinsic_method',
            op_id               => method_op_id($method),
            method_name         => $method,
            arity               => scalar(@{ $expr->{args} // [] }),
            receiver_type_hint  => defined($recv_type) ? $recv_type : 'unknown',
            result_type         => $resolved_result_type,
            fallibility         => method_fallibility_hint($method, $recv_type),
            arg_type_hints      => \@arg_hints,
        };

        if (method_requires_matrix_axis_argument($method) && defined($recv_type) && is_matrix_type($recv_type)) {
            my $meta = matrix_type_meta($recv_type);
            $contract->{axis_min} = 0;
            $contract->{axis_max} = $meta->{dim} - 1;
            $contract->{axis_contract} = "range(0, " . ($meta->{dim} - 1) . ")";
        }

        $expr->{resolved_call} = $contract;
        $expr->{canonical_call} = _canonical_call_expr(expr => $expr, contract => $contract);
        return;
    }

    if ($kind eq 'call') {
        my $name = $expr->{name} // '';
        my @arg_hints = map {
            my $t = _infer_expr_type_hint($_, $env, $sigs, {});
            defined($t) ? $t : 'unknown'
        } @{ $expr->{args} // [] };

        my $contract = _user_call_contract(
            name           => $name,
            arg_type_hints => \@arg_hints,
            sigs           => $sigs,
        );
        if (!defined $contract) {
            compile_error("ResolveCalls/F050-Call-Registry: unknown function or builtin '$name'")
              if !builtin_is_known($name);
            my $param_contract = builtin_param_contract($name);
            compile_error("ResolveCalls/F050-Param-Policy: builtin '$name' has invalid parameter policy")
              if !defined($param_contract) || ref($param_contract) ne 'HASH';
            my $result_type = _call_result_type($expr, $env, $sigs, {});
            compile_error("ResolveCalls/F050-Result-Type: builtin '$name' result type is unresolved")
              if !defined($result_type) || $result_type eq '' || $result_type eq 'unknown';
            $contract = {
                schema           => 'f050-call-contract-v1',
                call_kind        => 'builtin',
                op_id            => builtin_op_id($name),
                target_name      => $name,
                arity            => scalar(@{ $expr->{args} // [] }),
                result_type      => $result_type,
                param_policy     => $param_contract->{policy} // 'unknown',
                param_arity      => int($param_contract->{arity} // 0),
                arg_type_hints   => \@arg_hints,
                param_type_contract => $param_contract->{param_types} // [],
            };
        }
        _verify_named_call_parameter_contract(
            name      => $name,
            call_kind => $contract->{call_kind} // 'function',
            contract  => $contract,
            arg_exprs => $expr->{args} // [],
            env       => $env,
            sigs      => $sigs,
        );
        $expr->{resolved_call} = $contract;
        $expr->{canonical_call} = _canonical_call_expr(expr => $expr, contract => $contract);
    }
}

sub _register_binding_from_stmt {
    my (%args) = @_;
    my $stmt = $args{stmt};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $kind = $stmt->{kind} // '';

    if ($kind eq 'let' || $kind eq 'const' || $kind eq 'const_typed' || $kind eq 'typed_assign') {
        my $name = $stmt->{name};
        return if !defined($name) || $name eq '';
        my $type = $stmt->{type};
        if (!defined($type) || $type eq '') {
            $type = _infer_expr_type_hint($stmt->{expr}, $env, $sigs, {});
        }
        $env->{$name} = $type if defined($type) && $type ne '';
        return;
    }

    if ($kind eq 'const_try_expr' || $kind eq 'const_or_catch') {
        my $name = $stmt->{name};
        return if !defined($name) || $name eq '';
        my $expr = defined $stmt->{expr} ? $stmt->{expr} : $stmt->{first};
        my $type = _infer_expr_type_hint($expr, $env, $sigs, {});
        my $non_error = _type_without_error_union_member($type);
        $env->{$name} = defined($non_error) ? $non_error : $type
          if defined($type) && $type ne '';
        return;
    }

    if ($kind eq 'const_try_tail_expr') {
        my $name = $stmt->{name};
        return if !defined($name) || $name eq '';
        my $cur = _infer_expr_type_hint($stmt->{first}, $env, $sigs, {});
        my $ok = _type_without_error_union_member($cur);
        $cur = defined($ok) ? $ok : $cur;
        for my $step (@{ $stmt->{steps} // [] }) {
            next if !defined($step) || ref($step) ne 'HASH';
            my $tmp_env = _clone_env($env);
            $tmp_env->{__chain_recv} = $cur if defined($cur) && $cur ne '';
            my $call = {
                kind   => 'method_call',
                method => ($step->{name} // ''),
                recv   => { kind => 'ident', name => '__chain_recv' },
                args   => $step->{args} // [],
            };
            my $t = _infer_expr_type_hint($call, $tmp_env, $sigs, {});
            $cur = $t if defined($t) && $t ne '';
        }
        $env->{$name} = $cur if defined($cur) && $cur ne '';
        return;
    }

    if ($kind eq 'const_try_chain') {
        my $name = $stmt->{name};
        return if !defined($name) || $name eq '';
        my $cur = _infer_expr_type_hint($stmt->{first}, $env, $sigs, {});
        my $ok = _type_without_error_union_member($cur);
        $cur = defined($ok) ? $ok : $cur;
        for my $step (@{ $stmt->{steps} // [] }) {
            next if !defined($step) || ref($step) ne 'HASH';
            my $tmp_env = _clone_env($env);
            $tmp_env->{__chain_recv} = $cur if defined($cur) && $cur ne '';
            my $call = {
                kind   => 'method_call',
                method => ($step->{name} // ''),
                recv   => { kind => 'ident', name => '__chain_recv' },
                args   => $step->{args} // [],
            };
            my $t = _infer_expr_type_hint($call, $tmp_env, $sigs, {});
            my $next = _type_without_error_union_member($t);
            $cur = defined($next) ? $next : $t if defined($t) && $t ne '';
        }
        $env->{$name} = $cur if defined($cur) && $cur ne '';
        return;
    }

    if ($kind eq 'destructure_list') {
        my $list_t = _infer_expr_type_hint($stmt->{expr}, $env, $sigs, {});
        if (defined($list_t) && is_sequence_member_type($list_t)) {
            my $meta = sequence_member_meta($list_t);
            $list_t = $meta->{elem} if defined($meta) && defined($meta->{elem});
        }
        my $item_t = sequence_element_type($list_t);
        $item_t = _sequence_member_base_type($item_t);
        return if !defined $item_t;
        for my $v (@{ $stmt->{vars} // [] }) {
            $env->{$v} = $item_t if defined($v) && $v ne '';
        }
        return;
    }

    if ($kind eq 'destructure_split_or') {
        for my $v (@{ $stmt->{vars} // [] }) {
            $env->{$v} = 'string' if defined($v) && $v ne '';
        }
        return;
    }

    if ($kind eq 'destructure_match') {
        my $types = $stmt->{var_types};
        for my $i (0 .. $#{ $stmt->{vars} // [] }) {
            my $v = $stmt->{vars}[$i];
            next if !defined($v) || $v eq '';
            my $vt = (defined($types) && ref($types) eq 'ARRAY') ? ($types->[$i] // 'string') : 'string';
            $vt = 'string' if $vt ne 'number' && $vt ne 'string';
            $env->{$v} = $vt;
        }
        return;
    }
}

sub _resolve_stmt_tree {
    my (%args) = @_;
    my $stmt = $args{stmt};
    my $env = $args{env};
    my $sigs = $args{sigs};
    my $seen_expr = $args{seen_expr};
    my $seen_stmt = $args{seen_stmt};
    return if !defined($stmt) || ref($stmt) ne 'HASH';

    my $sid = refaddr($stmt);
    return if defined($sid) && $seen_stmt->{$sid}++;

    for my $k (qw(expr cond iterable index source recv value left right first tail_expr source_expr delim_expr)) {
        _resolve_expr(
            expr => $stmt->{$k},
            env  => $env,
            sigs => $sigs,
            seen => $seen_expr,
        ) if defined $stmt->{$k};
    }

    if (defined($stmt->{args}) && ref($stmt->{args}) eq 'ARRAY') {
        for my $arg (@{ $stmt->{args} }) {
            _resolve_expr(expr => $arg, env => $env, sigs => $sigs, seen => $seen_expr)
              if ref($arg) eq 'HASH';
        }
    }
    if (defined($stmt->{steps}) && ref($stmt->{steps}) eq 'ARRAY') {
        for my $chain_step (@{ $stmt->{steps} }) {
            next if ref($chain_step) ne 'HASH';
            if (defined($chain_step->{args}) && ref($chain_step->{args}) eq 'ARRAY') {
                for my $arg (@{ $chain_step->{args} }) {
                    _resolve_expr(expr => $arg, env => $env, sigs => $sigs, seen => $seen_expr)
              if ref($arg) eq 'HASH';
                }
            }
        }
    }

    if (($stmt->{kind} // '') eq 'const_try_chain' || ($stmt->{kind} // '') eq 'const_try_tail_expr') {
        my $is_tail = (($stmt->{kind} // '') eq 'const_try_tail_expr') ? 1 : 0;
        my $cur = _infer_expr_type_hint($stmt->{first}, $env, $sigs, {});
        my $ok = _type_without_error_union_member($cur);
        $cur = defined($ok) ? $ok : $cur;
        for my $chain_step (@{ $stmt->{steps} // [] }) {
            next if ref($chain_step) ne 'HASH';
            my $tmp_env = _clone_env($env);
            $tmp_env->{__chain_recv} = $cur if defined($cur) && $cur ne '';
            my $call = {
                kind   => 'method_call',
                method => ($chain_step->{name} // ''),
                recv   => { kind => 'ident', name => '__chain_recv' },
                args   => $chain_step->{args} // [],
            };
            _resolve_expr(
                expr => $call,
                env  => $tmp_env,
                sigs => $sigs,
                seen => {},
            );
            $chain_step->{resolved_call} = $call->{resolved_call} if exists $call->{resolved_call};
            $chain_step->{canonical_call} = $call->{canonical_call} if exists $call->{canonical_call};
            my $next_t = _infer_expr_type_hint($call, $tmp_env, $sigs, {});
            my $next_ok = _type_without_error_union_member($next_t);
            if ($is_tail) {
                $cur = $next_t if defined($next_t) && $next_t ne '';
            } else {
                $cur = defined($next_ok) ? $next_ok : $next_t if defined($next_t) && $next_t ne '';
            }
        }
        _register_binding_from_stmt(stmt => $stmt, env => $env, sigs => $sigs);
        return;
    }

    if (($stmt->{kind} // '') eq 'for_each' || ($stmt->{kind} // '') eq 'for_each_try' || ($stmt->{kind} // '') eq 'for_lines') {
        my $loop_env = _clone_env($env);
        if (($stmt->{kind} // '') eq 'for_lines') {
            $loop_env->{ $stmt->{var} } = 'string' if defined $stmt->{var};
        } else {
            my $iter_t = _infer_expr_type_hint($stmt->{iterable}, $env, $sigs, {});
            if (($stmt->{kind} // '') eq 'for_each_try') {
                my $ok = _type_without_error_union_member($iter_t);
                $iter_t = $ok if defined($ok) && $ok ne '';
            }
            my $item_t = _iterable_item_type_hint($iter_t);
            $loop_env->{ $stmt->{var} } = $item_t if defined($stmt->{var}) && defined($item_t);
        }
        for my $inner (@{ $stmt->{body} // [] }) {
            _resolve_stmt_tree(
                stmt      => $inner,
                env       => $loop_env,
                sigs      => $sigs,
                seen_expr => $seen_expr,
                seen_stmt => $seen_stmt,
            );
        }
        _register_binding_from_stmt(stmt => $stmt, env => $env, sigs => $sigs);
        return;
    }

    for my $k (qw(then_body else_body body handler)) {
        next if !defined($stmt->{$k}) || ref($stmt->{$k}) ne 'ARRAY';
        my $child_env = _clone_env($env);
        if ($k eq 'handler') {
            my $err_name = $stmt->{err_name};
            $child_env->{$err_name} = 'error' if defined($err_name) && $err_name ne '';
        }
        for my $inner (@{ $stmt->{$k} }) {
            _resolve_stmt_tree(
                stmt      => $inner,
                env       => $child_env,
                sigs      => $sigs,
                seen_expr => $seen_expr,
                seen_stmt => $seen_stmt,
            );
        }
    }

    _register_binding_from_stmt(stmt => $stmt, env => $env, sigs => $sigs);
}

sub _register_exit_bindings {
    my (%args) = @_;
    my $exit = $args{exit};
    my $env = $args{env};
    my $sigs = $args{sigs};
    return if !defined($exit) || ref($exit) ne 'HASH';

    my $kind = $exit->{kind} // '';
    if ($kind eq 'ForInExit') {
        my $item = $exit->{item_name};
        return if !defined($item) || $item eq '';
        my $iter_t = _infer_expr_type_hint($exit->{iterable_expr}, $env, $sigs, {});
        my $ok = _type_without_error_union_member($iter_t);
        $iter_t = $ok if defined($ok) && $ok ne '';
        my $item_t = _iterable_item_type_hint($iter_t);
        $env->{$item} = $item_t if defined($item_t) && $item_t ne '';
    }
}

sub _with_line_context {
    my ($line, $cb) = @_;
    if (defined($line) && $line =~ /^\d+$/ && $line > 0) {
        set_error_line($line);
    } else {
        clear_error_line();
    }
    my $ret = $cb->();
    clear_error_line();
    return $ret;
}

sub _resolve_region_calls {
    my (%args) = @_;
    my $region = $args{region};
    my $env = $args{env};
    my $sigs = $args{sigs};
    return if !defined($region) || ref($region) ne 'HASH';

    for my $step (@{ $region->{steps} // [] }) {
        my $line = $step->{provenance}{line};
        my $stmt = _with_line_context($line, sub {
            return step_payload_to_stmt($step->{payload});
        });
        next if !defined $stmt;
        _with_line_context($line, sub {
            _resolve_stmt_tree(
                stmt      => $stmt,
                env       => $env,
                sigs      => $sigs,
                seen_expr => {},
                seen_stmt => {},
            );
            return;
        });
        $step->{payload} = stmt_to_payload($stmt);
    }

    my $exit = $region->{exit} // {};
    my $line = $region->{line};
    _with_line_context($line, sub {
        for my $k (qw(cond_value iterable_expr fallible_expr value)) {
            _resolve_expr(expr => $exit->{$k}, env => $env, sigs => $sigs, seen => {})
              if defined $exit->{$k} && ref($exit->{$k}) eq 'HASH';
        }
        _register_exit_bindings(exit => $exit, env => $env, sigs => $sigs);
        return;
    });
}

sub _resolve_function_calls {
    my ($fn, $sigs) = @_;
    my $env = _env_from_params($fn->{params});
    my %region_by_id = map { $_->{id} => $_ } @{ $fn->{regions} // [] };

    my $schedule = $fn->{region_schedule} // [];
    my %scheduled = ();
    if (ref($schedule) eq 'ARRAY') {
        %scheduled = map { $_ => 1 } @$schedule;
    }
    if (ref($schedule) eq 'ARRAY') {
        for my $rid (@$schedule) {
            my $region = $region_by_id{$rid};
            next if !defined $region;
            _resolve_region_calls(region => $region, env => $env, sigs => $sigs);
        }
    }

    for my $region (@{ $fn->{regions} // [] }) {
        next if %scheduled && $scheduled{$region->{id}};
        _resolve_region_calls(region => $region, env => $env, sigs => $sigs);
    }
}

sub resolve_hir_calls {
    my ($hir) = @_;
    my $sigs = _function_sigs($hir);
    _resolve_function_calls($_, $sigs) for @{ $hir->{functions} // [] };
    return $hir;
}

1;
