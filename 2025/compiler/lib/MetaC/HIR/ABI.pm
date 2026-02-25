package MetaC::HIR::ABI;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error c_escape_string);
use MetaC::TypeSpec qw(
    is_array_type
    is_union_type
    is_supported_value_type
    is_matrix_type
    matrix_type_meta
    union_member_types
    is_supported_generic_union_return
    type_is_number_or_error
    type_is_bool_or_error
    type_is_string_or_error
);

our @EXPORT_OK = qw(normalize_hir_abi);

sub _c_value_type {
    my ($type) = @_;
    return 'int64_t' if $type eq 'number';
    return 'int' if $type eq 'bool';
    return 'const char *' if $type eq 'string';
    return 'NullableNumber' if $type eq 'number_or_null';
    return 'NumberList' if $type eq 'number_list';
    return 'NumberListList' if $type eq 'number_list_list';
    return 'StringList' if $type eq 'string_list';
    return 'BoolList' if $type eq 'bool_list';
    return 'AnyList' if is_array_type($type);
    if (is_matrix_type($type)) {
        my $meta = matrix_type_meta($type);
        return 'MatrixNumber' if $meta->{elem} eq 'number';
        return 'MatrixString' if $meta->{elem} eq 'string';
        return 'MatrixOpaque';
    }
    return undef;
}

sub _fallback_expr_for_value_type {
    my ($type) = @_;
    return '0' if $type eq 'number';
    return '0' if $type eq 'bool';
    return '""' if $type eq 'string';
    return 'metac_null_number()' if $type eq 'number_or_null';
    return '(NumberList){0, NULL}' if $type eq 'number_list';
    return '(NumberListList){0, NULL}' if $type eq 'number_list_list';
    return '(StringList){0, NULL}' if $type eq 'string_list';
    return '(BoolList){0, NULL}' if $type eq 'bool_list';
    return '(AnyList){0, NULL}' if is_array_type($type);
    if (is_matrix_type($type)) {
        my $meta = matrix_type_meta($type);
        return 'metac_matrix_number_new(2, NULL)' if $meta->{elem} eq 'number';
        return 'metac_matrix_string_new(2, NULL)' if $meta->{elem} eq 'string';
        return 'metac_matrix_opaque_new(2, NULL)';
    }
    return undef;
}

sub _abi_contract_for_function {
    my ($fn) = @_;
    my $name = $fn->{name};
    my $ret = $fn->{return_type};
    my $sig_params = MetaC::Codegen::render_c_params($fn->{params});

    if ($name eq 'main') {
        return {
            contract_id   => 'metac_main_v1',
            c_decl        => 'int main(void) {',
            c_return_mode => 'number',
            c_fallback    => '  return 0;',
        };
    }

    if (type_is_number_or_error($ret)) {
        my $msg = c_escape_string("Missing return in function $name");
        return {
            contract_id   => 'metac_result_number_v1',
            c_decl        => "static ResultNumber $name($sig_params) {",
            c_return_mode => $ret,
            c_fallback    => "  return err_number($msg, __metac_line_no, \"\");",
        };
    }

    if (type_is_bool_or_error($ret)) {
        my $msg = c_escape_string("Missing return in function $name");
        return {
            contract_id   => 'metac_result_bool_v1',
            c_decl        => "static ResultBool $name($sig_params) {",
            c_return_mode => $ret,
            c_fallback    => "  return err_bool($msg, __metac_line_no, \"\");",
        };
    }

    if (type_is_string_or_error($ret)) {
        my $msg = c_escape_string("Missing return in function $name");
        return {
            contract_id   => 'metac_result_string_v1',
            c_decl        => "static ResultStringValue $name($sig_params) {",
            c_return_mode => $ret,
            c_fallback    => "  return err_string_value($msg, __metac_line_no, \"\");",
        };
    }

    if (is_union_type($ret) && is_supported_generic_union_return($ret)) {
        my $members = union_member_types($ret);
        my $first = $members->[0] // 'error';
        my $fallback = '  return metac_value_error("Missing return", __metac_line_no, "");';
        $fallback = '  return metac_value_number(0);' if $first eq 'number';
        $fallback = '  return metac_value_bool(0);' if $first eq 'bool';
        $fallback = '  return metac_value_string("");' if $first eq 'string';
        $fallback = '  return metac_value_null();' if $first eq 'null';
        $fallback = '  return metac_value_number_list((NumberList){0, NULL});' if $first eq 'number_list';
        $fallback = '  return metac_value_number_list_list((NumberListList){0, NULL});' if $first eq 'number_list_list';
        $fallback = '  return metac_value_string_list((StringList){0, NULL});' if $first eq 'string_list';
        $fallback = '  return metac_value_bool_list((BoolList){0, NULL});' if $first eq 'bool_list';
        $fallback = '  return metac_value_any_list((AnyList){0, NULL});' if is_array_type($first);
        if (is_matrix_type($first)) {
            my $meta = matrix_type_meta($first);
            $fallback = '  return metac_value_matrix_number(metac_matrix_number_new(2, NULL));'
              if $meta->{elem} eq 'number';
            $fallback = '  return metac_value_matrix_string(metac_matrix_string_new(2, NULL));'
              if $meta->{elem} eq 'string';
            $fallback = '  return metac_value_matrix_opaque(metac_matrix_opaque_new(2, NULL));'
              if $meta->{elem} ne 'number' && $meta->{elem} ne 'string';
        }
        return {
            contract_id   => 'metac_value_union_v1',
            c_decl        => "static MetaCValue $name($sig_params) {",
            c_return_mode => $ret,
            c_fallback    => $fallback,
        };
    }

    if (is_supported_value_type($ret)) {
        my $c_type = _c_value_type($ret);
        my $fallback_expr = _fallback_expr_for_value_type($ret);
        compile_error("F050 ABI normalization: unsupported value return type '$ret' for '$name'")
          if !defined($c_type) || !defined($fallback_expr);
        return {
            contract_id   => 'metac_value_plain_v1',
            c_decl        => "static $c_type $name($sig_params) {",
            c_return_mode => $ret,
            c_fallback    => "  return $fallback_expr;",
        };
    }

    compile_error("F049 ABI normalization: unsupported return type '$ret' for '$name'");
}

sub normalize_hir_abi {
    my ($hir) = @_;
    for my $fn (@{ $hir->{functions} }) {
        $fn->{abi} = _abi_contract_for_function($fn);
    }
    return $hir;
}

1;
