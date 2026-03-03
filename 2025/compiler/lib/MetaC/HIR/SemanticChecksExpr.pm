package MetaC::HIR::SemanticChecksExpr;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::Parser qw(parse_expr);
use MetaC::HIR::OpRegistry qw(
    method_callback_contract
    method_callback_shape_label
    builtin_is_known
    builtin_result_type
    method_result_type
    method_dynamic_result_policy
    method_fallibility_hint
    method_requires_matrix_axis_argument
    method_has_tag
);
use MetaC::HIR::TypeRegistry qw(
    canonical_scalar_base
    scalar_is_numeric
    scalar_is_boolean
    scalar_is_string
    scalar_is_error
    scalar_is_comparison
    numeric_kind_for_type
    numeric_kind_assignable
    numeric_kind_is_concrete
    numeric_kind_additive_compatible
    numeric_kind_div_compatible
    sequence_elem_label
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
    is_matrix_member_type
    matrix_member_meta
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
    if (defined($m)) {
        $m = _base_member_type($m);
    }
    return scalar_is_numeric($m) ? 1 : 0;
}

sub _unwrap_member_type {
    my ($m) = @_;
    return $m if !defined($m);
    if (is_sequence_member_type($m)) {
        my $meta = sequence_member_meta($m);
        return _unwrap_member_type($meta->{elem}) if defined($meta) && defined($meta->{elem});
    }
    if (is_matrix_member_type($m)) {
        my $meta = matrix_member_meta($m);
        return _unwrap_member_type($meta->{elem}) if defined($meta) && defined($meta->{elem});
    }
    return $m;
}

sub _base_member_type {
    my ($m) = @_;
    return _unwrap_member_type($m);
}

sub _is_bool_member {
    my ($m) = @_;
    $m = _base_member_type($m) if defined($m);
    return scalar_is_boolean($m) ? 1 : 0;
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
    my %left = map {
        my $base = _base_member_type($_);
        $base = 'number' if _is_number_member($base);
        $base = 'bool' if _is_bool_member($base);
        $base => 1;
    } @{ _union_members($a) };
    for my $m (@{ _union_members($b) }) {
        my $base = _base_member_type($m);
        $base = 'number' if _is_number_member($base);
        $base = 'bool' if _is_bool_member($base);
        return 1 if $left{$base};
    }
    return 0;
}

sub _constrained_scalar_base {
    my ($t) = @_;
    return undef if !defined($t) || $t eq '';
    my $base = canonical_scalar_base($t);
    return undef if !defined($base);
    return $base if $base eq 'string' || $base eq 'number';
    return undef;
}

sub _single_type_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || !defined($expected) || $expected eq '';
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'number' && _is_number_member($actual);

    my $actual_base = _constrained_scalar_base($actual);
    return 1 if defined($actual_base) && $actual_base eq $expected;

    if (is_sequence_type($actual) && is_sequence_type($expected)) {
        my $actual_elem = sequence_element_type($actual);
        my $expected_elem = sequence_element_type($expected);
        return 0 if !defined($actual_elem) || !defined($expected_elem);
        return _types_assignable($actual_elem, $expected_elem);
    }
    if (is_matrix_type($actual) && is_matrix_type($expected)) {
        my $actual_meta = matrix_type_meta($actual);
        my $expected_meta = matrix_type_meta($expected);
        return 0 if !defined($actual_meta) || !defined($expected_meta);
        return 0 if int($actual_meta->{dim} // 0) != int($expected_meta->{dim} // 0);
        return _types_assignable($actual_meta->{elem}, $expected_meta->{elem});
    }
    return 0;
}

sub _type_allows_empty_list {
    my ($type) = @_;
    return 0 if !defined($type) || $type eq '';
    for my $m (@{ _union_members($type) }) {
        return 1 if is_sequence_type($m) || is_matrix_type($m);
    }
    return 0;
}

