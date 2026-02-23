package MetaC::Support;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(compile_error strip_comments trim c_escape_string split_top_level_commas parse_constraints emit_line);

sub compile_error {
    my ($msg) = @_;
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


sub parse_constraints {
    my ($raw) = @_;
    my %constraints = (
        range    => undef,
        wrap     => 0,
        positive => 0,
        negative => 0,
    );

    return \%constraints if !defined $raw || trim($raw) eq '';

    my @terms = map { trim($_) } split /\s*\+\s*/, $raw;
    for my $term (@terms) {
        if ($term =~ /^range\s*\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)$/) {
            $constraints{range} = { min => int($1), max => int($2) };
            next;
        }
        if ($term eq 'wrap') {
            $constraints{wrap} = 1;
            next;
        }
        if ($term eq 'positive') {
            $constraints{positive} = 1;
            next;
        }
        if ($term eq 'negative') {
            $constraints{negative} = 1;
            next;
        }
        compile_error("Unsupported constraint term: $term");
    }

    compile_error("Constraint conflict: cannot require both positive and negative")
      if $constraints{positive} && $constraints{negative};

    return \%constraints;
}


sub emit_line {
    my ($out, $indent, $text) = @_;
    push @$out, (' ' x $indent) . $text;
}


1;
