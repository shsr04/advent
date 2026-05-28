package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_method_reduce {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $init = $args[0] // '0';
                my $lam = $expr->{args}[1];
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($lam) && ref($lam) eq 'HASH')
                {
                    my ($param_types, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? (['int64_t', 'int64_t'], 'reduce_i64_cb', 'reduce_i64_cb_value', 'list_i64')
                      : (['int64_t', 'const char *'], 'reduce_str_cb', 'reduce_str_cb_value', 'list_str');
                    my $cb;
                    if (($lam->{kind} // '') eq 'lambda2') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $lam,
                            param_names => [ $lam->{param1} // 'acc', $lam->{param2} // 'x' ],
                            param_types => $param_types,
                            return_c => 'int64_t',
                        );
                    } elsif (($lam->{kind} // '') eq 'ident') {
                        $cb = { fn => ($lam->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_reduce_i64_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_reduce_str_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_reduce_i64_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_reduce_str_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($lam) && ref($lam) eq 'HASH' && (($lam->{kind} // '') eq 'lambda2'))
                {
                    my $p1 = $lam->{param1} // '';
                    my $p2 = $lam->{param2} // '';
                    my $b = $lam->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '+')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '*')
                            && (($r->{kind} // '') eq 'ident') && (($r->{name} // '') eq $p2)
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p1)
                            && (($l->{right}{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'reduce_i64_mul_add');
                            my $factor = _expr_to_c($l->{right}, $ctx);
                            return 'metac_reduce_i64_mul_add(' . $recv . ', ' . $init . ', ' . $factor . ')';
                        }
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($lam) && ref($lam) eq 'HASH' && (($lam->{kind} // '') eq 'lambda2'))
                {
                    my $p1 = $lam->{param1} // '';
                    my $p2 = $lam->{param2} // '';
                    my $b = $lam->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '+')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'ident') && (($l->{name} // '') eq $p1)
                            && (($r->{kind} // '') eq 'method_call')
                            && method_has_length_semantics($r->{method} // '')
                            && (($r->{recv}{kind} // '') eq 'ident') && (($r->{recv}{name} // '') eq $p2))
                        {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'reduce_str_add_size');
                            return 'metac_reduce_str_add_size(' . $recv . ', ' . $init . ')';
                        }
                    }
                }
            
}

sub _emit_method_assert {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $pred = $expr->{args}[0];
                my $msg = $args[1] // '""';
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($pred) && ref($pred) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? ('struct metac_list_i64', 'assert_i64_cb', 'assert_i64_cb_value', 'list_i64')
                      : ('struct metac_list_str', 'assert_str_cb', 'assert_str_cb_value', 'list_str');
                    my $cb;
                    if (($pred->{kind} // '') eq 'lambda1') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $pred,
                            param_names => [ $pred->{param} // 'x' ],
                            param_types => [ $param_ty ],
                            return_c => 'int',
                        );
                    } elsif (($pred->{kind} // '') eq 'ident') {
                        $cb = { fn => ($pred->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        _helper_mark($ctx, 'error_flag');
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_assert_i64_cb(&' . $rname . ', ' . $cb->{fn} . ', ' . $msg . ')'
                              : 'metac_assert_str_cb(&' . $rname . ', ' . $cb->{fn} . ', ' . $msg . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_assert_i64_cb_value(' . $recv . ', ' . $cb->{fn} . ', ' . $msg . ')'
                              : 'metac_assert_str_cb_value(' . $recv . ', ' . $cb->{fn} . ', ' . $msg . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $pred = $expr->{args}[0];
                    my $msg = $args[1] // '""';
                    if ($rty eq 'struct metac_list_i64'
                        && defined($pred) && ref($pred) eq 'HASH'
                        && ($pred->{kind} // '') eq 'lambda1')
                    {
                        my $b = $pred->{body};
                        if (defined($b) && ref($b) eq 'HASH' && ($b->{kind} // '') eq 'binop' && ($b->{op} // '') eq '==') {
                            my ($lhs, $rhs) = ($b->{left}, $b->{right});
                            if (defined($lhs) && defined($rhs)
                                && ref($lhs) eq 'HASH' && ref($rhs) eq 'HASH'
                                && ($lhs->{kind} // '') eq 'method_call'
                                && method_has_length_semantics($lhs->{method} // '')
                                && ($rhs->{kind} // '') eq 'num')
                            {
                                my $need = $rhs->{value} // '0';
                                _helper_mark($ctx, 'list_i64');
                                _helper_mark($ctx, 'assert_size_i64');
                                _helper_mark($ctx, 'error_flag');
                                return 'metac_assert_size_i64(&' . $rname . ', ' . $need . ', ' . $msg . ')';
                            }
                        }
                    }
                }
            
}

sub _emit_method_scan {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $init = $args[0] // '0';
                my $lam = $expr->{args}[1];
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($lam) && ref($lam) eq 'HASH')
                {
                    my ($param_types, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? (['int64_t', 'int64_t'], 'scan_i64_cb', 'scan_i64_cb_value', 'list_i64')
                      : (['int64_t', 'const char *'], 'scan_str_cb', 'scan_str_cb_value', 'list_str');
                    my $cb;
                    if (($lam->{kind} // '') eq 'lambda2') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $lam,
                            param_names => [ $lam->{param1} // 'acc', $lam->{param2} // 'x' ],
                            param_types => $param_types,
                            return_c => 'int64_t',
                        );
                    } elsif (($lam->{kind} // '') eq 'ident') {
                        $cb = { fn => ($lam->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, $helper);
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_scan_i64_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_scan_str_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_scan_i64_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_scan_str_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
            
}

1;
