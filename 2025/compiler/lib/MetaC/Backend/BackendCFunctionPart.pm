package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _matrix_meta_source_name_expr {
    my ($expr) = @_;
    return '' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return $expr->{name} // '' if $k eq 'ident';
    if ($k eq 'method_call') {
        return _matrix_meta_source_name_expr($expr->{recv});
    }
    return '';
}

sub _emit_exit {
    my ($exit, $out, $indent, $default_return, $ctx, $fn_name) = @_;
    my $sp = ' ' x $indent;
    my $k = $exit->{kind} // '';

    if ($k eq 'Goto') {
        my $to = $exit->{target_region} // '__missing_region';
        push @$out, "${sp}goto region_$to;";
        return;
    }
    if ($k eq 'IfExit') {
        my $cond = _expr_to_c($exit->{cond_value}, $ctx);
        my $t = $exit->{then_region} // '__missing_region';
        my $e = $exit->{else_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$t;";
        push @$out, "${sp}goto region_$e;";
        return;
    }
    if ($k eq 'WhileExit') {
        my $cond = _expr_to_c($exit->{cond_value}, $ctx);
        my $b = $exit->{body_region} // '__missing_region';
        my $n = $exit->{end_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$b;";
        push @$out, "${sp}goto region_$n;";
        return;
    }
    if ($k eq 'ForInExit') {
        my $loop = $exit->{loop_id} // 'L0';
        my $item = $exit->{item_name} // '__item';
        my $body = $exit->{body_region} // '__missing_region';
        my $end = $exit->{end_region} // '__missing_region';
        my $iter = $exit->{iterable_expr};
        my $loop_meta = $ctx->{loop_meta}{$loop} // {};
        my $iter_ty = $loop_meta->{iter_c_type} // 'struct metac_list_i64';
        my $iter_c = _expr_to_c($iter, $ctx);
        push @$out, "${sp}if (!__loop_init_$loop) {";
        push @$out, "${sp}  __loop_init_$loop = 1;";
        push @$out, "${sp}  __loop_idx_$loop = 0;";
        push @$out, "${sp}  __loop_iter_$loop = $iter_c;";
        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}  __loop_len_$loop = metac_list_str_size(&__loop_iter_$loop);";
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            push @$out, "${sp}  __loop_len_$loop = metac_list_list_i64_size(&__loop_iter_$loop);";
        } else {
            _helper_mark($ctx, 'list_i64');
            push @$out, "${sp}  __loop_len_$loop = metac_list_i64_size(&__loop_iter_$loop);";
        }
        push @$out, "${sp}}";
        push @$out, "${sp}if (__loop_idx_$loop < __loop_len_$loop) {";
        if ($iter_ty eq 'struct metac_list_str') {
            push @$out, "${sp}  $item = metac_list_str_get(&__loop_iter_$loop, __loop_idx_$loop);";
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            push @$out, "${sp}  $item = metac_list_list_i64_get(&__loop_iter_$loop, __loop_idx_$loop);";
        } else {
            push @$out, "${sp}  $item = metac_list_i64_get(&__loop_iter_$loop, __loop_idx_$loop);";
        }
        push @$out, "${sp}  __loop_idx_$loop++;";
        push @$out, "${sp}  goto region_$body;";
        push @$out, "${sp}}";
        push @$out, "${sp}__loop_init_$loop = 0;";
        push @$out, "${sp}goto region_$end;";
        return;
    }
    if ($k eq 'TryExit') {
        my $ok = $exit->{ok_region} // '__missing_region';
        my $err = $exit->{err_region} // '__missing_region';
        push @$out, "${sp}if (metac_last_error) {";
        push @$out, "${sp}  metac_last_error = 0;";
        push @$out, "${sp}  goto region_$err;";
        push @$out, "${sp}}";
        push @$out, "${sp}goto region_$ok;";
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'Return') {
        my $rv = $exit->{value};
        if (($fn_name // '') eq 'main') {
            _helper_mark($ctx, 'error_flag');
            if (defined($rv)) {
                my $tmp = '__main_ret_exit_' . ($ctx->{tmp_counter}++);
                push @$out, "${sp}int $tmp = " . _expr_to_c($rv, $ctx) . ';';
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $tmp;";
            } else {
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $default_return;";
            }
            return;
        }
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv, $ctx) . ';') : ($sp . "return $default_return;");
        return;
    }
    if ($k eq 'PropagateError') {
        if (($fn_name // '') eq 'main') {
            push @$out, "${sp}return 2;";
        } else {
            _helper_mark($ctx, 'error_flag');
            push @$out, "${sp}metac_last_error = 1;";
            push @$out, "${sp}return $default_return;";
        }
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing exit emitter for kind '$k' */};
}

