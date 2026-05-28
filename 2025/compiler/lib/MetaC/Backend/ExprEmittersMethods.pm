package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_method_match {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'method_match');
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'error_flag');
                return 'metac_method_match(' . $recv . ', ' . ($args[0] // '""') . ')';
            
}

sub _emit_method_split {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_split(' . $recv . ', ' . ($args[0] // '""') . ')';
            
}

sub _emit_method_compareTo {
    return undef;
}

sub _emit_method_andThen {
    return undef;
}

sub _emit_method_chars {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'method_chars');
                return "metac_method_chars($recv)";
            
}

sub _emit_method_chunk {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'method_chunk');
                return 'metac_method_chunk(' . $recv . ', ' . ($args[0] // '0') . ')';
            
}

sub _emit_method_isBlank {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'method_isblank');
                return "metac_method_isblank($recv)";
            
}

sub _emit_method_size {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix</
                    && defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident')
                {
                    my $rname = $recv_expr->{name} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    if ($mvar ne '') {
                        _helper_mark($ctx, 'matrix_meta');
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_matrix_axis_size(&' . $mvar . ', ' . ($args[0] // '0') . ')';
                    }
                }
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_list_i64') {
                        _helper_mark($ctx, 'list_list_i64');
                        return 'metac_list_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                    my $src_type = $ctx->{var_source_types}{ $recv_expr->{name} // '' } // '';
                    my $ops = c_type_collection_ops_for_type($src_type);
                    if (defined($ops) && ref($ops) eq 'HASH') {
                        _mark_type_helpers($ctx, $src_type);
                        return $ops->{size} . '(&' . $recv_expr->{name} . ')';
                    }
                }
                if (defined($meta->{receiver_type_hint}) && _is_array_type($meta->{receiver_type_hint})) {
                    if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                        if (_is_string_array_type($meta->{receiver_type_hint})) {
                            _helper_mark($ctx, 'list_str');
                            return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                        }
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'list_i64_size_value');
                    return "metac_list_i64_size_value($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_str_size_value');
                    return "metac_list_str_size_value($recv)";
                }
                _helper_mark($ctx, 'method_size');
                return "metac_method_size($recv)";
            
}

sub _emit_method_push {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'list_list_i64');
                        return 'metac_list_list_i64_push(&' . $recv_expr->{name} . ', ' . ($args[0] // 'metac_list_i64_empty()') . ')';
                    }
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'list_str_push');
                        return 'metac_list_str_push(&' . $recv_expr->{name} . ', ' . ($args[0] // '""') . ')';
                    }
                    my $src_type = $ctx->{var_source_types}{ $recv_expr->{name} // '' } // '';
                    my $ops = c_type_collection_ops_for_type($src_type);
                    if (defined($ops) && ref($ops) eq 'HASH') {
                        _mark_type_helpers($ctx, $src_type);
                        return $ops->{push} . '(&' . $recv_expr->{name} . ', ' . ($args[0] // $ops->{elem_default}) . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_push(&' . $recv_expr->{name} . ', ' . ($args[0] // '0') . ')';
                }
                _helper_mark($ctx, 'method_push');
                return 'metac_method_push(' . $recv . ', ' . ($args[0] // '0') . ')';
            
}

sub _emit_method_last {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'last_value_str');
                        return 'metac_builtin_last_value_str(' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'last_value_i64');
                        return 'metac_builtin_last_value_i64(' . $recv_expr->{name} . ')';
                    }
                }
            
}

sub _emit_method_max {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'member_index');
                        _helper_mark($ctx, 'method_max_str');
                        return 'metac_method_max_str(&' . $rname . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'member_index');
                        _helper_mark($ctx, 'method_max_i64');
                        return 'metac_method_max_i64(&' . $rname . ')';
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'member_index');
                    _helper_mark($ctx, 'method_max_str');
                    _helper_mark($ctx, 'method_max_str_value');
                    return 'metac_method_max_str_value(' . $recv . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'member_index');
                    _helper_mark($ctx, 'method_max_i64');
                    _helper_mark($ctx, 'method_max_i64_value');
                    return 'metac_method_max_i64_value(' . $recv . ')';
                }
            
}

sub _emit_method_slice {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $start = $args[0] // '0';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'method_slice_str');
                        return 'metac_method_slice_str(&' . $rname . ', ' . $start . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_slice_i64');
                    return 'metac_method_slice_i64(&' . $rname . ', ' . $start . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_slice_str');
                    _helper_mark($ctx, 'method_slice_str_value');
                    return 'metac_method_slice_str_value(' . $recv . ', ' . $start . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_slice_i64');
                _helper_mark($ctx, 'method_slice_i64_value');
                return 'metac_method_slice_i64_value(' . $recv . ', ' . $start . ')';
            
}

sub _emit_method_index {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $name = $recv_expr->{name} // '';
                    my $idx_expr = $ctx->{loop_item_index_expr}{$name};
                    return $idx_expr if defined $idx_expr && $idx_expr ne '';
                }
                if (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix_member</) {
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_empty()';
                }
                _helper_mark($ctx, 'member_index');
                return 'metac_last_member_index';
            
}

