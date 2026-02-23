package MetaC::TypeSpec;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error trim);

our @EXPORT_OK = qw(
    normalize_type_annotation
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

sub _split_top_level_commas {
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
            compile_error("Unbalanced ')' in matrix constraints") if $paren_depth < 0;
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
            compile_error("Unbalanced ']' in matrix constraints") if $bracket_depth < 0;
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

    compile_error("Unbalanced delimiters in matrix constraints")
      if $paren_depth != 0 || $bracket_depth != 0;
    my $tail = trim($current);
    push @parts, $tail if $tail ne '';
    return \@parts;
}

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

sub normalize_type_annotation {
    my ($type) = @_;
    $type = trim($type // '');
    $type =~ s/\s+//g;
    return 'bool' if $type eq 'boolean';
    return 'number_list' if $type eq 'number[]';
    return 'string_list' if $type eq 'string[]';
    return 'number_or_null' if $type eq 'number|null' || $type eq 'null|number';
    if ($type =~ /^matrix\((number|string)\)$/) {
        return _build_matrix_type(elem => $1, dim => 2, sizes => undef);
    }
    return $type;
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
    my ($matrix_type, $constraint_raw, $where) = @_;
    $where = defined($where) ? $where : 'matrix declaration';
    my $meta = matrix_type_meta($matrix_type);
    compile_error("Internal: apply_matrix_constraints expects matrix type")
      if !defined $meta;

    return $matrix_type if !defined($constraint_raw) || trim($constraint_raw) eq '';

    my $dim = $meta->{dim};
    my @sizes;
    my $has_size = 0;
    my $terms = _split_top_level_commas($constraint_raw);

    for my $term (@$terms) {
        next if $term eq '';
        if ($term =~ /^dim\s*\(\s*(-?\d+)\s*\)$/) {
            $dim = int($1);
            next;
        }
        if ($term =~ /^matrixSize\s*\(\s*\[(.*)\]\s*\)$/) {
            my $inside = trim($1);
            my @parts = $inside eq '' ? () : map { trim($_) } split /\s*,\s*/, $inside;
            compile_error("matrixSize(...) requires at least one size value in $where")
              if !@parts;
            @sizes = map {
                compile_error("matrixSize(...) entries must be integer literals in $where")
                  if $_ !~ /^-?\d+$/;
                int($_);
            } @parts;
            $has_size = 1;
            next;
        }
        compile_error("Unsupported matrix constraint term '$term' in $where");
    }

    compile_error("matrix dim(...) must be at least 2 in $where")
      if $dim < 2;

    if ($has_size) {
        compile_error("matrixSize(...) length must match dim($dim) in $where")
          if scalar(@sizes) != $dim;
        for my $size (@sizes) {
            compile_error("matrixSize entries must be positive in $where")
              if $size <= 0;
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
