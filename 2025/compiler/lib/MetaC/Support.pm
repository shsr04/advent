package MetaC::Support;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    compile_error
    set_error_line
    clear_error_line
    strip_comments
    trim
    c_escape_string
    split_top_level_commas
    parse_constraint_nodes
    parse_constraints
    constraint_nodes
    constraints_has_kind
    constraints_has_any_kind
    constraint_range_bounds
    constraints_has_bounded_range
    constraint_size_exact
    constraint_size_is_wildcard
    emit_line
);

my $CURRENT_ERROR_LINE;

sub set_error_line {
    my ($line) = @_;
    if (defined($line) && $line =~ /^\d+$/ && $line > 0) {
        $CURRENT_ERROR_LINE = int($line);
        return;
    }
    $CURRENT_ERROR_LINE = undef;
}

sub clear_error_line {
    $CURRENT_ERROR_LINE = undef;
}

sub compile_error {
    my ($msg) = @_;
    if (defined $CURRENT_ERROR_LINE) {
        die "compile error on line $CURRENT_ERROR_LINE: $msg\n";
    }
    die "compile error: $msg\n";
}


sub strip_comments {
    my ($line) = @_;
    $line =~ s{//.*$}{};
    return $line;
}


sub trim {
    my ($s) = @_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}


sub c_escape_string {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return '"' . $s . '"';
}


sub split_top_level_commas {
    my ($text) = @_;
    my @parts;
    my $current = '';
    my $paren_depth = 0;
    my $bracket_depth = 0;
    my $in_string = 0;
    my $escape = 0;
    my @chars = split //, $text;

    for my $ch (@chars) {
        if ($in_string) {
            $current .= $ch;
            if ($escape) {
                $escape = 0;
                next;
            }
            if ($ch eq '\\') {
                $escape = 1;
                next;
            }
            if ($ch eq '"') {
                $in_string = 0;
            }
            next;
        }

        if ($ch eq '"') {
            $in_string = 1;
            $current .= $ch;
            next;
        }

        if ($ch eq '(') {
            $paren_depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ')') {
            $paren_depth--;
            compile_error("Unbalanced ')' in parameter list") if $paren_depth < 0;
            $current .= $ch;
            next;
        }
        if ($ch eq '[') {
            $bracket_depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ']') {
            $bracket_depth--;
            compile_error("Unbalanced ']' in parameter list") if $bracket_depth < 0;
            $current .= $ch;
            next;
        }
        if ($ch eq ',' && $paren_depth == 0 && $bracket_depth == 0) {
            push @parts, trim($current);
            $current = '';
            next;
        }
        $current .= $ch;
    }

    compile_error("Unbalanced '(' in parameter list") if $paren_depth != 0;
    compile_error("Unbalanced '[' in parameter list") if $bracket_depth != 0;
    push @parts, trim($current) if trim($current) ne '';
    return \@parts;
}

sub _split_constraint_terms {
    my ($text) = @_;
    my @parts;
    my $current = '';
    my $paren_depth = 0;
    my $bracket_depth = 0;
    my $in_string = 0;
    my $escape = 0;
    my @chars = split //, ($text // '');

    for my $ch (@chars) {
        if ($in_string) {
            $current .= $ch;
            if ($escape) {
                $escape = 0;
                next;
            }
            if ($ch eq '\\') {
                $escape = 1;
                next;
            }
            if ($ch eq '"') {
                $in_string = 0;
            }
            next;
        }

        if ($ch eq '"') {
            $in_string = 1;
            $current .= $ch;
            next;
        }
        if ($ch eq '(') {
            $paren_depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ')') {
            $paren_depth--;
            compile_error("Unbalanced ')' in constraints") if $paren_depth < 0;
            $current .= $ch;
            next;
        }
        if ($ch eq '[') {
            $bracket_depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ']') {
            $bracket_depth--;
            compile_error("Unbalanced ']' in constraints") if $bracket_depth < 0;
            $current .= $ch;
            next;
        }
        if (($ch eq '+' || $ch eq ',') && $paren_depth == 0 && $bracket_depth == 0) {
            push @parts, trim($current);
            $current = '';
            next;
        }
        $current .= $ch;
    }

    compile_error("Unbalanced delimiters in constraints")
      if $paren_depth != 0 || $bracket_depth != 0;
    my $tail = trim($current);
    push @parts, $tail if $tail ne '';
    return \@parts;
}

sub _constraint_arg_number_or_wildcard {
    my ($text, $where) = @_;
    my $v = trim($text // '');
    return { kind => 'wildcard' } if $v eq '*';
    compile_error("$where must be integer literal or '*'")
      if $v !~ /^-?\d+$/;
    return { kind => 'number', value => int($v) };
}


sub parse_constraint_nodes {
    my ($raw) = @_;
    return [] if !defined $raw || trim($raw) eq '';

    my @nodes;
    my %seen_kind;
    my $terms = _split_constraint_terms($raw);
    for my $term (@$terms) {
        if ($term =~ /^range\s*\(\s*(\*|-?\d+)\s*,\s*(\*|-?\d+)\s*\)$/) {
            compile_error("Duplicate constraint term: range") if $seen_kind{range}++;
            my $min = $1 eq '*' ? { kind => 'wildcard' } : { kind => 'number', value => int($1) };
            my $max = $2 eq '*' ? { kind => 'wildcard' } : { kind => 'number', value => int($2) };
            my $min_v = $min->{kind} eq 'number' ? $min->{value} : undef;
            my $max_v = $max->{kind} eq 'number' ? $max->{value} : undef;
            if (defined($min_v) && defined($max_v) && $min_v > $max_v) {
                compile_error("range(min,max) requires min <= max");
            }
            push @nodes, {
                kind => 'range',
                args => [ $min, $max ],
            };
            next;
        }
        if ($term eq 'wrap') {
            compile_error("Duplicate constraint term: wrap") if $seen_kind{wrap}++;
            push @nodes, { kind => 'wrap', args => [] };
            next;
        }
        if ($term eq 'positive') {
            compile_error("Duplicate constraint term: positive") if $seen_kind{positive}++;
            push @nodes, { kind => 'positive', args => [] };
            next;
        }
        if ($term eq 'negative') {
            compile_error("Duplicate constraint term: negative") if $seen_kind{negative}++;
            push @nodes, { kind => 'negative', args => [] };
            next;
        }
        if ($term =~ /^size\s*\(\s*(\*|-?\d+)\s*\)$/) {
            compile_error("Duplicate constraint term: size") if $seen_kind{size}++;
            if ($1 eq '*') {
                push @nodes, {
                    kind => 'size',
                    args => [ { kind => 'wildcard' } ],
                };
                next;
            }
            my $size = int($1);
            compile_error("size(...) must be >= 0")
              if $size < 0;
            push @nodes, {
                kind => 'size',
                args => [ { kind => 'number', value => $size } ],
            };
            next;
        }
        if ($term =~ /^dim\s*\(\s*(\*|-?\d+)\s*\)$/) {
            compile_error("Duplicate constraint term: dim") if $seen_kind{dim}++;
            my $dim = _constraint_arg_number_or_wildcard($1, "dim(...) argument");
            if ($dim->{kind} eq 'number' && $dim->{value} < 2) {
                compile_error("matrix dim(...) must be at least 2");
            }
            push @nodes, {
                kind => 'dim',
                args => [ $dim ],
            };
            next;
        }
        if ($term =~ /^matrixSize\s*\(\s*\[(.*)\]\s*\)$/) {
            compile_error("Duplicate constraint term: matrixSize") if $seen_kind{matrixSize}++;
            my $inside = trim($1);
            my @parts = $inside eq '' ? () : map { trim($_) } split /\s*,\s*/, $inside;
            compile_error("matrixSize(...) requires at least one size value")
              if !@parts;
            my @args = map {
                _constraint_arg_number_or_wildcard($_, "matrixSize(...) entry");
            } @parts;
            push @nodes, {
                kind => 'matrixSize',
                args => \@args,
            };
            next;
        }
        compile_error("Unsupported constraint term: $term");
    }

    if ($seen_kind{positive} && $seen_kind{negative}) {
        compile_error("Constraint conflict: cannot require both positive and negative");
    }
    if ($seen_kind{wrap}) {
        my ($range_node) = grep { $_->{kind} eq 'range' } @nodes;
        compile_error("wrap requires range(min,max)")
          if !defined($range_node);
        my ($min, $max) = @{ $range_node->{args} };
        compile_error("wrap requires bounded range(min,max)")
          if $min->{kind} ne 'number' || $max->{kind} ne 'number';
    }

    return \@nodes;
}

sub parse_constraints {
    my ($raw) = @_;
    my $nodes = parse_constraint_nodes($raw);
    return { nodes => $nodes };
}

sub constraint_nodes {
    my ($constraints) = @_;
    return [] if !defined $constraints;
    return $constraints->{nodes} // [];
}

sub constraints_has_kind {
    my ($constraints, $kind) = @_;
    my $nodes = constraint_nodes($constraints);
    for my $node (@$nodes) {
        return 1 if $node->{kind} eq $kind;
    }
    return 0;
}

sub constraints_has_any_kind {
    my ($constraints, @kinds) = @_;
    for my $kind (@kinds) {
        return 1 if constraints_has_kind($constraints, $kind);
    }
    return 0;
}

sub _constraint_node_by_kind {
    my ($constraints, $kind) = @_;
    my $nodes = constraint_nodes($constraints);
    for my $node (@$nodes) {
        return $node if $node->{kind} eq $kind;
    }
    return undef;
}

sub constraint_range_bounds {
    my ($constraints) = @_;
    my $node = _constraint_node_by_kind($constraints, 'range');
    return (undef, undef) if !defined $node;
    my ($min, $max) = @{ $node->{args} };
    my $min_v = $min->{kind} eq 'number' ? $min->{value} : undef;
    my $max_v = $max->{kind} eq 'number' ? $max->{value} : undef;
    return ($min_v, $max_v);
}

sub constraints_has_bounded_range {
    my ($constraints) = @_;
    my ($min, $max) = constraint_range_bounds($constraints);
    return defined($min) && defined($max) ? 1 : 0;
}

sub constraint_size_is_wildcard {
    my ($constraints) = @_;
    my $node = _constraint_node_by_kind($constraints, 'size');
    return 0 if !defined $node;
    my ($arg) = @{ $node->{args} };
    return $arg->{kind} eq 'wildcard' ? 1 : 0;
}

sub constraint_size_exact {
    my ($constraints) = @_;
    my $node = _constraint_node_by_kind($constraints, 'size');
    return undef if !defined $node;
    my ($arg) = @{ $node->{args} };
    return undef if $arg->{kind} ne 'number';
    return $arg->{value};
}


sub emit_line {
    my ($out, $indent, $text) = @_;
    push @$out, (' ' x $indent) . $text;
}


1;
