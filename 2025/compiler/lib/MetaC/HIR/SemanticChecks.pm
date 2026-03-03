package MetaC::HIR::SemanticChecks;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(
    compile_error
    set_error_line
    clear_error_line
    constraint_range_bounds
    constraint_size_exact
);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);
use MetaC::HIR::OpRegistry qw(
    method_has_length_semantics
    method_traceability_hint
    method_has_tag
);
use MetaC::HIR::SemanticChecksExpr qw(
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
use MetaC::TypeSpec qw(
    is_union_type
    union_contains_member
    union_member_types
    is_sequence_type
    sequence_element_type
    sequence_member_type
    is_matrix_member_type
    matrix_member_meta
    is_sequence_member_type
    sequence_member_meta
);
use MetaC::HIR::TypeRegistry qw(
    scalar_is_numeric
    scalar_is_string
    scalar_is_boolean
    scalar_is_error
);

our @EXPORT_OK = qw(enforce_hir_semantics);

sub _derive_if_narrowing {
    my ($cond, $ctx) = @_;
    my (%then_types, %else_types, %then_facts, %else_facts);
    return (\%then_types, \%else_types, \%then_facts, \%else_facts)
      if !defined($cond) || ref($cond) ne 'HASH' || ($cond->{kind} // '') ne 'binop';

    my $op = $cond->{op} // '';
    if ($op eq '&&' || $op eq '||') {
        my ($lt_t, $le_t, $lt_f, $le_f) = _derive_if_narrowing($cond->{left}, $ctx);
        if ($op eq '&&') {
            my %rhs_ctx = %$ctx;
            $rhs_ctx{types} = _clone_hash($ctx->{types});
            $rhs_ctx{facts} = _clone_hash($ctx->{facts});
            $rhs_ctx{types}{$_} = $lt_t->{$_} for keys %$lt_t;
            $rhs_ctx{facts}{$_} = 1 for keys %$lt_f;
            my ($rt_t, $re_t, $rt_f, $re_f) = _derive_if_narrowing($cond->{right}, \%rhs_ctx);
            $then_types{$_} = $lt_t->{$_} for keys %$lt_t;
            $then_types{$_} = $rt_t->{$_} for keys %$rt_t;
            $then_facts{$_} = 1 for keys %$lt_f;
            $then_facts{$_} = 1 for keys %$rt_f;
            return (\%then_types, \%else_types, \%then_facts, \%else_facts);
        }
        my %rhs_ctx = %$ctx;
        $rhs_ctx{types} = _clone_hash($ctx->{types});
        $rhs_ctx{facts} = _clone_hash($ctx->{facts});
        $rhs_ctx{types}{$_} = $le_t->{$_} for keys %$le_t;
        $rhs_ctx{facts}{$_} = 1 for keys %$le_f;
        my ($rt_t, $re_t, $rt_f, $re_f) = _derive_if_narrowing($cond->{right}, \%rhs_ctx);
        $else_types{$_} = $le_t->{$_} for keys %$le_t;
        $else_types{$_} = $re_t->{$_} for keys %$re_t;
        $else_facts{$_} = 1 for keys %$le_f;
        $else_facts{$_} = 1 for keys %$re_f;
        return (\%then_types, \%else_types, \%then_facts, \%else_facts);
    }

    if (($op eq '==' || $op eq '!=')
        && defined($cond->{left}) && defined($cond->{right})
        && ref($cond->{left}) eq 'HASH' && ref($cond->{right}) eq 'HASH')
    {
        my ($ident, $is_eq_null);
        if (($cond->{left}{kind} // '') eq 'ident' && ($cond->{right}{kind} // '') eq 'null') {
            $ident = $cond->{left}{name};
            $is_eq_null = $op eq '==';
        } elsif (($cond->{right}{kind} // '') eq 'ident' && ($cond->{left}{kind} // '') eq 'null') {
            $ident = $cond->{right}{name};
            $is_eq_null = $op eq '==';
        }
        if (defined($ident) && $ident ne '' && exists $ctx->{types}{$ident}) {
            my $cur = $ctx->{types}{$ident};
            my $nonnull = _type_without_member($cur, 'null');
            $then_types{$ident} = $nonnull if defined($nonnull) && !$is_eq_null;
            $else_types{$ident} = $nonnull if defined($nonnull) && $is_eq_null;
        }
    }

    if (($op eq '==' || $op eq '!=')
        && defined($cond->{left}) && defined($cond->{right})
        && ref($cond->{left}) eq 'HASH' && ref($cond->{right}) eq 'HASH')
    {
        my ($size_expr, $num_expr);
        if (($cond->{left}{kind} // '') eq 'method_call' && ($cond->{right}{kind} // '') eq 'num') {
            $size_expr = $cond->{left};
            $num_expr = $cond->{right};
        } elsif (($cond->{right}{kind} // '') eq 'method_call' && ($cond->{left}{kind} // '') eq 'num') {
            $size_expr = $cond->{right};
            $num_expr = $cond->{left};
        }
        if (defined($size_expr) && defined($num_expr)) {
            my $method = $size_expr->{method} // '';
            my $args = $size_expr->{args} // [];
            my $recv = $size_expr->{recv};
            if (method_has_length_semantics($method)
                && ref($args) eq 'ARRAY' && !@$args
                && defined($recv) && ref($recv) eq 'HASH')
            {
                my $n = int($num_expr->{value});
                my $expr_key = _expr_fact_key($recv);
                if (defined($expr_key) && $expr_key ne '') {
                    my $fact = "len_expr:$expr_key:$n";
                    if ($op eq '==') {
                        $then_facts{$fact} = 1;
                    } else {
                        $else_facts{$fact} = 1;
                    }
                }
                if (($recv->{kind} // '') eq 'ident') {
                    my $name = $recv->{name} // '';
                    if ($name ne '') {
                        my $fact = "len_var:$name:$n";
                        if ($op eq '==') {
                            $then_facts{$fact} = 1;
                        } else {
                            $else_facts{$fact} = 1;
                        }
                    }
                }
            }
        }
    }

    return (\%then_types, \%else_types, \%then_facts, \%else_facts);
}

sub _normalize_fallible_expr_type_for_try_assignment {
    my ($expr, $expr_t, $ctx) = @_;
    return $expr_t if !defined($expr_t) || $expr_t eq '';
    return $expr_t if scalar_is_error($expr_t);
    return $expr_t if is_union_type($expr_t) && union_contains_member($expr_t, 'error');
    return $expr_t if !_expr_is_fallible($expr, $ctx);
    return $expr_t . ' | error';
}

sub _list_length_proved {
    my ($expr, $ctx, $need) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    my $expr_key = _expr_fact_key($expr);
    if (defined($expr_key) && $expr_key ne '') {
        my $facts = $ctx->{facts} // {};
        return 1 if $facts->{"len_expr:$expr_key:$need"};
    }
    if (($expr->{kind} // '') eq 'list_literal') {
        return scalar(@{ $expr->{items} // [] }) == $need ? 1 : 0;
    }
    if (($expr->{kind} // '') eq 'method_call'
        && (method_traceability_hint($expr->{method} // '') // '') eq 'requires_source_index_metadata')
    {
        my $recv = $expr->{recv};
        my $recv_t = _infer_expr_type($recv, $ctx);
        if (defined($recv_t) && is_sequence_member_type($recv_t)) {
            my $smeta = sequence_member_meta($recv_t);
            $recv_t = $smeta->{elem} if defined($smeta) && defined($smeta->{elem});
        }
        if (defined($recv_t) && is_matrix_member_type($recv_t)) {
            my $meta = matrix_member_meta($recv_t);
            return int($meta->{dim} // 0) == $need ? 1 : 0 if defined($meta);
        }
    }
    return 0 if ($expr->{kind} // '') ne 'ident';
    my $name = $expr->{name} // '';
    return 0 if $name eq '';
    my $facts = $ctx->{facts} // {};
    return $facts->{"len_var:$name:$need"} ? 1 : 0;
}

sub _expr_signature {
    my ($expr) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'ident') {
        return 'id(' . ($expr->{name} // '') . ')';
    }
    if ($kind eq 'num') {
        return 'num(' . ($expr->{value} // '') . ')';
    }
    if ($kind eq 'str') {
        return 'str(' . ($expr->{raw} // '') . ')';
    }
    if ($kind eq 'bool') {
        return 'bool(' . (($expr->{value} // 0) ? '1' : '0') . ')';
    }
    return 'null' if $kind eq 'null';
    if ($kind eq 'unary') {
        my $inner = _expr_signature($expr->{expr});
        return undef if !defined($inner);
        return 'u(' . ($expr->{op} // '') . ',' . $inner . ')';
    }
    if ($kind eq 'binop') {
        my $l = _expr_signature($expr->{left});
        my $r = _expr_signature($expr->{right});
        return undef if !defined($l) || !defined($r);
        return 'b(' . ($expr->{op} // '') . ',' . $l . ',' . $r . ')';
    }
    if ($kind eq 'call') {
        my @args;
        for my $a (@{ $expr->{args} // [] }) {
            my $s = _expr_signature($a);
            return undef if !defined($s);
            push @args, $s;
        }
        return 'c(' . ($expr->{name} // '') . ',' . join(',', @args) . ')';
    }
    if ($kind eq 'method_call') {
        my $recv = _expr_signature($expr->{recv});
        return undef if !defined($recv);
        my @args;
        for my $a (@{ $expr->{args} // [] }) {
            my $s = _expr_signature($a);
            return undef if !defined($s);
            push @args, $s;
        }
        return 'm(' . ($expr->{method} // '') . ',' . $recv . ',' . join(',', @args) . ')';
    }
    if ($kind eq 'index') {
        my $recv = _expr_signature($expr->{recv});
        my $idx = _expr_signature($expr->{index});
        return undef if !defined($recv) || !defined($idx);
        return 'i(' . $recv . ',' . $idx . ')';
    }
    if ($kind eq 'try') {
        my $inner = _expr_signature($expr->{expr});
        return undef if !defined($inner);
        return 't(' . $inner . ')';
    }
    if ($kind eq 'list_literal') {
        my @items;
        for my $it (@{ $expr->{items} // [] }) {
            my $s = _expr_signature($it);
            return undef if !defined($s);
            push @items, $s;
        }
        return 'l(' . join(',', @items) . ')';
    }
    return undef;
}

sub _expr_fact_key {
    my ($expr) = @_;
    my $sig = _expr_signature($expr);
    return undef if !defined($sig) || $sig eq '';
    return unpack('H*', $sig);
}

sub _sequence_type_label {
    my ($type) = @_;
    return undef if !defined($type) || !is_sequence_type($type);
    my $elem = sequence_element_type($type);
    return undef if !defined($elem) || $elem eq '';
    return 'number[]' if scalar_is_numeric($elem);
    return 'string[]' if scalar_is_string($elem);
    return 'bool[]' if scalar_is_boolean($elem);
    return $elem . '[]';
}

sub _single_non_error_member_from_error_union {
    my ($type) = @_;
    return undef if !defined($type) || !is_union_type($type) || !union_contains_member($type, 'error');
    my @members = grep { $_ ne 'error' } @{ union_member_types($type) };
    return undef if @members != 1;
    return $members[0];
}

sub _nested_required_size_for_receiver {
    my ($recv_expr, $ctx) = @_;
    return undef if !defined($recv_expr) || ref($recv_expr) ne 'HASH' || ($recv_expr->{kind} // '') ne 'ident';
    my $name = $recv_expr->{name} // '';
    return undef if $name eq '';
    my $constraints = $ctx->{constraints}{$name};
    return undef if !defined($constraints) || ref($constraints) ne 'HASH';
    my $need = $constraints->{nested_number_list_size};
    return undef if !defined($need) || $need !~ /^-?\d+$/;
    $need = int($need);
    return undef if $need < 0;
    return $need;
}

sub _fn_allows_error_propagation {
    my ($ctx) = @_;
    my $ret = $ctx->{fn_return};
    return 0 if !defined($ret) || $ret eq '';
    return 1 if scalar_is_error($ret);
    return 1 if is_union_type($ret) && union_contains_member($ret, 'error');
    return 0;
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

sub _constraints_range_partial {
    my ($constraints) = @_;
    return (undef, undef) if !defined($constraints) || ref($constraints) ne 'HASH';
    my $nodes = $constraints->{nodes};
    return (undef, undef) if !defined($nodes) || ref($nodes) ne 'ARRAY';
    for my $node (@$nodes) {
        next if !defined($node) || ref($node) ne 'HASH';
        next if ($node->{kind} // '') ne 'range';
        my $args = $node->{args} // [];
        next if ref($args) ne 'ARRAY' || @$args < 2;
        my ($min, $max) = @$args;
        my $min_v = (defined($min) && ref($min) eq 'HASH' && (($min->{kind} // '') eq 'number')) ? int($min->{value}) : undef;
        my $max_v = (defined($max) && ref($max) eq 'HASH' && (($max->{kind} // '') eq 'number')) ? int($max->{value}) : undef;
        return ($min_v, $max_v);
    }
    return (undef, undef);
}

sub _constraints_integral_range {
    my ($constraints) = @_;
    my ($min, $max) = constraint_range_bounds($constraints);
    return (undef, undef) if !defined($min) || !defined($max);
    return (undef, undef) if $min !~ /^-?\d+$/ || $max !~ /^-?\d+$/;
    return (int($min), int($max));
}

sub _clear_symbol_facts {
    my ($ctx, $name) = @_;
    return if !defined($name) || $name eq '';
    my $facts = $ctx->{facts} // {};
    for my $k (keys %$facts) {
        delete $facts->{$k} if $k =~ /^(?:len_var|range_var|len_alias):\Q$name\E:/;
    }
}

sub _seed_constraint_facts {
    my ($ctx, $name, $constraints) = @_;
    return if !defined($name) || $name eq '';
    my $facts = $ctx->{facts} // {};

    my ($min, $max) = _constraints_integral_range($constraints);
    if (defined($min) && defined($max)) {
        $facts->{"range_var:$name:$min:$max"} = 1;
    }

    my $size = constraint_size_exact($constraints);
    if (defined($size) && $size =~ /^-?\d+$/) {
        my $n = int($size);
        $facts->{"len_var:$name:$n"} = 1 if $n >= 0;
    }
}

sub _single_known_len_for_expr {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    my $facts = $ctx->{facts} // {};

    if ($kind eq 'list_literal') {
        return scalar(@{ $expr->{items} // [] });
    }
    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        return undef if $name eq '';
        my @vals;
        for my $k (keys %$facts) {
            next if $k !~ /^len_var:\Q$name\E:(-?\d+)$/;
            push @vals, int($1);
        }
        return undef if !@vals;
        return undef if @vals > 1;
        return $vals[0];
    }
    if ($kind eq 'method_call'
        && method_has_tag(($expr->{method} // ''), 'entailment_insert_sequence_index_literal_if_size_known'))
    {
        my $base = _single_known_len_for_expr($expr->{recv}, $ctx);
        return undef if !defined($base);
        return $base;
    }
    return undef;
}

sub _record_len_alias_if_any {
    my ($ctx, $name, $expr) = @_;
    return if !defined($name) || $name eq '' || !defined($expr) || ref($expr) ne 'HASH';
    my $facts = $ctx->{facts} // {};
    my $kind = $expr->{kind} // '';
    return if $kind ne 'method_call';
    my $method = $expr->{method} // '';
    return if !method_has_length_semantics($method);
    my $args = $expr->{args} // [];
    return if ref($args) ne 'ARRAY' || @$args;
    my $recv = $expr->{recv};
    return if !defined($recv) || ref($recv) ne 'HASH' || ($recv->{kind} // '') ne 'ident';
    my $src = $recv->{name} // '';
    return if $src eq '';
    $facts->{"len_alias:$name:$src"} = 1;
}

sub _len_source_var_from_expr {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'method_call') {
        my $method = $expr->{method} // '';
        my $args = $expr->{args} // [];
        return undef if !method_has_length_semantics($method);
        return undef if ref($args) ne 'ARRAY' || @$args;
        my $recv = $expr->{recv};
        return undef if !defined($recv) || ref($recv) ne 'HASH' || ($recv->{kind} // '') ne 'ident';
        my $src = $recv->{name} // '';
        return $src if $src ne '';
    }
    if ($kind eq 'ident') {
        my $alias = $expr->{name} // '';
        return undef if $alias eq '';
        my $facts = $ctx->{facts} // {};
        for my $k (keys %$facts) {
            next if $k !~ /^len_alias:\Q$alias\E:(.+)$/;
            return $1;
        }
    }
    return undef;
}

sub _len_bounds_for_var {
    my ($name, $ctx) = @_;
    return (undef, undef) if !defined($name) || $name eq '';
    my $facts = $ctx->{facts} // {};
    my @vals;
    for my $k (keys %$facts) {
        next if $k !~ /^len_var:\Q$name\E:(-?\d+)$/;
        push @vals, int($1);
    }
    return (undef, undef) if !@vals;
    my ($min, $max) = ($vals[0], $vals[0]);
    for my $v (@vals) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }
    return ($min, $max);
}

sub _static_int_expr {
    my ($expr) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'num') {
        my $v = $expr->{value};
        return undef if !defined($v) || $v !~ /^-?\d+$/;
        return int($v);
    }
    return undef if $kind ne 'binop';
    my $op = $expr->{op} // '';
    return undef if $op ne '+' && $op ne '-';
    my $l = _static_int_expr($expr->{left});
    my $r = _static_int_expr($expr->{right});
    return undef if !defined($l) || !defined($r);
    return $op eq '+' ? ($l + $r) : ($l - $r);
}

sub _expr_as_len_plus_offset {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $n = _static_int_expr($expr);
    return { src => undef, offset => $n } if defined($n);

    my $src = _len_source_var_from_expr($expr, $ctx);
    return { src => $src, offset => 0 } if defined($src) && $src ne '';

    return undef if ($expr->{kind} // '') ne 'binop';
    my $op = $expr->{op} // '';
    return undef if $op ne '+' && $op ne '-';
    my $l = _expr_as_len_plus_offset($expr->{left}, $ctx);
    my $r = _expr_as_len_plus_offset($expr->{right}, $ctx);
    return undef if !defined($l) || !defined($r);

    if ($op eq '+') {
        return undef if defined($l->{src}) && defined($r->{src});
        my $src_sum = defined($l->{src}) ? $l->{src} : $r->{src};
        return { src => $src_sum, offset => int($l->{offset}) + int($r->{offset}) };
    }

    return undef if defined($r->{src});
    return { src => $l->{src}, offset => int($l->{offset}) - int($r->{offset}) };
}

sub _for_seq_index_bound_fact {
    my ($iterable, $var, $ctx) = @_;
    return undef if !defined($iterable) || ref($iterable) ne 'HASH' || !defined($var) || $var eq '';
    return undef if ($iterable->{kind} // '') ne 'call' || ($iterable->{name} // '') ne 'seq';
    my $args = $iterable->{args} // [];
    return undef if ref($args) ne 'ARRAY' || @$args != 2;
    my ($start, $end) = @$args;

    my $start_form = _expr_as_len_plus_offset($start, $ctx);
    my $end_form = _expr_as_len_plus_offset($end, $ctx);
    return undef if !defined($start_form) || !defined($end_form);

    my $src = defined($start_form->{src}) ? $start_form->{src} : $end_form->{src};
    return undef if !defined($src) || $src eq '';
    return undef if defined($start_form->{src}) && defined($end_form->{src}) && $start_form->{src} ne $end_form->{src};

    my ($len_min, $len_max) = _len_bounds_for_var($src, $ctx);
    my $start_ok = 0;
    if (!defined($start_form->{src})) {
        $start_ok = int($start_form->{offset}) >= 0 ? 1 : 0;
    } elsif ($start_form->{src} eq $src) {
        $start_ok = int($start_form->{offset}) >= 0 ? 1 : 0;
        $start_ok = 1 if !$start_ok && defined($len_min) && ($len_min + int($start_form->{offset}) >= 0);
    }
    return undef if !$start_ok;

    my $end_ok = 0;
    if (!defined($end_form->{src})) {
        $end_ok = 1 if defined($len_min) && int($end_form->{offset}) < $len_min;
    } elsif ($end_form->{src} eq $src) {
        $end_ok = int($end_form->{offset}) <= -1 ? 1 : 0;
        $end_ok = 1 if !$end_ok && defined($len_min) && defined($len_max)
          && ($len_max + int($end_form->{offset}) < $len_min);
    }
    return undef if !$end_ok;

    return "idx_in_bounds:$var:$src";
}

sub _expr_references_mutable {
    my ($expr, $ctx) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'ident') {
        my $name = $expr->{name} // '';
        return ($name ne '' && ($ctx->{mut}{$name} // 0)) ? 1 : 0;
    }
    if ($kind eq 'binop') {
        return _expr_references_mutable($expr->{left}, $ctx) || _expr_references_mutable($expr->{right}, $ctx);
    }
    if ($kind eq 'unary' || $kind eq 'try' || $kind eq 'index') {
        return _expr_references_mutable($expr->{expr}, $ctx) if $kind ne 'index';
        return _expr_references_mutable($expr->{recv}, $ctx) || _expr_references_mutable($expr->{index}, $ctx);
    }
    if ($kind eq 'call') {
        for my $a (@{ $expr->{args} // [] }) {
            return 1 if _expr_references_mutable($a, $ctx);
        }
        return 0;
    }
    if ($kind eq 'method_call') {
        return 1 if _expr_references_mutable($expr->{recv}, $ctx);
        for my $a (@{ $expr->{args} // [] }) {
            return 1 if _expr_references_mutable($a, $ctx);
        }
        return 0;
    }
    if ($kind eq 'list_literal') {
        for my $a (@{ $expr->{items} // [] }) {
            return 1 if _expr_references_mutable($a, $ctx);
        }
        return 0;
    }
    return 0;
}

sub _validate_stmt_seq {
    my ($stmts, $ctx) = @_;
    for my $stmt (@{ $stmts // [] }) {
        my $line = (defined($stmt) && ref($stmt) eq 'HASH') ? ($stmt->{line} // undef) : undef;
        set_error_line($line);
        _validate_stmt($stmt, $ctx);
        clear_error_line();
    }
}

sub _stmt_seq_terminal_return {
    my ($stmts) = @_;
    return 0 if !defined($stmts) || ref($stmts) ne 'ARRAY' || !@$stmts;
    my $last = $stmts->[-1];
    return 0 if !defined($last) || ref($last) ne 'HASH';
    return (($last->{kind} // '') eq 'return') ? 1 : 0;
}

sub _validate_stmt {
    my ($stmt, $ctx) = @_;
    return if !defined($stmt) || ref($stmt) ne 'HASH';
    my $kind = $stmt->{kind} // '';

    if ($kind eq 'const' || $kind eq 'let' || $kind eq 'const_typed') {
        my $name = $stmt->{name} // '';
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        my $decl_t = $stmt->{type};
        my $decl_k = $stmt->{declared_numeric_kind};
        compile_error("Semantic/F053-Type: Empty list literal requires an explicit list type")
          if (!defined($decl_t) || $decl_t eq '') && defined($expr_t) && $expr_t eq 'empty_list';
        if (defined($decl_t) && $decl_t ne '') {
            compile_error("Semantic/F053-Type: cannot assign '$expr_t' to declared type '$decl_t' for '$name'")
              if !$expr_t || !_types_assignable($expr_t, $decl_t);
        } else {
            $decl_t = $expr_t;
        }
        if (($kind eq 'const' || $kind eq 'const_typed')
            && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH' && (($stmt->{expr}{kind} // '') eq 'num'))
        {
            my ($min, $max) = _constraints_range_partial($stmt->{constraints});
            if (defined($min) || defined($max)) {
                my $v = 0 + ($stmt->{expr}{value} // 0);
                my $out = (defined($min) && $v < $min) || (defined($max) && $v > $max);
                if ($out) {
                    my $min_txt = defined($min) ? $min : '*';
                    my $max_txt = defined($max) ? $max : '*';
                    compile_error("Semantic/F053-Constraint: range($min_txt,$max_txt) constant '$name' initialized out of range");
                }
            }
        }
        my $numeric_target = _is_number_type($decl_t) ? 1 : 0;
        if ($numeric_target) {
            if (!defined($decl_k) || $decl_k eq '') {
                $decl_k = _numeric_kind_for_type($decl_t);
            }
            my $expr_k = _infer_numeric_kind($stmt->{expr}, $ctx);
            if (defined($decl_k) && $decl_k ne '') {
                compile_error("Semantic/F053-Type: cannot assign numeric kind '" . ($expr_k // '') . "' to declared numeric kind '$decl_k' for '$name'")
                  if !defined($expr_k) || !_numeric_kind_assignable($expr_k, $decl_k);
                $ctx->{numeric_kinds}{$name} = $decl_k if $name ne '';
            } elsif (defined($expr_k) && $expr_k ne '') {
                $ctx->{numeric_kinds}{$name} = $expr_k if $name ne '';
            } else {
                delete $ctx->{numeric_kinds}{$name} if $name ne '';
            }
        } else {
            delete $ctx->{numeric_kinds}{$name} if $name ne '';
        }
        _clear_symbol_facts($ctx, $name);
        _seed_constraint_facts($ctx, $name, $stmt->{constraints});
        my $known_len = _single_known_len_for_expr($stmt->{expr}, $ctx);
        $ctx->{facts}{"len_var:$name:$known_len"} = 1
          if $name ne '' && defined($known_len) && $known_len >= 0;
        _record_len_alias_if_any($ctx, $name, $stmt->{expr});
        $ctx->{types}{$name} = $decl_t if $name ne '' && defined $decl_t;
        $ctx->{mut}{$name} = ($kind eq 'let') ? 1 : 0 if $name ne '';
        $ctx->{constraints}{$name} = $stmt->{constraints} if $name ne '';
        return;
    }

    if ($kind eq 'typed_assign' || $kind eq 'assign') {
        my $name = $stmt->{name} // '';
        compile_error("Semantic/F053-Type: assignment to unknown variable '$name'")
          if !exists $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: Cannot assign to immutable variable '$name'")
          if !($ctx->{mut}{$name} // 0);
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        my $target_t = (defined($stmt->{type}) && $stmt->{type} ne '') ? $stmt->{type} : $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: cannot assign '$expr_t' to '$name' of type '$target_t'")
          if !$expr_t || !_types_assignable($expr_t, $target_t);
        my $numeric_target = _is_number_type($target_t) ? 1 : 0;
        if ($numeric_target) {
            my $target_k = $stmt->{declared_numeric_kind};
            $target_k = $ctx->{numeric_kinds}{$name}
              if (!defined($target_k) || $target_k eq '') && exists $ctx->{numeric_kinds}{$name};
            $target_k = _numeric_kind_for_type($target_t)
              if !defined($target_k) || $target_k eq '';
            my $expr_k = _infer_numeric_kind($stmt->{expr}, $ctx);
            if (defined($target_k) && $target_k ne '') {
                compile_error("Semantic/F053-Type: cannot assign numeric kind '" . ($expr_k // '') . "' to '$name' with numeric kind '$target_k'")
                  if !defined($expr_k) || !_numeric_kind_assignable($expr_k, $target_k);
                $ctx->{numeric_kinds}{$name} = $target_k;
            } elsif (defined($expr_k) && $expr_k ne '') {
                $ctx->{numeric_kinds}{$name} = $expr_k;
            } else {
                delete $ctx->{numeric_kinds}{$name};
            }
        } else {
            delete $ctx->{numeric_kinds}{$name};
        }
        _clear_symbol_facts($ctx, $name);
        _seed_constraint_facts($ctx, $name, $stmt->{constraints});
        my $known_len = _single_known_len_for_expr($stmt->{expr}, $ctx);
        $ctx->{facts}{"len_var:$name:$known_len"} = 1
          if $name ne '' && defined($known_len) && $known_len >= 0;
        _record_len_alias_if_any($ctx, $name, $stmt->{expr});
        $ctx->{types}{$name} = $target_t if defined $target_t;
        $ctx->{constraints}{$name} = $stmt->{constraints}
          if $kind eq 'typed_assign' && $name ne '';
        return;
    }

    if ($kind eq 'assign_op' || $kind eq 'incdec') {
        my $name = $stmt->{name} // '';
        compile_error("Semantic/F053-Type: assignment to unknown variable '$name'")
          if !exists $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: Cannot assign to immutable variable '$name'")
          if !($ctx->{mut}{$name} // 0);
        compile_error("Semantic/F053-Type: '$name' must be number for '$kind'")
          if !_is_number_type($ctx->{types}{$name});
        if ($kind eq 'assign_op') {
            my $et = _validate_expr($stmt->{expr}, $ctx, 0);
            compile_error("Semantic/F053-Type: '+=' requires number rhs")
              if !_is_number_type($et);
        }
        _clear_symbol_facts($ctx, $name);
        return;
    }

    if ($kind eq 'destructure_list') {
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        compile_error("Semantic/F053-Type: list destructuring requires sequence expression")
          if !defined($expr_t) || !is_sequence_type($expr_t);
        my $need = scalar(@{ $stmt->{vars} // [] });
        compile_error("Semantic/F053-Entailment: Cannot prove destructuring arity")
          if !_list_length_proved($stmt->{expr}, $ctx, $need);
        my $elem_t = sequence_element_type($expr_t);
        for my $v (@{ $stmt->{vars} // [] }) {
            next if !defined($v) || $v eq '';
            $ctx->{types}{$v} = $elem_t;
            $ctx->{mut}{$v} = 0;
            my $nk = _numeric_kind_for_type($elem_t);
            if (defined($nk) && $nk ne '') {
                $ctx->{numeric_kinds}{$v} = $nk;
            } else {
                delete $ctx->{numeric_kinds}{$v};
            }
            _clear_symbol_facts($ctx, $v);
        }
        return;
    }

    if ($kind eq 'destructure_split_or') {
        _validate_expr($stmt->{source_expr}, $ctx, 1) if defined $stmt->{source_expr};
        _validate_expr($stmt->{delim_expr}, $ctx, 1) if defined $stmt->{delim_expr};
        my %hctx = %$ctx;
        $hctx{types} = _clone_hash($ctx->{types});
        $hctx{mut} = _clone_hash($ctx->{mut});
        $hctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
        $hctx{facts} = _clone_hash($ctx->{facts});
        $hctx{constraints} = _clone_hash($ctx->{constraints});
        $hctx{constraints} = _clone_hash($ctx->{constraints});
        if (defined($stmt->{err_name}) && $stmt->{err_name} ne '') {
            $hctx{types}{ $stmt->{err_name} } = 'error';
            $hctx{mut}{ $stmt->{err_name} } = 0;
        }
        _validate_stmt_seq($stmt->{handler}, \%hctx) if defined $stmt->{handler};
        for my $v (@{ $stmt->{vars} // [] }) {
            next if !defined($v) || $v eq '';
            $ctx->{types}{$v} = 'string';
            $ctx->{mut}{$v} = 0;
            delete $ctx->{numeric_kinds}{$v};
            _clear_symbol_facts($ctx, $v);
        }
        return;
    }

    if ($kind eq 'destructure_match') {
        my $source_var = $stmt->{source_var} // '';
        my $source_t = _validate_expr({ kind => 'ident', name => $source_var }, $ctx, 0);
        compile_error("Semantic/F053-Type: match(...) source must be string")
          if !defined($source_t) || $source_t ne 'string';
        my $types = $stmt->{var_types};
        for my $i (0 .. $#{ $stmt->{vars} // [] }) {
            my $v = $stmt->{vars}[$i];
            next if !defined($v) || $v eq '';
            my $vt = (defined($types) && ref($types) eq 'ARRAY') ? ($types->[$i] // 'string') : 'string';
            $vt = 'string' if $vt ne 'number' && $vt ne 'string';
            $ctx->{types}{$v} = $vt;
            $ctx->{mut}{$v} = 0;
            my $nk = _numeric_kind_for_type($vt);
            if (defined($nk) && $nk ne '') {
                $ctx->{numeric_kinds}{$v} = $nk;
            } else {
                delete $ctx->{numeric_kinds}{$v};
            }
            _clear_symbol_facts($ctx, $v);
        }
        return;
    }

    if ($kind eq 'const_try_expr' || $kind eq 'expr_stmt_try') {
        my $expr = defined($stmt->{expr}) ? $stmt->{expr} : $stmt->{first};
        if ($kind eq 'const_try_expr' && defined($expr) && ref($expr) eq 'HASH') {
            my $target = (($expr->{kind} // '') eq 'try') ? $expr->{expr} : $expr;
            if (defined($target) && ref($target) eq 'HASH' && (($target->{kind} // '') eq 'method_call')) {
                my $m = $target->{method} // '';
                if (method_has_tag($m, 'try_const_assignment_unsupported')) {
                    compile_error("Semantic/F053-Type: Unsupported try expression in const assignment");
                }
            }
        }
        _validate_expr($expr, $ctx, 1);
        compile_error("Semantic/F053-Type: Unsupported try expression in const assignment")
          if !_expr_is_fallible($expr, $ctx);
        if ($kind ne 'expr_stmt_try') {
            my $name = $stmt->{name} // '';
            my $inner_t = _infer_expr_type($expr, $ctx);
            $inner_t = _normalize_fallible_expr_type_for_try_assignment($expr, $inner_t, $ctx);
            my $without_error = _type_without_error_union_member($inner_t);
            compile_error("Semantic/F053-Type: try-assignment requires an error-union expression")
              if !defined($without_error);
            $ctx->{types}{$name} = $without_error if $name ne '';
            $ctx->{mut}{$name} = 0 if $name ne '';
            my $nk = _numeric_kind_for_type($without_error);
            if (defined($nk) && $nk ne '') {
                $ctx->{numeric_kinds}{$name} = $nk;
            } else {
                delete $ctx->{numeric_kinds}{$name} if $name ne '';
            }
            _clear_symbol_facts($ctx, $name);
            delete $ctx->{constraints}{$name} if $name ne '';
        }
        return;
    }

    if ($kind eq 'const_try_tail_expr') {
        my $first = $stmt->{first};
        _validate_expr($first, $ctx, 1);
        compile_error("Semantic/F053-Type: Unsupported try expression in const assignment")
          if !_expr_is_fallible($first, $ctx);

        my $cur_t = _infer_expr_type($first, $ctx);
        $cur_t = _normalize_fallible_expr_type_for_try_assignment($first, $cur_t, $ctx);
        my $ok_t = _type_without_error_union_member($cur_t);
        compile_error("Semantic/F053-Type: try-assignment requires an error-union expression")
          if !defined($ok_t);
        $cur_t = $ok_t;

        for my $step (@{ $stmt->{steps} // [] }) {
            next if !defined($step) || ref($step) ne 'HASH';
            my %tmp = %$ctx;
            $tmp{types} = _clone_hash($ctx->{types});
            $tmp{mut} = _clone_hash($ctx->{mut});
            $tmp{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
            $tmp{facts} = _clone_hash($ctx->{facts});
            $tmp{types}{__chain_recv} = $cur_t;
            $tmp{mut}{__chain_recv} = 0;
            my $call = {
                kind   => 'method_call',
                method => ($step->{name} // ''),
                recv   => { kind => 'ident', name => '__chain_recv' },
                args   => $step->{args} // [],
            };
            _validate_expr($call, \%tmp, 0);
            my $step_t = _infer_expr_type($call, \%tmp);
            compile_error("Semantic/F053-Type: chain step type is unresolved")
              if !defined($step_t) || $step_t eq '';
            $cur_t = $step_t;
        }

        my $name = $stmt->{name} // '';
        $ctx->{types}{$name} = $cur_t if $name ne '';
        $ctx->{mut}{$name} = 0 if $name ne '';
        my $nk = _numeric_kind_for_type($cur_t);
        if (defined($nk) && $nk ne '') {
            $ctx->{numeric_kinds}{$name} = $nk;
        } else {
            delete $ctx->{numeric_kinds}{$name} if $name ne '';
        }
        _clear_symbol_facts($ctx, $name);
        delete $ctx->{constraints}{$name} if $name ne '';
        return;
    }

    if ($kind eq 'const_try_chain') {
        my $name = $stmt->{name} // '';
        my $first = $stmt->{first};
        _validate_expr($first, $ctx, 1);
        compile_error("Semantic/F053-Fallibility: try-expression requires fallible expression")
          if !_expr_is_fallible($first, $ctx);
        my $cur_t = _infer_expr_type($first, $ctx);
        $cur_t = _normalize_fallible_expr_type_for_try_assignment($first, $cur_t, $ctx);
        my $ok_t = _type_without_error_union_member($cur_t);
        compile_error("Semantic/F053-Type: try-assignment requires an error-union expression")
          if !defined($ok_t);

        for my $step (@{ $stmt->{steps} // [] }) {
            next if !defined($step) || ref($step) ne 'HASH';
            my $recv_name = '__chain_recv';
            my %tmp = %$ctx;
            $tmp{types} = _clone_hash($ctx->{types});
            $tmp{mut} = _clone_hash($ctx->{mut});
            $tmp{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
            $tmp{facts} = _clone_hash($ctx->{facts});
            $tmp{types}{$recv_name} = $ok_t;
            $tmp{mut}{$recv_name} = 0;
            my $call = {
                kind   => 'method_call',
                method => ($step->{name} // ''),
                recv   => { kind => 'ident', name => $recv_name },
                args   => $step->{args} // [],
            };
            _validate_expr($call, \%tmp, 1);
            my $step_t = _infer_expr_type($call, \%tmp);
            my $next_t = _type_without_error_union_member($step_t);
            $next_t = $step_t if !defined($next_t);
            compile_error("Semantic/F053-Type: chain step type is unresolved")
              if !defined($next_t) || $next_t eq '';
            $ok_t = $next_t;
        }

        _clear_symbol_facts($ctx, $name);
        for my $step (@{ $stmt->{steps} // [] }) {
            next if !defined($step) || ref($step) ne 'HASH';
            next if ($step->{name} // '') ne 'assert';
            my $pred = $step->{args}[0];
            next if !defined($pred) || ref($pred) ne 'HASH' || ($pred->{kind} // '') ne 'lambda1';
            my $param = $pred->{param} // '';
            my $body = $pred->{body};
            next if !defined($body) || ref($body) ne 'HASH' || ($body->{kind} // '') ne 'binop' || ($body->{op} // '') ne '==';
            my ($lhs, $rhs) = ($body->{left}, $body->{right});
            next if !defined($lhs) || !defined($rhs) || ref($lhs) ne 'HASH' || ref($rhs) ne 'HASH';
            next if ($lhs->{kind} // '') ne 'method_call' || ($lhs->{method} // '') ne 'size';
            next if !defined($lhs->{recv}) || ref($lhs->{recv}) ne 'HASH' || ($lhs->{recv}{kind} // '') ne 'ident' || ($lhs->{recv}{name} // '') ne $param;
            next if ($rhs->{kind} // '') ne 'num' || !defined($rhs->{value}) || $rhs->{value} !~ /^-?\d+$/;
            my $n = int($rhs->{value});
            $ctx->{facts}{"len_var:$name:$n"} = 1 if $n >= 0;
        }

        $ctx->{types}{$name} = $ok_t if $name ne '';
        $ctx->{mut}{$name} = 0 if $name ne '';
        my $nk = _numeric_kind_for_type($ok_t);
        if (defined($nk) && $nk ne '') {
            $ctx->{numeric_kinds}{$name} = $nk if $name ne '';
        } else {
            delete $ctx->{numeric_kinds}{$name} if $name ne '';
        }
        delete $ctx->{constraints}{$name} if $name ne '';
        return;
    }

    if ($kind eq 'const_or_catch' || $kind eq 'expr_or_catch') {
        my $expr = $stmt->{expr};
        _validate_expr($expr, $ctx, 1);
        compile_error("Semantic/F053-Fallibility: 'or catch' requires fallible expression")
          if !_expr_is_fallible($expr, $ctx);
        my %hctx = %$ctx;
        $hctx{types} = _clone_hash($ctx->{types});
        $hctx{mut} = _clone_hash($ctx->{mut});
        $hctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
        $hctx{facts} = _clone_hash($ctx->{facts});
        $hctx{constraints} = _clone_hash($ctx->{constraints});
        if (defined($stmt->{err_name}) && $stmt->{err_name} ne '') {
            $hctx{types}{ $stmt->{err_name} } = 'error';
            $hctx{mut}{ $stmt->{err_name} } = 0;
        }
        _validate_stmt_seq($stmt->{handler}, \%hctx) if defined $stmt->{handler};
        if ($kind eq 'const_or_catch') {
            my $name = $stmt->{name} // '';
            my $t = _infer_expr_type($expr, $ctx);
            my $ok = _type_without_error_union_member($t);
            $ok = $t if !defined($ok);
            $ctx->{types}{$name} = $ok if $name ne '' && defined($ok);
            $ctx->{mut}{$name} = 0 if $name ne '';
            my $nk = _numeric_kind_for_type($ok);
            if (defined($nk) && $nk ne '') {
                $ctx->{numeric_kinds}{$name} = $nk;
            } else {
                delete $ctx->{numeric_kinds}{$name} if $name ne '';
            }
            _clear_symbol_facts($ctx, $name);
            delete $ctx->{constraints}{$name} if $name ne '';
        }
        return;
    }

    if ($kind eq 'expr_stmt') {
        my $expr = $stmt->{expr};
        if (defined($expr) && ref($expr) eq 'HASH' && ($expr->{kind} // '') eq 'method_call') {
            my $m = $expr->{method} // '';
            if (method_has_tag($m, 'mutates_receiver')) {
                my $recv = $expr->{recv};
                if (defined($recv) && ref($recv) eq 'HASH' && ($recv->{kind} // '') eq 'ident') {
                    my $name = $recv->{name} // '';
                    compile_error("Semantic/F053-Type: Cannot mutate immutable variable '$name'")
                      if $name ne '' && !($ctx->{mut}{$name} // 0);
                }
                if (method_has_tag($m, 'requires_nested_size_push_proof')) {
                    my $need = _nested_required_size_for_receiver($recv, $ctx);
                    if (defined($need)) {
                        my $args = $expr->{args} // [];
                        my $pushed = (ref($args) eq 'ARRAY') ? $args->[0] : undef;
                        my $pushed_t = _infer_expr_type($pushed, $ctx);
                        my $label = _sequence_type_label($pushed_t);
                        $label = $pushed_t if !defined($label) && defined($pushed_t);
                        $label = 'value' if !defined($label) || $label eq '';
                        compile_error("Semantic/F053-Entailment: Method 'push(...)' requires pushed $label with proven size($need)")
                          if !_list_length_proved($pushed, $ctx, $need);
                    }
                }
            }
        }
        _validate_expr($stmt->{expr}, $ctx, 0);
        return;
    }

    if ($kind eq 'if' || $kind eq 'while') {
        if (!_fn_allows_error_propagation($ctx) && _expr_contains_try($stmt->{cond})) {
            compile_error("Semantic/F053-Type: Postfix '?' is only supported in const assignments and expression statements");
        }
        my $ct = _validate_expr($stmt->{cond}, $ctx, 0);
        compile_error("Semantic/F053-Type: condition must be boolean in '$kind'")
          if !_is_bool_type($ct);
        if ($kind eq 'while') {
            compile_error("Semantic/F053-Entailment: Conditional comparison in while condition depends only on immutable values")
              if !_expr_references_mutable($stmt->{cond}, $ctx);
            my %loop_ctx = %$ctx;
            $loop_ctx{types} = _clone_hash($ctx->{types});
            $loop_ctx{mut} = _clone_hash($ctx->{mut});
            $loop_ctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
            $loop_ctx{facts} = _clone_hash($ctx->{facts});
            $loop_ctx{constraints} = _clone_hash($ctx->{constraints});
            $loop_ctx{loop_depth} = ($ctx->{loop_depth} // 0) + 1;
            _validate_stmt_seq($stmt->{body}, \%loop_ctx);
            return;
        }
        my ($then_types, $else_types, $then_facts, $else_facts) = _derive_if_narrowing($stmt->{cond}, $ctx);
        my %then_ctx = %$ctx;
        $then_ctx{types} = _clone_hash($ctx->{types});
        $then_ctx{mut} = _clone_hash($ctx->{mut});
        $then_ctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
        $then_ctx{facts} = _clone_hash($ctx->{facts});
        $then_ctx{constraints} = _clone_hash($ctx->{constraints});
        $then_ctx{types}{$_} = $then_types->{$_} for keys %$then_types;
        $then_ctx{facts}{$_} = 1 for keys %$then_facts;

        my %else_ctx = %$ctx;
        $else_ctx{types} = _clone_hash($ctx->{types});
        $else_ctx{mut} = _clone_hash($ctx->{mut});
        $else_ctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
        $else_ctx{facts} = _clone_hash($ctx->{facts});
        $else_ctx{constraints} = _clone_hash($ctx->{constraints});
        $else_ctx{types}{$_} = $else_types->{$_} for keys %$else_types;
        $else_ctx{facts}{$_} = 1 for keys %$else_facts;

        _validate_stmt_seq($stmt->{then_body}, \%then_ctx);
        _validate_stmt_seq($stmt->{else_body} // [], \%else_ctx);
        my $then_returns = _stmt_seq_terminal_return($stmt->{then_body});
        my $else_returns = _stmt_seq_terminal_return($stmt->{else_body} // []);
        if ($then_returns && !$else_returns) {
            $ctx->{types} = $else_ctx{types};
            $ctx->{mut} = $else_ctx{mut};
            $ctx->{numeric_kinds} = $else_ctx{numeric_kinds};
            $ctx->{facts} = $else_ctx{facts};
            $ctx->{constraints} = $else_ctx{constraints};
            return;
        }
        if ($else_returns && !$then_returns) {
            $ctx->{types} = $then_ctx{types};
            $ctx->{mut} = $then_ctx{mut};
            $ctx->{numeric_kinds} = $then_ctx{numeric_kinds};
            $ctx->{facts} = $then_ctx{facts};
            $ctx->{constraints} = $then_ctx{constraints};
            return;
        }
        return;
    }

    if ($kind eq 'for_each' || $kind eq 'for_each_try' || $kind eq 'for_lines') {
        if ($kind eq 'for_lines') {
            my %loop_ctx = %$ctx;
            $loop_ctx{types} = _clone_hash($ctx->{types});
            $loop_ctx{mut} = _clone_hash($ctx->{mut});
            $loop_ctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
            $loop_ctx{facts} = _clone_hash($ctx->{facts});
            $loop_ctx{constraints} = _clone_hash($ctx->{constraints});
            $loop_ctx{loop_depth} = ($ctx->{loop_depth} // 0) + 1;
            my $var = $stmt->{var} // '';
            $loop_ctx{types}{$var} = 'string' if $var ne '';
            $loop_ctx{mut}{$var} = 0 if $var ne '';
            delete $loop_ctx{numeric_kinds}{$var} if $var ne '';
            _clear_symbol_facts(\%loop_ctx, $var);
            _validate_stmt_seq($stmt->{body}, \%loop_ctx);
            return;
        }
        my $iter_t = _validate_expr($stmt->{iterable}, $ctx, $kind eq 'for_each_try' ? 1 : 0);
        if ($kind eq 'for_each_try') {
            compile_error("Semantic/F053-Fallibility: for_each_try requires fallible iterable expression")
              if !_expr_is_fallible($stmt->{iterable}, $ctx);
            my $ok_iter_t = _type_without_error_union_member($iter_t);
            $iter_t = $ok_iter_t if defined($ok_iter_t) && $ok_iter_t ne '';
        }
        compile_error("Semantic/F053-Type: for_each iterable must be sequence")
          if !defined($iter_t) || !is_sequence_type($iter_t);
        my $elem = sequence_element_type($iter_t);
        if (defined($elem) && !is_matrix_member_type($elem)) {
            $elem = sequence_member_type($elem);
        }
        my %loop_ctx = %$ctx;
        $loop_ctx{types} = _clone_hash($ctx->{types});
        $loop_ctx{mut} = _clone_hash($ctx->{mut});
        $loop_ctx{numeric_kinds} = _clone_hash($ctx->{numeric_kinds});
        $loop_ctx{facts} = _clone_hash($ctx->{facts});
        $loop_ctx{constraints} = _clone_hash($ctx->{constraints});
        $loop_ctx{loop_depth} = ($ctx->{loop_depth} // 0) + 1;
        my $var = $stmt->{var} // '';
        $loop_ctx{types}{$var} = $elem if $var ne '';
        $loop_ctx{mut}{$var} = 0 if $var ne '';
        if ($var ne '') {
            my $nk = _numeric_kind_for_type($elem);
            if (defined($nk) && $nk ne '') {
                $loop_ctx{numeric_kinds}{$var} = $nk;
            } else {
                delete $loop_ctx{numeric_kinds}{$var};
            }
            _clear_symbol_facts(\%loop_ctx, $var);
            my $idx_fact = _for_seq_index_bound_fact($stmt->{iterable}, $var, $ctx);
            $loop_ctx{facts}{$idx_fact} = 1 if defined($idx_fact) && $idx_fact ne '';
        }
        _validate_stmt_seq($stmt->{body}, \%loop_ctx);
        return;
    }

    if ($kind eq 'return') {
        my $expect = $ctx->{fn_return};
        if (!defined($expect) || $expect eq '') {
            compile_error("Semantic/F053-Type: return with value is not allowed in void function")
              if defined($stmt->{expr});
            return;
        }
        compile_error("Semantic/F053-Type: missing return value for function return type '$expect'")
          if !defined($stmt->{expr});
        if (!_fn_allows_error_propagation($ctx) && _expr_contains_try($stmt->{expr})) {
            compile_error("Semantic/F053-Type: Postfix '?' is only supported in const assignments and expression statements");
        }
        my $ret_t = _validate_expr($stmt->{expr}, $ctx, 0);
        if (!$ret_t || !_types_assignable($ret_t, $expect)) {
            my $expect_non_error = _single_non_error_member_from_error_union($expect);
            if (defined($expect_non_error) && is_sequence_type($ret_t) && is_sequence_type($expect_non_error)) {
                my $actual_label = _sequence_type_label($ret_t) // $ret_t;
                my $expect_label = _sequence_type_label($expect_non_error) // $expect_non_error;
                compile_error("Semantic/F053-Type: cannot convert $actual_label to $expect_label");
            }
            compile_error("Semantic/F053-Type: return type mismatch: cannot return '$ret_t' from function expecting '$expect'");
        }
        return;
    }

    if ($kind eq 'break') {
        compile_error("Semantic/F053-Control: break is only valid inside a loop")
          if ($ctx->{loop_depth} // 0) <= 0;
        return;
    }
    if ($kind eq 'continue') {
        compile_error("Semantic/F053-Control: continue is only valid inside a loop")
          if ($ctx->{loop_depth} // 0) <= 0;
        return;
    }
    if ($kind eq 'rewind') {
        compile_error("Semantic/F053-Control: rewind is only valid inside a loop")
          if ($ctx->{loop_depth} // 0) <= 0;
        return;
    }
}

sub _scheduled_statements {
    my ($fn) = @_;
    my %by_id = map { $_->{id} => $_ } @{ $fn->{regions} // [] };
    my @stmts;
    for my $rid (@{ $fn->{region_schedule} // [] }) {
        my $region = $by_id{$rid};
        next if !defined($region);
        my $step = $region->{steps}[0];
        next if !defined($step);
        my $stmt = step_payload_to_stmt($step->{payload});
        push @stmts, $stmt if defined($stmt);
    }
    return \@stmts;
}

sub enforce_hir_semantics {
    my ($hir) = @_;
    my $sigs = _function_sigs($hir);
    for my $fn (@{ $hir->{functions} // [] }) {
        my ($types, $mut, $numeric_kinds) = _env_from_params($fn);
        my %constraints;
        my %facts;
        for my $p (@{ $fn->{params} // [] }) {
            next if !defined($p->{name}) || $p->{name} eq '';
            $constraints{$p->{name}} = $p->{constraints};
            my ($min, $max) = _constraints_integral_range($p->{constraints});
            if (defined($min) && defined($max)) {
                $facts{"range_var:$p->{name}:$min:$max"} = 1;
            }
            my $size = constraint_size_exact($p->{constraints});
            if (defined($size) && $size =~ /^-?\d+$/) {
                my $n = int($size);
                $facts{"len_var:$p->{name}:$n"} = 1 if $n >= 0;
            }
        }
        my %ctx = (
            fn_name => $fn->{name},
            fn_return => $fn->{return_type},
            sigs      => $sigs,
            types     => $types,
            mut       => $mut,
            numeric_kinds => $numeric_kinds,
            constraints => \%constraints,
            facts     => \%facts,
            loop_depth => 0,
        );
        $ctx{fn_allows_error_propagation} = _fn_allows_error_propagation(\%ctx) ? 1 : 0;
        _validate_stmt_seq(_scheduled_statements($fn), \%ctx);
        $fn->{semantic_artifacts} = {
            schema              => 'hir-semantic-artifacts.v1',
            final_types         => _clone_hash($ctx{types}),
            final_numeric_kinds => _clone_hash($ctx{numeric_kinds}),
            final_constraints   => _clone_hash($ctx{constraints}),
            proven_facts        => [ sort keys %{ $ctx{facts} // {} } ],
        };
    }
    return $hir;
}

1;
