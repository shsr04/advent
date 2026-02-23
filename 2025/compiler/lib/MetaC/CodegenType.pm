package MetaC::CodegenType;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::TypeSpec qw(
    is_matrix_type
    matrix_type_meta
    is_matrix_member_type
    matrix_member_meta
    is_union_type
    union_member_types
    type_is_number_or_null
);

our @EXPORT_OK = qw(
    param_c_type
    render_c_params
    is_number_like_type
    number_like_to_c_expr
    type_matches_expected
    number_or_null_to_c_expr
);

sub param_c_type {
    my ($param) = @_;
    return 'int64_t' if $param->{type} eq 'number';
    return 'NullableNumber' if $param->{type} eq 'number_or_null';
    return 'int' if $param->{type} eq 'bool';
    return 'const char *' if $param->{type} eq 'string';
    if (is_matrix_type($param->{type})) {
        my $meta = matrix_type_meta($param->{type});
        return 'MatrixNumber' if $meta->{elem} eq 'number';
        return 'MatrixString' if $meta->{elem} eq 'string';
        compile_error("Unsupported matrix parameter element type '$meta->{elem}'");
    }
    compile_error("Unsupported parameter type: $param->{type}");
}

sub render_c_params {
    my ($params) = @_;
    return 'void' if !@$params;
    return join(', ', map { param_c_type($_) . ' ' . $_->{c_in_name} } @$params);
}

sub is_number_like_type {
    my ($type) = @_;
    return 1 if $type eq 'number';
    return 1 if $type eq 'indexed_number';
    if (is_matrix_member_type($type)) {
        my $meta = matrix_member_meta($type);
        return 1 if $meta->{elem} eq 'number';
    }
    return 0;
}

sub number_like_to_c_expr {
    my ($code, $type, $where) = @_;
    return $code if $type eq 'number';
    return "(($code).value)" if $type eq 'indexed_number';
    if (is_matrix_member_type($type)) {
        my $meta = matrix_member_meta($type);
        return "(($code).value)" if $meta->{elem} eq 'number';
    }
    compile_error("$where requires number operand, got $type");
}

sub type_matches_expected {
    my ($expected, $actual) = @_;
    if (is_union_type($expected)) {
        my $members = union_member_types($expected);
        for my $member (@$members) {
            return 1 if type_matches_expected($member, $actual);
        }
        return 0;
    }
    return 1 if $expected eq $actual;
    return 1 if $expected eq 'number' && $actual eq 'indexed_number';
    if ($expected eq 'number' && is_matrix_member_type($actual)) {
        my $meta = matrix_member_meta($actual);
        return 1 if $meta->{elem} eq 'number';
    }
    return 1 if type_is_number_or_null($expected) && ($actual eq 'number' || $actual eq 'indexed_number' || $actual eq 'null');
    return 1 if ($expected eq 'number_list' || $expected eq 'string_list') && $actual eq 'empty_list';
    return 1 if is_matrix_type($expected) && $actual eq 'empty_list';
    return 1 if is_matrix_type($expected) && is_matrix_type($actual) && $expected eq $actual;
    return 0;
}

sub number_or_null_to_c_expr {
    my ($code, $type, $where) = @_;
    return $code if type_is_number_or_null($type);
    if (is_number_like_type($type)) {
        my $num = number_like_to_c_expr($code, $type, $where);
        return "metac_some_number($num)";
    }
    return "metac_null_number()" if $type eq 'null';
    compile_error("$where requires number|null operand, got $type");
}

1;
