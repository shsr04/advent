package MetaC::TypeSpec;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(
    compile_error
    trim
    parse_constraint_nodes
    constraint_nodes
);

our @EXPORT_OK = qw(
    normalize_type_annotation
    is_union_type
    union_member_types
    union_contains_member
    is_supported_generic_union_return
    type_is_number_or_error
    type_is_bool_or_error
    type_is_string_or_error
    type_is_number_or_null
    non_error_member_of_error_union
    type_without_union_member
    apply_matrix_constraints
    is_matrix_type
    matrix_type_meta
    matrix_member_type
    matrix_member_list_type
    is_matrix_member_type
    matrix_member_meta
    is_matrix_member_list_type
    matrix_member_list_meta
    matrix_neighbor_list_type
);

sub _build_matrix_type {
    my (%args) = @_;
    my $elem = $args{elem};
    my $dim = $args{dim};
    my $sizes = $args{sizes};
    my $encoded = "matrix<$elem;d=$dim";
    if (defined $sizes && @$sizes) {
        $encoded .= ';s=' . join(',', @$sizes);
    }
    $encoded .= '>';
    return $encoded;
}

sub _strip_outer_parens {
    my ($text) = @_;
    my $s = trim($text // '');
    while ($s =~ /^\(.*\)$/) {
        my @chars = split //, $s;
        my $depth = 0;
        my $ok = 1;
        for (my $i = 0; $i < @chars; $i++) {
            my $ch = $chars[$i];
            if ($ch eq '(') {
                $depth++;
            } elsif ($ch eq ')') {
                $depth--;
                if ($depth < 0) {
                    $ok = 0;
                    last;
                }
                if ($depth == 0 && $i != $#chars) {
                    $ok = 0;
                    last;
                }
            }
        }
        last if !$ok || $depth != 0;
        $s = trim(substr($s, 1, -1));
    }
    return $s;
}

sub _split_top_level_union {
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
            compile_error("Unbalanced ')' in union type annotation") if $paren_depth < 0;
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
            compile_error("Unbalanced ']' in union type annotation") if $bracket_depth < 0;
            $current .= $ch;
            next;
        }
        if ($ch eq '|' && $paren_depth == 0 && $bracket_depth == 0) {
            push @parts, trim($current);
            $current = '';
            next;
        }
        $current .= $ch;
    }

    compile_error("Unbalanced delimiters in union type annotation")
      if $paren_depth != 0 || $bracket_depth != 0;
    my $tail = trim($current);
    push @parts, $tail if $tail ne '';
    return \@parts;
}

