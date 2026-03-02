package MetaC::HIR;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);
use MetaC::HIR::Lowering qw(lower_source_to_vnf_hir);
use MetaC::HIR::Gates qw(verify_vnf_hir dump_vnf_hir);
use MetaC::HIR::ResolveCalls qw(resolve_hir_calls);
use MetaC::HIR::SemanticChecks qw(enforce_hir_semantics);
use MetaC::HIR::BackendEcho qw(emit_echo_from_vnf_hir);

our @EXPORT_OK = qw(
    compile_source_via_vnf_hir
    lower_source_to_vnf_hir
    verify_vnf_hir
    enforce_hir_semantics
    emit_echo_from_vnf_hir
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

sub _emit_backend_output {
    my (%args) = @_;
    my $backend = $args{backend} // 'echo';
    my $hir = $args{hir};

    return emit_echo_from_vnf_hir($hir) if $backend eq 'echo';
    compile_error("Unknown backend '$backend'");
}

sub compile_source_via_vnf_hir {
    my ($source, %opts) = @_;
    my $backend = $opts{backend} // 'echo';
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
            $s->{hir} = enforce_hir_semantics($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir} = resolve_hir_calls($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{hir_dump} = dump_vnf_hir($s->{hir});
            return $s;
        },
        sub {
            my ($s) = @_;
            $s->{backend_output} = _emit_backend_output(
                backend => $backend,
                hir     => $s->{hir},
            );
            return $s;
        },
    ];

    my $out = _run_passes($state, $passes);
    return ($out->{backend_output}, $out->{hir_dump});
}

1;
