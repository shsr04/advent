package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error);

our @EXPORT_OK = qw(codegen_from_vnf_hir);

sub _emit_function_prototypes_from_hir {
    my ($functions) = @_;
    my %by_name;
    for my $fn (@$functions) {
        $by_name{$fn->{name}} = {
            name          => $fn->{name},
            return_type   => $fn->{return_type},
            parsed_params => $fn->{params},
        };
    }
    my @ordered_names = sort grep { $_ ne 'main' } keys %by_name;
    return MetaC::Codegen::emit_function_prototypes(\@ordered_names, \%by_name);
}

sub _validate_backend_templates {
    my ($functions) = @_;
    for my $fn (@$functions) {
        my $tpl = $fn->{backend_c_template};
        compile_error("Backend/F049: missing materialized C template for '$fn->{name}'")
          if !defined($tpl) || ref($tpl) ne '' || $tpl eq '';
    }
}

sub _validate_backend_capabilities {
    my ($functions) = @_;
    my %step_caps = map { $_ => 1 } qw(Declare Assign Destructure Eval Control);
    my %exit_caps = map { $_ => 1 } qw(Goto IfExit TryExit ForInExit WhileExit Return PropagateError);
    for my $fn (@$functions) {
        for my $region (@{ $fn->{regions} // [] }) {
            for my $step (@{ $region->{steps} // [] }) {
                my $kind = $step->{kind} // '';
                compile_error("Backend/F049: unsupported step node kind '$kind' in '$fn->{name}'")
                  if !$step_caps{$kind};
            }
            my $exit_kind = $region->{exit}{kind} // '';
            compile_error("Backend/F049: unsupported exit node kind '$exit_kind' in '$fn->{name}'")
              if !$exit_caps{$exit_kind};
        }
    }
}

sub _ordered_functions {
    my ($functions) = @_;
    my %by_name = map { $_->{name} => $_ } @$functions;
    my $main = $by_name{main};
    compile_error('Internal HIR error: missing main function') if !defined $main;
    my @ordered = map { $by_name{$_} } sort grep { $_ ne 'main' } keys %by_name;
    push @ordered, $main;
    return \@ordered;
}

sub codegen_from_vnf_hir {
    my ($hir) = @_;
    compile_error('Internal HIR error: unverified HIR rejected by codegen') if !$hir->{verified};

    my @functions = @{ $hir->{functions} // [] };
    _validate_backend_capabilities(\@functions);
    _validate_backend_templates(\@functions);

    my $non_runtime = '';
    $non_runtime .= _emit_function_prototypes_from_hir(\@functions);
    $non_runtime .= "\n\n";

    my $ordered = _ordered_functions(\@functions);
    for my $fn (@$ordered) {
        $non_runtime .= $fn->{backend_c_template};
        $non_runtime .= "\n" if $fn->{name} ne 'main';
    }

    my $c = MetaC::Codegen::runtime_prelude_for_code($non_runtime);
    $c .= "\n" . $non_runtime;
    return $c;
}

1;
