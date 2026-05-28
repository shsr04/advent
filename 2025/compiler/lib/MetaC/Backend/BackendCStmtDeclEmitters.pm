package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_declare_stmt {
    my ($stmt, $out, $indent, $seen_decl, $ctx) = @_;
    my $sp = ' ' x $indent;
    my $name = $stmt->{name} // '__missing_name';
    my $decl = $seen_decl->{$name}++;
    my $inferred = _expr_c_type_hint($stmt->{expr}, $ctx);
    my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
    my $rhs = _expr_to_c($stmt->{expr}, $ctx);
    my $constraints = $stmt->{constraints};
    if ($c_ty eq 'struct metac_list_str' && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH' && ($stmt->{expr}{kind} // '') eq 'list_literal') {
        _helper_mark($ctx, 'list_str');
        my @items = @{ $stmt->{expr}{items} // [] };
        if (!@items) {
            $rhs = 'metac_list_str_empty()';
        } else {
            my @vals = map { _expr_to_c($_, $ctx) } @items;
            my $arr = '(const char*[]){' . join(', ', @vals) . '}';
            $rhs = 'metac_list_str_from_array(' . $arr . ', ' . scalar(@vals) . ')';
        }
    }
    if ($c_ty eq 'struct metac_list_list_i64' && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH' && ($stmt->{expr}{kind} // '') eq 'list_literal') {
        _helper_mark($ctx, 'list_i64');
        _helper_mark($ctx, 'list_list_i64');
        my @items = @{ $stmt->{expr}{items} // [] };
        if (!@items) {
            $rhs = 'metac_list_list_i64_empty()';
        } else {
            my @vals = map { _expr_to_c($_, $ctx) } @items;
            my $arr = '(struct metac_list_i64[]){' . join(', ', @vals) . '}';
            $rhs = 'metac_list_list_i64_from_array(' . $arr . ', ' . scalar(@vals) . ')';
        }
    }
    my $size_need = _constraint_exact_size($constraints);
    if ($c_ty eq 'const char *' && defined($size_need) && $size_need >= 0) {
        _helper_mark($ctx, 'error_flag');
        _helper_mark($ctx, 'constrained_string_assign');
        $rhs = 'metac_constrained_string_assign(' . $rhs . ', ' . $size_need . ')';
    }
    _helper_mark($ctx, 'list_str') if $c_ty eq 'struct metac_list_str';
    _helper_mark($ctx, 'list_i64') if $c_ty eq 'struct metac_list_i64';
    _helper_mark($ctx, 'list_list_i64') if $c_ty eq 'struct metac_list_list_i64';
    push @$out, $decl ? "${sp}$name = $rhs;" : "${sp}$c_ty $name = $rhs;";
    $ctx->{var_types}{$name} = $c_ty;
    $ctx->{var_constraints}{$name} = $constraints if $name ne '';
    my $mmeta = _matrix_meta_for_type($stmt->{type});
    if (defined($mmeta) && ref($mmeta) eq 'HASH' && $name ne '') {
        _helper_mark($ctx, 'list_i64');
        _helper_mark($ctx, 'matrix_meta');
        my $mvar = _matrix_meta_var_name($name);
        my $mdecl = $seen_decl->{$mvar}++;
        my $dim = int($mmeta->{dim} // 0);
        my $has_size = ($mmeta->{has_size} // 0) ? 1 : 0;
        my @sizes = @{ $mmeta->{sizes} // [] };
        if (!$has_size || @sizes != $dim) {
            @sizes = map { -1 } (1 .. $dim);
        }
        my $sizes_c = @sizes ? join(', ', @sizes) : '-1';
        my $init = "metac_matrix_meta_init($dim, (int64_t[]){$sizes_c}, " . ($has_size ? 1 : 0) . ')';
        push @$out, $mdecl ? "${sp}$mvar = $init;" : "${sp}struct metac_matrix_meta $mvar = $init;";
        $ctx->{matrix_meta_vars}{$name} = $mvar;
    } elsif ($name ne '') {
        my $src_name = _matrix_meta_alias_source_name_stmt($stmt->{expr});
        my $src_mvar = $ctx->{matrix_meta_vars}{$src_name} // '';
        $ctx->{matrix_meta_vars}{$name} = $src_mvar if $src_mvar ne '';
    }
}

1;
