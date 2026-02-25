package MetaC::Codegen;
use strict;
use warnings;

sub _register_owned_cleanup {
    my ($ctx, $var_name, $cleanup_call) = @_;
    return if !defined $var_name || $var_name eq '';
    return if !defined $cleanup_call || $cleanup_call eq '';
    $ctx->{ownership_scopes} = [ [] ] if !defined $ctx->{ownership_scopes};
    my $scope = $ctx->{ownership_scopes}[-1];
    push @$scope, {
        var_name     => $var_name,
        cleanup_call => $cleanup_call,
    };
}

sub register_owned_cleanup_for_var {
    my ($ctx, $var_name, $cleanup_call) = @_;
    _register_owned_cleanup($ctx, $var_name, $cleanup_call);
}

sub _cleanup_call_for_expr_type_and_source {
    my ($var_name, $decl_type, $expr_code) = @_;
    return undef if !defined $expr_code || $expr_code eq '';

    if ($decl_type eq 'number_list') {
        return "metac_free_number_list($var_name)"
          if $expr_code =~ /\bmetac_(?:number_list_from_array|filter_number_list|matrix_number_neighbours|slice_number_list)\s*\(/;
        return undef;
    }
    if ($decl_type eq 'number_list_list') {
        return "metac_free_number_list_list($var_name)"
          if $expr_code =~ /\bmetac_(?:number_list_list_from_array|sort_number_list_list_by)\s*\(/;
        return undef;
    }
    if ($decl_type eq 'bool_list') {
        return "metac_free_bool_list($var_name)"
          if $expr_code =~ /\bmetac_bool_list_from_array\s*\(/;
        return undef;
    }
    if ($decl_type eq 'string_list') {
        return "metac_free_string_list($var_name, 1)"
          if $expr_code =~ /\bmetac_(?:chars_string|chunk_string|string_list_from_array)\s*\(/;
        return "metac_free_string_list($var_name, 0)"
          if $expr_code =~ /\bmetac_(?:filter_string_list|matrix_string_neighbours|slice_string_list)\s*\(/;
        return undef;
    }
    if ($decl_type eq 'indexed_number_list') {
        return "metac_free_indexed_number_list($var_name)"
          if $expr_code =~ /\bmetac_sort_number_list\s*\(/;
        return undef;
    }
    if (is_matrix_member_list_type($decl_type)) {
        my $meta = matrix_member_list_meta($decl_type);
        return "metac_free_matrix_number_member_list($var_name)"
          if $meta->{elem} eq 'number'
          && $expr_code =~ /\bmetac_(?:matrix_number_members|filter_matrix_number_member_list)\s*\(/;
        return "metac_free_matrix_string_member_list($var_name)"
          if $meta->{elem} eq 'string'
          && $expr_code =~ /\bmetac_(?:matrix_string_members|filter_matrix_string_member_list)\s*\(/;
        return undef;
    }
    if (is_matrix_type($decl_type)) {
        my $meta = matrix_type_meta($decl_type);
        return "metac_free_matrix_number(&$var_name)"
          if $meta->{elem} eq 'number'
          && $expr_code =~ /\bmetac_matrix_number_new\s*\(/;
        return "metac_free_matrix_string(&$var_name)"
          if $meta->{elem} eq 'string'
          && $expr_code =~ /\bmetac_matrix_string_new\s*\(/;
        return undef;
    }
    return undef;
}

sub maybe_register_owned_cleanup_for_decl {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $var_name = $args{var_name};
    my $decl_type = $args{decl_type};
    my $expr_code = $args{expr_code};
    my $cleanup = _cleanup_call_for_expr_type_and_source($var_name, $decl_type, $expr_code);
    _register_owned_cleanup($ctx, $var_name, $cleanup) if defined $cleanup;
}

sub cleanup_call_for_temp_expr {
    my (%args) = @_;
    my $var_name = $args{var_name};
    my $decl_type = $args{decl_type};
    my $expr_code = $args{expr_code};
    return _cleanup_call_for_expr_type_and_source($var_name, $decl_type, $expr_code);
}

sub _expr_temp_decl_line {
    my (%args) = @_;
    my $var_name = $args{var_name};
    my $expr_type = $args{expr_type};
    my $expr_code = $args{expr_code};

    return "NumberList $var_name = $expr_code;" if $expr_type eq 'number_list';
    return "NumberListList $var_name = $expr_code;" if $expr_type eq 'number_list_list';
    return "BoolList $var_name = $expr_code;" if $expr_type eq 'bool_list';
    return "StringList $var_name = $expr_code;" if $expr_type eq 'string_list';
    return "IndexedNumberList $var_name = $expr_code;" if $expr_type eq 'indexed_number_list';
    if (is_matrix_type($expr_type)) {
        my $meta = matrix_type_meta($expr_type);
        return "MatrixNumber $var_name = $expr_code;" if $meta->{elem} eq 'number';
        return "MatrixString $var_name = $expr_code;" if $meta->{elem} eq 'string';
        return undef;
    }
    if (is_matrix_member_list_type($expr_type)) {
        my $meta = matrix_member_list_meta($expr_type);
        return "MatrixNumberMemberList $var_name = $expr_code;" if $meta->{elem} eq 'number';
        return "MatrixStringMemberList $var_name = $expr_code;" if $meta->{elem} eq 'string';
        return undef;
    }
    return undef;
}

sub expr_temp_scope_active {
    my ($ctx) = @_;
    return 0 if !defined $ctx->{expr_temp_scopes};
    return @{ $ctx->{expr_temp_scopes} } > 0;
}

sub begin_expr_temp_scope {
    my ($ctx) = @_;
    $ctx->{expr_temp_scopes} = [] if !defined $ctx->{expr_temp_scopes};
    push @{ $ctx->{expr_temp_scopes} }, {
        prelude => [],
        entries => [],
    };
}

sub end_expr_temp_scope {
    my ($ctx) = @_;
    return { prelude => [], entries => [] }
      if !defined $ctx->{expr_temp_scopes} || !@{ $ctx->{expr_temp_scopes} };
    return pop @{ $ctx->{expr_temp_scopes} };
}

sub maybe_materialize_owned_expr_result {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $expr_code = $args{expr_code};
    my $expr_type = $args{expr_type};

    return ($expr_code, $expr_type, undef) if !expr_temp_scope_active($ctx);
    my $tmp = '__metac_expr_tmp' . $ctx->{tmp_counter}++;
    my $decl_line = _expr_temp_decl_line(
        var_name  => $tmp,
        expr_type => $expr_type,
        expr_code => $expr_code,
    );
    return ($expr_code, $expr_type, undef) if !defined $decl_line;
    my $cleanup = cleanup_call_for_temp_expr(
        var_name  => $tmp,
        decl_type => $expr_type,
        expr_code => $expr_code,
    );
    return ($expr_code, $expr_type, undef) if !defined $cleanup;

    my $scope = $ctx->{expr_temp_scopes}[-1];
    push @{ $scope->{prelude} }, $decl_line;
    push @{ $scope->{entries} }, {
        var_name     => $tmp,
        cleanup_call => $cleanup,
        decl_line    => $decl_line,
    };

    return ($tmp, $expr_type, {
        owned_temp_var  => $tmp,
        owned_decl_line => $decl_line,
        owned_expr_code => $expr_code,
    });
}

sub _cleanups_for_expr_temp_scope {
    my ($scope, $transfer_var) = @_;
    my @entries = @{ $scope->{entries} // [] };
    if (defined $transfer_var && $transfer_var ne '') {
        @entries = grep { (($_->{var_name}) // '') ne $transfer_var } @entries;
    }
    my @cleanups = map { $_->{cleanup_call} }
      reverse grep { defined $_->{cleanup_call} && $_->{cleanup_call} ne '' } @entries;
    return \@cleanups;
}

sub compile_expr_with_temp_scope {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $expr = $args{expr};
    my $transfer_root_ownership = $args{transfer_root_ownership} ? 1 : 0;

    begin_expr_temp_scope($ctx);
    my ($expr_code, $expr_type, $meta) = compile_expr($expr, $ctx);
    my $scope = end_expr_temp_scope($ctx);
    my @prelude = @{ $scope->{prelude} // [] };
    my $transfer_var = $transfer_root_ownership && defined($meta) ? ($meta->{owned_temp_var} // '') : '';
    if ($transfer_root_ownership && defined($meta) && ($meta->{owned_expr_code} // '') ne '') {
        $expr_code = $meta->{owned_expr_code};
        my $owned_decl = $meta->{owned_decl_line} // '';
        if ($owned_decl ne '') {
            @prelude = grep { $_ ne $owned_decl } @prelude;
        }
    }
    my $cleanups = _cleanups_for_expr_temp_scope($scope, $transfer_var);
    return ($expr_code, $expr_type, \@prelude, $cleanups);
}

sub emit_expr_temp_prelude {
    my ($out, $indent, $prelude) = @_;
    return if !defined $prelude;
    for my $line (@$prelude) {
        emit_line($out, $indent, $line);
    }
}

sub emit_expr_temp_cleanups {
    my ($out, $indent, $cleanups) = @_;
    return if !defined $cleanups;
    for my $cleanup (@$cleanups) {
        emit_line($out, $indent, $cleanup . ';');
    }
}

sub push_active_temp_cleanups {
    my ($ctx, $cleanups) = @_;
    return 0 if !defined $cleanups || !@$cleanups;
    $ctx->{active_temp_cleanups} = [] if !defined $ctx->{active_temp_cleanups};
    push @{ $ctx->{active_temp_cleanups} }, @$cleanups;
    return scalar @$cleanups;
}

sub pop_active_temp_cleanups {
    my ($ctx, $count) = @_;
    return if !defined $count || $count <= 0;
    return if !defined $ctx->{active_temp_cleanups};
    for (my $i = 0; $i < $count; $i++) {
        pop @{ $ctx->{active_temp_cleanups} };
    }
}

sub emit_scope_owned_cleanups {
    my ($ctx, $out, $indent) = @_;
    return if !defined $ctx->{ownership_scopes} || !@{ $ctx->{ownership_scopes} };
    my $scope = $ctx->{ownership_scopes}[-1];
    return if !defined $scope || !@$scope;
    for (my $i = $#$scope; $i >= 0; $i--) {
        emit_line($out, $indent, $scope->[$i]{cleanup_call} . ';');
    }
}

sub emit_all_owned_cleanups {
    my ($ctx, $out, $indent) = @_;
    return if !defined $ctx->{ownership_scopes};
    for (my $s = $#{ $ctx->{ownership_scopes} }; $s >= 0; $s--) {
        my $scope = $ctx->{ownership_scopes}[$s];
        next if !defined $scope || !@$scope;
        for (my $i = $#$scope; $i >= 0; $i--) {
            emit_line($out, $indent, $scope->[$i]{cleanup_call} . ';');
        }
    }
}

sub consume_owned_cleanup_for_var {
    my ($ctx, $var_name) = @_;
    return if !defined $ctx->{ownership_scopes};
    return if !defined $var_name || $var_name eq '';
    for (my $s = $#{ $ctx->{ownership_scopes} }; $s >= 0; $s--) {
        my $scope = $ctx->{ownership_scopes}[$s];
        next if !defined $scope || !@$scope;
        for (my $i = $#$scope; $i >= 0; $i--) {
            if (($scope->[$i]{var_name} // '') eq $var_name) {
                splice @$scope, $i, 1;
                return;
            }
        }
    }
}

sub close_codegen_scope {
    my ($ctx, $out, $indent) = @_;
    emit_scope_owned_cleanups($ctx, $out, $indent);
    pop_scope($ctx);
}

1;
