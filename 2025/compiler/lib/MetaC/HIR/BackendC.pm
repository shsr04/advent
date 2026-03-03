package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Backend::RuntimeHelpers qw(emit_runtime_helpers);
use MetaC::Backend::TemplateEmitter qw(template_expr_to_c);
use MetaC::HIR::OpRegistry qw(
    builtin_is_known
    builtin_op_id
    method_is_known
    method_op_id
    method_has_length_semantics
    method_traceability_hint
    method_result_type
);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);
use MetaC::Support qw(constraint_size_exact);
use MetaC::HIR::TypeRegistry qw(
    scalar_c_type
    scalar_is_boolean
    scalar_is_string
);
use MetaC::TypeSpec qw(
    is_sequence_member_type
    sequence_member_meta
    matrix_type_meta
);

our @EXPORT_OK = qw(codegen_from_vnf_hir);

sub _helper_mark {
    my ($ctx, $name) = @_;
    return if !defined($ctx) || ref($ctx) ne 'HASH' || !defined($name) || $name eq '';
    $ctx->{helpers}{$name} = 1;
}

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

sub _is_array_type {
    my ($t) = @_;
    return defined($t) && $t =~ /^array</ ? 1 : 0;
}

sub _is_nested_array_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^array<e=array</;
    return 1 if $t =~ /^array<e=61727261793C/;    # hex("array<")
    return 0;
}

sub _is_string_array_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^array<e=737472696E67/;
    return 1 if $t =~ /^array<e=string/;
    return 0;
}

sub _is_string_matrix_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix<e=737472696E67/;
    return 1 if $t =~ /^matrix<e=string/;
    return 0;
}

sub _is_string_matrix_member_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix_member<e=737472696E67/;
    return 1 if $t =~ /^matrix_member<e=string/;
    return 0;
}

sub _is_string_matrix_member_list_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix_member_list<e=737472696E67/;
    return 1 if $t =~ /^matrix_member_list<e=string/;
    return 0;
}

sub _is_matrix_type {
    my ($t) = @_;
    return defined($t) && $t =~ /^matrix</ ? 1 : 0;
}

sub _sequence_member_elem_type {
    my ($t) = @_;
    return undef if !defined($t) || $t eq '' || !is_sequence_member_type($t);
    my $meta = sequence_member_meta($t);
    return undef if !defined($meta) || ref($meta) ne 'HASH';
    return $meta->{elem};
}

sub _matrix_meta_var_name {
    my ($name) = @_;
    return '' if !defined($name) || $name eq '';
    return "__metac_matrix_meta_$name";
}

sub _matrix_meta_for_type {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    my $meta = matrix_type_meta($type);
    return undef if !defined($meta) || ref($meta) ne 'HASH';
    return $meta;
}

sub _constraint_exact_size {
    my ($constraints) = @_;
    return undef if !defined($constraints) || ref($constraints) ne 'HASH';
    my $n = constraint_size_exact($constraints);
    return undef if !defined($n) || $n !~ /^-?\d+$/;
    return int($n);
}

sub _strip_error_union {
    my ($t) = @_;
    return $t if !defined($t) || $t !~ /\|/;
    my @parts = map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } split /\|/, $t;
    my @non_error = grep { $_ ne 'error' } @parts;
    return $non_error[0] // $parts[0];
}

sub _result_type_to_c {
    my ($t) = @_;
    return undef if !defined $t || $t eq '';
    $t = _strip_error_union($t);
    my $seq_elem = _sequence_member_elem_type($t);
    $t = $seq_elem if defined($seq_elem) && $seq_elem ne '';
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_str' if _is_string_matrix_type($t);
    return 'struct metac_list_str' if _is_string_matrix_member_list_type($t);
    return 'const char *' if _is_string_matrix_member_type($t);
    return 'int64_t' if defined($t) && $t =~ /^matrix_member</;
    return 'struct metac_list_i64' if $t =~ /array</;
    return 'struct metac_list_i64' if defined($t) && $t =~ /^matrix_member_list</;
    return 'struct metac_list_i64' if $t =~ /matrix</;
    return 'const char *' if $t =~ /\bstring\b/ || $t =~ /^stringwith/;
    return 'int' if $t =~ /\bbool(?:ean)?\b/;
    return 'double' if $t =~ /\bfloat\b/;
    return 'int64_t' if $t =~ /\b(?:number|int)\b/;
    return undef;
}

