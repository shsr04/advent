package MetaC::Backend::CTypeRegistry;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::TypeRegistry qw(canonical_scalar_base);
use MetaC::Support qw(compile_error);
use MetaC::TypeSpec qw(
    normalize_type_annotation
    is_union_type
    union_member_types
    is_array_type
    array_type_meta
    is_matrix_type
    matrix_type_meta
    is_matrix_member_type
    matrix_member_meta
    is_matrix_member_list_type
    matrix_member_list_meta
    is_sequence_member_type
    sequence_member_meta
);

our @EXPORT_OK = qw(
    scalar_c_type
    type_to_c_type
    type_to_c_type_or_error
    c_log_strategy_for_c_type
    c_log_strategy_for_type
    c_intrinsic_method_strategy_for_types
);

my %SCALAR_C_TYPE = (
    number  => 'int64_t',
    int     => 'int64_t',
    float   => 'double',
    bool    => 'int',
    boolean => 'int',
    string  => 'const char *',
    null    => 'int',
    error   => 'struct metac_error',
);

my %LOG_STRATEGY_FOR_C_TYPE = (
    'const char *' => {
        call    => 'metac_builtin_log_str',
        helpers => [qw(log_str)],
    },
    'double' => {
        call    => 'metac_builtin_log_f64',
        helpers => [qw(log_f64)],
    },
    'int' => {
        call    => 'metac_builtin_log_bool',
        helpers => [qw(log_bool)],
    },
    'int64_t' => {
        call    => 'metac_builtin_log_i64',
        helpers => [qw(log_i64)],
    },
    'struct metac_list_i64' => {
        call    => 'metac_method_log_list_i64',
        helpers => [qw(list_i64 list_i64_render log_str method_log_list_i64)],
    },
    'struct metac_list_str' => {
        call    => 'metac_method_log_list_str',
        helpers => [qw(list_str list_str_render log_str method_log_list_str)],
    },
    'struct metac_list_list_i64' => {
        call    => 'metac_method_log_list_list_i64',
        helpers => [qw(list_i64 list_i64_render list_list_i64 list_list_i64_render log_str method_log_list_list_i64)],
    },
);

my %I64_LIST_SCALAR_BASE = map { $_ => 1 } qw(number int float bool boolean null string);

my %DEFAULT_C_EXPR_FOR_TYPE = (
    'const char *' => '""',
    'double' => '0',
    'int' => '0',
    'int64_t' => '0',
    'struct metac_list_i64' => 'metac_list_i64_empty()',
    'struct metac_list_str' => 'metac_list_str_empty()',
    'struct metac_list_list_i64' => 'metac_list_list_i64_empty()',
);

sub scalar_c_type {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    my $base = canonical_scalar_base($type);
    return undef if !defined($base);
    return $SCALAR_C_TYPE{$base};
}

sub _normalize_for_type_lookup {
    my ($type) = @_;
    return undef if !defined($type);
    my $t = $type;
    $t =~ s/^\s+|\s+$//g;
    return undef if $t eq '';
    my $base = canonical_scalar_base($t);
    return $base if defined($base);
    return normalize_type_annotation($t);
}