sub _emit_method_members {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_members');
                    return "metac_method_members_str($recv)";
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_members');
                return "metac_method_members($recv)";
            
}

sub _emit_method_insert {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $dispatched = _emit_insert_call_by_registry(
                    meta => $meta,
                    recv_expr => $recv_expr,
                    recv => $recv,
                    call_args => \@args,
                    ctx => $ctx,
                );
                return $dispatched if defined($dispatched) && $dispatched ne '';
                my $idx_hint = _expr_c_type_hint($expr->{args}[1], $ctx);
                my $is_matrix_idx = defined($idx_hint) && $idx_hint eq 'struct metac_list_i64' ? 1 : 0;
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                my $is_matrix_recv = (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix</) ? 1 : 0;
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name};
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'method_insert');
                        if ($is_matrix_idx) {
                            if ($is_matrix_recv && $mvar ne '') {
                                _helper_mark($ctx, 'matrix_meta');
                                _helper_mark($ctx, 'list_i64');
                                return 'metac_method_insert_str_matrix_meta(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $mvar . ')';
                            }
                            return 'metac_method_insert_str_matrix(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                        }
                        return 'metac_method_insert_str(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // '0') . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_insert');
                    if ($is_matrix_idx) {
                        if ($is_matrix_recv && $mvar ne '') {
                            _helper_mark($ctx, 'matrix_meta');
                            return 'metac_method_insert_i64_matrix_meta(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $mvar . ')';
                        }
                        return 'metac_method_insert_i64_matrix(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                    }
                    return 'metac_method_insert_i64(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_insert');
                    if ($is_matrix_idx) {
                        my $src_ident = _root_ident_name($recv_expr);
                        my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                        if ($src_mvar ne '' && $is_matrix_recv) {
                            _helper_mark($ctx, 'matrix_meta');
                            return 'metac_method_insert_str_matrix_meta_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $src_mvar . ')';
                        }
                        return 'metac_method_insert_str_matrix_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                    }
                    return 'metac_method_insert_str_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // '0') . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_insert');
                if ($is_matrix_idx) {
                    my $src_ident = _root_ident_name($recv_expr);
                    my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                    if ($src_mvar ne '' && $is_matrix_recv) {
                        _helper_mark($ctx, 'matrix_meta');
                        return 'metac_method_insert_i64_matrix_meta_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $src_mvar . ')';
                    }
                    return 'metac_method_insert_i64_matrix_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                }
                return 'metac_method_insert_i64_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
            
}

sub _emit_method_at {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $idx = $args[0] // 'metac_list_i64_empty()';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    return ($rty eq 'struct metac_list_str') ? '""' : '0' if $mvar eq '';
                    _helper_mark($ctx, 'method_at');
                    _helper_mark($ctx, 'matrix_meta');
                    _helper_mark($ctx, 'list_i64');
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_method_at_str_matrix_meta(&' . $rname . ', ' . $idx . ', &' . $mvar . ')';
                    }
                    return 'metac_method_at_i64_matrix_meta(&' . $rname . ', ' . $idx . ', &' . $mvar . ')';
                }
                my $src_ident = _root_ident_name($recv_expr);
                my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                return (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') ? '""' : '0'
                  if $src_mvar eq '';
                _helper_mark($ctx, 'method_at');
                _helper_mark($ctx, 'matrix_meta');
                _helper_mark($ctx, 'list_i64');
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    return 'metac_method_at_str_matrix_meta_value(' . $recv . ', ' . $idx . ', &' . $src_mvar . ')';
                }
                return 'metac_method_at_i64_matrix_meta_value(' . $recv . ', ' . $idx . ', &' . $src_mvar . ')';
            
}

sub _emit_method_log {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $from_c = _emit_log_call_for_c_type($recv, $recv_hint, $ctx);
                return $from_c if defined($from_c);
                _helper_mark($ctx, 'log_i64');
                return "metac_builtin_log_i64($recv)";
            
}

sub _emit_method_count {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_count_str');
                    return "metac_method_count_str($recv)";
                }
                _helper_mark($ctx, 'method_count');
                return "metac_method_count($recv)";
            
}

sub _emit_method_neighbours {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'const char *') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_neighbours_str');
                    return 'metac_method_neighbours_str(' . $recv . ')';
                }
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if ($receiver_type_hint =~ /^matrix</) {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_neighbours_i64');
                    return 'metac_method_neighbours_i64(' . $recv . ', ' . ($args[0] // 'metac_list_i64_empty()') . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_neighbours_i64');
                return 'metac_method_neighbours_i64_value(' . $recv . ')';
            
}

sub _emit_method_sort {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'sort_i64');
                    return 'metac_sort_i64_with_index(' . $recv . ')';
                }
                return $recv;
            
}

sub _emit_method_sortBy {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'list_list_i64');
                    _helper_mark($ctx, 'method_sortby_pair');
                    return 'metac_method_sortby_pair_lex(' . $recv . ')';
                }
                return $recv;
            
}

1;
