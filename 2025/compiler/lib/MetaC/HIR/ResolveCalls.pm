package MetaC::HIR::ResolveCalls;
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(refaddr);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt stmt_to_payload);
use MetaC::IntrinsicRegistry qw(method_base_specs intrinsic_method_op_id);

use MetaC::TypeSpec qw(
    is_matrix_type
    matrix_type_meta
    matrix_member_type
    matrix_member_list_type
    is_matrix_member_type
    matrix_member_meta
    is_matrix_member_list_type
    matrix_member_list_meta
    matrix_neighbor_list_type
    non_error_member_of_error_union
    is_array_type
    array_type_meta
);

our @EXPORT_OK = qw(resolve_hir_calls);

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
    return 'number' if ($iterable_type // '') eq 'number_list';
    return 'string' if ($iterable_type // '') eq 'string_list';
    return 'bool' if ($iterable_type // '') eq 'bool_list';
    return 'number_list' if ($iterable_type // '') eq 'number_list_list';
    if (defined $iterable_type && $iterable_type =~ /^matrix_member_list<(.+)>$/) {
        return "matrix_member<$1>";
    }
    if (is_array_type($iterable_type)) {
        my $meta = array_type_meta($iterable_type);
        return $meta->{elem} if defined $meta && defined $meta->{elem};
    }
    return undef;
}

sub _infer_method_result_hint {
    my ($method, $recv_type) = @_;
    return 'number' if $method eq 'size' || $method eq 'count';
    return 'string_list' if $method eq 'chars';
    return 'string_list' if $method eq 'chunk';
    return 'bool' if $method eq 'isBlank';
    return 'string_list | error' if $method eq 'split' || $method eq 'match';
    return 'number' if $method eq 'compareTo' || $method eq 'andThen' || $method eq 'push';
    return 'bool' if $method eq 'any' || $method eq 'all';
    return 'indexed_number' if $method eq 'max';
    if ($method eq 'last') {
        return 'string' if ($recv_type // '') eq 'string_list';
        return 'number' if ($recv_type // '') eq 'number_list';
        return 'number_list' if ($recv_type // '') eq 'number_list_list';
        return 'bool' if ($recv_type // '') eq 'bool_list';
        return 'indexed_number' if ($recv_type // '') eq 'indexed_number_list';
        return undef;
    }
    return 'indexed_number_list' if $method eq 'sort';
    return $recv_type if $method eq 'map';
    return $recv_type if $method eq 'slice' || $method eq 'filter' || $method eq 'sortBy' || $method eq 'insert' || $method eq 'log';
    return undef if !defined $recv_type;

    if ($method eq 'members' && is_matrix_type($recv_type)) {
        return matrix_member_list_type($recv_type);
    }
    if ($method eq 'index') {
        return 'number_list' if is_matrix_member_type($recv_type);
        return 'number';
    }
    if ($method eq 'neighbours') {
        if (is_matrix_type($recv_type)) {
            return matrix_neighbor_list_type($recv_type);
        }
        if (is_matrix_member_type($recv_type)) {
            my $meta = matrix_member_meta($recv_type);
            return 'number_list' if $meta->{elem} eq 'number';
            return 'string_list' if $meta->{elem} eq 'string';
        }
    }
    return undef;
}

sub _method_fallibility_hint {
    my ($method, $recv_type) = @_;
    my $spec = method_base_specs()->{$method};
    return 'always' if defined($spec) && ($spec->{fallibility} // '') eq 'always';
    return 'contextual' if defined($spec) && ($spec->{fallibility} // '') eq 'mapper';
    if ($method eq 'insert' && defined $recv_type && is_matrix_type($recv_type)) {
        my $meta = matrix_type_meta($recv_type);
        return $meta->{has_size} ? 'never' : 'conditional';
    }
    return 'never';
}

sub _canonical_call_expr {
    my (%args) = @_;
    my $contract = $args{contract};
    my $kind = $contract->{call_kind} // '';
    my $canonical_kind = $kind eq 'intrinsic_method' ? 'intrinsic' : $kind;
    my $call_kind = $kind eq 'intrinsic_method' ? 'intrinsic_method' : $canonical_kind;
    my $call = {
        node_kind   => 'CallExpr',
        kind        => $canonical_kind,
        call_kind   => $call_kind,
        op_id       => $contract->{op_id},
        arity       => int($contract->{arity} // 0),
        result_type => $contract->{result_type_hint} // 'unknown',
    };
    $call->{target_name} = $contract->{target_name} if defined $contract->{target_name};
    $call->{receiver_type_hint} = $contract->{receiver_type_hint}
      if defined $contract->{receiver_type_hint};
    return $call;
}

sub _call_result_hint {
    my ($expr, $env, $sigs, $seen) = @_;
    my $name = $expr->{name} // '';
    if (exists $sigs->{$name}) {
        return $sigs->{$name}{return_type};
    }
    return 'number | error' if $name eq 'parseNumber';
    return 'error' if $name eq 'error';
    return 'number' if $name eq 'max' || $name eq 'min' || $name eq 'last';
    return 'number_list' if $name eq 'seq';
    if ($name eq 'log') {
        return undef if !defined($expr->{args}) || ref($expr->{args}) ne 'ARRAY' || !@{ $expr->{args} };
        return _infer_expr_type_hint($expr->{args}[0], $env, $sigs, $seen);
    }
    return undef;
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
        return 'number_list' if keys(%uniq) == 1 && exists $uniq{number};
        return 'string_list' if keys(%uniq) == 1 && exists $uniq{string};
        return 'bool_list' if keys(%uniq) == 1 && exists $uniq{bool};
        return 'number_list_list' if keys(%uniq) == 1 && exists $uniq{number_list};
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
        return 'number' if ($recv_t // '') eq 'string' || ($recv_t // '') eq 'number_list' || ($recv_t // '') eq 'indexed_number_list';
        return 'string' if ($recv_t // '') eq 'string_list';
        return 'bool' if ($recv_t // '') eq 'bool_list';
        return 'number_list' if ($recv_t // '') eq 'number_list_list';
        return undef;
    }

    if ($kind eq 'try') {
        my $inner_t = _infer_expr_type_hint($expr->{expr}, $env, $sigs, $seen);
        return undef if !defined $inner_t;
        my $non_error = non_error_member_of_error_union($inner_t);
        return defined($non_error) ? $non_error : $inner_t;
    }

    if ($kind eq 'call') {
        my $resolved = $expr->{resolved_call};
        if (defined $resolved && ref($resolved) eq 'HASH') {
            my $hint = $resolved->{result_type_hint};
            return $hint if defined($hint) && $hint ne '' && $hint ne 'unknown';
        }
        return _call_result_hint($expr, $env, $sigs, $seen);
    }

    if ($kind eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        if (defined $resolved && ref($resolved) eq 'HASH') {
            my $hint = $resolved->{result_type_hint};
            return $hint if defined($hint) && $hint ne '' && $hint ne 'unknown';
        }
        my $recv_t = _infer_expr_type_hint($expr->{recv}, $env, $sigs, $seen);
        return _infer_method_result_hint($expr->{method} // '', $recv_t);
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

    for my $k (sort keys %$expr) {
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

    my $kind = $expr->{kind} // '';
    if ($kind eq 'method_call') {
        my $method = $expr->{method} // '';
        my $recv_type = _infer_expr_type_hint($expr->{recv}, $env, $sigs, {});
        my @arg_hints = map {
            my $t = _infer_expr_type_hint($_, $env, $sigs, {});
            defined($t) ? $t : 'unknown'
        } @{ $expr->{args} // [] };

        my $contract = {
            schema              => 'f050-call-contract-v1',
            call_kind           => 'intrinsic_method',
            op_id               => intrinsic_method_op_id($method),
            method_name         => $method,
            arity               => scalar(@{ $expr->{args} // [] }),
            receiver_type_hint  => defined($recv_type) ? $recv_type : 'unknown',
            result_type_hint    => _infer_method_result_hint($method, $recv_type) // 'unknown',
            fallibility         => _method_fallibility_hint($method, $recv_type),
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
        my $call_kind = exists $sigs->{$name} ? 'user' : 'builtin';
        my $return_hint = _call_result_hint($expr, $env, $sigs, {});
        my @arg_hints = map {
            my $t = _infer_expr_type_hint($_, $env, $sigs, {});
            defined($t) ? $t : 'unknown'
        } @{ $expr->{args} // [] };

        my $contract = {
            schema           => 'f050-call-contract-v1',
            call_kind        => $call_kind,
            op_id            => ($call_kind eq 'user' ? "call.user.$name.v1" : "call.builtin.$name.v1"),
            target_name      => $name,
            arity            => scalar(@{ $expr->{args} // [] }),
            result_type_hint => defined($return_hint) ? $return_hint : 'unknown',
            arg_type_hints   => \@arg_hints,
        };

        if ($call_kind eq 'user') {
            my $sig = $sigs->{$name};
            $contract->{param_type_contract} = [ map { $_->{type} } @{ $sig->{params} // [] } ];
        }
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
        my $non_error = defined($type) ? non_error_member_of_error_union($type) : undef;
        $env->{$name} = defined($non_error) ? $non_error : $type
          if defined($type) && $type ne '';
        return;
    }

    if ($kind eq 'destructure_list') {
        my $list_t = _infer_expr_type_hint($stmt->{expr}, $env, $sigs, {});
        my $item_t = !defined($list_t) ? undef
          : $list_t eq 'number_list' ? 'number'
          : $list_t eq 'string_list' ? 'string'
          : $list_t eq 'bool_list' ? 'bool'
          : undef;
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
