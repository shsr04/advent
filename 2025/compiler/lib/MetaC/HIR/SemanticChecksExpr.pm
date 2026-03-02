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
    sequence_member_type
    is_sequence_member_type
    sequence_member_meta
    is_matrix_type
    matrix_type_meta
);

our @EXPORT_OK = qw(
    _clone_hash
    _env_from_params
    _expr_is_fallible
    _function_sigs
    _infer_expr_type
    _infer_numeric_kind
    _is_bool_type
    _is_number_type
    _numeric_kind_assignable
    _numeric_kind_for_type
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

sub _type_with_error_member {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    return $type if _type_has_member($type, 'error');
    return $type . ' | error';
}

sub _is_number_member {
    my ($m) = @_;
    if (defined($m) && is_sequence_member_type($m)) {
        my $meta = sequence_member_meta($m);
        $m = defined($meta) ? $meta->{elem} : $m;
    }
    return 1 if defined($m) && ($m eq 'number' || $m eq 'int' || $m eq 'float');
    return 0;
}

sub _base_member_type {
    my ($m) = @_;
    return $m if !defined($m) || !is_sequence_member_type($m);
    my $meta = sequence_member_meta($m);
    return defined($meta) ? $meta->{elem} : $m;
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
    my %left = map { _base_member_type($_) => 1 } @{ _union_members($a) };
    for my $m (@{ _union_members($b) }) {
        my $base = _base_member_type($m);
        return 1 if $left{$base};
    }
    return 0;
}

sub _types_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || !defined($expected) || $expected eq '';
    if (is_sequence_member_type($actual)) {
        my $meta = sequence_member_meta($actual);
        $actual = $meta->{elem} if defined($meta) && defined($meta->{elem});
    }
    return 1 if $actual eq 'empty_list' && (is_sequence_type($expected) || is_matrix_type($expected));
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
            return_type                 => $fn->{return_type},
            declared_return_numeric_kind => $fn->{declared_return_numeric_kind},
            params                      => $fn->{params},
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
    my (%types, %mut, %numeric_kinds);
    $types{STDIN} = 'string';
    $mut{STDIN} = 0;
    for my $p (@{ $fn->{params} // [] }) {
        next if !defined($p->{name}) || $p->{name} eq '';
        $types{$p->{name}} = $p->{type} if defined $p->{type};
        $mut{$p->{name}} = 0;
        my $k = $p->{declared_numeric_kind};
        $k = _numeric_kind_for_type($p->{type}) if !defined($k) || $k eq '';
        $numeric_kinds{$p->{name}} = $k if defined($k) && $k ne '';
    }
    return (\%types, \%mut, \%numeric_kinds);
}

sub _num_literal_kind {
    my ($expr) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH' || ($expr->{kind} // '') ne 'num';
    my $v = $expr->{value} // '';
    return 'float' if $v =~ /[.eE]/;
    return 'int' if $v =~ /^-?\d+$/;
    return undef;
}

sub _numeric_kind_for_type {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    if (is_sequence_member_type($type)) {
        my $meta = sequence_member_meta($type);
        $type = $meta->{elem} if defined($meta) && defined($meta->{elem});
    }
    return 'int' if $type eq 'int';
    return 'float' if $type eq 'float';
    return 'number' if $type eq 'number';
    return undef;
}

sub _numeric_kind_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || !defined($expected) || $actual eq '' || $expected eq '';
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'number' && ($actual eq 'int' || $actual eq 'float' || $actual eq 'number');
    return 0;
}

sub _infer_numeric_kind {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    return _num_literal_kind($expr) if $kind eq 'num';
    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        return $ctx->{numeric_kinds}{$name} if $name ne '' && exists $ctx->{numeric_kinds}{$name};
        return _numeric_kind_for_type($ctx->{types}{$name});
    }
    if ($kind eq 'unary') {
        return _infer_numeric_kind($expr->{expr}, $ctx) if ($expr->{op} // '') eq '-';
        return undef;
    }
    if ($kind eq 'try') {
        return _infer_numeric_kind($expr->{expr}, $ctx);
    }
    if ($kind eq 'binop') {
        my $op = $expr->{op} // '';
        my $l = _infer_numeric_kind($expr->{left}, $ctx);
        my $r = _infer_numeric_kind($expr->{right}, $ctx);
        return undef if !defined($l) || !defined($r) || $l eq '' || $r eq '';
        if ($op eq '+' || $op eq '-' || $op eq '*' || $op eq '%') {
            return undef if $l ne $r;
            return $l if $l eq 'int' || $l eq 'float' || $l eq 'number';
            return undef;
        }
        return 'float' if $op eq '/' && $l eq 'float' && $r eq 'float';
        return 'int' if $op eq '~/' && $l eq 'int' && $r eq 'int';
        return undef;
    }
    if ($kind eq 'call' || $kind eq 'method_call' || $kind eq 'index') {
        if ($kind eq 'call') {
            my $name = $expr->{name} // '';
            my $sig = $ctx->{sigs}{$name};
            my $declared = defined($sig) ? $sig->{declared_return_numeric_kind} : undef;
            return $declared if defined($declared) && $declared ne '';
        }
        my $t = _infer_expr_type($expr, $ctx);
        return _numeric_kind_for_type($t);
    }
    return undef;
}

