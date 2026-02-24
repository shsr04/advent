package MetaC::Parser;
use strict;
use warnings;

sub parse_match_statement {
    my ($line) = @_;
    return undef
      if $line !~ /^const\s*\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\]\s*=\s*match\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*\/(.*)\/\s*\)\?\s*$/;

    my ($vars_raw, $source_var, $pattern) = ($1, $2, $3);
    my @vars = map { trim($_) } split /\s*,\s*/, $vars_raw;
    return {
        kind       => 'destructure_match',
        vars       => \@vars,
        source_var => $source_var,
        pattern    => $pattern,
    };
}


sub parse_call_invocation_text {
    my ($text, $name) = @_;
    my $src = trim($text);
    my $prefix = $name . '(';
    return undef if index($src, $prefix) != 0;

    my $open_idx = length($name);
    my @chars = split //, $src;
    my $depth = 0;
    my $close_idx = -1;

    for (my $i = $open_idx; $i < @chars; $i++) {
        my $ch = $chars[$i];
        if ($ch eq '(') {
            $depth++;
            next;
        }
        if ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                $close_idx = $i;
                last;
            }
            return undef if $depth < 0;
            next;
        }
    }

    return undef if $close_idx < 0 || $depth != 0;

    my $inside = substr($src, $open_idx + 1, $close_idx - $open_idx - 1);
    my $rest = trim(substr($src, $close_idx + 1));
    my $arg_parts = split_top_level_commas($inside);
    return {
        name => $name,
        args => $arg_parts,
        rest => $rest,
    };
}

sub split_try_chain_segments {
    my ($text) = @_;
    my @parts;
    my $current = '';
    my $depth = 0;
    my $in_string = 0;
    my $escape = 0;
    my @chars = split //, $text;

    for (my $i = 0; $i < @chars; $i++) {
        my $ch = $chars[$i];

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
            $depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ')') {
            $depth--;
            compile_error("Unbalanced ')' in try-chain expression") if $depth < 0;
            $current .= $ch;
            next;
        }

        if ($depth == 0 && $ch eq '?' && $i + 1 < @chars && $chars[$i + 1] eq '.') {
            push @parts, trim($current);
            $current = '';
            $i++;
            next;
        }

        $current .= $ch;
    }

    compile_error("Unbalanced '(' in try-chain expression") if $depth != 0;
    push @parts, trim($current) if trim($current) ne '';
    return \@parts;
}

sub parse_method_step {
    my ($text) = @_;
    my $src = trim($text);
    $src =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\(/
      or compile_error("Invalid method step in try-chain: $src");
    my $name = $1;
    my $call = parse_call_invocation_text($src, $name);
    compile_error("Invalid method step in try-chain: $src")
      if !defined($call) || $call->{rest} ne '';

    my @args;
    for my $arg_raw (@{ $call->{args} }) {
        my $arg = trim($arg_raw);
        push @args, parse_expr($arg);
    }
    return {
        name => $name,
        args => \@args,
    };
}


sub parse_iterable_expression {
    my ($raw) = @_;
    my $text = trim($raw);
    return parse_expr($text);
}



sub parse_function_body {
    my ($fn) = @_;
    my $idx = 0;
    my $base_line = $fn->{body_start_line_no};
    set_error_line($base_line);
    my ($stmts, $reason) = parse_block($fn->{body_lines}, \$idx, $base_line);
    if ($reason ne 'eof') {
        my $unexpected_line = defined($base_line) ? ($base_line + $idx - 1) : undef;
        set_error_line($unexpected_line);
        compile_error("Unexpected '}' in function '$fn->{name}'");
    }
    clear_error_line();
    return $stmts;
}


1;