sub _build_type_shape {
    my ($type) = @_;
    my $normalized = _normalize_for_type_lookup($type);
    return undef if !defined($normalized) || $normalized eq '';

    if (is_union_type($normalized)) {
        my @members = grep { defined($_) && $_ ne '' && $_ ne 'error' } @{ union_member_types($normalized) };
        return undef if !@members;
        my @member_shapes = map { _build_type_shape($_) } @members;
        return undef if grep { !defined($_) } @member_shapes;
        return {
            kind    => 'union',
            members => \@member_shapes,
        };
    }

    my $base = canonical_scalar_base($normalized);
    if (defined($base)) {
        return {
            kind => 'scalar',
            base => $base,
        };
    }

    if (is_sequence_member_type($normalized)) {
        my $meta = sequence_member_meta($normalized);
        return undef if !defined($meta) || ref($meta) ne 'HASH';
        my $elem = _build_type_shape($meta->{elem});
        return undef if !defined($elem);
        return {
            kind => 'sequence_member',
            elem => $elem,
        };
    }

    if (is_array_type($normalized)) {
        my $meta = array_type_meta($normalized);
        return undef if !defined($meta) || ref($meta) ne 'HASH';
        my $elem = _build_type_shape($meta->{elem});
        return undef if !defined($elem);
        return {
            kind => 'array',
            elem => $elem,
        };
    }

    if (is_matrix_member_type($normalized)) {
        my $meta = matrix_member_meta($normalized);
        return undef if !defined($meta) || ref($meta) ne 'HASH';
        my $elem = _build_type_shape($meta->{elem});
        return undef if !defined($elem);
        return {
            kind => 'matrix_member',
            elem => $elem,
        };
    }

    if (is_matrix_member_list_type($normalized)) {
        my $meta = matrix_member_list_meta($normalized);
        return undef if !defined($meta) || ref($meta) ne 'HASH';
        my $elem = _build_type_shape($meta->{elem});
        return undef if !defined($elem);
        return {
            kind => 'matrix_member_list',
            elem => $elem,
        };
    }

    if (is_matrix_type($normalized)) {
        my $meta = matrix_type_meta($normalized);
        return undef if !defined($meta) || ref($meta) ne 'HASH';
        my $elem = _build_type_shape($meta->{elem});
        return undef if !defined($elem);
        return {
            kind => 'matrix',
            elem => $elem,
            dim  => int($meta->{dim} // 0),
        };
    }

    return {
        kind => 'unknown',
        raw  => $normalized,
    };
}

sub _shape_scalar_family_set {
    my ($shape, $out) = @_;
    return 0 if !defined($shape) || ref($shape) ne 'HASH' || !defined($out) || ref($out) ne 'HASH';

    my $kind = $shape->{kind} // '';
    if ($kind eq 'scalar') {
        my $base = $shape->{base} // '';
        return 0 if $base eq '' || $base eq 'error';
        $out->{$base} = 1;
        return 1;
    }
    if ($kind eq 'union') {
        my $members = $shape->{members} // [];
        return 0 if ref($members) ne 'ARRAY' || !@$members;
        for my $member (@$members) {
            return 0 if !_shape_scalar_family_set($member, $out);
        }
        return 1;
    }
    return 0;
}

sub _shape_collection_scalar_family {
    my ($shape) = @_;
    my %set;
    return undef if !_shape_scalar_family_set($shape, \%set);
    my @bases = sort keys %set;
    return undef if !@bases;
    return 'string' if @bases == 1 && $bases[0] eq 'string';
    for my $base (@bases) {
        return undef if !$I64_LIST_SCALAR_BASE{$base};
    }
    return 'i64';
}

sub _shape_to_c_type {
    my ($shape) = @_;
    return undef if !defined($shape) || ref($shape) ne 'HASH';

    my $kind = $shape->{kind} // '';

    if ($kind eq 'scalar') {
        return $SCALAR_C_TYPE{ $shape->{base} // '' };
    }

    if ($kind eq 'union') {
        my $scalar_family = _shape_collection_scalar_family($shape);
        return 'const char *' if defined($scalar_family) && $scalar_family eq 'string';
        return 'int64_t' if defined($scalar_family) && $scalar_family eq 'i64';

        my %seen;
        my @candidates;
        for my $member (@{ $shape->{members} // [] }) {
            my $c = _shape_to_c_type($member);
            next if !defined($c) || $c eq '' || $seen{$c}++;
            push @candidates, $c;
        }
        return undef if @candidates != 1;
        return $candidates[0];
    }

    if ($kind eq 'sequence_member' || $kind eq 'matrix_member') {
        return _shape_to_c_type($shape->{elem});
    }

    if ($kind eq 'array' || $kind eq 'matrix' || $kind eq 'matrix_member_list') {
        my $elem = $shape->{elem};
        return undef if !defined($elem) || ref($elem) ne 'HASH';

        my $fam = _shape_collection_scalar_family($elem);
        return 'struct metac_list_str' if defined($fam) && $fam eq 'string';
        return 'struct metac_list_i64' if defined($fam) && $fam eq 'i64';

        my $elem_c = _shape_to_c_type($elem);
        return 'struct metac_list_list_i64'
          if defined($elem_c) && $elem_c eq 'struct metac_list_i64';

        return undef;
    }

    return undef;
}

sub type_to_c_type {
    my ($type) = @_;
    my $shape = _build_type_shape($type);
    return _shape_to_c_type($shape);
}

sub type_to_c_type_or_error {
    my (%args) = @_;
    my $type = $args{type};
    my $context = $args{context} // 'type lowering';
    my $shape = _build_type_shape($type);
    my $c = _shape_to_c_type($shape);
    return $c if defined($c) && $c ne '';

    compile_error("Backend/CType: unsupported type carrier for $context: '$type'");
}

sub c_log_strategy_for_c_type {
    my ($c_type) = @_;
    return undef if !defined($c_type) || $c_type eq '';
    my $spec = $LOG_STRATEGY_FOR_C_TYPE{$c_type};
    return undef if !defined($spec) || ref($spec) ne 'HASH';
    return {
        call    => $spec->{call},
        helpers => [ @{ $spec->{helpers} // [] } ],
    };
}

sub c_log_strategy_for_type {
    my ($type) = @_;
    my $c_type = type_to_c_type($type);
    return undef if !defined($c_type) || $c_type eq '';
    return c_log_strategy_for_c_type($c_type);
}

sub _default_c_expr_for_type {
    my ($c_type) = @_;
    return '0' if !defined($c_type) || $c_type eq '';
    return $DEFAULT_C_EXPR_FOR_TYPE{$c_type} if exists $DEFAULT_C_EXPR_FOR_TYPE{$c_type};
    return '0';
}

sub _insert_strategy_for_types {
    my (%args) = @_;
    my $receiver_type = $args{receiver_type};
    my $arg_types = $args{arg_types};
    return undef if !defined($receiver_type) || !defined($arg_types) || ref($arg_types) ne 'ARRAY' || @$arg_types < 2;

    my $recv_c = type_to_c_type($receiver_type);
    my $value_c = type_to_c_type($arg_types->[0]);
    my $index_c = type_to_c_type($arg_types->[1]);
    return undef if !defined($recv_c) || $recv_c eq '' || !defined($value_c) || $value_c eq '' || !defined($index_c) || $index_c eq '';

    my $index_mode = ($index_c eq 'struct metac_list_i64') ? 'matrix' : 'scalar';
    my $stem;
    my @helpers = qw(method_insert);
    my @matrix_helpers = ();

    if ($recv_c eq 'struct metac_list_i64' && $value_c eq 'int64_t') {
        $stem = 'metac_method_insert_i64';
        push @helpers, 'list_i64';
    } elsif ($recv_c eq 'struct metac_list_str' && $value_c eq 'const char *') {
        $stem = 'metac_method_insert_str';
        push @helpers, 'list_str';
    } elsif ($recv_c eq 'struct metac_list_list_i64' && $value_c eq 'struct metac_list_i64') {
        return undef if $index_mode ne 'scalar';
        $stem = 'metac_method_insert_list_i64';
        push @helpers, qw(list_i64 list_list_i64);
    } else {
        return undef;
    }

    if ($index_mode eq 'matrix') {
        return undef if $recv_c eq 'struct metac_list_list_i64';
        push @helpers, 'list_i64';
        push @matrix_helpers, 'matrix_meta';
    }

    return {
        family => 'insert',
        stem => $stem,
        receiver_c_type => $recv_c,
        value_c_type => $value_c,
        index_c_type => $index_c,
        index_mode => $index_mode,
        supports_matrix => ($index_mode eq 'matrix') ? 1 : 0,
        supports_matrix_meta => ($index_mode eq 'matrix') ? 1 : 0,
        default_value_expr => _default_c_expr_for_type($value_c),
        default_index_scalar_expr => _default_c_expr_for_type('int64_t'),
        default_index_matrix_expr => _default_c_expr_for_type('struct metac_list_i64'),
        helpers => \@helpers,
        helpers_matrix => \@matrix_helpers,
    };
}

sub c_intrinsic_method_strategy_for_types {
    my (%args) = @_;
    my $op_id = $args{op_id} // '';
    my $receiver_type = $args{receiver_type};
    my $arg_types = $args{arg_types};
    return undef if $op_id eq '';

    if ($op_id eq 'method.insert.v1') {
        return _insert_strategy_for_types(
            receiver_type => $receiver_type,
            arg_types => $arg_types,
        );
    }

    return undef;
}

1;
