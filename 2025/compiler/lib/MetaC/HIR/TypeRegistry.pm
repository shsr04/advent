package MetaC::HIR::TypeRegistry;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    scalar_type_info
    scalar_family
    canonical_scalar_base
    scalar_c_type
    scalar_is_numeric
    scalar_is_boolean
    scalar_is_string
    scalar_is_error
    scalar_is_null
    scalar_is_comparison
    numeric_kind_for_type
    numeric_kind_assignable
    numeric_kind_is_concrete
    numeric_kind_additive_compatible
    numeric_kind_div_compatible
    sequence_elem_label
);

my %SCALAR_TYPES = (
    number => {
        family => 'numeric',
        c_type => 'int64_t',
    },
    int => {
        family => 'numeric',
        c_type => 'int64_t',
    },
    float => {
        family => 'numeric',
        c_type => 'double',
    },
    bool => {
        family => 'boolean',
        c_type => 'int',
    },
    boolean => {
        family => 'boolean',
        c_type => 'int',
    },
    string => {
        family => 'string',
        c_type => 'const char *',
    },
    null => {
        family => 'null',
        c_type => 'int',
    },
    error => {
        family => 'error',
        c_type => 'struct metac_error',
    },
    comparison_result => {
        family => 'comparison',
    },
);

sub scalar_type_info {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    return $SCALAR_TYPES{$type};
}

sub canonical_scalar_base {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    return 'string' if $type =~ /^stringwith/;
    return 'number' if $type =~ /^numberwith/;
    return $type if defined(scalar_type_info($type));
    return undef;
}

sub scalar_family {
    my ($type) = @_;
    my $base = canonical_scalar_base($type);
    my $info = scalar_type_info($base);
    return undef if !defined($info);
    return $info->{family};
}

sub scalar_c_type {
    my ($type) = @_;
    my $info = scalar_type_info($type);
    return undef if !defined($info);
    return $info->{c_type};
}

sub scalar_is_numeric {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'numeric' ? 1 : 0;
}

sub scalar_is_boolean {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'boolean' ? 1 : 0;
}

sub scalar_is_string {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'string' ? 1 : 0;
}

sub scalar_is_error {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'error' ? 1 : 0;
}

sub scalar_is_null {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'null' ? 1 : 0;
}

sub scalar_is_comparison {
    my ($type) = @_;
    return (scalar_family($type) // '') eq 'comparison' ? 1 : 0;
}

sub numeric_kind_for_type {
    my ($type) = @_;
    my $base = canonical_scalar_base($type);
    return undef if !defined($base);
    return 'int' if $base eq 'int';
    return 'float' if $base eq 'float';
    return 'number' if $base eq 'number';
    return undef;
}

sub numeric_kind_assignable {
    my ($actual, $expected) = @_;
    return 0 if !defined($actual) || !defined($expected) || $actual eq '' || $expected eq '';
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'number' && scalar_is_numeric($actual);
    return 0;
}

sub numeric_kind_is_concrete {
    my ($kind) = @_;
    return 1 if defined($kind) && ($kind eq 'int' || $kind eq 'float');
    return 0;
}

sub numeric_kind_additive_compatible {
    my (%args) = @_;
    my $lk = $args{left_kind};
    my $rk = $args{right_kind};
    my $left_literal = $args{left_is_literal} ? 1 : 0;
    my $right_literal = $args{right_is_literal} ? 1 : 0;
    return 0 if !defined($lk) || !defined($rk) || $lk eq '' || $rk eq '';
    return 1 if $lk eq $rk && ($lk eq 'int' || $lk eq 'float' || $lk eq 'number');
    return 1 if numeric_kind_is_concrete($lk) && numeric_kind_is_concrete($rk);
    return 1 if numeric_kind_is_concrete($lk) && $rk eq 'number';
    return 1 if $lk eq 'number' && numeric_kind_is_concrete($rk) && $right_literal;
    return 1 if $rk eq 'number' && numeric_kind_is_concrete($lk) && $left_literal;
    return 0;
}

sub numeric_kind_div_compatible {
    my (%args) = @_;
    my $lk = $args{left_kind};
    my $rk = $args{right_kind};
    my $left_literal = $args{left_is_literal} ? 1 : 0;
    my $right_literal = $args{right_is_literal} ? 1 : 0;
    return 0 if !defined($lk) || !defined($rk) || $lk eq '' || $rk eq '';
    return 1 if numeric_kind_is_concrete($lk) && numeric_kind_is_concrete($rk);
    return 1 if $lk eq 'number' && numeric_kind_is_concrete($rk) && $right_literal;
    return 1 if $rk eq 'number' && numeric_kind_is_concrete($lk) && $left_literal;
    return 0;
}

sub sequence_elem_label {
    my ($elem_type) = @_;
    return undef if !defined($elem_type) || $elem_type eq '';
    return 'number_list' if scalar_is_numeric($elem_type);
    return 'string_list' if scalar_is_string($elem_type);
    return 'bool_list' if scalar_is_boolean($elem_type);
    return undef;
}

1;
