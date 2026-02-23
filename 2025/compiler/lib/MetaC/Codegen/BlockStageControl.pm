package MetaC::Codegen;
use strict;
use warnings;

sub _compile_block_stage_control {
    my ($stmt, $ctx, $out, $indent, $current_fn_return) = @_;
        if ($stmt->{kind} eq 'if') {
            my $size_check = size_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_check = nullable_number_check_from_condition($stmt->{cond}, $ctx);
            my $nullable_nonnull_on_false = nullable_number_names_non_null_on_false_expr($stmt->{cond}, $ctx);
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("if condition must evaluate to bool, got $cond_type") if $cond_type ne 'bool';

            emit_line($out, $indent, "if ($cond_code) {");
            new_scope($ctx);
            if (defined $size_check && $size_check->{op} eq '==') {
                set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
            }
            if (defined $nullable_check && $nullable_check->{op} eq '!=') {
                declare_not_null_number_shadow($ctx, $nullable_check->{name});
            }
            compile_block($stmt->{then_body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');

            if (defined $stmt->{else_body}) {
                emit_line($out, $indent, 'else {');
                new_scope($ctx);
                if (defined $size_check && $size_check->{op} eq '!=') {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $nullable_check && $nullable_check->{op} eq '==') {
                    declare_not_null_number_shadow($ctx, $nullable_check->{name});
                }
                compile_block($stmt->{else_body}, $ctx, $out, $indent + 2, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent, '}');
            }

            if (defined $size_check) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;

                if (!defined $stmt->{else_body} && $size_check->{op} eq '!=' && $then_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $stmt->{else_body} && $size_check->{op} eq '==' && $else_returns && !$then_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
                if (defined $stmt->{else_body} && $size_check->{op} eq '!=' && $then_returns && !$else_returns) {
                    set_list_len_fact($ctx, $size_check->{key}, $size_check->{len});
                }
            }

            if (defined $nullable_check) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;

                if (!defined $stmt->{else_body} && $nullable_check->{op} eq '==' && $then_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
                if (defined $stmt->{else_body} && $nullable_check->{op} eq '==' && $then_returns && !$else_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
                if (defined $stmt->{else_body} && $nullable_check->{op} eq '!=' && $else_returns && !$then_returns) {
                    set_nonnull_fact_for_var_name($ctx, $nullable_check->{name});
                }
            }

            if (defined $nullable_nonnull_on_false && @$nullable_nonnull_on_false) {
                my $then_returns = block_definitely_returns($stmt->{then_body});
                my $else_returns = defined($stmt->{else_body}) ? block_definitely_returns($stmt->{else_body}) : 0;
                if (!defined $stmt->{else_body} && $then_returns) {
                    for my $name (@$nullable_nonnull_on_false) {
                        set_nonnull_fact_for_var_name($ctx, $name);
                    }
                }
                if (defined $stmt->{else_body} && $then_returns && !$else_returns) {
                    for my $name (@$nullable_nonnull_on_false) {
                        set_nonnull_fact_for_var_name($ctx, $name);
                    }
                }
            }
            return 1;
        }

        if ($stmt->{kind} eq 'return') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($current_fn_return eq 'number_or_error') {
                if ($expr_type eq 'number') {
                    emit_line($out, $indent, "return ok_number($expr_code);");
                } elsif ($expr_type eq 'indexed_number') {
                    my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                    emit_line($out, $indent, "return ok_number($num_expr);");
                } elsif ($expr_type eq 'error') {
                    emit_line($out, $indent, "return $expr_code;");
                } else {
                    compile_error("return type mismatch: expected number or error for number|error function");
                }
            } elsif ($current_fn_return eq 'number') {
                my $num_expr = number_like_to_c_expr($expr_code, $expr_type, "return");
                emit_line($out, $indent, "return $num_expr;");
            } elsif ($current_fn_return eq 'bool') {
                compile_error("return type mismatch: expected bool return")
                  if $expr_type ne 'bool';
                emit_line($out, $indent, "return $expr_code;");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            return 1;
        }

        if ($stmt->{kind} eq 'expr_stmt') {
            my ($expr_code, undef) = compile_expr($stmt->{expr}, $ctx);
            emit_line($out, $indent, "(void)($expr_code);");
            return 1;
        }

        if ($stmt->{kind} eq 'raw') {
            compile_error("Unsupported statement in day1 subset: $stmt->{text}");
        }

        compile_error("Unsupported statement kind: $stmt->{kind}");
    return 0;
}

1;
