package MetaC::HIR::MaterializeC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);

our @EXPORT_OK = qw(materialize_c_templates emit_function_c_from_hir);

sub _collect_function_sigs {
    my ($hir) = @_;
    my %sigs;
    for my $fn (@{ $hir->{functions} }) {
        next if $fn->{name} eq 'main';
        $sigs{ $fn->{name} } = {
            return_type => $fn->{return_type},
            params      => $fn->{params},
        };
    }
    return \%sigs;
}

sub _region_map {
    my ($fn) = @_;
    my %map = map { $_->{id} => $_ } @{ $fn->{regions} // [] };
    return \%map;
}

sub _scheduled_regions_from_hir {
    my ($fn) = @_;
    my $region_by_id = _region_map($fn);
    my @regions;

    my $schedule = $fn->{region_schedule};
    compile_error("F049 materialization: missing region_schedule in '$fn->{name}'")
      if !defined($schedule) || ref($schedule) ne 'ARRAY';
    for my $rid (@$schedule) {
        my $region = $region_by_id->{$rid};
        compile_error("F049 materialization: unknown scheduled region '$rid' in '$fn->{name}'")
          if !defined $region;
        push @regions, $region;
    }

    compile_error("F049 materialization: no scheduled regions recovered for '$fn->{name}'")
      if $fn->{name} ne 'main' && !@regions;
    return \@regions;
}

sub _validate_expr_resolved_calls {
    my ($expr, $fn_name) = @_;
    return if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';
    if ($kind eq 'call' || $kind eq 'method_call' || $kind eq 'call_expr') {
        my $resolved = $expr->{resolved_call};
        compile_error("F049 materialization: missing resolved call contract in '$fn_name'")
          if !defined($resolved) || ref($resolved) ne 'HASH';
        my $canonical = $expr->{canonical_call};
        compile_error("F049 materialization: missing canonical_call for resolved call in '$fn_name'")
          if !defined($canonical) || ref($canonical) ne 'HASH';
        compile_error("F049 materialization: canonical_call.node_kind must be CallExpr in '$fn_name'")
          if ($canonical->{node_kind} // '') ne 'CallExpr';
        compile_error("F049 materialization: canonical_call.op_id is required in '$fn_name'")
          if !defined($canonical->{op_id}) || $canonical->{op_id} eq '';
    }
    for my $k (sort keys %$expr) {
        my $v = $expr->{$k};
        if (ref($v) eq 'HASH') {
            _validate_expr_resolved_calls($v, $fn_name);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $item (@$v) {
            _validate_expr_resolved_calls($item, $fn_name) if ref($item) eq 'HASH';
        }
    }
}

sub _validate_stmt_resolved_calls {
    my ($stmt, $fn_name) = @_;
    return if !defined($stmt) || ref($stmt) ne 'HASH';
    for my $k (qw(expr cond iterable index source recv value left right first tail_expr source_expr delim_expr)) {
        _validate_expr_resolved_calls($stmt->{$k}, $fn_name) if defined $stmt->{$k};
    }
    if (defined($stmt->{args}) && ref($stmt->{args}) eq 'ARRAY') {
        _validate_expr_resolved_calls($_, $fn_name) for @{ $stmt->{args} };
    }
    for my $k (qw(then_body else_body body handler)) {
        next if !defined($stmt->{$k}) || ref($stmt->{$k}) ne 'ARRAY';
        _validate_stmt_resolved_calls($_, $fn_name) for @{ $stmt->{$k} };
    }
}

sub _emit_hir_stmt_direct {
    my (%args) = @_;
    my $stmt = $args{stmt};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $return_mode = $args{return_mode};
    my $fn_name = $args{fn_name};
    my $kind = $stmt->{kind} // '';

    my %decl_kinds = map { $_ => 1 } qw(let const const_typed const_try_expr const_try_tail_expr const_or_catch);
    my %try_kinds = map { $_ => 1 } qw(const_try_chain destructure_split_or destructure_list);
    my %assign_loop_kinds = map { $_ => 1 } qw(let_producer typed_assign assign assign_op incdec for_lines for_each for_each_try while break continue rewind destructure_match);
    my %control_kinds = map { $_ => 1 } qw(if return expr_stmt expr_stmt_try expr_or_catch raw);

    if ($decl_kinds{$kind}) {
        return if MetaC::Codegen::_compile_block_stage_decls($stmt, $ctx, $out, $indent, $return_mode);
        compile_error("F049 materialization: declarations stage failed for '$kind' in '$fn_name'");
    }
    if ($try_kinds{$kind}) {
        return if MetaC::Codegen::_compile_block_stage_try($stmt, $ctx, $out, $indent, $return_mode);
        compile_error("F049 materialization: try stage failed for '$kind' in '$fn_name'");
    }
    if ($assign_loop_kinds{$kind}) {
        return if MetaC::Codegen::_compile_block_stage_assign_loops($stmt, $ctx, $out, $indent, $return_mode);
        compile_error("F049 materialization: assign/loop stage failed for '$kind' in '$fn_name'");
    }
    if ($control_kinds{$kind}) {
        return if MetaC::Codegen::_compile_block_stage_control($stmt, $ctx, $out, $indent, $return_mode);
        compile_error("F049 materialization: control stage failed for '$kind' in '$fn_name'");
    }
    compile_error("F049 materialization: unsupported statement kind '$kind' in '$fn_name'");
}

sub _emit_hir_step {
    my (%args) = @_;
    my $fn = $args{fn};
    my $step = $args{step};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $return_mode = $args{return_mode};

    my $stmt = step_payload_to_stmt($step->{payload});
    compile_error("F049 materialization: missing statement payload for step '$step->{id}' in '$fn->{name}'")
      if !defined($stmt) || ref($stmt) ne 'HASH';

    _validate_stmt_resolved_calls($stmt, $fn->{name});

    MetaC::Codegen::set_error_line($stmt->{line});
    _emit_hir_stmt_direct(
        stmt        => $stmt,
        ctx         => $ctx,
        out         => $out,
        indent      => $indent,
        return_mode => $return_mode,
        fn_name     => $fn->{name},
    );
}

sub _seed_ctx_facts_from_region_in {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $region = $args{region};
    my $facts = $region->{facts_in} // [];
    return if !defined($facts) || ref($facts) ne 'ARRAY';
    for my $fact (@$facts) {
        next if !defined $fact;
        if ($fact =~ /^len_var:([A-Za-z_][A-Za-z0-9_]*):(-?\d+)$/) {
            my ($name, $len) = ($1, int($2));
            my $info = MetaC::Codegen::lookup_var($ctx, $name);
            next if !defined $info;
            my $key = MetaC::Codegen::expr_fact_key({ kind => 'ident', name => $name }, $ctx);
            MetaC::Codegen::set_list_len_fact($ctx, $key, $len);
        }
    }
}

sub _emit_hir_exit {
    my (%args) = @_;
    my $fn = $args{fn};
    my $region = $args{region};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $return_mode = $args{return_mode};
    my $had_steps = $args{had_steps} ? 1 : 0;
    my $exit = $region->{exit} // {};
    my $kind = $exit->{kind} // '';

    return if $kind eq '' || $kind eq 'Goto' || $kind eq 'IfExit' || $kind eq 'WhileExit' || $kind eq 'ForInExit' || $kind eq 'TryExit';
    if ($kind eq 'Return') {
        return if $had_steps;
        return if !defined $exit->{value};
        my $stmt = { kind => 'return', expr => $exit->{value}, line => $region->{provenance}{line} // 0 };
        MetaC::Codegen::set_error_line($stmt->{line});
        return _emit_hir_stmt_direct(
            stmt        => $stmt,
            ctx         => $ctx,
            out         => $out,
            indent      => $indent,
            return_mode => $return_mode,
            fn_name     => $fn->{name},
        );
    }
    if ($kind eq 'PropagateError') {
        return if $had_steps;
        my $msg = $exit->{error_value} // '"Internal try propagation error"';
        return MetaC::Codegen::_emit_stmt_try_failure($ctx, $out, $indent, $return_mode, $msg);
    }
    compile_error("F049 materialization: unsupported region exit '$kind' in '$fn->{name}'");
}

sub _emit_hir_regions {
    my (%args) = @_;
    my $regions = $args{regions};
    for my $region (@$regions) {
        my $steps = $region->{steps} // [];
        my $had_steps = @$steps ? 1 : 0;
        _seed_ctx_facts_from_region_in(
            ctx    => $args{ctx},
            region => $region,
        );
        for my $step (@$steps) {
            _emit_hir_step(
                fn          => $args{fn},
                step        => $step,
                ctx         => $args{ctx},
                out         => $args{out},
                indent      => $args{indent},
                return_mode => $args{return_mode},
            );
        }
        _emit_hir_exit(
            fn          => $args{fn},
            region      => $region,
            ctx         => $args{ctx},
            out         => $args{out},
            indent      => $args{indent},
            return_mode => $args{return_mode},
            had_steps   => $had_steps,
        );
    }
    MetaC::Codegen::clear_error_line();
}

sub _compile_function_template {
    my (%args) = @_;
    my $fn = $args{fn};
    my $regions = $args{regions};
    my $function_sigs = $args{function_sigs};
    my $abi = $args{abi};

    my ($ctx, $helper_defs) = MetaC::Codegen::_new_codegen_ctx($function_sigs, $fn->{name});
    my $decl = $abi->{c_decl};
    my $return_mode = $abi->{c_return_mode};
    my $fallback = $abi->{c_fallback};
    compile_error("F049 materialization: missing ABI declaration for '$fn->{name}'") if !defined $decl;
    compile_error("F049 materialization: missing ABI return mode for '$fn->{name}'") if !defined $return_mode;
    compile_error("F049 materialization: missing ABI fallback for '$fn->{name}'") if !defined $fallback;

    my @out;
    push @out, $decl;
    if ($fn->{name} ne 'main') {
        MetaC::Codegen::emit_param_bindings($fn->{params}, $ctx, \@out, 2, $return_mode);
    }
    _emit_hir_regions(
        fn          => $fn,
        regions     => $regions,
        ctx         => $ctx,
        out         => \@out,
        indent      => 2,
        return_mode => $return_mode,
    );
    MetaC::Codegen::emit_scope_owned_cleanups($ctx, \@out, 2);
    push @out, $fallback;
    push @out, '}';

    my $fn_code = MetaC::Codegen::_function_code_with_usage_tracked_locals(\@out);
    return MetaC::Codegen::_prepend_helper_defs($helper_defs, $fn_code);
}

sub emit_function_c_from_hir {
    my (%args) = @_;
    my $fn = $args{fn};
    my $function_sigs = $args{function_sigs};

    compile_error('Internal HIR error: emit_function_c_from_hir requires function')
      if !defined($fn) || ref($fn) ne 'HASH';
    compile_error("F049 materialization: missing normalized ABI contract for '$fn->{name}'")
      if !defined($fn->{abi}) || ref($fn->{abi}) ne 'HASH';
    my $regions = _scheduled_regions_from_hir($fn);
    return _compile_function_template(
        fn            => $fn,
        regions       => $regions,
        function_sigs => $function_sigs,
        abi           => $fn->{abi},
    );
}

sub materialize_c_templates {
    my ($hir) = @_;
    compile_error('Internal HIR error: unverified HIR rejected by materializer') if !$hir->{verified};

    my $function_sigs = _collect_function_sigs($hir);
    for my $fn (@{ $hir->{functions} }) {
        $fn->{backend_c_template} = emit_function_c_from_hir(
            fn            => $fn,
            function_sigs => $function_sigs,
        );
    }
    return $hir;
}

1;
