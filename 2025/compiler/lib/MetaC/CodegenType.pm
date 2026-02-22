package MetaC::CodegenType;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);

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
    return 0;
}

sub number_like_to_c_expr {
    my ($code, $type, $where) = @_;
    return $code if $type eq 'number';
    return "(($code).value)" if $type eq 'indexed_number';
    compile_error("$where requires number operand, got $type");
}

sub type_matches_expected {
    my ($expected, $actual) = @_;
    return 1 if $expected eq $actual;
    return 1 if $expected eq 'number' && $actual eq 'indexed_number';
    return 1 if $expected eq 'number_or_null' && ($actual eq 'number' || $actual eq 'indexed_number' || $actual eq 'null');
    return 1 if ($expected eq 'number_list' || $expected eq 'string_list') && $actual eq 'empty_list';
    return 0;
}

sub number_or_null_to_c_expr {
    my ($code, $type, $where) = @_;
    return $code if $type eq 'number_or_null';
    if (is_number_like_type($type)) {
        my $num = number_like_to_c_expr($code, $type, $where);
        return "metac_some_number($num)";
    }
    return "metac_null_number()" if $type eq 'null';
    compile_error("$where requires number|null operand, got $type");
}

1;
