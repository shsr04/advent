package MetaC::HIR;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::Lowering qw(lower_source_to_vnf_hir);
use MetaC::HIR::Gates qw(verify_vnf_hir dump_vnf_hir);
use MetaC::HIR::ABI qw(normalize_hir_abi);
use MetaC::HIR::ResolveCalls qw(resolve_hir_calls);
use MetaC::HIR::BackendC qw(codegen_from_vnf_hir);

our @EXPORT_OK = qw(
    compile_source_via_vnf_hir
    lower_source_to_vnf_hir
    verify_vnf_hir
    codegen_from_vnf_hir
    dump_vnf_hir
);

sub _run_passes {
    my ($state, $passes) = @_;
    my $cur = $state;
    for my $pass (@$passes) {
        $cur = $pass->($cur);
    }
    return $cur;
}

sub compile_source_via_vnf_hir {
    my ($source) = @_;
    my $state = { source => $source };
    my $passes = [
        sub {
            my ($s) = @_;
            $s->{hir} = lower_source_to_vnf_hir($s->{source});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir} = verify_vnf_hir($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir_dump} = dump_vnf_hir($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir} = normalize_hir_abi($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir} = resolve_hir_calls($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{c_code} = codegen_from_vnf_hir($s->{hir});
            return $s;
        },
    ];

    my $out = _run_passes($state, $passes);
    return ($out->{c_code}, $out->{hir_dump});
}

1;
