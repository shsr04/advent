package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error c_escape_string);
use MetaC::TypeSpec qw(
    union_member_types
    is_supported_generic_union_return
    type_is_number_or_error
    type_is_bool_or_error
    type_is_string_or_error
);

our @EXPORT_OK = qw(codegen_from_vnf_hir);

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
        for my $step (@{ $region->{steps} }) {
            push @stmts, $step->{stmt};
        }
        my $exit = $region->{exit}{kind} // '';
        if ($exit eq 'Goto') {
            $rid = $region->{exit}{target_region};
            next;
        }
        last;
    }
    return \@stmts;
}

sub _compile_single_function {
    my (%args) = @_;
    my $fn = $args{fn};
    my $stmts = $args{stmts};
    my $function_sigs = $args{function_sigs};

    my ($ctx, $helper_defs) = MetaC::Codegen::_new_codegen_ctx($function_sigs, $fn->{name});
    my $sig_params = MetaC::Codegen::render_c_params($fn->{params});
    my @out;

    my $ret = $fn->{return_type};
    my ($decl, $return_mode, $fallback);
    if ($fn->{name} eq 'main') {
        $decl = 'int main(void) {';
        $return_mode = 'number';
        $fallback = '  return 0;';
    } elsif (type_is_number_or_error($ret)) {
        $decl = "static ResultNumber $fn->{name}($sig_params) {";
        $return_mode = $ret;
        my $msg = c_escape_string("Missing return in function $fn->{name}");
        $fallback = "  return err_number($msg, __metac_line_no, \"\");";
    } elsif (type_is_bool_or_error($ret)) {
        $decl = "static ResultBool $fn->{name}($sig_params) {";
        $return_mode = $ret;
        my $msg = c_escape_string("Missing return in function $fn->{name}");
        $fallback = "  return err_bool($msg, __metac_line_no, \"\");";
    } elsif (type_is_string_or_error($ret)) {
        $decl = "static ResultStringValue $fn->{name}($sig_params) {";
        $return_mode = $ret;
        my $msg = c_escape_string("Missing return in function $fn->{name}");
        $fallback = "  return err_string_value($msg, __metac_line_no, \"\");";
    } elsif (is_supported_generic_union_return($ret)) {
        $decl = "static MetaCValue $fn->{name}($sig_params) {";
        $return_mode = $ret;
        my $members = union_member_types($ret);
        my $first = $members->[0] // 'error';
        $fallback = '  return metac_value_number(0);' if $first eq 'number';
        $fallback = '  return metac_value_bool(0);' if $first eq 'bool';
        $fallback = '  return metac_value_string("");' if $first eq 'string';
        $fallback = '  return metac_value_null();' if $first eq 'null';
        $fallback = '  return metac_value_error("Missing return", __metac_line_no, "");' if !defined $fallback;
    } elsif ($ret eq 'number') {
        $decl = "static int64_t $fn->{name}($sig_params) {";
        $return_mode = 'number';
        $fallback = '  return 0;';
    } elsif ($ret eq 'bool') {
        $decl = "static int $fn->{name}($sig_params) {";
        $return_mode = 'bool';
        $fallback = '  return 0;';
    } else {
        compile_error("Unsupported function return type for '$fn->{name}': $ret");
    }

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

sub codegen_from_vnf_hir {
    my ($hir) = @_;
    compile_error('Internal HIR error: unverified HIR rejected by codegen') if !$hir->{verified};

    my @functions = @{ $hir->{functions} };
    my %by_name = map { $_->{name} => $_ } @functions;
    my $main = $by_name{main};
    compile_error('Internal HIR error: missing main function') if !defined $main;

    my $function_sigs = _collect_function_sigs($hir);
    my @ordered_names = sort grep { $_ ne 'main' } keys %by_name;

    my $non_runtime = '';
    $non_runtime .= _emit_function_prototypes_from_hir(\@functions);
    $non_runtime .= "\n\n";

    for my $name (@ordered_names) {
        my $fn = $by_name{$name};
        my $stmts = _stmts_from_hir($fn);
        $non_runtime .= _compile_single_function(
            fn            => $fn,
            stmts         => $stmts,
            function_sigs => $function_sigs,
        );
        $non_runtime .= "\n";
    }

    my $main_stmts = _stmts_from_hir($main);
    $non_runtime .= _compile_single_function(
        fn            => $main,
        stmts         => $main_stmts,
        function_sigs => $function_sigs,
    );

    my $c = MetaC::Codegen::runtime_prelude_for_code($non_runtime);
    $c .= "\n" . $non_runtime;
    return $c;
}

1;
