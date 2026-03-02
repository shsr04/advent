package MetaC::HIR::ResolveCalls;
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(refaddr);
use MetaC::Support qw(compile_error);
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
    method_fallibility_hint
    method_callback_contract
    method_param_contract
);

use MetaC::TypeSpec qw(
    is_union_type
    union_contains_member
    union_member_types
    is_supported_value_type
    is_supported_generic_union_return
    is_array_type
    is_matrix_member_type
    is_matrix_member_list_type
    sequence_element_type
    sequence_type_for_element
    is_matrix_type
    matrix_type_meta
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
    return sequence_element_type($iterable_type);
}

sub _callback_type_valid {
    my ($type) = @_;
    return 0 if !defined($type) || $type eq '' || $type eq 'unknown' || $type eq 'inferred' || $type eq 'empty_list';
    return 1 if $type eq 'comparison_result';
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
    return 1 if defined($actual) && $actual eq $base;
    return 0 if !defined($actual) || !is_union_type($actual) || !union_contains_member($actual, 'error');
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
    return $symbol if $symbol eq 'bool' || $symbol eq 'comparison_result';
    return $ctx->{$symbol} if exists $ctx->{$symbol};
    compile_error("ResolveCalls/F050-Callback-Signature: '$method' callback contract has unknown $part symbol '$symbol'");
}

sub _method_param_type_compatible {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || $actual eq 'unknown';
    return 0 if !defined($expected) || $expected eq '' || $expected eq 'unknown';
    return 1 if $expected eq 'any';
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'number' && ($actual eq 'int' || $actual eq 'float' || $actual eq 'indexed_number');
    my $actual_non_error = _single_non_error_member_from_error_union($actual);
    return 1 if defined($actual_non_error) && $actual_non_error eq $expected;
    return 0;
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
      if !$arity || @$param_types != $arity || $has_bad_param || !_callback_type_valid($return_base);
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
        compile_error("ResolveCalls/F050-Callback-Signature: unknown callback function '$name' for '$method' $role")
          if !defined($sig) || ref($sig) ne 'HASH';
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
    my %ctx = (elem => $elem_t);

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
        my %uniq = map { $_ => 1 } @types;
        return sequence_type_for_element($types[0]) if keys(%uniq) == 1;
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
        return 'number' if ($recv_t // '') eq 'string';
        my $elem = sequence_element_type($recv_t);
        return undef if !defined $elem;
        return 'number' if $elem eq 'indexed_number';
        return $elem;
    }

    if ($kind eq 'try') {
        my $inner_t = _infer_expr_type_hint($expr->{expr}, $env, $sigs, $seen);
        return undef if !defined $inner_t;
        my $non_error = _single_non_error_member_from_error_union($inner_t);
        return defined($non_error) ? $non_error : $inner_t;
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
        return method_result_type($expr->{method} // '', $recv_t);
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
        compile_error("ResolveCalls/F050-Call-Registry: method '$method' is not defined for receiver type '$recv_type'")
          if !method_receiver_supported($method, $recv_type);
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
        my $resolved_result_type = method_result_type($method, $recv_type);
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

        if ($method eq 'size' && defined($recv_type) && is_matrix_type($recv_type)) {
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

    if ($kind eq 'const_try_expr' || $kind eq 'const_try_tail_expr' || $kind eq 'const_or_catch') {
        my $name = $stmt->{name};
        return if !defined($name) || $name eq '';
        my $expr = defined $stmt->{expr} ? $stmt->{expr} : $stmt->{first};
        my $type = _infer_expr_type_hint($expr, $env, $sigs, {});
        my $non_error = _single_non_error_member_from_error_union($type);
        $env->{$name} = defined($non_error) ? $non_error : $type
          if defined($type) && $type ne '';
        return;
    }

    if ($kind eq 'destructure_list') {
        my $list_t = _infer_expr_type_hint($stmt->{expr}, $env, $sigs, {});
        my $item_t = sequence_element_type($list_t);
        $item_t = 'number' if defined($item_t) && $item_t eq 'indexed_number';
        return if !defined $item_t;
        for my $v (@{ $stmt->{vars} // [] }) {
            $env->{$v} = $item_t if defined($v) && $v ne '';
        }
        return;
    }

    if ($kind eq 'destructure_match' || $kind eq 'destructure_split_or') {
        for my $v (@{ $stmt->{vars} // [] }) {
            $env->{$v} = 'string' if defined($v) && $v ne '';
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

    if (($stmt->{kind} // '') eq 'for_each' || ($stmt->{kind} // '') eq 'for_each_try' || ($stmt->{kind} // '') eq 'for_lines') {
        my $loop_env = _clone_env($env);
        if (($stmt->{kind} // '') eq 'for_lines') {
            $loop_env->{ $stmt->{var} } = 'string' if defined $stmt->{var};
        } else {
            my $iter_t = _infer_expr_type_hint($stmt->{iterable}, $env, $sigs, {});
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

sub _resolve_function_calls {
    my ($fn, $sigs) = @_;
    my $env = _env_from_params($fn->{params});
    my %region_by_id = map { $_->{id} => $_ } @{ $fn->{regions} // [] };

    my $schedule = $fn->{region_schedule} // [];
    if (ref($schedule) eq 'ARRAY') {
        for my $rid (@$schedule) {
            my $region = $region_by_id{$rid};
            next if !defined $region;
            for my $step (@{ $region->{steps} // [] }) {
                my $stmt = step_payload_to_stmt($step->{payload});
                next if !defined $stmt;
                _resolve_stmt_tree(
                    stmt      => $stmt,
                    env       => $env,
                    sigs      => $sigs,
                    seen_expr => {},
                    seen_stmt => {},
                );
                _resolve_expr(
                    expr => $stmt,
                    env  => $env,
                    sigs => $sigs,
                    seen => {},
                );
                $step->{payload} = stmt_to_payload($stmt);
            }
        }
    }

    for my $region (@{ $fn->{regions} // [] }) {
        for my $step (@{ $region->{steps} // [] }) {
            my $stmt = step_payload_to_stmt($step->{payload});
            next if !defined $stmt;
            _resolve_stmt_tree(
                stmt      => $stmt,
                env       => _clone_env($env),
                sigs      => $sigs,
                seen_expr => {},
                seen_stmt => {},
            );
            _resolve_expr(
                expr => $stmt,
                env  => $env,
                sigs => $sigs,
                seen => {},
            );
            $step->{payload} = stmt_to_payload($stmt);
        }
        my $exit = $region->{exit} // {};
        for my $k (qw(cond_value iterable_expr fallible_expr value)) {
            _resolve_expr(expr => $exit->{$k}, env => $env, sigs => $sigs, seen => {})
              if defined $exit->{$k} && ref($exit->{$k}) eq 'HASH';
        }
    }
}

sub resolve_hir_calls {
    my ($hir) = @_;
    my $sigs = _function_sigs($hir);
    _resolve_function_calls($_, $sigs) for @{ $hir->{functions} // [] };
    return $hir;
}

1;
