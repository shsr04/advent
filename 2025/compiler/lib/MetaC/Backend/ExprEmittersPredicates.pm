package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_method_any {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $arg0 = $expr->{args}[0];
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if (($rty eq 'struct metac_list_i64' || $rty eq 'struct metac_list_str' || $rty eq 'struct metac_list_list_i64')
                        && defined($arg0) && ref($arg0) eq 'HASH')
                    {
                        my ($param_ty, $helper, $list_helper);
                        if ($rty eq 'struct metac_list_i64') {
                            ($param_ty, $helper, $list_helper) = ('int64_t', 'any_i64', 'list_i64');
                        } elsif ($rty eq 'struct metac_list_str') {
                            ($param_ty, $helper, $list_helper) = ('const char *', 'any_str', 'list_str');
                        } else {
                            ($param_ty, $helper, $list_helper) = ('struct metac_list_i64', 'any_list_i64', 'list_list_i64');
                        }
                        my $cb;
                        if (($arg0->{kind} // '') eq 'lambda1') {
                            $cb = _lambda_callback_codegen(
                                ctx => $ctx,
                                lambda => $arg0,
                                param_names => [ $arg0->{param} // 'x' ],
                                param_types => [ $param_ty ],
                                return_c => 'int',
                            );
                        } elsif (($arg0->{kind} // '') eq 'ident') {
                            $cb = { fn => ($arg0->{name} // ''), pre => '' };
                        }
                        if (defined($cb) && ($cb->{fn} // '') ne '') {
                            _helper_mark($ctx, $list_helper);
                            _helper_mark($ctx, $helper);
                            my $call;
                            if ($rty eq 'struct metac_list_i64') {
                                $call = 'metac_any_i64(&' . $rname . ', ' . $cb->{fn} . ')';
                            } elsif ($rty eq 'struct metac_list_str') {
                                $call = 'metac_any_str(&' . $rname . ', ' . $cb->{fn} . ')';
                            } else {
                                $call = 'metac_any_list_i64(&' . $rname . ', ' . $cb->{fn} . ')';
                            }
                            return _with_callback_setup($cb->{pre}, $call);
                        }
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if ((defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str' || $recv_hint eq 'struct metac_list_list_i64'))
                    && defined($arg0) && ref($arg0) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper);
                    if ($recv_hint eq 'struct metac_list_i64') {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('int64_t', 'any_i64', 'any_i64_value', 'list_i64');
                    } elsif ($recv_hint eq 'struct metac_list_str') {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('const char *', 'any_str', 'any_str_value', 'list_str');
                    } else {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('struct metac_list_i64', 'any_list_i64', 'any_list_i64_value', 'list_list_i64');
                    }
                    my $cb;
                    if (($arg0->{kind} // '') eq 'lambda1') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ $param_ty ],
                            return_c => 'int',
                        );
                    } elsif (($arg0->{kind} // '') eq 'ident') {
                        $cb = { fn => ($arg0->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        _helper_mark($ctx, $helper_value);
                        my $call;
                        if ($recv_hint eq 'struct metac_list_i64') {
                            $call = 'metac_any_i64_value(' . $recv . ', ' . $cb->{fn} . ')';
                        } elsif ($recv_hint eq 'struct metac_list_str') {
                            $call = 'metac_any_str_value(' . $recv . ', ' . $cb->{fn} . ')';
                        } else {
                            $call = 'metac_any_list_i64_value(' . $recv . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_list_i64' && defined($expr->{args}[0]) && ref($expr->{args}[0]) eq 'HASH' && (($expr->{args}[0]{kind} // '') eq 'lambda1')) {
                        my $lam = $expr->{args}[0];
                        my $p = $lam->{param} // '';
                        my $b = $lam->{body};
                        if (defined($b) && ref($b) eq 'HASH' && ($b->{kind} // '') eq 'binop' && ($b->{op} // '') eq '&&') {
                            my $l = $b->{left};
                            my $r = $b->{right};
                            my $ok_l = defined($l) && ref($l) eq 'HASH' && ($l->{kind} // '') eq 'binop' && ($l->{op} // '') eq '<=';
                            my $ok_r = defined($r) && ref($r) eq 'HASH' && ($r->{kind} // '') eq 'binop' && ($r->{op} // '') eq '<=';
                            if ($ok_l && $ok_r) {
                                my $lx = $l->{left};
                                my $la = $l->{right};
                                my $ra = $r->{left};
                                my $rx = $r->{right};
                                my $lhs_ok = defined($lx) && ref($lx) eq 'HASH' && ($lx->{kind} // '') eq 'index'
                                  && (($lx->{recv}{kind} // '') eq 'ident') && (($lx->{recv}{name} // '') eq $p)
                                  && (($lx->{index}{kind} // '') eq 'num') && (($lx->{index}{value} // '') eq '0');
                                my $rhs_ok = defined($rx) && ref($rx) eq 'HASH' && ($rx->{kind} // '') eq 'index'
                                  && (($rx->{recv}{kind} // '') eq 'ident') && (($rx->{recv}{name} // '') eq $p)
                                  && (($rx->{index}{kind} // '') eq 'num') && (($rx->{index}{value} // '') eq '1');
                                my $mid_ok = defined($la) && defined($ra)
                                  && ref($la) eq 'HASH' && ref($ra) eq 'HASH'
                                  && (($la->{kind} // '') eq 'ident') && (($ra->{kind} // '') eq 'ident')
                                  && (($la->{name} // '') eq ($ra->{name} // ''));
                                if ($lhs_ok && $rhs_ok && $mid_ok) {
                                    _helper_mark($ctx, 'list_i64');
                                    _helper_mark($ctx, 'list_list_i64');
                                    _helper_mark($ctx, 'any_range_contains');
                                    return 'metac_any_range_contains(&' . $rname . ', ' . _expr_to_c($la, $ctx) . ')';
                                }
                            }
                        }
                    }
                }
            
}

sub _emit_method_filter {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $pred = $expr->{args}[0];
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($pred) && ref($pred) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? ('int64_t', 'filter_i64_cb', 'filter_i64_cb_value', 'list_i64')
                      : ('const char *', 'filter_str_cb', 'filter_str_cb_value', 'list_str');
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
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_filter_i64_cb(&' . $rname . ', ' . $cb->{fn} . ')'
                              : 'metac_filter_str_cb(&' . $rname . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_filter_i64_cb_value(' . $recv . ', ' . $cb->{fn} . ')'
                              : 'metac_filter_str_cb_value(' . $recv . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($pred) && ref($pred) eq 'HASH'
                    && (($pred->{kind} // '') eq 'lambda1'))
                {
                    my $p = $pred->{param} // '';
                    my $b = $pred->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '==')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        my $lit;
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'ident') && (($l->{name} // '') eq $p)
                            && (($r->{kind} // '') eq 'str'))
                        {
                            $lit = _expr_to_c($r, $ctx);
                        } elsif (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($r->{kind} // '') eq 'ident') && (($r->{name} // '') eq $p)
                            && (($l->{kind} // '') eq 'str'))
                        {
                            $lit = _expr_to_c($l, $ctx);
                        }
                        if (defined($lit)) {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'filter_str_eq');
                            return 'metac_filter_str_eq(' . $recv . ', ' . $lit . ')';
                        }
                    }
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_filter_str');
                    return 'metac_method_filter_identity_str(' . $recv . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($pred) && ref($pred) eq 'HASH'
                    && (($pred->{kind} // '') eq 'lambda1'))
                {
                    my $p = $pred->{param} // '';
                    my $b = $pred->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '||')) {
                        my $extract_eq_num = sub {
                            my ($node) = @_;
                            return undef if !defined($node) || ref($node) ne 'HASH';
                            return undef if ($node->{kind} // '') ne 'binop' || ($node->{op} // '') ne '==';
                            my ($l, $r) = ($node->{left}, $node->{right});
                            if (defined($l) && defined($r)
                                && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                                && ($l->{kind} // '') eq 'ident' && ($l->{name} // '') eq $p
                                && ($r->{kind} // '') eq 'num')
                            {
                                return _expr_to_c($r, $ctx);
                            }
                            if (defined($l) && defined($r)
                                && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                                && ($r->{kind} // '') eq 'ident' && ($r->{name} // '') eq $p
                                && ($l->{kind} // '') eq 'num')
                            {
                                return _expr_to_c($l, $ctx);
                            }
                            return undef;
                        };
                        my $v1 = $extract_eq_num->($b->{left});
                        my $v2 = $extract_eq_num->($b->{right});
                        if (defined($v1) && defined($v2)) {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_eq2');
                            return 'metac_filter_i64_eq2(' . $recv . ', ' . $v1 . ', ' . $v2 . ')';
                        }
                    }
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '!=')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p)
                            && (($l->{right}{kind} // '') eq 'num')
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_mod_ne');
                            my $mod = _expr_to_c($l->{right}, $ctx);
                            my $neq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_mod_ne(' . $recv . ', ' . $mod . ', ' . $neq . ')';
                        }
                    }
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '==')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p)
                            && (($l->{right}{kind} // '') eq 'num')
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_mod_eq');
                            my $mod = _expr_to_c($l->{right}, $ctx);
                            my $eq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_mod_eq(' . $recv . ', ' . $mod . ', ' . $eq . ')';
                        }
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{right}{kind} // '') eq 'ident') && (($l->{right}{name} // '') eq $p)
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_value_mod_eq');
                            my $value = _expr_to_c($l->{left}, $ctx);
                            my $eq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_value_mod_eq(' . $recv . ', ' . $value . ', ' . $eq . ')';
                        }
                    }
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_filter');
                return 'metac_method_filter_identity(' . $recv . ')';
            
}

1;