sub _extract_proven_range_for_ident {
    my ($name, $ctx) = @_;
    return undef if !defined($name) || $name eq '';
    my $facts = $ctx->{facts} // {};
    my ($best_min, $best_max, $found);
    for my $k (keys %$facts) {
        next if $k !~ /^range_var:\Q$name\E:(-?\d+):(-?\d+)$/;
        my ($min, $max) = (int($1), int($2));
        if (!$found) {
            ($best_min, $best_max, $found) = ($min, $max, 1);
            next;
        }
        $best_min = $min if $min > $best_min;
        $best_max = $max if $max < $best_max;
    }
    return undef if !$found;
    return { min => $best_min, max => $best_max };
}

sub _expr_int_range_proved {
    my ($expr, $ctx, $min_need, $max_need) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'num') {
        my $v = $expr->{value} // '';
        return 0 if $v !~ /^-?\d+$/;
        my $n = int($v);
        return ($n >= $min_need && $n <= $max_need) ? 1 : 0;
    }
    return 0 if $kind ne 'ident';
    my $name = $expr->{name} // '';
    my $r = _extract_proven_range_for_ident($name, $ctx);
    return 0 if !defined($r);
    return ($r->{min} >= $min_need && $r->{max} <= $max_need) ? 1 : 0;
}

