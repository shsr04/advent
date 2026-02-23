package MetaC::Parser;
use strict;
use warnings;

sub parse_capture_groups {
    my ($pattern) = @_;
    my @groups;
    my @chars = split //, $pattern;
    my $in_class = 0;
    my $escape = 0;

    for (my $i = 0; $i < @chars; $i++) {
        my $ch = $chars[$i];

        if ($escape) {
            $escape = 0;
            next;
        }

        if ($ch eq '\\') {
            $escape = 1;
            next;
        }

        if ($ch eq '[') {
            $in_class = 1;
            next;
        }

        if ($ch eq ']') {
            $in_class = 0;
            next;
        }

        next if $in_class;

        next if $ch ne '(';
        next if ($i + 1 < @chars && $chars[$i + 1] eq '?');

        my $depth = 1;
        my $j = $i + 1;
        my $group = '';
        my $inner_class = 0;
        my $inner_escape = 0;

        while ($j < @chars) {
            my $c = $chars[$j];

            if ($inner_escape) {
                $group .= $c;
                $inner_escape = 0;
                $j++;
                next;
            }

            if ($c eq '\\') {
                $group .= $c;
                $inner_escape = 1;
                $j++;
                next;
            }

            if ($c eq '[') {
                $inner_class = 1;
                $group .= $c;
                $j++;
                next;
            }

            if ($c eq ']') {
                $inner_class = 0;
                $group .= $c;
                $j++;
                next;
            }

            if (!$inner_class && $c eq '(') {
                $depth++;
                $group .= $c;
                $j++;
                next;
            }

            if (!$inner_class && $c eq ')') {
                $depth--;
                last if $depth == 0;
                $group .= $c;
                $j++;
                next;
            }

            $group .= $c;
            $j++;
        }

        compile_error("Unterminated capture group in regex: /$pattern/") if $j >= @chars;

        push @groups, $group;
        $i = $j;
    }

    return \@groups;
}


sub infer_group_type {
    my ($group) = @_;
    my $g = trim($group);
    return 'number' if $g =~ /^\[0-9\](\+|\*)?$/;
    return 'number' if $g =~ /^\\d(\+|\*)?$/;
    return 'string';
}


1;
