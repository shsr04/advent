package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _matrix_meta_alias_source_name_stmt {
    my ($expr) = @_;
    return '' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return $expr->{name} // '' if $k eq 'ident';
    if ($k eq 'method_call') {
        return _matrix_meta_alias_source_name_stmt($expr->{recv});
    }
    return '';
}

sub _emit_stmt {
    my ($stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx) = @_;
    my $sp = ' ' x $indent;
    my $k = $stmt->{kind} // '';

    if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed' || $k eq 'const_try_expr') {
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
        return;
    }
    if ($k eq 'const_try_tail_expr') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;
        my $step_id = $ctx->{tmp_counter}++;
        my $first_name = "__try_tail_${step_id}_0";
        my $first_ty = _expr_c_type_hint($stmt->{first}, $ctx) // 'int64_t';
        my $first_rhs = _expr_to_c($stmt->{first}, $ctx);

        my $final_ty = $first_ty;
        my $probe_name = $first_name;
        my $probe_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            $ctx->{var_types}{$probe_name} = $probe_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $probe_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $probe_ty;
            $probe_name = "__try_tail_${step_id}_" . ($i + 1);
            $probe_ty = $next_ty;
            $final_ty = $next_ty;
        }

        my $decl_ty = _type_to_c($stmt->{type}, $final_ty // 'int64_t');
        my $def = _default_return_for_c_type($decl_ty);
        push @$out, $decl ? "${sp}$name = $def;" : "${sp}$decl_ty $name = $def;";
        push @$out, "${sp}$first_ty $first_name = $first_rhs;";
        push @$out, "${sp}if (!metac_last_error) {";

        my $cur_name = $first_name;
        my $cur_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            my $next_name = "__try_tail_${step_id}_" . ($i + 1);
            $ctx->{var_types}{$cur_name} = $cur_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $cur_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $cur_ty;
            my $next_rhs = _expr_to_c($mexpr, $ctx);
            push @$out, "${sp}  $next_ty $next_name = $next_rhs;";
            $cur_name = $next_name;
            $cur_ty = $next_ty;
        }

        push @$out, "${sp}  $name = $cur_name;";
        push @$out, "${sp}}";
        $ctx->{var_types}{$name} = $decl_ty;
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'const_try_chain') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;

        my $step_id = $ctx->{tmp_counter}++;
        my $first_name = "__chain_${step_id}_0";
        my $first_ty = _expr_c_type_hint($stmt->{first}, $ctx) // 'int64_t';
        my $first_rhs = _expr_to_c($stmt->{first}, $ctx);
        push @$out, "${sp}$first_ty $first_name = $first_rhs;";

        my $cur_name = $first_name;
        my $cur_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            my $next_name = "__chain_${step_id}_" . ($i + 1);
            $ctx->{var_types}{$cur_name} = $cur_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $cur_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $cur_ty;
            my $next_rhs = _expr_to_c($mexpr, $ctx);
            push @$out, "${sp}$next_ty $next_name = $next_rhs;";
            $cur_name = $next_name;
            $cur_ty = $next_ty;
        }

        push @$out, $decl ? "${sp}$name = $cur_name;" : "${sp}$cur_ty $name = $cur_name;";
        $ctx->{var_types}{$name} = $cur_ty;
        return;
    }
    if ($k eq 'const_or_catch') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;
        my $c_ty = _expr_c_type_hint($stmt->{expr}, $ctx) // 'int64_t';
        my $tmp = '__or_tmp_' . ($ctx->{tmp_counter}++);
        my $tmp_ty = _expr_c_type_hint($stmt->{expr}, $ctx) // $c_ty;
        my $def = _default_return_for_c_type($c_ty);

        push @$out, $decl ? "${sp}$name = $def;" : "${sp}$c_ty $name = $def;";
        push @$out, "${sp}$tmp_ty $tmp = " . _expr_to_c($stmt->{expr}, $ctx) . ';';
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}} else {";
        push @$out, "${sp}  $name = $tmp;";
        push @$out, "${sp}}";
        $ctx->{var_types}{$name} = $c_ty;
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'expr_or_catch') {
        push @$out, $sp . _expr_to_c($stmt->{expr}, $ctx) . ';';
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}}";
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'destructure_split_or') {
        _helper_mark($ctx, 'list_str');
        _helper_mark($ctx, 'builtin_split');
        _helper_mark($ctx, 'list_str_get');
        _helper_mark($ctx, 'error_flag');
        my $src_expr = defined($stmt->{source_expr}) ? $stmt->{source_expr} : $stmt->{source};
        my $delim_expr = defined($stmt->{delim_expr}) ? $stmt->{delim_expr} : $stmt->{delim};
        my $tmp = '__split_or_' . ($ctx->{tmp_counter}++);
        my @vars = @{ $stmt->{vars} // [] };
        for my $v (@vars) {
            next if !defined($v) || $v eq '';
            my $decl = $seen_decl->{$v}++;
            push @$out, "${sp}const char *$v = \"\";" if !$decl;
            $ctx->{var_types}{$v} = 'const char *';
        }
        my $src_c = _expr_to_c($src_expr, $ctx);
        my $delim_c = _expr_to_c($delim_expr, $ctx);
        push @$out, "${sp}struct metac_list_str $tmp = metac_builtin_split($src_c, $delim_c);";
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}} else {";
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            push @$out, "${sp}  $v = metac_list_str_get(&$tmp, $i);";
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'destructure_match') {
        _helper_mark($ctx, 'list_str');
        _helper_mark($ctx, 'method_match');
        _helper_mark($ctx, 'list_str_get');
        my $tmp = '__match_' . ($ctx->{tmp_counter}++);
        my @vars = @{ $stmt->{vars} // [] };
        my $types = $stmt->{var_types};
        my @var_types = map {
            my $t = (defined($types) && ref($types) eq 'ARRAY') ? ($types->[$_] // 'string') : 'string';
            ($t eq 'number') ? 'number' : 'string';
        } 0 .. $#vars;
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            my $decl = $seen_decl->{$v}++;
            if (($var_types[$i] // 'string') eq 'number') {
                push @$out, "${sp}int64_t $v = 0;" if !$decl;
                $ctx->{var_types}{$v} = 'int64_t';
            } else {
                push @$out, "${sp}const char *$v = \"\";" if !$decl;
                $ctx->{var_types}{$v} = 'const char *';
            }
        }
        my $src = $stmt->{source_var} // '';
        my $src_c = $src ne '' ? $src : '""';
        my $pattern = '"' . _c_escape($stmt->{pattern} // '') . '"';
        push @$out, "${sp}struct metac_list_str $tmp = metac_method_match($src_c, $pattern);";
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            if (($var_types[$i] // 'string') eq 'number') {
                _helper_mark($ctx, 'parse_number');
                _helper_mark($ctx, 'error_flag');
                push @$out, "${sp}$v = metac_builtin_parse_number(metac_list_str_get(&$tmp, $i));";
            } else {
                push @$out, "${sp}$v = metac_list_str_get(&$tmp, $i);";
            }
        }
        return;
    }
    if ($k eq 'destructure_list') {
        my $src = $stmt->{expr};
        if (defined($src) && ref($src) eq 'HASH' && ($src->{kind} // '') eq 'ident') {
            my $src_name = $src->{name};
            my $src_ty = $ctx->{var_types}{$src_name} // '';
            for my $i (0 .. $#{ $stmt->{vars} // [] }) {
                my $v = $stmt->{vars}[$i];
                my $decl = $seen_decl->{$v}++;
                if ($src_ty eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_str_get');
                    my $rhs = "metac_list_str_get(&$src_name, $i)";
                    push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}const char *$v = $rhs;";
                    $ctx->{var_types}{$v} = 'const char *';
                    next;
                }
                _helper_mark($ctx, 'list_i64');
                my $rhs = "metac_list_i64_get(&$src_name, $i)";
                push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}int64_t $v = $rhs;";
                $ctx->{var_types}{$v} = 'int64_t';
            }
            return;
        }
        my $src_ty = _expr_c_type_hint($src, $ctx) // 'struct metac_list_i64';
        my $tmp = '__destructure_src_' . ($ctx->{tmp_counter}++);
        if ($src_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}struct metac_list_str $tmp = " . _expr_to_c($src, $ctx) . ';';
            for my $i (0 .. $#{ $stmt->{vars} // [] }) {
                my $v = $stmt->{vars}[$i];
                my $decl = $seen_decl->{$v}++;
                my $rhs = "metac_list_str_get(&$tmp, $i)";
                push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}const char *$v = $rhs;";
                $ctx->{var_types}{$v} = 'const char *';
            }
            return;
        }
        _helper_mark($ctx, 'list_i64');
        push @$out, "${sp}struct metac_list_i64 $tmp = " . _expr_to_c($src, $ctx) . ';';
        for my $i (0 .. $#{ $stmt->{vars} // [] }) {
            my $v = $stmt->{vars}[$i];
            my $decl = $seen_decl->{$v}++;
            my $rhs = "metac_list_i64_get(&$tmp, $i)";
            push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}int64_t $v = $rhs;";
            $ctx->{var_types}{$v} = 'int64_t';
        }
        return;
    }
    if ($k eq 'assign' || $k eq 'typed_assign') {
        my $name = $stmt->{name} // '__missing_name';
        my $rhs = _expr_to_c($stmt->{expr}, $ctx);
        my $constraints = $stmt->{constraints};
        if ((!defined($constraints) || ref($constraints) ne 'HASH') && exists $ctx->{var_constraints}{$name}) {
            $constraints = $ctx->{var_constraints}{$name};
        }
        my $target_ty = $ctx->{var_types}{$name} // '';
        my $size_need = _constraint_exact_size($constraints);
        if ($target_ty eq 'const char *' && defined($size_need) && $size_need >= 0) {
            _helper_mark($ctx, 'error_flag');
            _helper_mark($ctx, 'constrained_string_assign');
            $rhs = 'metac_constrained_string_assign(' . $rhs . ', ' . $size_need . ')';
        }
        push @$out, "${sp}$name = $rhs;";
        if ($k eq 'typed_assign' && defined($constraints) && ref($constraints) eq 'HASH') {
            $ctx->{var_constraints}{$name} = $constraints;
        }
        my $mvar = $ctx->{matrix_meta_vars}{$name} // '';
        if ($mvar ne '') {
            my $src = _matrix_meta_alias_source_name_stmt($stmt->{expr});
            my $src_mvar = $ctx->{matrix_meta_vars}{$src} // '';
            push @$out, "${sp}$mvar = $src_mvar;" if $src_mvar ne '';
        }
        return;
    }
    if ($k eq 'assign_op') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '+=';
        push @$out, "${sp}$name $op " . _expr_to_c($stmt->{expr}, $ctx) . ';';
        return;
    }
    if ($k eq 'incdec') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '++';
        push @$out, "${sp}$name$op;";
        return;
    }
    if ($k eq 'expr_stmt' || $k eq 'expr_stmt_try') {
        push @$out, $sp . _expr_to_c($stmt->{expr}, $ctx) . ';';
        return;
    }
    if ($k eq 'return') {
        return if $suppress_step_return;
        my $rv = $stmt->{expr};
        if (defined($rv) && ref($rv) eq 'HASH' && (($rv->{kind} // '') eq 'call') && (($rv->{name} // '') eq 'error')) {
            my $args = $rv->{args} // [];
            my $msg = (ref($args) eq 'ARRAY' && @$args) ? _expr_to_c($args->[0], $ctx) : '""';
            _helper_mark($ctx, 'builtin_error');
            _helper_mark($ctx, 'error_flag');
            my $def = $ctx->{fn_default_return} // '0';
            push @$out, "${sp}metac_builtin_error($msg);";
            push @$out, "${sp}return $def;";
            return;
        }
        if (($ctx->{fn_name} // '') eq 'main') {
            _helper_mark($ctx, 'error_flag');
            if (defined($rv)) {
                my $tmp = '__main_ret_' . ($ctx->{tmp_counter}++);
                push @$out, "${sp}int $tmp = " . _expr_to_c($rv, $ctx) . ';';
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $tmp;";
            } else {
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return 0;";
            }
            return;
        }
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv, $ctx) . ';') : ($sp . 'return 0;');
        return;
    }

    if ($k eq 'if') {
        return if ($ctx->{current_region_exit_kind} // '') eq 'IfExit';
        my $cond = _expr_to_c($stmt->{cond}, $ctx);
        push @$out, "${sp}if ($cond) {";
        my %then_seen = %$seen_decl;
        for my $s (@{ $stmt->{then_body} // [] }) {
            _emit_stmt($s, $out, $indent + 2, \%then_seen, 0, $ctx);
        }
        if (defined($stmt->{else_body}) && ref($stmt->{else_body}) eq 'ARRAY' && @{ $stmt->{else_body} }) {
            push @$out, "${sp}} else {";
            my %else_seen = %$seen_decl;
            for my $s (@{ $stmt->{else_body} }) {
                _emit_stmt($s, $out, $indent + 2, \%else_seen, 0, $ctx);
            }
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'rewind') {
        for my $lid (@{ $ctx->{loop_ids} // [] }) {
            push @$out, "${sp}__loop_init_$lid = 0;";
        }
        my $to = $ctx->{current_region_exit_target};
        push @$out, defined($to) ? "${sp}goto region_$to;" : "${sp}continue;";
        return;
    }
    if ($k eq 'for_each' || $k eq 'for_each_try' || $k eq 'for_lines') {
        my $exit_kind = $ctx->{current_region_exit_kind} // '';
        return if ($k eq 'for_each' || $k eq 'for_each_try') && $exit_kind eq 'ForInExit';

        my $iter_expr = $stmt->{iterable};
        my $iter_c;
        my $iter_ty;
        if ($k eq 'for_lines') {
            my $src_expr = defined($stmt->{source}) ? $stmt->{source} : { kind => 'ident', name => 'STDIN' };
            my $src_c = _expr_to_c($src_expr, $ctx);
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'builtin_lines');
            _helper_mark($ctx, 'builtin_split');
            _helper_mark($ctx, 'error_flag');
            $iter_c = 'metac_builtin_lines(' . $src_c . ')';
            $iter_ty = 'struct metac_list_str';
        } else {
            $iter_c = _expr_to_c($iter_expr, $ctx);
            $iter_ty = _expr_c_type_hint($iter_expr, $ctx) // 'struct metac_list_i64';
        }
        my $loop_id = '__inline_for_' . ($ctx->{tmp_counter}++);
        my $var = $stmt->{var} // '__item';
        my $decl = $seen_decl->{$var}++;

        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}struct metac_list_str ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_str_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_str_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  const char *$var = $bind;";
            $ctx->{var_types}{$var} = 'const char *';
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            push @$out, "${sp}struct metac_list_list_i64 ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_list_i64_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_list_i64_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  struct metac_list_i64 $var = $bind;";
            $ctx->{var_types}{$var} = 'struct metac_list_i64';
        } else {
            _helper_mark($ctx, 'list_i64');
            push @$out, "${sp}struct metac_list_i64 ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_i64_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_i64_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  int64_t $var = $bind;";
            $ctx->{var_types}{$var} = 'int64_t';
        }

        for my $inner (@{ $stmt->{body} // [] }) {
            local $ctx->{inline_loop_depth} = ($ctx->{inline_loop_depth} // 0) + 1;
            _emit_stmt($inner, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'break' || $k eq 'continue') {
        if (($ctx->{inline_loop_depth} // 0) > 0) {
            push @$out, "${sp}$k;";
            return;
        }
        my $to = $ctx->{current_region_exit_target};
        if (($ctx->{current_region_exit_kind} // '') eq 'Goto' && defined($to) && $to ne '') {
            push @$out, "${sp}goto region_$to;";
            return;
        }
        push @$out, "${sp}$k;";
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing stmt emitter for kind '$k' */};
}

1;
