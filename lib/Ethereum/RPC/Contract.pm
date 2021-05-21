package Ethereum::RPC::Contract;
# ABSTRACT: Support for interacting with Ethereum contracts using the geth RPC interface

use strict;
use warnings;

our $VERSION = '0.03';

=head1 NAME

    Ethereum::Contract - Support for interacting with Ethereum contracts using the geth RPC interface

=cut

use Moo;
use JSON::MaybeXS;
use Math::BigInt;
use Scalar::Util qw(looks_like_number);
use List::Util qw(first);

use Ethereum::RPC::Client;
use Ethereum::RPC::Contract::ContractResponse;
use Ethereum::RPC::Contract::ContractTransaction;
use Ethereum::RPC::Contract::Helper::UnitConversion;

has contract_address => (is => 'rw');
has contract_abi => (
    is       => 'ro',
    required => 1
);
has rpc_client => (
    is => 'lazy',
);

sub _build_rpc_client {
    return Ethereum::RPC::Client->new;
}

has from => (
    is   => 'rw',
    lazy => 1
);

sub _build_from {
    return shift->rpc_client->eth_coinbase();
}

has gas_price => (
    is   => 'rw',
    lazy => 1
);

sub _build_gas_price {
    return shift->rpc_client->eth_gasPrice();
}

has gas => (is => 'rw');

has contract_decoded => (
    is      => 'rw',
    default => sub{{}},
);

=head2 BUILD

Constructor: Here we get all functions and events from the given ABI and set
it to the contract class.

=over 4

=item contract_address => string (optional)