sub _type_to_c {
    my ($t, $fallback) = @_;
    return $fallback if !defined $t || $t eq '';
    $t = _strip_error_union($t);
    my $seq_elem = _sequence_member_elem_type($t);
    $t = $seq_elem if defined($seq_elem) && $seq_elem ne '';
    return 'const char *' if $t =~ /^stringwith/;
    my $scalar_c = scalar_c_type($t);
    return $scalar_c if defined($scalar_c);
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_str' if _is_string_matrix_type($t);
    return 'struct metac_list_str' if _is_string_matrix_member_list_type($t);
    return 'const char *' if _is_string_matrix_member_type($t);
    return 'struct metac_list_i64' if _is_array_type($t);
    return 'struct metac_list_i64' if defined($t) && $t =~ /^matrix_member_list</;
    return 'int64_t' if defined($t) && $t =~ /^matrix_member</;
    return 'struct metac_list_i64' if _is_matrix_type($t);
    return $fallback;
}

sub _expr_c_type_hint {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return 'int64_t' if $k eq 'num';
    return 'int' if $k eq 'bool' || $k eq 'null';
    return 'const char *' if $k eq 'str';
    if ($k eq 'list_literal') {
        my $items = $expr->{items} // [];
        return 'struct metac_list_str' if @$items && !grep { !defined($_) || ref($_) ne 'HASH' || (($_->{kind} // '') ne 'str') } @$items;
        return 'struct metac_list_i64';
    }
    if ($k eq 'ident') {
        return $ctx->{var_types}{ $expr->{name} // '' };
    }
    if ($k eq 'unary') {
        return 'int64_t';
    }
    if ($k eq 'binop') {
        my $op = $expr->{op} // '';
        return 'int' if $op eq '&&' || $op eq '||' || $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=';
        return 'int64_t';
    }
    if ($k eq 'index') {
        my $recv_hint = _expr_c_type_hint($expr->{recv}, $ctx);
        return 'const char *' if defined($recv_hint) && $recv_hint eq 'struct metac_list_str';
        return 'struct metac_list_i64' if defined($recv_hint) && $recv_hint eq 'struct metac_list_list_i64';
        return 'int64_t';
    }
    if ($k eq 'call' || $k eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        my $canonical = $expr->{canonical_call};
        my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
          : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
        my $rt = _result_type_to_c($meta->{result_type});
        return $rt if defined $rt;
        if ($k eq 'method_call') {
            my $m = $expr->{method} // '';
            my $recv_type_hint = $meta->{receiver_type_hint};
            my $hinted_result = method_result_type($m, $recv_type_hint);
            my $hinted_c = _result_type_to_c($hinted_result);
            return $hinted_c if defined($hinted_c);
            my $recv_c = _expr_c_type_hint($expr->{recv}, $ctx);
            return $recv_c if ($m eq 'filter' || $m eq 'slice' || $m eq 'assert' || $m eq 'sort' || $m eq 'sortBy')
              && defined($recv_c);
            return 'int' if $m eq 'all' || $m eq 'any' || $m eq 'isBlank';
            return 'int64_t' if $m eq 'max' || $m eq 'last' || $m eq 'count' || method_has_length_semantics($m);
            return 'struct metac_list_i64' if $m eq 'scan' || $m eq 'map' || $m eq 'index';
            if ($m eq 'neighbours') {
                return 'struct metac_list_str' if defined($recv_c) && $recv_c eq 'const char *';
                return 'struct metac_list_i64';
            }
            if ($m eq 'members') {
                return 'struct metac_list_str' if defined($recv_c) && $recv_c eq 'struct metac_list_str';
                return 'struct metac_list_i64';
            }
            my $traceability = method_traceability_hint($m) // '';
            return 'int64_t'
              if method_has_length_semantics($m)
              || $traceability eq 'requires_source_index_metadata';
        }
        return undef;
    }
    return undef;
}


require MetaC::Backend::BackendCExprPart;
require MetaC::Backend::BackendCStmtPart;
require MetaC::Backend::BackendCFunctionPart;

1;