sub _normalize_single_type {
    my ($type) = @_;
    my $t = trim($type // '');
    $t = _strip_outer_parens($t);
    $t =~ s/\s+//g;

    return 'number' if $t eq 'int';
    return 'bool' if $t eq 'boolean';
    return 'bool_list' if $t eq 'bool[]' || $t eq 'boolean[]';
    return 'number_list' if $t eq 'number[]' || $t eq 'int[]';
    return 'number_list_list' if $t eq 'number[][]' || $t eq 'int[][]';
    return 'string_list' if $t eq 'string[]';
    if ($t =~ /^matrix\((number|string)\)$/) {
        return _build_matrix_type(elem => $1, dim => 2, sizes => undef);
    }
    return $t;
}

sub normalize_type_annotation {
    my ($type) = @_;
    my $raw = _strip_outer_parens(trim($type // ''));
    my $parts = _split_top_level_union($raw);

    if (@$parts > 1) {
        my %seen;
        my @members;
        for my $part (@$parts) {
            my $n = normalize_type_annotation($part);
            my $nested = union_member_types($n);
            for my $m (@$nested) {
                next if $seen{$m};
                $seen{$m} = 1;
                push @members, $m;
            }
        }
        @members = sort @members;
        return 'number_or_null' if @members == 2 && $members[0] eq 'null' && $members[1] eq 'number';
        return 'number | error' if @members == 2 && $members[0] eq 'error' && $members[1] eq 'number';
        return join(' | ', @members);
    }

    return _normalize_single_type($raw);
}

sub union_member_types {
    my ($type) = @_;
    my $t = trim($type // '');
    return ['number', 'null'] if $t eq 'number_or_null';
    if ($t =~ /\|/) {
        my @parts = map { trim($_) } split /\|/, $t;
        my @members = grep { $_ ne '' } @parts;
        return \@members;
    }
    return [ $t ];
}

sub is_union_type {
    my ($type) = @_;
    my $members = union_member_types($type);
    return @$members > 1 ? 1 : 0;
}

sub union_contains_member {
    my ($type, $member) = @_;
    my $members = union_member_types($type);
    for my $m (@$members) {
        return 1 if $m eq $member;
    }
    return 0;
}

sub _is_runtime_scalar_member {
    my ($member) = @_;
    return 1 if $member eq 'number';
    return 1 if $member eq 'bool';
    return 1 if $member eq 'string';
    return 1 if $member eq 'error';
    return 1 if $member eq 'null';
    return 0;
}

sub is_supported_generic_union_return {
    my ($type) = @_;
    return 0 if !is_union_type($type);
    my $members = union_member_types($type);
    for my $m (@$members) {
        return 0 if !_is_runtime_scalar_member($m);
    }
    return 1;
}

sub type_is_number_or_error {
    my ($type) = @_;
    my $members = union_member_types($type);
    return 0 if @$members != 2;
    my %set = map { $_ => 1 } @$members;
    return $set{number} && $set{error} ? 1 : 0;
}

sub type_is_bool_or_error {
    my ($type) = @_;
    my $members = union_member_types($type);
    return 0 if @$members != 2;
    my %set = map { $_ => 1 } @$members;
    return $set{bool} && $set{error} ? 1 : 0;
}

sub type_is_string_or_error {
    my ($type) = @_;
    my $members = union_member_types($type);
    return 0 if @$members != 2;
    my %set = map { $_ => 1 } @$members;
    return $set{string} && $set{error} ? 1 : 0;
}

sub type_is_number_or_null {
    my ($type) = @_;
    my $members = union_member_types($type);
    return 0 if @$members != 2;
    my %set = map { $_ => 1 } @$members;
    return $set{number} && $set{null} ? 1 : 0;
}

sub non_error_member_of_error_union {
    my ($type) = @_;
    my $members = union_member_types($type);
    return undef if @$members != 2;
    my @non_error = grep { $_ ne 'error' } @$members;
    return undef if @non_error != 1;
    return undef if !union_contains_member($type, 'error');
    return $non_error[0];
}

sub type_without_union_member {
    my ($type, $member) = @_;
    my $members = union_member_types($type);
    my @rest = grep { $_ ne $member } @$members;
    compile_error("Cannot remove '$member' from non-union type '$type'")
      if @rest == @$members;
    return $rest[0] if @rest == 1;
    return normalize_type_annotation(join(' | ', @rest));
}

sub is_matrix_type {
    my ($type) = @_;
    return defined($type) && $type =~ /^matrix<(number|string);d=\d+(?:;s=-?\d+(?:,-?\d+)*)?>$/ ? 1 : 0;
}

sub matrix_type_meta {
    my ($type) = @_;
    return undef if !is_matrix_type($type);
    my ($elem, $dim, $sizes_raw) =
      $type =~ /^matrix<(number|string);d=(\d+)(?:;s=(-?\d+(?:,-?\d+)*))?>$/;
    my @sizes = defined($sizes_raw) ? map { int($_) } split /,/, $sizes_raw : ();
    return {
        elem     => $elem,
        dim      => int($dim),
        has_size => @sizes ? 1 : 0,
        sizes    => \@sizes,
    };
}

sub apply_matrix_constraints {
    my ($matrix_type, $constraint_spec, $where) = @_;
    $where = defined($where) ? $where : 'matrix declaration';
    my $meta = matrix_type_meta($matrix_type);
    compile_error("Internal: apply_matrix_constraints expects matrix type")
      if !defined $meta;

    my $nodes;
    if (ref($constraint_spec) eq 'HASH') {
        $nodes = constraint_nodes($constraint_spec);
    } else {
        my $raw = $constraint_spec;
        return $matrix_type if !defined($raw) || trim($raw) eq '';
        $nodes = parse_constraint_nodes($raw);
    }
    return $matrix_type if !@$nodes;

    my $dim = $meta->{dim};
    my @sizes;
    my $has_size = 0;
    for my $node (@$nodes) {
        if ($node->{kind} eq 'dim') {
            my ($arg) = @{ $node->{args} };
            next if $arg->{kind} eq 'wildcard';
            $dim = int($arg->{value});
            next;
        }
        if ($node->{kind} eq 'matrixSize') {
            @sizes = map { $_->{kind} eq 'number' ? int($_->{value}) : -1 } @{ $node->{args} };
            $has_size = 1;
            next;
        }
    }

    compile_error("matrix dim(...) must be at least 2 in $where")
      if $dim < 2;

    if ($has_size) {
        compile_error("matrixSize(...) length must match dim($dim) in $where")
          if scalar(@sizes) != $dim;
        for my $size (@sizes) {
            compile_error("matrixSize entries must be positive or '*' in $where")
              if $size <= 0 && $size != -1;
        }
    }

    return _build_matrix_type(
        elem  => $meta->{elem},
        dim   => $dim,
        sizes => $has_size ? \@sizes : undef,
    );
}

sub matrix_member_type {
    my ($matrix_type) = @_;
    my $meta = matrix_type_meta($matrix_type);
    compile_error("matrix_member_type expects matrix type")
      if !defined $meta;
    return "matrix_member<$meta->{elem};d=$meta->{dim}>";
}

sub matrix_member_list_type {
    my ($matrix_type) = @_;
    my $meta = matrix_type_meta($matrix_type);
    compile_error("matrix_member_list_type expects matrix type")
      if !defined $meta;
    return "matrix_member_list<$meta->{elem};d=$meta->{dim}>";
}

sub is_matrix_member_type {
    my ($type) = @_;
    return defined($type) && $type =~ /^matrix_member<(number|string);d=\d+>$/ ? 1 : 0;
}

sub matrix_member_meta {
    my ($type) = @_;
    return undef if !is_matrix_member_type($type);
    my ($elem, $dim) = $type =~ /^matrix_member<(number|string);d=(\d+)>$/;
    return {
        elem => $elem,
        dim  => int($dim),
    };
}

sub is_matrix_member_list_type {
    my ($type) = @_;
    return defined($type) && $type =~ /^matrix_member_list<(number|string);d=\d+>$/ ? 1 : 0;
}

sub matrix_member_list_meta {
    my ($type) = @_;
    return undef if !is_matrix_member_list_type($type);
    my ($elem, $dim) = $type =~ /^matrix_member_list<(number|string);d=(\d+)>$/;
    return {
        elem => $elem,
        dim  => int($dim),
    };
}

sub matrix_neighbor_list_type {
    my ($matrix_type) = @_;
    my $meta = matrix_type_meta($matrix_type);
    compile_error("matrix_neighbor_list_type expects matrix type")
      if !defined $meta;
    return $meta->{elem} eq 'number' ? 'number_list' : 'string_list';
}

1;
