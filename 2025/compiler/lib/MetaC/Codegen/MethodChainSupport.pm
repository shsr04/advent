package MetaC::Codegen;
use strict;
use warnings;

sub propagate_list_len_fact_from_recv {
    my ($recv_expr, $target_name, $ctx) = @_;
    return if !expr_is_stable_for_facts($recv_expr, $ctx);
    my $recv_key = expr_fact_key($recv_expr, $ctx);
    my $known_len = lookup_list_len_fact($ctx, $recv_key);
    return if !defined $known_len;
    my $new_key = expr_fact_key({ kind => 'ident', name => $target_name }, $ctx);
    set_list_len_fact($ctx, $new_key, $known_len);
}

sub emit_map_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $propagate_errors = $args{propagate_errors} ? 1 : 0;

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("map(...) receiver must be string_list, got $recv_type")
      if $recv_type ne 'string_list';

    my $mapper = map_mapper_info($expr, $ctx);
    if (!$propagate_errors && $mapper->{return_mode} eq 'number_or_error') {
        compile_error("Method 'map(...)' is fallible for mapper '$mapper->{name}'; handle it with '?' (or an explicit error handler)");
    }

    my $source = '__metac_map_src' . $ctx->{tmp_counter}++;
    my $count = '__metac_map_count' . $ctx->{tmp_counter}++;
    my $idx = '__metac_map_i' . $ctx->{tmp_counter}++;
    my $out_items = '__metac_map_items' . $ctx->{tmp_counter}++;
    my $tmp_num = '__metac_map_num' . $ctx->{tmp_counter}++;
    my $tmp_res = '__metac_map_res' . $ctx->{tmp_counter}++;

    emit_line($out, $indent, "StringList $source = $recv_code;");
    emit_line($out, $indent, "size_t $count = $source.count;");
    emit_line($out, $indent, "int64_t *$out_items = (int64_t *)calloc($count == 0 ? 1 : $count, sizeof(int64_t));");
    emit_line($out, $indent, "if ($out_items == NULL) {");
    if ($propagate_errors) {
        emit_line($out, $indent + 2, "return err_number(\"out of memory in map\", __metac_line_no, \"\");");
    } else {
        emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in map\\n\");");
        emit_line($out, $indent + 2, "exit(1);");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
    if ($mapper->{builtin}) {
        emit_line($out, $indent + 2, "int64_t $tmp_num = 0;");
        emit_line($out, $indent + 2, "if (!metac_parse_int($source.items[$idx], &$tmp_num)) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 4, "return err_number(\"Invalid number\", __metac_line_no, $source.items[$idx]);");
        } else {
            emit_line($out, $indent + 4, "fprintf(stderr, \"Invalid number: %s\\n\", $source.items[$idx]);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_num;");
    } elsif ($mapper->{return_mode} eq 'number') {
        emit_line($out, $indent + 2, "${out_items}[$idx] = $mapper->{name}($source.items[$idx]);");
    } else {
        emit_line($out, $indent + 2, "ResultNumber $tmp_res = $mapper->{name}($source.items[$idx]);");
        emit_line($out, $indent + 2, "if ($tmp_res.is_error) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 4, "return err_number($tmp_res.message, __metac_line_no, $source.items[$idx]);");
        } else {
            emit_line($out, $indent + 4, "fprintf(stderr, \"%s\\n\", $tmp_res.message);");
            emit_line($out, $indent + 4, "exit(1);");
        }
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent + 2, "${out_items}[$idx] = $tmp_res.value;");
    }
    emit_line($out, $indent, "}");

    emit_line($out, $indent, "NumberList $name;");
    emit_line($out, $indent, "$name.count = $count;");
    emit_line($out, $indent, "$name.items = $out_items;");

    declare_var(
        $ctx,
        $name,
        {
            type      => 'number_list',
            immutable => 1,
            c_name    => $name,
        }
    );
    propagate_list_len_fact_from_recv($expr->{recv}, $name, $ctx);
}

