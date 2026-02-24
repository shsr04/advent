package MetaC::Parser;
use strict;
use warnings;

sub _constraint_applicable_to_type {
    my ($constraint_name, $type) = @_;
    return 1 if $constraint_name eq 'size' && ($type eq 'string' || $type eq 'number_list' || $type eq 'string_list' || $type eq 'bool_list');
    return 1 if ($constraint_name eq 'range' || $constraint_name eq 'wrap' || $constraint_name eq 'positive' || $constraint_name eq 'negative') && $type eq 'number';
    return 1 if ($constraint_name eq 'dim' || $constraint_name eq 'matrixSize') && is_matrix_type($type);
    return 0;
}

sub _enforce_constraint_applicability {
    my (%args) = @_;
    my $type = $args{type};
    my $constraints = $args{constraints};
    my $where = $args{where};
    my $constraint_raw = $args{constraint_raw};

    if (is_union_type($type) && defined($constraint_raw) && trim($constraint_raw) ne '') {
        compile_error("Constraints on union types are not supported in $where");
    }

    for my $node (@{ constraint_nodes($constraints) }) {
        my $name = $node->{kind};
        if (($name eq 'dim' || $name eq 'matrixSize') && !is_matrix_type($type)) {
            compile_error("Matrix constraints require matrix type in $where");
        }
        next if _constraint_applicable_to_type($name, $type);
        compile_error("Constraint '$name' cannot be applied to type '$type' in $where");
    }
}

sub parse_declared_type_and_constraints {
    my (%args) = @_;
    my $raw = trim($args{raw} // '');
    my $where = $args{where} // 'declaration';
    my ($type_raw, $constraint_raw) = ($raw, undef);
    if ($raw =~ /^(.*?)\s+with\s+(.+)$/) {
        $type_raw = trim($1);
        $constraint_raw = trim($2);
    }

    my $type = normalize_type_annotation($type_raw);
    my $members = union_member_types($type);
    for my $m (@$members) {
        next if $m eq 'number';
        next if $m eq 'string';
        next if $m eq 'bool';
        next if $m eq 'error';
        next if $m eq 'null';
        next if $m eq 'number_list';
        next if $m eq 'string_list';
        next if $m eq 'bool_list';
        next if is_matrix_type($m);
        compile_error("Unsupported type annotation '$type_raw' in $where");
    }

    my $constraints = parse_constraints($constraint_raw);
    _enforce_constraint_applicability(
        type           => $type,
        constraints    => $constraints,
        where          => $where,
        constraint_raw => $constraint_raw,
    );
    if (is_matrix_type($type)) {
        my $final = apply_matrix_constraints($type, $constraints, $where);
        return ($final, $constraints);
    }
    return ($type, $constraints);
}

sub parse_function_header {
    my ($line) = @_;
    return undef if $line !~ /^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/;

    my $name = $1;
    my $open_idx = index($line, '(');
    return undef if $open_idx < 0;

    my @chars = split //, $line;
    my $depth = 0;
    my $close_idx = -1;
    for (my $i = $open_idx; $i < @chars; $i++) {
        my $ch = $chars[$i];
        if ($ch eq '(') {
            $depth++;
        } elsif ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                $close_idx = $i;
                last;
            }
            return undef if $depth < 0;
        }
    }
    return undef if $close_idx < 0 || $depth != 0;

    my $args = trim(substr($line, $open_idx + 1, $close_idx - $open_idx - 1));
    my $rest = trim(substr($line, $close_idx + 1));
    return undef if $rest !~ /\{\s*$/;

    $rest =~ s/\{\s*$//;
    $rest = trim($rest);

    my $return_type;
    if ($rest ne '') {
        return undef if $rest !~ /^:\s*(.+)$/;
        $return_type = trim($1);
    }

    return {
        name        => $name,
        args        => $args,
        return_type => $return_type,
    };
}


sub collect_functions {
    my ($source) = @_;
    my @lines = split /\n/, $source, -1;
    my %functions;
    my $idx = 0;

    while ($idx < @lines) {
        set_error_line($idx + 1);
        my $line = strip_comments($lines[$idx]);
        $line =~ s/\s+$//;
        my $trimmed = trim($line);

        if ($trimmed eq '') {
            $idx++;
            next;
        }

        my $header = parse_function_header($trimmed);
        if (defined $header) {
            my ($name, $args, $return_type) = ($header->{name}, $header->{args}, $header->{return_type});
            my $header_line_no = $idx + 1;

            compile_error("Duplicate function definition: $name") if exists $functions{$name};

            my @body;
            my $brace_depth = 1;
            $idx++;

            while ($idx < @lines) {
                set_error_line($idx + 1);
                my $body_line = strip_comments($lines[$idx]);
                $body_line =~ s/\s+$//;

                my $open_count  = () = $body_line =~ /\{/g;
                my $close_count = () = $body_line =~ /\}/g;
                $brace_depth += $open_count;
                $brace_depth -= $close_count;

                compile_error("Too many closing braces near line " . ($idx + 1))
                  if $brace_depth < 0;

                last if $brace_depth == 0;

                push @body, $body_line;
                $idx++;
            }

            compile_error("Unterminated function body for '$name'") if $brace_depth != 0;

            $functions{$name} = {
                name               => $name,
                args               => $args,
                return_type        => $return_type,
                header_line_no     => $header_line_no,
                body_start_line_no => $header_line_no + 1,
                body_lines         => \@body,
            };

            $idx++;
            next;
        }

        compile_error("Unexpected top-level syntax: $trimmed");
    }

    clear_error_line();
    return \%functions;
}


sub parse_function_params {
    my ($fn) = @_;
    set_error_line($fn->{header_line_no});
    my $args = trim($fn->{args});
    if ($args eq '') {
        clear_error_line();
        return [];
    }

    my $parts = split_top_level_commas($args);
    my @params;
    my %seen;

    for my $part (@$parts) {
        $part =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/
          or compile_error("Invalid parameter declaration in function '$fn->{name}': $part");

        my ($name, $type_and_constraints) = ($1, trim($2));
        my ($type, $constraints) = parse_declared_type_and_constraints(
            raw   => $type_and_constraints,
            where => "parameter '$name' in function '$fn->{name}'",
        );
        compile_error("Duplicate parameter '$name' in function '$fn->{name}'")
          if $seen{$name};
        $seen{$name} = 1;

        push @params, {
            name        => $name,
            type        => $type,
            constraints => $constraints,
            c_in_name   => "__metac_in_$name",
        };
    }

    clear_error_line();
    return \@params;
}


1;