sub _matrix_index_proved_for_known_sizes {
    my ($idx_expr, $meta, $ctx) = @_;
    return 0 if !defined($idx_expr) || ref($idx_expr) ne 'HASH' || !defined($meta) || ref($meta) ne 'HASH';
    return 0 if ($idx_expr->{kind} // '') ne 'list_literal';
    my $coords = $idx_expr->{items} // [];
    my $dim = int($meta->{dim} // 0);
    return 0 if $dim <= 0 || @$coords != $dim;
    my $sizes = $meta->{sizes} // [];
    for my $i (0 .. $dim - 1) {
        my $size = int($sizes->[$i] // -1);
        next if $size < 0; # wildcard axis remains unconstrained
        return 0 if !$size;
        my $ok = _expr_int_range_proved($coords->[$i], $ctx, 0, $size - 1);
        return 0 if !$ok;
    }
    return 1;
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
        my $elem = sequence_element_type($recv_t);
        return undef if !defined($elem);
        return sequence_member_type($elem);
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
            my $method = $expr->{method} // '';
            if ($method eq 'reduce') {
                my $init_t = _infer_expr_type($expr->{args}[0], $ctx);
                return $init_t if defined($init_t) && $init_t ne '';
            }
            if ($method eq 'scan') {
                my $init_t = _infer_expr_type($expr->{args}[0], $ctx);
                return sequence_type_for_element($init_t) if defined($init_t) && $init_t ne '';
            }
            if ($method eq 'filter') {
                return $recv_t;
            }
            if ($method eq 'assert') {
                return _type_with_error_member($recv_t);
            }
            if ($method eq 'map' && is_sequence_type($recv_t)) {
                my $elem_t = sequence_element_type($recv_t);
                my $cb = $expr->{args}[0];
                my $cb_t = _callback_return_type($cb, [$elem_t], $ctx);
                if (defined($cb_t) && $cb_t ne '') {
                    my $base = _type_without_error_union_member($cb_t);
                    $base = $cb_t if !defined($base);
                    my $mapped = sequence_type_for_element($base);
                    return _type_with_error_member($mapped) if _type_has_member($cb_t, 'error');
                    return $mapped;
                }
            }
            my $method_t = method_result_type($expr->{method}, $recv_t);
            if (defined($method_t) && $method_t ne '') {
                my $fall = method_fallibility_hint($method, $recv_t) // 'never';
                return _type_with_error_member($method_t) if $fall eq 'always';
                return _type_with_error_member($method_t) if $fall eq 'conditional' && _method_conditionally_fallible($expr, $ctx);
                return _type_with_error_member($method_t) if $fall eq 'contextual' && _method_contextual_fallible($expr, $ctx);
                return $method_t;
            }
        }
    }

    return undef;
}

sub _callback_return_type {
    my ($expr, $param_types, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        my $sig = $ctx->{sigs}{$name};
        return $sig->{return_type} if defined($sig);
        if (builtin_is_known($name)) {
            my %pt;
            my @args;
            for my $i (0 .. $#$param_types) {
                my $n = "__cb_arg_$i";
                $pt{$n} = $param_types->[$i];
                push @args, { kind => 'ident', name => $n };
            }
            return builtin_result_type(
                $name,
                \@args,
                sub {
                    my ($arg_expr) = @_;
                    return undef if !defined($arg_expr) || ref($arg_expr) ne 'HASH';
                    return $pt{ $arg_expr->{name} // '' };
                },
            );
        }
        return undef;
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

sub _receiver_has_known_size {
    my ($recv_expr, $ctx) = @_;
    return 0 if !defined($recv_expr) || ref($recv_expr) ne 'HASH';
    my $kind = $recv_expr->{kind} // '';
    return 1 if $kind eq 'list_literal';
    return 0 if $kind ne 'ident';
    my $name = $recv_expr->{name} // '';
    return 0 if $name eq '';
    my $facts = $ctx->{facts} // {};
    for my $k (keys %$facts) {
        return 1 if $k =~ /^len_var:\Q$name\E:(-?\d+)$/;
    }
    return 0;
}

sub _method_conditionally_fallible {
    my ($expr, $ctx) = @_;
    my $method = $expr->{method} // '';
    my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
    return 1 if !defined($recv_t) || $recv_t eq '';

    if ($method eq 'insert' && is_sequence_type($recv_t)) {
        return _receiver_has_known_size($expr->{recv}, $ctx) ? 0 : 1;
    }
    if (($method eq 'slice' || $method eq 'last' || $method eq 'head') && is_sequence_type($recv_t)) {
        return _receiver_has_known_size($expr->{recv}, $ctx) ? 0 : 1;
    }
    return 1;
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
    if (defined($hint) && $hint ne '') {
        return 1 if is_union_type($hint) && union_contains_member($hint, 'error');
        return 0 if $hint eq 'error';
    }
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
    return 1 if $fall eq 'always';
    return _method_conditionally_fallible($expr, $ctx) if $fall eq 'conditional';
    return _method_contextual_fallible($expr, $ctx) if $fall eq 'contextual';
    return 0;
}

sub _validate_expr {
    my ($expr, $ctx, $handled) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        if ($name ne '' && !exists $ctx->{types}{$name}) {
            return 'function_ref' if exists $ctx->{sigs}{$name} || builtin_is_known($name);
            compile_error("Semantic/F053-Type: unknown variable '$name'");
        }
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
            my $lk = _infer_numeric_kind($expr->{left}, $ctx);
            my $rk = _infer_numeric_kind($expr->{right}, $ctx);
            if ($op eq '/' || $op eq '~/') {
                compile_error("Semantic/F053-Type: '$op' requires strict numeric operand kinds")
                  if !defined($lk) || !defined($rk);
                compile_error("Semantic/F053-Type: '/' requires operands of type float")
                  if $op eq '/' && !($lk eq 'float' && $rk eq 'float');
                compile_error("Semantic/F053-Type: '~/' requires operands of type int")
                  if $op eq '~/' && !($lk eq 'int' && $rk eq 'int');
                return 'number';
            }
            compile_error("Semantic/F053-Type: '$op' requires matching numeric operand types")
              if !defined($lk) || !defined($rk) || $lk ne $rk
                || ($lk ne 'int' && $lk ne 'float' && $lk ne 'number');
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
        if ($kind eq 'method_call') {
            my $method = $expr->{method} // '';
            my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
            if (defined($recv_t) && is_matrix_type($recv_t)) {
                my $meta = matrix_type_meta($recv_t);
                if ($method eq 'size') {
                    my $axis = $expr->{args}[0];
                    my $axis_max = int($meta->{dim} // 0) - 1;
                    compile_error("Semantic/F053-Entailment: Method 'size(...)' requires compile-time axis proof in range(0, $axis_max)")
                      if $axis_max < 0 || !_expr_int_range_proved($axis, $ctx, 0, $axis_max);
                }
                if ($method eq 'insert' && ($meta->{has_size} // 0)) {
                    my $idx = $expr->{args}[1];
                    compile_error("Semantic/F053-Entailment: Method 'insert(...)' requires compile-time matrix index proof against matrixSize constraints")
                      if !_matrix_index_proved_for_known_sizes($idx, $meta, $ctx);
                }
            }
        }
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