sub emit_filter_assignment {
    my (%args) = @_;
    my $name = $args{name};
    my $expr = $args{expr};
    my $ctx = $args{ctx};
    my $out = $args{out};
    my $indent = $args{indent};
    my $propagate_errors = $args{propagate_errors} ? 1 : 0;

    my ($recv_code, $recv_type) = compile_expr($expr->{recv}, $ctx);
    compile_error("filter(...) receiver must be string_list or number_list, got $recv_type")
      if $recv_type ne 'string_list' && $recv_type ne 'number_list';
    my $actual = scalar @{ $expr->{args} };
    compile_error("filter(...) expects exactly 1 predicate arg")
      if $actual != 1;
    my $predicate = $expr->{args}[0];
    compile_error("filter(...) predicate must be a single-parameter lambda, e.g. x => x > 0")
      if $predicate->{kind} ne 'lambda1';

    my $source = '__metac_filter_src' . $ctx->{tmp_counter}++;
    my $count = '__metac_filter_count' . $ctx->{tmp_counter}++;
    my $idx = '__metac_filter_i' . $ctx->{tmp_counter}++;
    my $out_count = '__metac_filter_out_count' . $ctx->{tmp_counter}++;

    my $elem_type = $recv_type eq 'string_list' ? 'string' : 'number';
    my $elem_expr = $source . ".items[$idx]";
    my ($pred_code, $pred_type);
    new_scope($ctx);
    declare_var(
        $ctx,
        $predicate->{param},
        {
            type      => $elem_type,
            immutable => 1,
            c_name    => $elem_expr,
        }
    );
    ($pred_code, $pred_type) = compile_expr($predicate->{body}, $ctx);
    pop_scope($ctx);
    compile_error("filter(...) predicate must evaluate to bool")
      if $pred_type ne 'bool';

    if ($recv_type eq 'string_list') {
        my $out_items = '__metac_filter_items' . $ctx->{tmp_counter}++;
        emit_line($out, $indent, "StringList $source = $recv_code;");
        emit_line($out, $indent, "size_t $count = $source.count;");
        emit_line($out, $indent, "char **$out_items = (char **)calloc($count == 0 ? 1 : $count, sizeof(char *));");
        emit_line($out, $indent, "if ($out_items == NULL) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 2, "return err_number(\"out of memory in filter\", __metac_line_no, \"\");");
        } else {
            emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in filter\\n\");");
            emit_line($out, $indent + 2, "exit(1);");
        }
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "size_t $out_count = 0;");
        emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
        emit_line($out, $indent + 2, "if ($pred_code) {");
        emit_line($out, $indent + 4, "${out_items}[$out_count++] = $source.items[$idx];");
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "StringList $name;");
        emit_line($out, $indent, "$name.count = $out_count;");
        emit_line($out, $indent, "$name.items = $out_items;");
    } else {
        my $out_items = '__metac_filter_items' . $ctx->{tmp_counter}++;
        emit_line($out, $indent, "NumberList $source = $recv_code;");
        emit_line($out, $indent, "size_t $count = $source.count;");
        emit_line($out, $indent, "int64_t *$out_items = (int64_t *)calloc($count == 0 ? 1 : $count, sizeof(int64_t));");
        emit_line($out, $indent, "if ($out_items == NULL) {");
        if ($propagate_errors) {
            emit_line($out, $indent + 2, "return err_number(\"out of memory in filter\", __metac_line_no, \"\");");
        } else {
            emit_line($out, $indent + 2, "fprintf(stderr, \"out of memory in filter\\n\");");
            emit_line($out, $indent + 2, "exit(1);");
        }
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "size_t $out_count = 0;");
        emit_line($out, $indent, "for (size_t $idx = 0; $idx < $count; $idx++) {");
        emit_line($out, $indent + 2, "if ($pred_code) {");
        emit_line($out, $indent + 4, "${out_items}[$out_count++] = $source.items[$idx];");
        emit_line($out, $indent + 2, "}");
        emit_line($out, $indent, "}");
        emit_line($out, $indent, "NumberList $name;");
        emit_line($out, $indent, "$name.count = $out_count;");
        emit_line($out, $indent, "$name.items = $out_items;");
    }

    declare_var(
        $ctx,
        $name,
        {
            type      => $recv_type,
            immutable => 1,
            c_name    => $name,
        }
    );
}

1;
