package MetaC::HIR::SemanticChecksExpr;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::HIR::OpRegistry qw(
    method_callback_contract
    builtin_is_known
    builtin_result_type
    method_result_type
    method_fallibility_hint
);
use MetaC::TypeSpec qw(
    is_union_type
    union_contains_member
    union_member_types
    is_sequence_type
    sequence_element_type
    sequence_type_for_element
);

our @EXPORT_OK = qw(
    _clone_hash
    _env_from_params
    _expr_is_fallible
    _function_sigs
    _infer_expr_type
    _is_bool_type
    _is_number_type
    _type_without_member
    _type_without_error_union_member
    _types_assignable
    _validate_expr
);

sub _union_members {
    my ($type) = @_;
    return [] if !defined($type) || $type eq '';
    return union_member_types($type) if is_union_type($type);
    return [$type];
}

sub _type_has_member {
    my ($type, $member) = @_;
    return 0 if !defined($type) || !defined($member);
    return union_contains_member($type, $member) ? 1 : 0 if is_union_type($type);
    return $type eq $member ? 1 : 0;
}

sub _type_without_member {
    my ($type, $drop) = @_;
    return undef if !defined($type);
    my @members = grep { $_ ne $drop } @{ _union_members($type) };
    return undef if !@members;
    return $members[0] if @members == 1;
    my %uniq = map { $_ => 1 } @members;
    return join(' | ', sort keys %uniq);
}

sub _type_without_error_union_member {
    my ($type) = @_;
    return undef if !defined($type) || !is_union_type($type) || !union_contains_member($type, 'error');
    return _type_without_member($type, 'error');
}

sub _is_number_member {
    my ($m) = @_;
    return 1 if defined($m) && ($m eq 'number' || $m eq 'int' || $m eq 'float' || $m eq 'indexed_number');
    return 0;
}

sub _is_bool_member {
    my ($m) = @_;
    return 1 if defined($m) && ($m eq 'bool' || $m eq 'boolean');
    return 0;
}

sub _all_members_match {
    my ($type, $pred) = @_;
    return 0 if !defined($type);
    for my $m (@{ _union_members($type) }) {
        return 0 if !$pred->($m);
    }
    return 1;
}

sub _is_number_type {
    my ($type) = @_;
    return _all_members_match($type, sub { _is_number_member($_[0]) });
}

sub _is_bool_type {
    my ($type) = @_;
    return _all_members_match($type, sub { _is_bool_member($_[0]) });
}

sub _has_shared_member {
    my ($a, $b) = @_;
    my %left = map { $_ => 1 } @{ _union_members($a) };
    for my $m (@{ _union_members($b) }) {
        return 1 if $left{$m};
    }
    return 0;
}

sub _types_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || !defined($expected) || $expected eq '';
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'number' && _is_number_type($actual);

    my %expect = map { $_ => 1 } @{ _union_members($expected) };
    for my $m (@{ _union_members($actual) }) {
        next if $expect{$m};
        next if $expect{number} && _is_number_member($m);
        return 0;
    }
    return 1;
}

