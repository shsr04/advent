package MetaC::Backend::RuntimeHelpers;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Backend::RuntimeHelpersCore qw(emit_runtime_helpers_core);
use MetaC::Backend::RuntimeHelpersExtra qw(emit_runtime_helpers_extra);

our @EXPORT_OK = qw(emit_runtime_helpers);

sub emit_runtime_helpers {
    my ($out, $helpers) = @_;
    emit_runtime_helpers_core($out, $helpers);
    emit_runtime_helpers_extra($out, $helpers);
}

1;
