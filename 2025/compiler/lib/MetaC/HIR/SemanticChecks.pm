package MetaC::HIR::SemanticChecks;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);
use MetaC::HIR::SemanticChecksExpr qw(
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
use MetaC::TypeSpec qw(
    is_sequence_type
    sequence_element_type
);

our @EXPORT_OK = qw(enforce_hir_semantics);

sub _derive_if_narrowing {
    my ($cond, $ctx) = @_;
    my (%then_types, %else_types, %then_facts, %else_facts);
    return (\%then_types, \%else_types, \%then_facts, \%else_facts)
      if !defined($cond) || ref($cond) ne 'HASH' || ($cond->{kind} // '') ne 'binop';

    my $op = $cond->{op} // '';
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
        if (defined($ident) && $ident ne '' && exists $ctx->{types}{$ident} && !($ctx->{mut}{$ident} // 0)) {
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
            if (($method eq 'size' || $method eq 'count')
                && ref($args) eq 'ARRAY' && !@$args
                && defined($recv) && ref($recv) eq 'HASH' && ($recv->{kind} // '') eq 'ident')
            {
                my $name = $recv->{name} // '';
                if ($name ne '') {
                    my $fact = "len_var:$name:" . int($num_expr->{value});
                    if ($op eq '==') {
                        $then_facts{$fact} = 1;
                    } else {
                        $else_facts{$fact} = 1;
                    }
                }
            }
        }
    }

    return (\%then_types, \%else_types, \%then_facts, \%else_facts);
}

sub _list_length_proved {
    my ($expr, $ctx, $need) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    if (($expr->{kind} // '') eq 'list_literal') {
        return scalar(@{ $expr->{items} // [] }) == $need ? 1 : 0;
    }
    return 0 if ($expr->{kind} // '') ne 'ident';
    my $name = $expr->{name} // '';
    return 0 if $name eq '';
    my $facts = $ctx->{facts} // {};
    return $facts->{"len_var:$name:$need"} ? 1 : 0;
}

sub _validate_stmt_seq {
    my ($stmts, $ctx) = @_;
    for my $stmt (@{ $stmts // [] }) {
        _validate_stmt($stmt, $ctx);
    }
}

sub _validate_stmt {
    my ($stmt, $ctx) = @_;
    return if !defined($stmt) || ref($stmt) ne 'HASH';
    my $kind = $stmt->{kind} // '';

    if ($kind eq 'const' || $kind eq 'let' || $kind eq 'const_typed') {
        my $name = $stmt->{name} // '';
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        my $decl_t = $stmt->{type};
        if (defined($decl_t) && $decl_t ne '') {
            compile_error("Semantic/F053-Type: cannot assign '$expr_t' to declared type '$decl_t' for '$name'")
              if !$expr_t || !_types_assignable($expr_t, $decl_t);
        } else {
            $decl_t = $expr_t;
        }
        $ctx->{types}{$name} = $decl_t if $name ne '' && defined $decl_t;
        $ctx->{mut}{$name} = ($kind eq 'let') ? 1 : 0 if $name ne '';
        return;
    }

    if ($kind eq 'typed_assign' || $kind eq 'assign') {
        my $name = $stmt->{name} // '';
        compile_error("Semantic/F053-Type: assignment to unknown variable '$name'")
          if !exists $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: cannot assign to immutable variable '$name'")
          if !($ctx->{mut}{$name} // 0);
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        my $target_t = (defined($stmt->{type}) && $stmt->{type} ne '') ? $stmt->{type} : $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: cannot assign '$expr_t' to '$name' of type '$target_t'")
          if !$expr_t || !_types_assignable($expr_t, $target_t);
        $ctx->{types}{$name} = $target_t if defined $target_t;
        return;
    }

    if ($kind eq 'assign_op' || $kind eq 'incdec') {
        my $name = $stmt->{name} // '';
        compile_error("Semantic/F053-Type: assignment to unknown variable '$name'")
          if !exists $ctx->{types}{$name};
        compile_error("Semantic/F053-Type: cannot assign to immutable variable '$name'")
          if !($ctx->{mut}{$name} // 0);
        compile_error("Semantic/F053-Type: '$name' must be number for '$kind'")
          if !_is_number_type($ctx->{types}{$name});
        if ($kind eq 'assign_op') {
            my $et = _validate_expr($stmt->{expr}, $ctx, 0);
            compile_error("Semantic/F053-Type: '+=' requires number rhs")
              if !_is_number_type($et);
        }
        return;
    }

    if ($kind eq 'destructure_list') {
        my $expr_t = _validate_expr($stmt->{expr}, $ctx, 0);
        compile_error("Semantic/F053-Type: list destructuring requires sequence expression")
          if !defined($expr_t) || !is_sequence_type($expr_t);
        my $need = scalar(@{ $stmt->{vars} // [] });
        compile_error("Semantic/F053-Entailment: list destructuring requires compile-time length proof ($need)")
          if !_list_length_proved($stmt->{expr}, $ctx, $need);
        my $elem_t = sequence_element_type($expr_t);
        for my $v (@{ $stmt->{vars} // [] }) {
            next if !defined($v) || $v eq '';
            $ctx->{types}{$v} = $elem_t;
            $ctx->{mut}{$v} = 0;
        }
        return;
    }

    if ($kind eq 'destructure_split_or' || $kind eq 'destructure_match') {
        _validate_expr($stmt->{source_expr}, $ctx, 1) if defined $stmt->{source_expr};
        _validate_expr($stmt->{delim_expr}, $ctx, 1) if defined $stmt->{delim_expr};
        my %hctx = %$ctx;
        $hctx{types} = _clone_hash($ctx->{types});
        $hctx{mut} = _clone_hash($ctx->{mut});
        if (defined($stmt->{err_name}) && $stmt->{err_name} ne '') {
            $hctx{types}{ $stmt->{err_name} } = 'error';
            $hctx{mut}{ $stmt->{err_name} } = 0;
        }
        _validate_stmt_seq($stmt->{handler}, \%hctx) if defined $stmt->{handler};
        for my $v (@{ $stmt->{vars} // [] }) {
            next if !defined($v) || $v eq '';
            $ctx->{types}{$v} = 'string';
            $ctx->{mut}{$v} = 0;
        }
        return;
    }

    if ($kind eq 'const_try_expr' || $kind eq 'const_try_tail_expr' || $kind eq 'expr_stmt_try') {
        my $expr = defined($stmt->{expr}) ? $stmt->{expr} : $stmt->{first};
        _validate_expr($expr, $ctx, 1);
        compile_error("Semantic/F053-Fallibility: try-expression requires fallible expression")
          if !_expr_is_fallible($expr, $ctx);
        if ($kind ne 'expr_stmt_try') {
            my $name = $stmt->{name} // '';
            my $inner_t = _infer_expr_type($expr, $ctx);
            my $without_error = _type_without_error_union_member($inner_t);
            compile_error("Semantic/F053-Type: try-assignment requires an error-union expression")
              if !defined($without_error);
            $ctx->{types}{$name} = $without_error if $name ne '';
            $ctx->{mut}{$name} = 0 if $name ne '';
        }
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
        }
        return;
    }

    if ($kind eq 'expr_stmt') {
        _validate_expr($stmt->{expr}, $ctx, 0);
        return;
    }

    if ($kind eq 'if' || $kind eq 'while') {
        my $ct = _validate_expr($stmt->{cond}, $ctx, 0);
        compile_error("Semantic/F053-Type: condition must be boolean in '$kind'")
          if !_is_bool_type($ct);
        if ($kind eq 'while') {
            my %loop_ctx = %$ctx;
            $loop_ctx{types} = _clone_hash($ctx->{types});
            $loop_ctx{mut} = _clone_hash($ctx->{mut});
            $loop_ctx{facts} = _clone_hash($ctx->{facts});
            _validate_stmt_seq($stmt->{body}, \%loop_ctx);
            return;
        }
        my ($then_types, $else_types, $then_facts, $else_facts) = _derive_if_narrowing($stmt->{cond}, $ctx);
        my %then_ctx = %$ctx;
        $then_ctx{types} = _clone_hash($ctx->{types});
        $then_ctx{mut} = _clone_hash($ctx->{mut});
        $then_ctx{facts} = _clone_hash($ctx->{facts});
        $then_ctx{types}{$_} = $then_types->{$_} for keys %$then_types;
        $then_ctx{facts}{$_} = 1 for keys %$then_facts;

        my %else_ctx = %$ctx;
        $else_ctx{types} = _clone_hash($ctx->{types});
        $else_ctx{mut} = _clone_hash($ctx->{mut});
        $else_ctx{facts} = _clone_hash($ctx->{facts});
        $else_ctx{types}{$_} = $else_types->{$_} for keys %$else_types;
        $else_ctx{facts}{$_} = 1 for keys %$else_facts;

        _validate_stmt_seq($stmt->{then_body}, \%then_ctx);
        _validate_stmt_seq($stmt->{else_body} // [], \%else_ctx);
        return;
    }

    if ($kind eq 'for_each' || $kind eq 'for_each_try' || $kind eq 'for_lines') {
        if ($kind eq 'for_lines') {
            my %loop_ctx = %$ctx;
            $loop_ctx{types} = _clone_hash($ctx->{types});
            $loop_ctx{mut} = _clone_hash($ctx->{mut});
            $loop_ctx{facts} = _clone_hash($ctx->{facts});
            my $var = $stmt->{var} // '';
            $loop_ctx{types}{$var} = 'string' if $var ne '';
            $loop_ctx{mut}{$var} = 0 if $var ne '';
            _validate_stmt_seq($stmt->{body}, \%loop_ctx);
            return;
        }
        my $iter_t = _validate_expr($stmt->{iterable}, $ctx, $kind eq 'for_each_try' ? 1 : 0);
        if ($kind eq 'for_each_try') {
            compile_error("Semantic/F053-Fallibility: for_each_try requires fallible iterable expression")
              if !_expr_is_fallible($stmt->{iterable}, $ctx);
        }
        compile_error("Semantic/F053-Type: for_each iterable must be sequence")
          if !defined($iter_t) || !is_sequence_type($iter_t);
        my $elem = sequence_element_type($iter_t);
        my %loop_ctx = %$ctx;
        $loop_ctx{types} = _clone_hash($ctx->{types});
        $loop_ctx{mut} = _clone_hash($ctx->{mut});
        $loop_ctx{facts} = _clone_hash($ctx->{facts});
        my $var = $stmt->{var} // '';
        $loop_ctx{types}{$var} = $elem if $var ne '';
        $loop_ctx{mut}{$var} = 0 if $var ne '';
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
        my $ret_t = _validate_expr($stmt->{expr}, $ctx, 0);
        compile_error("Semantic/F053-Type: cannot return '$ret_t' from function expecting '$expect'")
          if !$ret_t || !_types_assignable($ret_t, $expect);
        return;
    }

    return if $kind eq 'break' || $kind eq 'continue' || $kind eq 'rewind';
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
        my ($types, $mut) = _env_from_params($fn);
        my %ctx = (
            fn_return => $fn->{return_type},
            sigs      => $sigs,
            types     => $types,
            mut       => $mut,
            facts     => {},
        );
        _validate_stmt_seq(_scheduled_statements($fn), \%ctx);
    }
    return $hir;
}

1;
