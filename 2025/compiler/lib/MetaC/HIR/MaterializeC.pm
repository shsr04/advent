package MetaC::HIR::MaterializeC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);

our @EXPORT_OK = qw(materialize_c_templates);

sub _collect_function_sigs {
    my ($hir) = @_;
    my %sigs;
    for my $fn (@{ $hir->{functions} }) {
        next if $fn->{name} eq 'main';
        $sigs{ $fn->{name} } = {
            return_type => $fn->{return_type},
            params      => $fn->{params},
        };
    }
    return \%sigs;
}

sub _stmts_from_hir {
    my ($fn) = @_;
    return $fn->{source_stmts} if defined $fn->{source_stmts};

    my %region_by_id = map { $_->{id} => $_ } @{ $fn->{regions} };
    my @stmts;
    my %seen;
    my $rid = $fn->{entry_region};
    while (defined $rid) {
        last if $seen{$rid}++;
        my $region = $region_by_id{$rid};
        last if !defined $region;
        push @stmts, map { $_->{stmt} } @{ $region->{steps} };
        my $kind = $region->{exit}{kind} // '';
        if ($kind eq 'Goto') {
            $rid = $region->{exit}{target_region};
            next;
        }
        last;
    }
    return \@stmts;
}

sub _compile_function_template {
    my (%args) = @_;
    my $fn = $args{fn};
    my $stmts = $args{stmts};
    my $function_sigs = $args{function_sigs};
    my $abi = $args{abi};

    my ($ctx, $helper_defs) = MetaC::Codegen::_new_codegen_ctx($function_sigs, $fn->{name});
    my $decl = $abi->{c_decl};
    my $return_mode = $abi->{c_return_mode};
    my $fallback = $abi->{c_fallback};
    compile_error("F049 materialization: missing ABI declaration for '$fn->{name}'") if !defined $decl;
    compile_error("F049 materialization: missing ABI return mode for '$fn->{name}'") if !defined $return_mode;
    compile_error("F049 materialization: missing ABI fallback for '$fn->{name}'") if !defined $fallback;

    my @out;
    push @out, $decl;
    if ($fn->{name} ne 'main') {
        MetaC::Codegen::emit_param_bindings($fn->{params}, $ctx, \@out, 2, $return_mode);
    }
    MetaC::Codegen::compile_block($stmts, $ctx, \@out, 2, $return_mode);
    MetaC::Codegen::emit_scope_owned_cleanups($ctx, \@out, 2);
    push @out, $fallback;
    push @out, '}';

    my $fn_code = MetaC::Codegen::_function_code_with_usage_tracked_locals(\@out);
    return MetaC::Codegen::_prepend_helper_defs($helper_defs, $fn_code);
}

sub materialize_c_templates {
    my ($hir) = @_;
    compile_error('Internal HIR error: unverified HIR rejected by materializer') if !$hir->{verified};

    my $function_sigs = _collect_function_sigs($hir);
    for my $fn (@{ $hir->{functions} }) {
        my $abi = $fn->{abi};
        compile_error("F049 materialization: missing normalized ABI contract for '$fn->{name}'")
          if !defined($abi) || ref($abi) ne 'HASH';
        my $stmts = _stmts_from_hir($fn);
        $fn->{backend_c_template} = _compile_function_template(
            fn            => $fn,
            stmts         => $stmts,
            function_sigs => $function_sigs,
            abi           => $abi,
        );
    }
    return $hir;
}

1;
