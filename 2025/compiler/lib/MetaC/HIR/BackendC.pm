package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);

our @EXPORT_OK = qw(codegen_from_vnf_hir);

sub _c_escape {
    my ($s) = @_;
    $s = '' if !defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

sub _type_to_c {
    my ($t, $fallback) = @_;
    return $fallback if !defined $t || $t eq '';
    return 'int64_t' if $t eq 'number' || $t eq 'int';
    return 'double' if $t eq 'float';
    return 'int' if $t eq 'bool' || $t eq 'boolean';
    return 'const char *' if $t eq 'string';
    return 'int' if $t eq 'null';
    return 'struct metac_error' if $t eq 'error';
    return $fallback;
}

sub _expr_c_type_hint {
    my ($expr) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return 'int64_t' if $k eq 'num';
    return 'int' if $k eq 'bool' || $k eq 'null';
    return 'const char *' if $k eq 'str';
    return undef;
}

sub _default_return_for_c_type {
    my ($c_ty) = @_;
    return '0' if !defined $c_ty;
    return '0' if $c_ty eq 'int' || $c_ty eq 'int64_t' || $c_ty eq 'double';
    return 'NULL' if $c_ty eq 'const char *';
    return '(struct metac_error){0}' if $c_ty eq 'struct metac_error';
    return '0';
}

sub _expr_to_c {
    my ($expr) = @_;
    return '0' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return $expr->{value} // '0' if $k eq 'num';
    return ($expr->{value} ? '1' : '0') if $k eq 'bool';
    if ($k eq 'str') {
        my $v = $expr->{value};
        return $v if defined($v) && $v =~ /^".*"$/s;
        return '"' . _c_escape($v) . '"';
    }
    return '0' if $k eq 'null';
    return $expr->{name} // '/* missing-ident */ 0' if $k eq 'ident';
    if ($k eq 'unary') {
        my $op = defined($expr->{op}) ? $expr->{op} : '-';
        return "($op" . _expr_to_c($expr->{expr}) . ")";
    }
    if ($k eq 'binop') {
        my $op = defined($expr->{op}) ? $expr->{op} : '+';
        $op = '/' if $op eq '~/';
        return '(' . _expr_to_c($expr->{left}) . " $op " . _expr_to_c($expr->{right}) . ')';
    }
    if ($k eq 'try') {
        return _expr_to_c($expr->{expr});
    }
    return "/* Backend/F054 missing expr emitter for kind '$k' */ 0";
}

sub _emit_stmt {
    my ($stmt, $out, $indent, $seen_decl, $suppress_step_return) = @_;
    my $sp = ' ' x $indent;
    my $k = $stmt->{kind} // '';
    if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;
        my $inferred = _expr_c_type_hint($stmt->{expr});
        my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
        my $rhs = _expr_to_c($stmt->{expr});
        push @$out, $decl
          ? "${sp}$name = $rhs;"
          : "${sp}$c_ty $name = $rhs;";
        return;
    }
    if ($k eq 'assign' || $k eq 'typed_assign') {
        my $name = $stmt->{name} // '__missing_name';
        push @$out, "${sp}$name = " . _expr_to_c($stmt->{expr}) . ';';
        return;
    }
    if ($k eq 'assign_op') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '+=';
        push @$out, "${sp}$name $op " . _expr_to_c($stmt->{expr}) . ';';
        return;
    }
    if ($k eq 'incdec') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '++';
        push @$out, "${sp}$name$op;";
        return;
    }
    if ($k eq 'expr_stmt' || $k eq 'expr_stmt_try') {
        push @$out, $sp . _expr_to_c($stmt->{expr}) . ';';
        return;
    }
    if ($k eq 'return') {
        return if $suppress_step_return;
        my $rv = $stmt->{expr};
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv) . ';') : ($sp . 'return 0;');
        return;
    }
    return if $k eq 'if' || $k eq 'while' || $k eq 'for_each' || $k eq 'for_each_try' || $k eq 'for_lines';
    if ($k eq 'break' || $k eq 'continue') {
        push @$out, "${sp}$k;";
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing stmt emitter for kind '$k' */};
}

