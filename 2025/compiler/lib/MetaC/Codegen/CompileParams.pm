package MetaC::Codegen;
use strict;
use warnings;

sub emit_param_bindings {
    my ($params, $ctx, $out, $indent, $return_mode) = @_;

    for my $param (@$params) {
        my $name = $param->{name};
        my $in_name = $param->{c_in_name};
        my $constraints = $param->{constraints};

        if ($param->{type} eq 'number') {
            my $expr = $in_name;
            if (constraints_has_kind($constraints, 'wrap')) {
                my ($range_min, $range_max) = constraint_range_bounds($constraints);
                $expr = "metac_wrap_range($expr, $range_min, $range_max)";
            }
            emit_line($out, $indent, "const int64_t $name = $expr;");
            declare_var(
                $ctx,
                $name,
                {
                    type        => 'number',
                    immutable   => 1,
                    c_name      => $name,
                    constraints => $constraints,
                }
            );
            next;
        }

        if ($param->{type} eq 'number_or_null') {
            emit_line($out, $indent, "const NullableNumber $name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'number_or_null',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if ($param->{type} eq 'bool') {
            emit_line($out, $indent, "const int $name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'bool',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if ($param->{type} eq 'string') {
            emit_line($out, $indent, "const char *$name = $in_name;");
            emit_size_constraint_check(
                ctx         => $ctx,
                constraints => $constraints,
                target_expr => $name,
                target_type => 'string',
                out         => $out,
                indent      => $indent,
                where       => "parameter '$name'",
            );
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'string',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if ($param->{type} eq 'bool_list') {
            emit_line($out, $indent, "const BoolList $name = $in_name;");
            emit_size_constraint_check(
                ctx         => $ctx,
                constraints => $constraints,
                target_expr => $name,
                target_type => 'bool_list',
                out         => $out,
                indent      => $indent,
                where       => "parameter '$name'",
            );
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'bool_list',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if (is_array_type($param->{type})) {
            emit_line($out, $indent, "const AnyList $name = $in_name;");
            emit_size_constraint_check(
                ctx         => $ctx,
                constraints => $constraints,
                target_expr => $name,
                target_type => $param->{type},
                out         => $out,
                indent      => $indent,
                where       => "parameter '$name'",
            );
            declare_var(
                $ctx,
                $name,
                {
                    type      => $param->{type},
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if (is_supported_generic_union_return($param->{type})) {
            emit_line($out, $indent, "const MetaCValue $name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => $param->{type},
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        if (is_matrix_type($param->{type})) {
            my $meta = matrix_type_meta($param->{type});
            if ($meta->{elem} eq 'number') {
                emit_line($out, $indent, "const MatrixNumber $name = $in_name;");
            } elsif ($meta->{elem} eq 'string') {
                emit_line($out, $indent, "const MatrixString $name = $in_name;");
            } else {
                emit_line($out, $indent, "const MatrixOpaque $name = $in_name;");
            }
            declare_var(
                $ctx,
                $name,
                {
                    type      => $param->{type},
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        compile_error("Unsupported parameter type binding: $param->{type}");
    }
}


1;