sub _collect_forin_loops {
    my ($ordered_regions, $seed_var_types, $seed_matrix_meta) = @_;
    my %var_types = %{ $seed_var_types // {} };
    my %matrix_meta_vars = %{ $seed_matrix_meta // {} };
    my $tmp_ctx = { var_types => \%var_types };
    my %seen;
    my @loops;
    for my $region (@{ $ordered_regions // [] }) {
        for my $step (@{ $region->{steps} // [] }) {
            my $stmt = step_payload_to_stmt($step->{payload});
            next if !defined($stmt) || ref($stmt) ne 'HASH';
            my $k = $stmt->{kind} // '';
            if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed' || $k eq 'const_try_expr' || $k eq 'const_or_catch') {
                my $name = $stmt->{name} // '';
                next if $name eq '';
                my $expr = $stmt->{expr};
                my $inferred = _expr_c_type_hint($expr, $tmp_ctx);
                my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
                $var_types{$name} = $c_ty;
                my $mmeta = _matrix_meta_for_type($stmt->{type});
                if (defined($mmeta) && ref($mmeta) eq 'HASH') {
                    $matrix_meta_vars{$name} = _matrix_meta_var_name($name);
                } else {
                    my $src_name = _matrix_meta_source_name_expr($expr);
                    my $src_mvar = $matrix_meta_vars{$src_name} // '';
                    $matrix_meta_vars{$name} = $src_mvar if $src_mvar ne '';
                }
                next;
            }
            if ($k eq 'const_try_tail_expr') {
                my $name = $stmt->{name} // '';
                next if $name eq '';
                my $first_ty = _expr_c_type_hint($stmt->{first}, $tmp_ctx) // 'int64_t';
                my $cur_name = '__try_tail_probe_' . ($name // 'v');
                my $cur_ty = $first_ty;
                for my $chain (@{ $stmt->{steps} // [] }) {
                    next if !defined($chain) || ref($chain) ne 'HASH';
                    $var_types{$cur_name} = $cur_ty;
                    my $mexpr = {
                        kind => 'method_call',
                        method => ($chain->{name} // ''),
                        recv => { kind => 'ident', name => $cur_name },
                        args => $chain->{args} // [],
                        resolved_call => $chain->{resolved_call},
                        canonical_call => $chain->{canonical_call},
                    };
                    $cur_ty = _expr_c_type_hint($mexpr, $tmp_ctx) // $cur_ty;
                    $cur_name .= '_n';
                }
                my $c_ty = _type_to_c($stmt->{type}, $cur_ty // 'int64_t');
                $var_types{$name} = $c_ty;
                next;
            }
            if ($k eq 'destructure_list') {
                my $src = $stmt->{expr};
                next if !defined($src) || ref($src) ne 'HASH' || ($src->{kind} // '') ne 'ident';
                my $src_name = $src->{name} // '';
                my $src_ty = $var_types{$src_name} // '';
                my $item_ty = $src_ty eq 'struct metac_list_str' ? 'const char *' : 'int64_t';
                for my $v (@{ $stmt->{vars} // [] }) {
                    next if !defined($v) || $v eq '';
                    $var_types{$v} = $item_ty;
                }
            }
        }

        my $exit = $region->{exit} // {};
        next if ($exit->{kind} // '') ne 'ForInExit';
        my $id = $exit->{loop_id} // '';
        next if $id eq '' || $seen{$id}++;
        my $iter_ty = _expr_c_type_hint($exit->{iterable_expr}, $tmp_ctx);
        my $index_expr;
        if (!defined($iter_ty) || $iter_ty eq '') {
            my $iter = $exit->{iterable_expr};
            if (defined($iter) && ref($iter) eq 'HASH') {
                my $resolved = $iter->{resolved_call};
                my $canonical = $iter->{canonical_call};
                my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
                  : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
                $iter_ty = _result_type_to_c($meta->{result_type});
            }
        }
        $iter_ty = 'struct metac_list_i64' if !defined($iter_ty) || $iter_ty eq '';
        my $iter_expr = $exit->{iterable_expr};
        if (defined($iter_expr) && ref($iter_expr) eq 'HASH') {
            my $resolved = $iter_expr->{resolved_call};
            my $canonical = $iter_expr->{canonical_call};
            my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
              : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
            my $op_id = $meta->{op_id} // '';
            if ($op_id eq 'method.sort.v1') {
                $index_expr = "metac_sort_index_at(__loop_idx_$id - 1)";
            }
            if ($op_id eq 'method.members.v1') {
                my $recv = $iter_expr->{recv};
                my $recv_name = (defined($recv) && ref($recv) eq 'HASH' && ($recv->{kind} // '') eq 'ident')
                  ? ($recv->{name} // '')
                  : '';
                my $recv_hint = $meta->{receiver_type_hint} // '';
                if ($recv_name ne '' && defined($recv_hint) && $recv_hint =~ /^matrix</) {
                    my $mvar = $matrix_meta_vars{$recv_name} // '';
                    if ($mvar ne '') {
                        $index_expr = "metac_matrix_member_index_at(&$mvar, (__loop_idx_$id - 1))";
                    }
                }
            }
        }
        my $item_ty = $iter_ty eq 'struct metac_list_str' ? 'const char *'
          : ($iter_ty eq 'struct metac_list_list_i64' ? 'struct metac_list_i64' : 'int64_t');
        my $item_name = $exit->{item_name} // '__item';
        push @loops, {
            loop_id => $id,
            item_name => $item_name,
            iter_c_type => $iter_ty,
            item_c_type => $item_ty,
            index_expr => $index_expr,
        };
        $var_types{$item_name} = $item_ty if defined($item_name) && $item_name ne '';
    }
    return \@loops;
}

sub _emit_function {
    my ($fn) = @_;
    my @out;
    my $name = $fn->{name} // '__missing_fn_name';
    my $ret_type = $name eq 'main' ? 'int' : _type_to_c($fn->{return_type}, 'int64_t');
    my $default_return = _default_return_for_c_type($ret_type);
    my @params;
    for my $p (@{ $fn->{params} // [] }) {
        my $pn = $p->{name} // 'p';
        my $pt = _type_to_c($p->{type}, 'int64_t');
        push @params, "$pt $pn";
    }
    my $param_sig = @params ? join(', ', @params) : 'void';
    push @out, "$ret_type $name($param_sig) {";

    my $ctx = {
        helpers => {},
        var_types => {},
        var_constraints => {},
        matrix_meta_vars => {},
        generated_globals => {},
        generated_globals_order => [],
        generated_callbacks => [],
        callback_counter => 0,
        fn_default_return => $default_return,
        fn_c_return_type => $ret_type,
        fn_name => $name,
    };
    _helper_mark($ctx, 'list_i64') if $ret_type eq 'struct metac_list_i64';
    _helper_mark($ctx, 'list_str') if $ret_type eq 'struct metac_list_str';
    if ($ret_type eq 'struct metac_list_list_i64') {
        _helper_mark($ctx, 'list_i64');
        _helper_mark($ctx, 'list_list_i64');
    }
    for my $p (@{ $fn->{params} // [] }) {
        my $pn = $p->{name} // '';
        next if $pn eq '';
        my $pt = _type_to_c($p->{type}, 'int64_t');
        $ctx->{var_types}{$pn} = $pt;
        $ctx->{var_constraints}{$pn} = $p->{constraints} if defined($p->{constraints});
        _helper_mark($ctx, 'list_i64') if $pt eq 'struct metac_list_i64';
        _helper_mark($ctx, 'list_str') if $pt eq 'struct metac_list_str';
        if ($pt eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
        }
        my $mmeta = _matrix_meta_for_type($p->{type});
        if (defined($mmeta) && ref($mmeta) eq 'HASH') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'matrix_meta');
            my $mvar = _matrix_meta_var_name($pn);
            $ctx->{matrix_meta_vars}{$pn} = $mvar;
            my $dim = int($mmeta->{dim} // 0);
            my $has_size = ($mmeta->{has_size} // 0) ? 1 : 0;
            my @sizes = @{ $mmeta->{sizes} // [] };
            if (!$has_size || @sizes != $dim) {
                @sizes = map { -1 } (1 .. $dim);
            }
            my $sizes_c = @sizes ? join(', ', @sizes) : '-1';
            my $base = "metac_matrix_meta_init($dim, (int64_t[]){$sizes_c}, " . ($has_size ? 1 : 0) . ')';
            my $init = "metac_take_last_matrix_meta($base)";
            push @out, "  struct metac_matrix_meta $mvar = $init;";
        }
    }

    my $regions = $fn->{regions} // [];
    my $schedule = $fn->{region_schedule};
    my @ordered_regions;
    if (defined($schedule) && ref($schedule) eq 'ARRAY' && @$schedule) {
        my %by_id = map { ($_->{id} // '') => $_ } @$regions;
        my %seen;
        @ordered_regions = map { $seen{$_} = 1; $by_id{$_} } grep { exists $by_id{$_} } @$schedule;
        push @ordered_regions, grep { !$seen{ $_->{id} // '' } } @$regions;
    } else {
        @ordered_regions = @$regions;
    }
    my %regions_by_id = map { (($_->{id} // '') => $_) } @ordered_regions;

    my $loops = _collect_forin_loops(\@ordered_regions, $ctx->{var_types}, $ctx->{matrix_meta_vars});
    $ctx->{loop_meta} = { map { ($_->{loop_id} // '') => $_ } @$loops };
    for my $loop (@$loops) {
        my $lid = $loop->{loop_id};
        my $item = $loop->{item_name};
        my $iter_ty = $loop->{iter_c_type} // 'struct metac_list_i64';
        my $item_ty = $loop->{item_c_type} // 'int64_t';
        my $iter_init = 'metac_list_i64_empty()';
        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            $iter_init = 'metac_list_str_empty()';
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            $iter_init = 'metac_list_list_i64_empty()';
        } else {
            _helper_mark($ctx, 'list_i64');
        }
        push @out, "  int __loop_init_$lid = 0;";
        push @out, "  int64_t __loop_idx_$lid = 0;";
        push @out, "  int64_t __loop_len_$lid = 0;";
        push @out, "  $iter_ty __loop_iter_$lid = $iter_init;";
        if ($item_ty eq 'const char *') {
            push @out, qq{  const char *$item = "";};
        } elsif ($item_ty eq 'struct metac_list_i64') {
            _helper_mark($ctx, 'list_i64');
            push @out, "  struct metac_list_i64 $item = metac_list_i64_empty();";
        } else {
            push @out, "  int64_t $item = 0;";
        }
        $ctx->{var_types}{$item} = $item_ty;
        my $idx_expr = $loop->{index_expr};
        if (defined($idx_expr) && $idx_expr ne '') {
            if ($idx_expr =~ /metac_sort_index_at/) {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'sort_i64');
            }
            if ($idx_expr =~ /metac_matrix_axis_size/) {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'matrix_meta');
            }
            if ($idx_expr =~ /metac_matrix_member_index_at/) {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'matrix_meta');
            }
            $ctx->{loop_item_index_expr}{$item} = $idx_expr;
        } else {
            $ctx->{loop_item_index_expr}{$item} = "(__loop_idx_$lid - 1)";
        }
    }
    $ctx->{loop_ids} = [ map { $_->{loop_id} } @$loops ];

    my %seen_decl;
    for my $region (@ordered_regions) {
        my $rid = $region->{id} // '__missing_region';
        my $exit_kind = $region->{exit}{kind} // '';
        $ctx->{current_region_exit_kind} = $exit_kind;
        $ctx->{current_region_exit_target} = ($exit_kind eq 'Goto') ? ($region->{exit}{target_region}) : undef;
        push @out, "region_$rid: ;";
        my @steps = @{ $region->{steps} // [] };
        my @stmts = map { step_payload_to_stmt($_->{payload}) } @steps;
        if ($exit_kind eq 'IfExit' && @stmts) {
            my $if_idx = -1;
            for my $i (0 .. $#stmts) {
                my $stmt = $stmts[$i];
                next if !defined($stmt) || ref($stmt) ne 'HASH';
                if (($stmt->{kind} // '') eq 'if') {
                    $if_idx = $i;
                    last;
                }
            }
            if ($if_idx >= 0 && $if_idx < $#stmts) {
                for my $i (0 .. $if_idx - 1) {
                    my $stmt = $stmts[$i];
                    if (!defined $stmt) {
                        push @out, '  /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 2, \%seen_decl, 0, $ctx);
                }
                my $cond = _expr_to_c($region->{exit}{cond_value}, $ctx);
                my $then_region = $region->{exit}{then_region} // '__missing_region';
                my $else_region = $region->{exit}{else_region} // '__missing_region';
                my $then_target = $then_region;
                my $else_target = $else_region;
                my $then_node = $regions_by_id{$then_region};
                my $else_node = $regions_by_id{$else_region};
                if (defined($then_node) && ref($then_node) eq 'HASH' && (($then_node->{exit}{kind} // '') eq 'Goto')) {
                    $then_target = $then_node->{exit}{target_region} // $then_region;
                }
                if (defined($else_node) && ref($else_node) eq 'HASH' && (($else_node->{exit}{kind} // '') eq 'Goto')) {
                    $else_target = $else_node->{exit}{target_region} // $else_region;
                }
                my @trailing = @stmts[$if_idx + 1 .. $#stmts];
                my $if_stmt = $stmts[$if_idx];
                my $then_body = (defined($if_stmt) && ref($if_stmt) eq 'HASH') ? ($if_stmt->{then_body} // []) : [];
                my $else_body = (defined($if_stmt) && ref($if_stmt) eq 'HASH') ? ($if_stmt->{else_body} // []) : [];
                my %then_seen_decl = %seen_decl;
                my %else_seen_decl = %seen_decl;

                push @out, "  if ($cond) {";
                my $saved_kind = $ctx->{current_region_exit_kind};
                my $saved_target = $ctx->{current_region_exit_target};
                $ctx->{current_region_exit_kind} = 'Goto';
                $ctx->{current_region_exit_target} = $then_target;
                for my $stmt (@$then_body) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%then_seen_decl, 0, $ctx);
                }
                if (defined($then_target) && defined($else_target) && $then_target eq $else_target) {
                    for my $stmt (@trailing) {
                        if (!defined $stmt) {
                            push @out, '    /* Backend/F054 missing payload decode for step */';
                            next;
                        }
                        _emit_stmt($stmt, \@out, 4, \%then_seen_decl, 0, $ctx);
                    }
                }
                push @out, "    goto region_$then_target;";
                push @out, "  } else {";
                $ctx->{current_region_exit_kind} = 'Goto';
                $ctx->{current_region_exit_target} = $else_target;
                for my $stmt (@$else_body) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%else_seen_decl, 0, $ctx);
                }
                for my $stmt (@trailing) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%else_seen_decl, 0, $ctx);
                }
                push @out, "    goto region_$else_target;";
                push @out, "  }";
                $ctx->{current_region_exit_kind} = $saved_kind;
                $ctx->{current_region_exit_target} = $saved_target;
                next;
            }
        }
        for my $stmt (@stmts) {
            if (!defined $stmt) {
                push @out, '  /* Backend/F054 missing payload decode for step */';
                next;
            }
            _emit_stmt($stmt, \@out, 2, \%seen_decl, ($exit_kind eq 'Return' ? 1 : 0), $ctx);
        }
        _emit_exit($region->{exit} // {}, \@out, 2, $default_return, $ctx, $name);
    }

    push @out, "  return $default_return;";
    push @out, '}';
    my @generated_top_level;
    for my $g (@{ $ctx->{generated_globals_order} // [] }) {
        my $decl = $ctx->{generated_globals}{$g};
        push @generated_top_level, $decl if defined($decl) && $decl ne '';
    }
    push @generated_top_level, @{ $ctx->{generated_callbacks} // [] };
    return (join("\n", @out), $ctx->{helpers}, \@generated_top_level);
}

sub _emit_used_helpers {
    my ($out, $helpers) = @_;
    return emit_runtime_helpers($out, $helpers);
}

sub _emit_function_prototypes {
    my ($hir) = @_;
    my @out;
    for my $fn (@{ $hir->{functions} // [] }) {
        my $name = $fn->{name} // '';
        next if $name eq '';
        my $ret_type = $name eq 'main' ? 'int' : _type_to_c($fn->{return_type}, 'int64_t');
        my @params;
        for my $p (@{ $fn->{params} // [] }) {
            my $pn = $p->{name} // 'p';
            my $pt = _type_to_c($p->{type}, 'int64_t');
            push @params, "$pt $pn";
        }
        my $param_sig = @params ? join(', ', @params) : 'void';
        push @out, "$ret_type $name($param_sig);";
    }
    push @out, '' if @out;
    return \@out;
}

sub codegen_from_vnf_hir {
    my ($hir) = @_;
    my @fn_blocks;
    my @generated_blocks;
    my %helpers_used;

    for my $fn (@{ $hir->{functions} // [] }) {
        my ($code, $helpers, $generated) = _emit_function($fn // {});
        push @fn_blocks, $code;
        push @generated_blocks, grep { defined($_) && $_ ne '' } @{ $generated // [] };
        for my $k (keys %{ $helpers // {} }) {
            $helpers_used{$k} = 1;
        }
    }

    my @out;
    push @out, '#include <stdint.h>';
    push @out, '#include <stdio.h>';
    push @out, '#include <stdlib.h>';
    push @out, '#include <string.h>';
    push @out, '#include <ctype.h>';
    push @out, '#include <stdarg.h>';
    push @out, '#include <regex.h>';
    push @out, '';
    push @out, 'struct metac_error { const char *message; };';
    push @out, '';

    _emit_used_helpers(\@out, \%helpers_used);
    push @out, @{ _emit_function_prototypes($hir) };
    if (@generated_blocks) {
        push @out, @generated_blocks;
        push @out, '';
    }

    for my $fn_code (@fn_blocks) {
        push @out, $fn_code;
        push @out, '';
    }

    return join("\n", @out);
}

1;
