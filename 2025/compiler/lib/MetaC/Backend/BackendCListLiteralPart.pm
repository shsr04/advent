package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _list_literal_to_c_for_type {
    my ($expr, $type, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH' || (($expr->{kind} // '') ne 'list_literal');
    return undef if !defined($type) || $type eq '';
    _mark_type_helpers($ctx, $type);
    my @items = @{ $expr->{items} // [] };
    return c_type_default_expr_for_type($type) if !@items;

    my $ops = c_type_collection_ops_for_type($type);
    if (defined($ops) && ref($ops) eq 'HASH') {
        my $elem_t = $ops->{elem_type};
        my @vals = map {
            (defined($_) && ref($_) eq 'HASH' && (($_->{kind} // '') eq 'list_literal'))
              ? (_list_literal_to_c_for_type($_, $elem_t, $ctx) // _expr_to_c($_, $ctx))
              : _expr_to_c($_, $ctx)
        } @items;
        my $arr = '(' . $ops->{elem_c_type} . '[]){' . join(', ', @vals) . '}';
        return $ops->{from_array} . '(' . $arr . ', ' . scalar(@vals) . ')';
    }

    my $c_ty = _type_to_c($type, '');
    if ($c_ty eq 'struct metac_list_str') {
        my @vals = map { _expr_to_c($_, $ctx) } @items;
        return 'metac_list_str_from_array((const char*[]){' . join(', ', @vals) . '}, ' . scalar(@vals) . ')';
    }
    if ($c_ty eq 'struct metac_list_list_i64') {
        my @vals = map { _expr_to_c($_, $ctx) } @items;
        return 'metac_list_list_i64_from_array((struct metac_list_i64[]){' . join(', ', @vals) . '}, ' . scalar(@vals) . ')';
    }
    if ($c_ty eq 'struct metac_list_i64') {
        my @vals = map { _expr_to_c($_, $ctx) } @items;
        return 'metac_list_i64_from_array((int64_t[]){' . join(', ', @vals) . '}, ' . scalar(@vals) . ')';
    }
    return undef;
}

1;
