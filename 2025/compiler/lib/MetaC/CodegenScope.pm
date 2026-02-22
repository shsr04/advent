package MetaC::CodegenScope;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);

our @EXPORT_OK = qw(
    new_scope
    pop_scope
    lookup_var
    declare_var
    set_list_len_fact
    lookup_list_len_fact
    set_nonnull_fact_by_c_name
    clear_nonnull_fact_by_c_name
    has_nonnull_fact_by_c_name
    set_nonnull_fact_for_var_name
    clear_nonnull_fact_for_var_name
);

sub new_scope {
    my ($ctx) = @_;
    push @{ $ctx->{scopes} }, {};
    push @{ $ctx->{fact_scopes} }, {};
    push @{ $ctx->{nonnull_scopes} }, {};
}

sub pop_scope {
    my ($ctx) = @_;
    pop @{ $ctx->{scopes} };
    pop @{ $ctx->{fact_scopes} };
    pop @{ $ctx->{nonnull_scopes} };
}

sub lookup_var {
    my ($ctx, $name) = @_;
    for (my $i = $#{ $ctx->{scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{scopes}[$i];
        return $scope->{$name} if exists $scope->{$name};
    }
    return undef;
}

sub declare_var {
    my ($ctx, $name, $info) = @_;
    my $scope = $ctx->{scopes}[-1];
    compile_error("Variable already declared in this scope: $name") if exists $scope->{$name};
    $info->{c_name} = $name if !exists $info->{c_name};
    $info->{immutable} = 0 if !exists $info->{immutable};
    $scope->{$name} = $info;
}

sub set_list_len_fact {
    my ($ctx, $key, $len) = @_;
    my $scope = $ctx->{fact_scopes}[-1];
    $scope->{$key} = $len;
}

sub lookup_list_len_fact {
    my ($ctx, $key) = @_;
    for (my $i = $#{ $ctx->{fact_scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{fact_scopes}[$i];
        return $scope->{$key} if exists $scope->{$key};
    }
    return undef;
}

sub set_nonnull_fact_by_c_name {
    my ($ctx, $c_name) = @_;
    my $scope = $ctx->{nonnull_scopes}[-1];
    $scope->{$c_name} = 1;
}

sub clear_nonnull_fact_by_c_name {
    my ($ctx, $c_name) = @_;
    for (my $i = 0; $i <= $#{ $ctx->{nonnull_scopes} }; $i++) {
        my $scope = $ctx->{nonnull_scopes}[$i];
        delete $scope->{$c_name} if exists $scope->{$c_name};
    }
}

sub has_nonnull_fact_by_c_name {
    my ($ctx, $c_name) = @_;
    for (my $i = $#{ $ctx->{nonnull_scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{nonnull_scopes}[$i];
        return 1 if exists $scope->{$c_name};
    }
    return 0;
}

sub set_nonnull_fact_for_var_name {
    my ($ctx, $name) = @_;
    my $info = lookup_var($ctx, $name);
    return if !defined $info;
    return if $info->{type} ne 'number_or_null';
    set_nonnull_fact_by_c_name($ctx, $info->{c_name});
}

sub clear_nonnull_fact_for_var_name {
    my ($ctx, $name) = @_;
    my $info = lookup_var($ctx, $name);
    return if !defined $info;
    return if $info->{type} ne 'number_or_null';
    clear_nonnull_fact_by_c_name($ctx, $info->{c_name});
}

1;