=item contract_abi => string (required, https://solidity.readthedocs.io/en/develop/abi-spec.html)

=item rpc_client => L<Ethereum::RPC::Client> (optional, default: L<Ethereum::RPC::Client>)

=item from => string (optional)

=item gas => numeric (optional)

=item gas_price => numeric (optional)

=back

=cut

sub BUILD {
    my ($self) = @_;
    my @decoded_json = @{decode_json( $self->contract_abi // "[]" )};

    for my $json_input (@decoded_json) {
        if ( $json_input->{type} =~ /^function|event$/ ) {
            $self->contract_decoded->{$json_input->{name}} ||= [];
            push(@{$self->contract_decoded->{$json_input->{name}}}, $json_input->{inputs}) if scalar @{$json_input->{inputs}} > 0;
        }
    }

    $self->from($self->rpc_client->eth_coinbase())      unless $self->from;
    $self->gas_price($self->rpc_client->eth_gasPrice()) unless $self->gas_price;

    return;

}

=head2 invoke

Prepare a function to be called/sent to a contract.

=over 4

=item name => string (required)

=item params => array (optional, the function params)

=back

Returns a L<Ethereum::Contract::ContractTransaction> object.

=cut

sub invoke {
    my ($self, $name, @params) = @_;

    my $function_id = substr($self->get_function_id($name, scalar @params), 0, 10);

    my $res = $self->_prepare_transaction($function_id, $name, \@params);

    return $res;
}

=head2 get_function_id

The function ID is derived from the function signature using: SHA3(approve(address,uint256)).

=over 4

=item fuction_name => string (required)

=item params_size => numeric (required, size of inputs called by the function)

=back

Returns a string hash

=cut

sub get_function_id {
    my ($self, $function_name, $params_size) = @_;

    my @inputs = @{$self->contract_decoded->{$function_name}};

    my $selected_data = first { (not $_ and not $params_size) or ($params_size and scalar @{$_} == $params_size) } @inputs;

    $function_name .= sprintf("(%s)", join(",", map { $_->{type} } grep { $_->{type} } @$selected_data));

    my $hex_function = $self->append_prefix(unpack("H*", $function_name));

    my $sha3_hex_function = $self->rpc_client->web3_sha3($hex_function);

    return $sha3_hex_function;
}

=head2 _prepare_transaction

Join the data and parameters and return a prepared transaction to be called as send, call or deploy.

=over 4

=item compiled_data => string (required, function signature or the contract bytecode)

=item params => array (required)

=back

L<Future> object
on_done: L<Ethereum::Contract::ContractTransaction>
on_fail: error string

=cut

sub _prepare_transaction {
    my ($self, $compiled_data, $function_name, $params) = @_;

    my $hex_params = $self->get_hex_param($function_name, $params);

    my $data = $compiled_data . $hex_params;

    return Ethereum::RPC::Contract::ContractTransaction->new(
        contract_address => $self->contract_address,
        rpc_client       => $self->rpc_client,
        data             => $self->append_prefix($data),
        from             => $self->from,
        gas              => $self->gas,
        gas_price        => $self->gas_price,
    );

}

=head2 get_hex_param

Convert parameter list to the ABI format:
https://solidity.readthedocs.io/en/develop/abi-spec.html#function-selector-and-argument-encoding

=over 4

=item params => array (required)

=back

Returns a string containing the ABI format to be send to the contract.

=cut

sub get_hex_param {
    my ($self, $current_offset_count, $input_type, $param) = @_;

    my @static;
    my @dynamic;

    if ($input_type eq 'address' && $param =~ /^0x[0-9A-F]+$/i) {
        push(@static, sprintf("%064s", substr($param, 2)));
    } elsif ($input_type =~ /^(u)?(int|bool)(\d+)?/ && looks_like_number($param)) {
        push(@static, sprintf("%064s", Math::BigInt->new($param)->to_hex));
    } elsif ($input_type =~ /^bytes\d+/){
        my $hex_value = unpack("H*", $param);
        push(@static, $hex_value . "0" x (64 - length($hex_value)));
    } elsif ($input_type =~ /^(string|bytes)$/){
        my $hex_value = unpack("H*", $param);
        push(@static, sprintf("%064s", Math::BigInt->new($current_offset_count * 32)->to_hex));
        push(@dynamic, sprintf("%064s", sprintf("%x", length($param))));
        push(@dynamic, $hex_value . "0" x (64 - length($hex_value)));
    } elsif ($input_type =~ /\[(\d+)?\]/){
        my $size = $param->@*;
        unless ($1) {
            push(@static, sprintf("%064s", Math::BigInt->new($current_offset_count * 32)->to_hex));
            push(@dynamic, sprintf("%064s", Math::BigInt->new($size)->to_hex));
        }

        my @internal_static;
        my @internal_dynamic;

        $input_type =~ /^([a-z]+)\[(?:\d+)?\]/;
        for my $item ($param->@*) {
            my ($internal_static, $internal_dynamic) = $self->get_hex_param($size, $1, $item);
            push(@internal_static, $internal_static->@*);
            push(@internal_dynamic, $internal_dynamic->@*);
            $size += $internal_dynamic->@*;
        }

        push(@dynamic, @internal_static);
        push(@dynamic, @internal_dynamic);
    }

    return \@static, \@dynamic;

}

=head2 read_event

Read the specified log from the specified block to the latest block

=over 4

=item from_block => numeric (optional)

=item event => string (required)

=item event_params_size => numeric (required)

=back

Returns a json encoded object: https://github.com/ethereum/wiki/wiki/JSON-RPC#returns-42

=cut

sub read_event {
    my ($self, $from_block, $event, $event_params_size) = @_;

    my $function_id = $self->get_function_id($event, $event_params_size);

    $from_block = $self->append_prefix(unpack("H*", $from_block // "latest"));

    my $res = $self->rpc_client->eth_getLogs([{
                address   => $self->contract_address,
                fromBlock => $from_block,
                topics    => [$function_id] }]);

    return $res;
}

=head2 invoke_deploy

Prepare a deploy transaction.

=over 4

=item compiled (required, contract bytecode)

=item params (required, constructor params)

=back

Returns a L<Ethereum::Contract::ContractTransaction> object.

=cut

sub invoke_deploy {
    my ($self, $compiled_data, @params) = @_;
    return $self->_prepare_transaction($compiled_data, undef, \@params);
}

=head2 append_prefix

Ensure that the given hexadecimal string starts with 0x.

=over 4

=item str => string (hexadecimal)

=back

Returns a string hexadecimal

=cut

sub append_prefix {
    my ($self, $str) = @_;
    return $str =~ /^0x/ ? $str : "0x$str";
}

1;
