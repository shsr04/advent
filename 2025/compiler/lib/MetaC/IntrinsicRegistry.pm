package MetaC::IntrinsicRegistry;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    method_base_specs
    method_codegen_templates
    intrinsic_method_codegen_template
    intrinsic_method_op_id
    method_from_op_id
);

sub method_base_specs {
    return {
        size => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { string => 1, string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1, indexed_number_list => 1 } },
        chunk => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { string => 1 } },
        chars => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { string => 1 } },
        isBlank => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { string => 1 } },
        split => { arity => 1, expr_callable => 0, fallibility => 'always', receivers => { string => 1 } },
        match => { arity => 1, expr_callable => 0, fallibility => 'always', receivers => { string => 1 } },
        slice => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1 } },
        max => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1 } },
        sort => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { number_list => 1 } },
        sortBy => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { number_list_list => 1 } },
        compareTo => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { number => 1, indexed_number => 1 } },
        andThen => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { number => 1, indexed_number => 1 } },
        index => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { indexed_number => 1 } },
        log => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { string => 1, number => 1, bool => 1, indexed_number => 1, string_list => 1, number_list => 1, bool_list => 1, indexed_number_list => 1 } },
        map => { arity => 1, expr_callable => 0, fallibility => 'mapper', receivers => { string_list => 1 } },
        filter => { arity => 1, expr_callable => 0, fallibility => 'never', receivers => { string_list => 1, number_list => 1 } },
        any => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1 } },
        all => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1 } },
        reduce => { arity => 2, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1 } },
        assert => { arity => 2, expr_callable => 0, fallibility => 'always', receivers => { string_list => 1, number_list => 1 } },
        push => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { string_list => 1, number_list => 1, number_list_list => 1, bool_list => 1 } },
        insert => { arity => 2, expr_callable => 1, fallibility => 'conditional', receivers => { matrix_any => 1 } },
        members => { arity => 0, expr_callable => 1, fallibility => 'never', receivers => { matrix_any => 1 } },
        neighbours => { arity => 1, expr_callable => 1, fallibility => 'never', receivers => { matrix_any => 1, matrix_member_any => 1 } },
    };
}

sub method_codegen_templates {
    return {
        size => {
            string             => { arity => 0, result_type => 'number', expr_template => 'metac_strlen(%RECV%)' },
            string_list        => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            number_list        => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            number_list_list   => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            bool_list          => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            indexed_number_list => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
        },
        count => {
            string_list        => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            number_list        => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            number_list_list   => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            bool_list          => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
            indexed_number_list => { arity => 0, result_type => 'number', expr_template => '((int64_t)%RECV%.count)' },
        },
        chunk => {
            string => { arity => 1, result_type => 'string_list', expr_template => 'metac_chunk_string(%RECV%, %ARG0_NUM%)' },
        },
        chars => {
            string => { arity => 0, result_type => 'string_list', expr_template => 'metac_chars_string(%RECV%)' },
        },
        isBlank => {
            string => { arity => 0, result_type => 'bool', expr_template => 'metac_is_blank(%RECV%)' },
        },
        slice => {
            string_list => { arity => 1, result_type => 'string_list', expr_template => 'metac_slice_string_list(%RECV%, %ARG0_NUM%)' },
            number_list => { arity => 1, result_type => 'number_list', expr_template => 'metac_slice_number_list(%RECV%, %ARG0_NUM%)' },
        },
        max => {
            number_list => { arity => 0, result_type => 'indexed_number', expr_template => 'metac_list_max_number(%RECV%)' },
            string_list => { arity => 0, result_type => 'indexed_number', expr_template => 'metac_list_max_string_number(%RECV%)' },
        },
        sort => {
            number_list => { arity => 0, result_type => 'indexed_number_list', expr_template => 'metac_sort_number_list(%RECV%)' },
        },
        compareTo => {
            number         => { arity => 1, result_type => 'number', expr_template => '((%RECV_NUM% < %ARG0_NUM%) ? -1 : ((%RECV_NUM% > %ARG0_NUM%) ? 1 : 0))' },
            indexed_number => { arity => 1, result_type => 'number', expr_template => '((%RECV_NUM% < %ARG0_NUM%) ? -1 : ((%RECV_NUM% > %ARG0_NUM%) ? 1 : 0))' },
        },
        andThen => {
            number         => { arity => 1, result_type => 'number', expr_template => '((%RECV_NUM% != 0) ? %RECV_NUM% : %ARG0_NUM%)' },
            indexed_number => { arity => 1, result_type => 'number', expr_template => '((%RECV_NUM% != 0) ? %RECV_NUM% : %ARG0_NUM%)' },
        },
        index => {
            indexed_number => { arity => 0, result_type => 'number', expr_template => '((%RECV%).index)' },
        },
        log => {
            number              => { arity => 0, result_type => 'number', expr_template => 'metac_log_number(%RECV%)' },
            string              => { arity => 0, result_type => 'string', expr_template => 'metac_log_string(%RECV%)' },
            bool                => { arity => 0, result_type => 'bool', expr_template => 'metac_log_bool(%RECV%)' },
            indexed_number      => { arity => 0, result_type => 'indexed_number', expr_template => 'metac_log_indexed_number(%RECV%)' },
            string_list         => { arity => 0, result_type => 'string_list', expr_template => 'metac_log_string_list(%RECV%)' },
            number_list         => { arity => 0, result_type => 'number_list', expr_template => 'metac_log_number_list(%RECV%)' },
            bool_list           => { arity => 0, result_type => 'bool_list', expr_template => 'metac_log_bool_list(%RECV%)' },
            indexed_number_list => { arity => 0, result_type => 'indexed_number_list', expr_template => 'metac_log_indexed_number_list(%RECV%)' },
        },
    };
}

sub intrinsic_method_codegen_template {
    my ($method, $recv_type) = @_;
    return undef if !defined($method) || $method eq '';
    return undef if !defined($recv_type) || $recv_type eq '';
    my $all = method_codegen_templates();
    my $by_method = $all->{$method};
    return undef if !defined $by_method;
    my $spec = $by_method->{$recv_type};
    return undef if !defined $spec;
    return { %$spec };
}

sub intrinsic_method_op_id {
    my ($name) = @_;
    return "intrinsic.method.$name.v1";
}

sub method_from_op_id {
    my ($op_id) = @_;
    return undef if !defined $op_id;
    return $1 if $op_id =~ /^intrinsic\.method\.([A-Za-z_][A-Za-z0-9_]*)\.v1$/;
    return undef;
}

1;