sub _function_sigs {
    my ($hir) = @_;
    my %sigs;
    for my $fn (@{ $hir->{functions} // [] }) {
        $sigs{$fn->{name}} = {
            return_type => $fn->{return_type},
            params      => $fn->{params},
        };
    }
    return \%sigs;
}

sub _clone_hash {
    my ($h) = @_;
    return { %{ $h // {} } };
}

sub _env_from_params {
    my ($fn) = @_;
    my (%types, %mut);
    for my $p (@{ $fn->{params} // [] }) {
        next if !defined($p->{name}) || $p->{name} eq '';
        $types{$p->{name}} = $p->{type} if defined $p->{type};
        $mut{$p->{name}} = 0;
    }
    return (\%types, \%mut);
}

sub _infer_expr_type {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    return 'number' if $kind eq 'num';
    return 'string' if $kind eq 'str';
    return 'bool' if $kind eq 'bool';
    return 'null' if $kind eq 'null';
    return $ctx->{types}{ $expr->{name} } if $kind eq 'ident';

    if ($kind eq 'list_literal') {
        my $items = $expr->{items} // [];
        return 'empty_list' if !@$items;
        my @types = map { _infer_expr_type($_, $ctx) } @$items;
        return undef if grep { !defined $_ || $_ eq '' } @types;
        my %uniq = map { $_ => 1 } @types;
        return undef if keys(%uniq) != 1;
        return sequence_type_for_element($types[0]);
    }

    if ($kind eq 'unary') {
        return 'number' if ($expr->{op} // '') eq '-';
        return undef;
    }

    if ($kind eq 'binop') {
        my $op = $expr->{op} // '';
        return 'number' if $op eq '+' || $op eq '-' || $op eq '*' || $op eq '/' || $op eq '~/' || $op eq '%';
        return 'bool' if $op eq '&&' || $op eq '||' || $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=';
        return undef;
    }

    if ($kind eq 'index') {
        my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
        return 'number' if defined($recv_t) && $recv_t eq 'string';
        return sequence_element_type($recv_t);
    }

    if ($kind eq 'try') {
        my $inner_t = _infer_expr_type($expr->{expr}, $ctx);
        my $without_error = _type_without_error_union_member($inner_t);
        return defined($without_error) ? $without_error : $inner_t;
    }

    if ($kind eq 'call' || $kind eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        if (defined($resolved) && ref($resolved) eq 'HASH') {
            my $resolved_type = $resolved->{result_type};
            compile_error("Semantic/F053-Type: resolved call is missing strict result_type")
              if !defined($resolved_type) || $resolved_type eq '';
            return $resolved_type if $resolved_type ne 'unknown';
        }
        if ($kind eq 'call') {
            my $name = $expr->{name} // '';
            my $sig = $ctx->{sigs}{$name};
            return $sig->{return_type} if defined($sig) && defined($sig->{return_type});
            if (builtin_is_known($name)) {
                my $args = $expr->{args} // [];
                my $builtin_t = builtin_result_type(
                    $name,
                    $args,
                    sub { _infer_expr_type($_[0], $ctx) },
                );
                return $builtin_t if defined($builtin_t) && $builtin_t ne '';
            }
            return undef;
        }
        if ($kind eq 'method_call') {
            my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
            return undef if !defined($recv_t) || $recv_t eq '';
            my $method_t = method_result_type($expr->{method}, $recv_t);
            return $method_t if defined($method_t) && $method_t ne '';
        }
    }

    return undef;
}

sub _callback_return_type {
    my ($expr, $param_types, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'ident') {
        my $sig = $ctx->{sigs}{ $expr->{name} // '' };
        return undef if !defined($sig);
        return $sig->{return_type};
    }

    return undef if $kind ne 'lambda1' && $kind ne 'lambda2';
    my @params = $kind eq 'lambda1'
      ? (($expr->{param} // ''))
      : (($expr->{param1} // ''), ($expr->{param2} // ''));
    return undef if @params != @$param_types;
    my %types = %{ _clone_hash($ctx->{types}) };
    for my $i (0 .. $#params) {
        return undef if !defined($params[$i]) || $params[$i] eq '';
        $types{ $params[$i] } = $param_types->[$i];
    }
    my %lambda_ctx = %$ctx;
    $lambda_ctx{types} = \%types;
    return _infer_expr_type($expr->{body}, \%lambda_ctx);
}

sub _method_contextual_fallible {
    my ($expr, $ctx) = @_;
    my $method = $expr->{method} // '';
    my $contract = method_callback_contract($method);
    return 1 if !defined($contract) || ref($contract) ne 'HASH';

    my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
    my $elem_t = sequence_element_type($recv_t);
    return 1 if !defined($elem_t);
    my %sym = (elem => $elem_t);
    my $arg_exprs = $expr->{args} // [];

    if (defined($contract->{initial_arg_index})) {
        my $idx = int($contract->{initial_arg_index});
        return 1 if $idx < 0 || $idx >= @$arg_exprs;
        my $it = _infer_expr_type($arg_exprs->[$idx], $ctx);
        return 1 if !defined($it);
        $sym{initial} = $it;
    }

    my $cb_idx = int($contract->{callback_arg_index} // -1);
    return 1 if $cb_idx < 0 || $cb_idx >= @$arg_exprs;
    my $symbols = $contract->{param_type_symbols} // [];
    return 1 if ref($symbols) ne 'ARRAY';
    my @param_types;
    for my $s (@$symbols) {
        return 1 if !defined($s);
        if ($s eq 'bool' || $s eq 'comparison_result') {
            push @param_types, $s;
            next;
        }
        return 1 if !exists $sym{$s};
        push @param_types, $sym{$s};
    }

    my $ret_t = _callback_return_type($arg_exprs->[$cb_idx], \@param_types, $ctx);
    return 1 if !defined($ret_t);
    return _type_has_member($ret_t, 'error') ? 1 : 0;
}

sub _index_has_bounds_proof {
    my ($expr, $ctx) = @_;
    return 0 if !defined($expr) || ($expr->{kind} // '') ne 'index';
    my $idx = $expr->{index};
    return 0 if !defined($idx) || ($idx->{kind} // '') ne 'num';
    my $n = int($idx->{value});
    return 0 if $n < 0;

    my $recv = $expr->{recv};
    return 0 if !defined($recv) || ref($recv) ne 'HASH';
    if (($recv->{kind} // '') eq 'list_literal') {
        my $len = scalar(@{ $recv->{items} // [] });
        return $n < $len ? 1 : 0;
    }
    return 0 if ($recv->{kind} // '') ne 'ident';

    my $name = $recv->{name} // '';
    return 0 if $name eq '';
    my $facts = $ctx->{facts} // {};
    for my $k (keys %$facts) {
        next if $k !~ /^len_var:\Q$name\E:(-?\d+)$/;
        my $len = int($1);
        return 1 if $n < $len;
    }
    return 0;
}

sub _expr_is_fallible {
    my ($expr, $ctx) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    return 0 if $kind eq 'try';

    if ($kind eq 'index') {
        return _index_has_bounds_proof($expr, $ctx) ? 0 : 1;
    }

    return 0 if $kind ne 'call' && $kind ne 'method_call';
    my $hint = _infer_expr_type($expr, $ctx);
    return 1 if _type_has_member($hint, 'error');
    return 0 if $kind ne 'method_call';

    my $resolved = $expr->{resolved_call};
    my $fall = defined($resolved) && ref($resolved) eq 'HASH'
      ? ($resolved->{fallibility} // 'never')
      : undef;
    if (!defined($fall) || $fall eq '' || $fall eq 'never') {
        my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
        my $hint = method_fallibility_hint($expr->{method}, $recv_t);
        $fall = $hint if defined($hint) && $hint ne '';
    }
    $fall = 'never' if !defined($fall) || $fall eq '';
    return 1 if $fall eq 'always' || $fall eq 'conditional';
    return _method_contextual_fallible($expr, $ctx) if $fall eq 'contextual';
    return 0;
}

sub _validate_expr {
    my ($expr, $ctx, $handled) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        compile_error("Semantic/F053-Type: unknown variable '$name'")
          if $name ne '' && !exists $ctx->{types}{$name};
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'list_literal') {
        _validate_expr($_, $ctx, 0) for @{ $expr->{items} // [] };
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'unary') {
        my $t = _validate_expr($expr->{expr}, $ctx, 0);
        compile_error("Semantic/F053-Type: unary '-' requires number operand")
          if !_is_number_type($t);
        return 'number';
    }

    if ($kind eq 'binop') {
        my $lt = _validate_expr($expr->{left}, $ctx, 0);
        my $rt = _validate_expr($expr->{right}, $ctx, 0);
        my $op = $expr->{op} // '';

        if ($op eq '+' || $op eq '-' || $op eq '*' || $op eq '/' || $op eq '~/' || $op eq '%') {
            compile_error("Semantic/F053-Type: '$op' requires number operands")
              if !_is_number_type($lt) || !_is_number_type($rt);
            return 'number';
        }
        if ($op eq '&&' || $op eq '||') {
            compile_error("Semantic/F053-Type: '$op' requires boolean operands")
              if !_is_bool_type($lt) || !_is_bool_type($rt);
            return 'bool';
        }
        if ($op eq '==' || $op eq '!=') {
            compile_error("Semantic/F053-Type: '$op' requires operands with at least one shared type")
              if !_has_shared_member($lt, $rt);
            return 'bool';
        }
        if ($op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=') {
            compile_error("Semantic/F053-Type: '$op' requires operands with at least one shared ordered type")
              if !_has_shared_member($lt, $rt);
            compile_error("Semantic/F053-Type: '$op' is not defined for boolean operands")
              if _is_bool_type($lt) || _is_bool_type($rt);
            return 'bool';
        }
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'index') {
        my $rt = _validate_expr($expr->{recv}, $ctx, 0);
        my $it = _validate_expr($expr->{index}, $ctx, 0);
        compile_error("Semantic/F053-Type: index operator requires sequence or string receiver")
          if !defined($rt) || ($rt ne 'string' && !is_sequence_type($rt));
        compile_error("Semantic/F053-Type: index must be number")
          if !_is_number_type($it);
        my $fallible = _expr_is_fallible($expr, $ctx);
        compile_error("Semantic/F053-Fallibility: unhandled fallible expression; use '?' or 'or catch(...)'")
          if $fallible && !$handled;
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'try') {
        my $inner = $expr->{expr};
        _validate_expr($inner, $ctx, 1);
        compile_error("Semantic/F053-Fallibility: '?' cannot be applied to infallible expression")
          if !_expr_is_fallible($inner, $ctx);
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'call' || $kind eq 'method_call') {
        _validate_expr($_, $ctx, 0) for @{ $expr->{args} // [] };
        _validate_expr($expr->{recv}, $ctx, 0) if $kind eq 'method_call';
        my $fallible = _expr_is_fallible($expr, $ctx);
        compile_error("Semantic/F053-Fallibility: unhandled fallible expression; use '?' or 'or catch(...)'")
          if $fallible && !$handled;
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'lambda1' || $kind eq 'lambda2') {
        return _infer_expr_type($expr, $ctx);
    }

    return _infer_expr_type($expr, $ctx);
}

1;