sub _types_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || $actual eq '' || !defined($expected) || $expected eq '';
    if (is_sequence_member_type($actual) || is_matrix_member_type($actual)) {
        $actual = _base_member_type($actual);
    }
    return 1 if $actual eq 'empty_list' && _type_allows_empty_list($expected);
    for my $a (@{ _union_members($actual) }) {
        my $ok = 0;
        for my $e (@{ _union_members($expected) }) {
            if (_single_type_assignable($a, $e)) {
                $ok = 1;
                last;
            }
        }
        return 0 if !$ok;
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
    if (is_sequence_member_type($type) || is_matrix_member_type($type)) {
        $type = _base_member_type($type);
    }
    return numeric_kind_for_type($type);
}

sub _numeric_kind_assignable {
    my ($actual, $expected) = @_;
    return numeric_kind_assignable($actual, $expected);
}

sub _is_concrete_numeric_kind {
    my ($k) = @_;
    return numeric_kind_is_concrete($k);
}

sub _is_numeric_literal_expr {
    my ($expr) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    return (($expr->{kind} // '') eq 'num') ? 1 : 0;
}

sub _numeric_kinds_compatible_additive {
    my ($lk, $rk, $left_expr, $right_expr) = @_;
    return numeric_kind_additive_compatible(
        left_kind => $lk,
        right_kind => $rk,
        left_is_literal => _is_numeric_literal_expr($left_expr),
        right_is_literal => _is_numeric_literal_expr($right_expr),
    );
}

sub _numeric_kinds_compatible_div {
    my ($lk, $rk, $left_expr, $right_expr) = @_;
    return numeric_kind_div_compatible(
        left_kind => $lk,
        right_kind => $rk,
        left_is_literal => _is_numeric_literal_expr($left_expr),
        right_is_literal => _is_numeric_literal_expr($right_expr),
    );
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
            return $l if $l eq $r && ($l eq 'int' || $l eq 'float' || $l eq 'number');
            if (_numeric_kinds_compatible_additive($l, $r, $expr->{left}, $expr->{right})) {
                return $l if ($l eq 'int' || $l eq 'float') && $r eq 'number';
                return $r if ($r eq 'int' || $r eq 'float') && $l eq 'number' && _is_numeric_literal_expr($expr->{left});
                return 'number';
            }
            return undef;
        }
        return 'float' if $op eq '/' && _numeric_kinds_compatible_div($l, $r, $expr->{left}, $expr->{right});
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
        if (@$items && !grep { !defined($_) || ref($_) ne 'HASH' || ($_->{kind} // '') ne 'str' } @$items) {
            my @sizes = map {
                my $raw = $_->{raw};
                $raw = '' if !defined($raw);
                my $decoded = $raw;
                $decoded =~ s/\\./x/g;
                length($decoded);
            } @$items;
            my %usize = map { $_ => 1 } @sizes;
            if (keys(%usize) == 1) {
                my $n = $sizes[0];
                return sequence_type_for_element("stringwithsize($n)");
            }
        }
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
        return 'number' if scalar_is_string($recv_t);
        if (defined($recv_t) && is_sequence_member_type($recv_t)) {
            my $meta = sequence_member_meta($recv_t);
            $recv_t = $meta->{elem} if defined($meta) && defined($meta->{elem});
        }
        my $elem = sequence_element_type($recv_t);
        return undef if !defined($elem);
        return $elem if is_matrix_member_type($elem);
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
            my $dynamic_policy = method_dynamic_result_policy($method);
            if (defined($dynamic_policy) && $dynamic_policy ne '') {
                my $dynamic = _infer_method_dynamic_result_type(
                    policy => $dynamic_policy,
                    expr   => $expr,
                    recv_t => $recv_t,
                    ctx    => $ctx,
                );
                return $dynamic if defined($dynamic) && $dynamic ne '';
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

sub _infer_method_dynamic_result_type {
    my (%args) = @_;
    my $policy = $args{policy} // '';
    my $expr = $args{expr};
    my $recv_t = $args{recv_t};
    my $ctx = $args{ctx};

    if ($policy eq 'initial') {
        my $init_t = _infer_expr_type($expr->{args}[0], $ctx);
        return $init_t if defined($init_t) && $init_t ne '';
        return undef;
    }
    if ($policy eq 'sequence_of_initial') {
        my $init_t = _infer_expr_type($expr->{args}[0], $ctx);
        return sequence_type_for_element($init_t) if defined($init_t) && $init_t ne '';
        return undef;
    }
    if ($policy eq 'receiver') {
        return $recv_t;
    }
    if ($policy eq 'receiver_with_error') {
        return _type_with_error_member($recv_t);
    }
    if ($policy eq 'mapped_sequence' && is_sequence_type($recv_t)) {
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
        return undef;
    }
    return undef;
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
        if (scalar_is_boolean($s) || scalar_is_comparison($s)) {
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
    my $recv = $expr->{recv};
    return 0 if !defined($recv) || ref($recv) ne 'HASH';
    my $recv_t = _infer_expr_type($recv, $ctx);
    return 1 if scalar_is_string($recv_t);
    my $idx = $expr->{index};
    return 0 if !defined($idx) || ref($idx) ne 'HASH';
    my $idx_kind = $idx->{kind} // '';
    my $n = 0;
    if ($idx_kind eq 'num') {
        $n = int($idx->{value});
        return 0 if $n < 0;
        return 1 if defined($recv_t) && is_sequence_member_type($recv_t);
    }
    if (($recv->{kind} // '') eq 'list_literal') {
        return 0 if $idx_kind ne 'num';
        my $len = scalar(@{ $recv->{items} // [] });
        return $n < $len ? 1 : 0;
    }
    return 0 if ($recv->{kind} // '') ne 'ident';

    my $name = $recv->{name} // '';
    return 0 if $name eq '';
    my $facts = $ctx->{facts} // {};
    if ($idx_kind eq 'num') {
        for my $k (keys %$facts) {
            next if $k !~ /^len_var:\Q$name\E:(-?\d+)$/;
            my $len = int($1);
            return 1 if $n < $len;
        }
    }
    if ($idx_kind eq 'ident') {
        my $idx_name = $idx->{name} // '';
        return 0 if $idx_name eq '';
        return 1 if $facts->{"idx_in_bounds:$idx_name:$name"};
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

    if (method_has_tag($method, 'conditional_sequence_requires_known_size') && is_sequence_type($recv_t)) {
        return _receiver_has_known_size($expr->{recv}, $ctx) ? 0 : 1;
    }
    if (method_has_tag($method, 'conditional_sequence_infallible') && is_sequence_type($recv_t)) {
        return 0;
    }
    if (method_has_tag($method, 'conditional_sequence_requires_known_size') && is_sequence_type($recv_t)) {
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
        return 0 if scalar_is_error($hint);
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

sub _unhandled_fallibility_diagnostic {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'call') {
        my $name = $expr->{name} // '';
        return "Semantic/F053-Fallibility: parseNumber(...) is fallible; use parseNumber(...)? or map(parseNumber)?"
          if $name eq 'parseNumber';
        return "Semantic/F053-Fallibility: '$name(...)' is fallible; handle it with '?'"
          if defined($name) && $name ne '';
        return undef;
    }
    return undef if $kind ne 'method_call';
    my $method = $expr->{method} // '';
    return "Semantic/F053-Fallibility: Method 'split(...)' is fallible; handle it with '?'"
      if method_has_tag($method, 'fallible_diag_split');
    if (method_has_tag($method, 'fallible_diag_mapper')) {
        my $mapper = $expr->{args}[0];
        my $mapper_name = (defined($mapper) && ref($mapper) eq 'HASH' && ($mapper->{kind} // '') eq 'ident')
          ? ($mapper->{name} // '')
          : '';
        return "Semantic/F053-Fallibility: Method 'map(...)' is fallible for mapper '$mapper_name'; handle it with '?'"
          if $mapper_name ne '';
        return "Semantic/F053-Fallibility: Method 'map(...)' is fallible for mapper; handle it with '?'";
    }
    if (method_has_tag($method, 'fallible_diag_insert_matrix_unconstrained')) {
        my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
        if (defined($recv_t) && is_matrix_type($recv_t)) {
            my $meta = matrix_type_meta($recv_t);
            return "Semantic/F053-Fallibility: Method 'insert(...)' is fallible on unconstrained matrix; handle it with '?'"
              if !defined($meta) || !($meta->{has_size} // 0);
        }
    }
    return "Semantic/F053-Fallibility: Method '$method(...)' is fallible; handle it with '?'"
      if defined($method) && $method ne '';
    return undef;
}

sub _expr_contains_try {
    my ($expr) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    return 1 if ($expr->{kind} // '') eq 'try';
    for my $k (keys %$expr) {
        my $v = $expr->{$k};
        if (ref($v) eq 'HASH') {
            return 1 if _expr_contains_try($v);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $item (@$v) {
            return 1 if ref($item) eq 'HASH' && _expr_contains_try($item);
        }
    }
    return 0;
}

sub _receiver_diag_label {
    my ($recv_t) = @_;
    return undef if !defined($recv_t) || $recv_t eq '';
    if (is_sequence_type($recv_t)) {
        my $elem = sequence_element_type($recv_t);
        my $label = sequence_elem_label($elem);
        return $label if defined($label) && $label ne '';
        return 'sequence';
    }
    return 'matrix' if is_matrix_type($recv_t);
    return $recv_t;
}

sub _method_callback_shape_label {
    my ($method, $arity) = @_;
    my $specific = method_callback_shape_label($method);
    return $specific if defined($specific) && $specific ne '';
    return "method '$method(...)' callback must be a two-parameter lambda" if $arity == 2;
    return "method '$method(...)' callback must be a single-parameter lambda";
}

sub _validate_method_callback_shape {
    my ($expr, $method) = @_;
    return if !method_has_tag($method, 'enforce_callback_lambda_shape');

    my $contract = method_callback_contract($method);
    return if !defined($contract) || ref($contract) ne 'HASH';
    my $args = $expr->{args} // [];
    return if ref($args) ne 'ARRAY';

    my $cb_idx = int($contract->{callback_arg_index} // -1);
    my $arity = int($contract->{callback_arity} // 0);
    return if $cb_idx < 0 || $arity <= 0 || $cb_idx >= @$args;

    my $cb = $args->[$cb_idx];
    my $expect_kind = $arity == 2 ? 'lambda2' : 'lambda1';
    my $ok = defined($cb) && ref($cb) eq 'HASH' && (($cb->{kind} // '') eq $expect_kind);
    return if $ok;

    my $label = _method_callback_shape_label($method, $arity);
    compile_error("Semantic/F053-Type: $label");
}

sub _validate_expr {
    my ($expr, $ctx, $handled) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        if ($name ne '' && !exists $ctx->{types}{$name}) {
            return 'function_ref' if exists $ctx->{sigs}{$name} || builtin_is_known($name);
            compile_error("Semantic/F053-Type: Unknown variable: $name");
        }
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'list_literal') {
        _validate_expr($_, $ctx, 0) for @{ $expr->{items} // [] };
        my @types = map { _infer_expr_type($_, $ctx) } @{ $expr->{items} // [] };
        if (@types) {
            compile_error("Semantic/F053-Type: List literal items must share the same type category")
              if grep { !defined($_) || $_ eq '' } @types;
            my %uniq = map { $_ => 1 } @types;
            compile_error("Semantic/F053-Type: List literal items must share the same type category")
              if keys(%uniq) > 1;
        }
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'str') {
        my $raw = $expr->{raw};
        if (defined($raw) && $raw =~ /\$\{/) {
            while ($raw =~ /\$\{(.*?)\}/g) {
                my $slot = defined($1) ? $1 : '';
                $slot =~ s/^\s+//;
                $slot =~ s/\s+$//;
                my $slot_expr = eval { parse_expr($slot) };
                if ($@ || !defined($slot_expr) || ref($slot_expr) ne 'HASH') {
                    my $detail = $@ // 'invalid interpolation expression';
                    $detail =~ s/\s+$//;
                    $detail =~ s/^compile error(?: on line \d+)?:\s*//;
                    compile_error("Semantic/F053-Type: Invalid interpolation expression '\${$slot}': $detail");
                }
                my $it = _validate_expr($slot_expr, $ctx, 0);
                compile_error("Semantic/F053-Type: Unsupported interpolation expression type: unknown")
                  if !defined($it) || $it eq '';
                compile_error("Semantic/F053-Type: Unsupported interpolation expression type: $it")
                  if is_union_type($it);
            }
        }
        return 'string';
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
            compile_error("Semantic/F053-Type: Operator '$op' requires number operand, got $lt")
              if !_is_number_type($lt);
            compile_error("Semantic/F053-Type: Operator '$op' requires number operand, got $rt")
              if !_is_number_type($rt);
            my $lk = _infer_numeric_kind($expr->{left}, $ctx);
            my $rk = _infer_numeric_kind($expr->{right}, $ctx);
            if ($op eq '/' || $op eq '~/') {
                compile_error("Semantic/F053-Type: '$op' requires strict numeric operand kinds")
                  if !defined($lk) || !defined($rk);
                compile_error("Semantic/F053-Type: '/' requires operands of type float")
                  if $op eq '/' && !_numeric_kinds_compatible_div($lk, $rk, $expr->{left}, $expr->{right});
                compile_error("Semantic/F053-Type: '~/' requires operands of type int")
                  if $op eq '~/' && !($lk eq 'int' && $rk eq 'int');
                return 'number';
            }
            compile_error("Semantic/F053-Type: '$op' requires matching numeric operand types")
              if !_numeric_kinds_compatible_additive($lk, $rk, $expr->{left}, $expr->{right});
            return 'number';
        }
        if ($op eq '&&' || $op eq '||') {
            compile_error("Semantic/F053-Type: Operator '$op' requires bool operands")
              if !_is_bool_type($lt) || !_is_bool_type($rt);
            return 'bool';
        }
        if ($op eq '==' || $op eq '!=') {
            my $l_kind = $expr->{left}{kind} // '';
            my $r_kind = $expr->{right}{kind} // '';
            if (is_union_type($lt) && is_union_type($rt) && $l_kind ne 'null' && $r_kind ne 'null') {
                my $bad = is_union_type($lt) ? $lt : $rt;
                compile_error("Semantic/F053-Type: Unsupported '$op' operand type: $bad");
            }
            compile_error("Semantic/F053-Type: Type mismatch in '$op'")
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
          if !defined($rt) || (!scalar_is_string($rt) && !is_sequence_type($rt));
        compile_error("Semantic/F053-Type: index must be number")
          if !_is_number_type($it);
        my $fallible = _expr_is_fallible($expr, $ctx);
        if ($fallible && !$handled) {
            if (defined($rt) && !scalar_is_string($rt) && is_sequence_type($rt)) {
                my $elem = sequence_element_type($rt);
                my $label = 'sequence';
                my $elem_label = sequence_elem_label($elem);
                $label = $elem_label if defined($elem_label) && $elem_label ne '';
                compile_error("Semantic/F053-Entailment: Index on '$label' requires compile-time in-bounds proof");
            }
            compile_error("Semantic/F053-Fallibility: unhandled fallible expression; use '?' or 'or catch(...)'");
        }
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
        if (!($ctx->{fn_allows_error_propagation} // 0)) {
            for my $arg (@{ $expr->{args} // [] }) {
                compile_error("Semantic/F053-Type: Postfix '?' is only supported in const assignments and expression statements")
                  if _expr_contains_try($arg);
            }
        }
        _validate_expr($_, $ctx, 0) for @{ $expr->{args} // [] };
        _validate_expr($expr->{recv}, $ctx, 0) if $kind eq 'method_call';
        if ($kind eq 'call') {
            my $name = $expr->{name} // '';
            if ($name eq 'seq') {
                my $args = $expr->{args} // [];
                if (ref($args) eq 'ARRAY') {
                    my $start_t = defined($args->[0]) ? _infer_expr_type($args->[0], $ctx) : undef;
                    my $end_t = defined($args->[1]) ? _infer_expr_type($args->[1], $ctx) : undef;
                    compile_error("Semantic/F053-Type: seq start must be number")
                      if !defined($start_t) || !_is_number_type($start_t);
                    compile_error("Semantic/F053-Type: seq end must be number")
                      if !defined($end_t) || !_is_number_type($end_t);
                }
            }
        }
        if ($kind eq 'method_call') {
            my $method = $expr->{method} // '';
            _validate_method_callback_shape($expr, $method);
            my $recv_t = _infer_expr_type($expr->{recv}, $ctx);
            if (method_has_tag($method, 'entailment_filter_receiver_elem_supported')
                && defined($recv_t) && is_sequence_type($recv_t))
            {
                my $elem = sequence_element_type($recv_t);
                my $ok = 0;
                $ok = 1 if scalar_is_numeric($elem) || scalar_is_string($elem);
                $ok = 1 if defined($elem) && is_matrix_member_type($elem);
                if (!$ok) {
                    my $label = 'sequence';
                    if (defined($elem)) {
                        my $elem_label = sequence_elem_label($elem);
                        $label = $elem_label if defined($elem_label) && $elem_label ne '';
                    }
                    compile_error("Semantic/F053-Type: filter(...) receiver must be string_list, number_list, or matrix member list, got $label");
                }
            }
            if (method_has_tag($method, 'entailment_insert_sequence_index_literal_if_size_known')
                && defined($recv_t) && is_sequence_type($recv_t) && _receiver_has_known_size($expr->{recv}, $ctx))
            {
                my $args = $expr->{args} // [];
                my $idx = (ref($args) eq 'ARRAY') ? $args->[1] : undef;
                if (!defined($idx) || ref($idx) ne 'HASH' || (($idx->{kind} // '') ne 'num')) {
                    my $label = _receiver_diag_label($recv_t) // 'sequence';
                    compile_error("Semantic/F053-Entailment: Method 'insert(...)' on '$label' requires compile-time in-bounds proof");
                }
            }
            my $method_t = _infer_expr_type($expr, $ctx);
            if (!defined($method_t) || $method_t eq '') {
                my $label = _receiver_diag_label($recv_t);
                compile_error("Semantic/F053-Type: Unsupported method call '$method' on type '$label'")
                  if defined($label) && $label ne '';
                compile_error("Semantic/F053-Type: Unsupported method call '$method'");
            }
            if (defined($recv_t) && is_matrix_type($recv_t)) {
                my $meta = matrix_type_meta($recv_t);
                if (method_requires_matrix_axis_argument($method)) {
                    my $axis = $expr->{args}[0];
                    my $axis_max = int($meta->{dim} // 0) - 1;
                    compile_error("Semantic/F053-Entailment: Method '$method(...)' requires compile-time axis proof in range(0, $axis_max)")
                      if $axis_max < 0 || !_expr_int_range_proved($axis, $ctx, 0, $axis_max);
                }
                if (method_has_tag($method, 'entailment_insert_matrix_index_proof_if_size_known') && ($meta->{has_size} // 0)) {
                    my $sizes = $meta->{sizes} // [];
                    my $all_concrete = @$sizes ? 1 : 0;
                    for my $s (@$sizes) {
                        if (int($s // -1) < 0) {
                            $all_concrete = 0;
                            last;
                        }
                    }
                    if ($all_concrete) {
                        my $idx = $expr->{args}[1];
                        compile_error("Semantic/F053-Entailment: Method 'insert(...)' requires compile-time matrix index proof against matrixSize constraints")
                          if !_matrix_index_proved_for_known_sizes($idx, $meta, $ctx);
                    }
                }
            }
        }
        my $fallible = _expr_is_fallible($expr, $ctx);
        if ($fallible && !$handled) {
            my $diag = _unhandled_fallibility_diagnostic($expr, $ctx);
            compile_error($diag) if defined($diag) && $diag ne '';
            compile_error("Semantic/F053-Fallibility: unhandled fallible expression; use '?' or 'or catch(...)'");
        }
        return _infer_expr_type($expr, $ctx);
    }

    if ($kind eq 'lambda1' || $kind eq 'lambda2') {
        return _infer_expr_type($expr, $ctx);
    }

    return _infer_expr_type($expr, $ctx);
}

1;
