package MetaC::Parser;
use strict;
use warnings;

sub parse_block {
    my ($lines, $idx_ref, $base_line) = @_;
    my @stmts;

    while ($$idx_ref < @$lines) {
        my $line_no = defined($base_line) ? ($base_line + $$idx_ref) : undef;
        set_error_line($line_no);

        my $line = _parse_block_current_line($lines, $idx_ref);
        if ($line eq '') {
            $$idx_ref++;
            next;
        }

        my $terminator = _parse_block_terminator($line);
        if (defined($terminator)) {
            $$idx_ref++;
            return (\@stmts, $terminator);
        }

        if (_normalize_inline_if($lines, $idx_ref, $line)) {
            next;
        }

        my $ctx = {
            lines => $lines,
            idx_ref => $idx_ref,
            base_line => $base_line,
            line => $line,
            line_no => $line_no,
        };
        my $result = _parse_registered_statement($ctx);
        compile_error("Internal parser error: no recognizer handled line '$line'")
          if !defined($result) || !($result->{matched} // 0);
        push @stmts, @{ $result->{statements} // [] };
    }

    return (\@stmts, 'eof');
}

sub _parse_block_current_line {
    my ($lines, $idx_ref) = @_;
    my $line = trim(strip_comments($lines->[$$idx_ref]));

    my $look = $$idx_ref + 1;
    while ($look < @$lines) {
        my $next = trim(strip_comments($lines->[$look]));
        last if $next eq '';
        last if $next !~ /^\./;
        $line .= $next;
        $look++;
    }
    $$idx_ref = $look - 1 if $look > $$idx_ref + 1;
    return $line;
}

sub _parse_block_terminator {
    my ($line) = @_;
    return 'close' if $line eq '}';
    return 'close_else' if $line =~ /^\}\s*else\s*\{$/;
    return 'close_else_if:' . trim($1) if $line =~ /^\}\s*else\s+if\s+(.+)\s*\{$/;
    return undef;
}

sub _normalize_inline_if {
    my ($lines, $idx_ref, $line) = @_;
    if ($line =~ /^if\s+(.+?)\s*\{\s*(.+?)\s*\}\s*else\s*\{\s*(.+?)\s*\}$/) {
        my ($cond, $then_stmt, $else_stmt) = (trim($1), trim($2), trim($3));
        splice @$lines, $$idx_ref, 1, ("if $cond {", $then_stmt, "} else {", $else_stmt, "}");
        return 1;
    }
    if ($line =~ /^if\s+(.+?)\s*\{\s*(.+?)\s*\}$/) {
        my ($cond, $stmt_text) = (trim($1), trim($2));
        splice @$lines, $$idx_ref, 1, ("if $cond {", $stmt_text, "}");
        return 1;
    }
    return 0;
}

1;
