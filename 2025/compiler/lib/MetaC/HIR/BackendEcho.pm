package MetaC::HIR::BackendEcho;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::HIR::Gates qw(dump_vnf_hir);

our @EXPORT_OK = qw(emit_echo_from_vnf_hir);

sub emit_echo_from_vnf_hir {
    my ($hir) = @_;
    compile_error('HIR echo backend requires verified HIR')
      if !defined($hir) || ref($hir) ne 'HASH' || !$hir->{verified};
    return dump_vnf_hir($hir);
}

1;