sub _emit_exit {
    my ($exit, $out, $indent, $default_return) = @_;
    my $sp = ' ' x $indent;
    my $k = $exit->{kind} // '';
    if ($k eq 'Goto') {
        my $to = $exit->{target_region} // '__missing_region';
        push @$out, "${sp}goto region_$to;";
        return;
    }
    if ($k eq 'IfExit') {
        my $cond = _expr_to_c($exit->{cond_value});
        my $t = $exit->{then_region} // '__missing_region';
        my $e = $exit->{else_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$t;";
        push @$out, "${sp}goto region_$e;";
        return;
    }
    if ($k eq 'WhileExit') {
        my $cond = _expr_to_c($exit->{cond_value});
        my $b = $exit->{body_region} // '__missing_region';
        my $n = $exit->{end_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$b;";
        push @$out, "${sp}goto region_$n;";
        return;
    }
    if ($k eq 'ForInExit') {
        my $b = $exit->{body_region} // '__missing_region';
        my $n = $exit->{end_region} // '__missing_region';
        push @$out, "${sp}/* Backend/F054 placeholder ForInExit */";
        push @$out, "${sp}goto region_$b;";
        push @$out, "${sp}goto region_$n;";
        return;
    }
    if ($k eq 'TryExit') {
        my $ok = $exit->{ok_region} // '__missing_region';
        push @$out, "${sp}goto region_$ok;";
        return;
    }
    if ($k eq 'Return') {
        my $rv = $exit->{value};
        push @$out, defined($rv)
          ? ($sp . 'return ' . _expr_to_c($rv) . ';')
          : ($sp . "return $default_return;");
        return;
    }
    if ($k eq 'PropagateError') {
        push @$out, "${sp}return 2;";
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing exit emitter for kind '$k' */};
}

sub _emit_function {
    my ($fn) = @_;
    my @out;
    my $name = $fn->{name} // '__missing_fn_name';
    my $ret_type = $name eq 'main' ? 'int' : _type_to_c($fn->{return_type}, 'int64_t');
    my $default_return = _default_return_for_c_type($ret_type);
    my @params;
    for my $p (@{ $fn->{params} // [] }) {
        my $pn = $p->{name} // 'p';
        my $pt = _type_to_c($p->{type}, 'int64_t');
        push @params, "$pt $pn";
    }
    my $param_sig = @params ? join(', ', @params) : 'void';
    push @out, "$ret_type $name($param_sig) {";
    my %seen_decl;
    my $regions = $fn->{regions} // [];
    my $schedule = $fn->{region_schedule};
    my @ordered_regions;
    if (defined($schedule) && ref($schedule) eq 'ARRAY' && @$schedule) {
        my %by_id = map { ($_->{id} // '') => $_ } @$regions;
        my %seen;
        @ordered_regions = map { $seen{$_} = 1; $by_id{$_} } grep { exists $by_id{$_} } @$schedule;
        push @ordered_regions, grep { !$seen{ $_->{id} // '' } } @$regions;
    } else {
        @ordered_regions = @$regions;
    }
    for my $region (@ordered_regions) {
        my $rid = $region->{id} // '__missing_region';
        my $exit_kind = $region->{exit}{kind} // '';
        push @out, "region_$rid: ;";
        for my $step (@{ $region->{steps} // [] }) {
            my $stmt = step_payload_to_stmt($step->{payload});
            if (!defined $stmt) {
                push @out, "  /* Backend/F054 missing payload decode for step */";
                next;
            }
            _emit_stmt($stmt, \@out, 2, \%seen_decl, ($exit_kind eq 'Return' ? 1 : 0));
        }
        _emit_exit($region->{exit} // {}, \@out, 2, $default_return);
    }
    push @out, "  return $default_return;";
    push @out, "}";
    return join("\n", @out);
}

sub codegen_from_vnf_hir {
    my ($hir) = @_;
    my @out;
    push @out, '#include <stdint.h>';
    push @out, '#include <stdio.h>';
    push @out, '';
    push @out, 'struct metac_error { const char *message; };';
    push @out, '';
    for my $fn (@{ $hir->{functions} // [] }) {
        push @out, _emit_function($fn // {});
        push @out, '';
    }
    return join("\n", @out);
}

1;
