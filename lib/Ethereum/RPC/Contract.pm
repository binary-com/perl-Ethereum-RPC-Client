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
has contract_abi     => (
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

has gas_price => (is => 'rw');

has gas => (is => 'rw');

has max_fee_per_gas => (is => 'rw');

has max_priority_fee_per_gas => (is => 'rw');

has contract_decoded => (
    is      => 'rw',
    default => sub { {} },
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

=item max_fee_per_gas => numeric (optional)

=item max_priority_fee_per_gas => numeric (optional)

=back

=cut

sub BUILD {
    my ($self) = @_;
    my @decoded_json = @{decode_json($self->contract_abi // "[]")};

    for my $json_input (@decoded_json) {
        if ($json_input->{type} =~ /^function|event$/) {
            $self->contract_decoded->{$json_input->{name}} ||= [];
            push(@{$self->contract_decoded->{$json_input->{name}}}, $json_input->{inputs}) if scalar @{$json_input->{inputs}} > 0;
        }
    }

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

    my $res = $self->_prepare_transaction($function_id, \@params);

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
    my ($self, $compiled_data, $params) = @_;

    my $hex_params = $self->get_hex_param($params);

    my $data = $compiled_data . $hex_params;

    my $transaction = Ethereum::RPC::Contract::ContractTransaction->new(
        contract_address => $self->contract_address,
        rpc_client       => $self->rpc_client,
        data             => $self->append_prefix($data),
        from             => $self->from,
        gas              => $self->gas,
    );

    $transaction->{gas_price}                = $self->gas_price                if $self->gas_price;
    $transaction->{max_fee_per_gas}          = $self->max_fee_per_gas          if $self->max_fee_per_gas;
    $transaction->{max_priority_fee_per_gas} = $self->max_priority_fee_per_gas if $self->max_priority_fee_per_gas;
    return $transaction;
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
    my ($self, $params) = @_;

    my @offset_indices;
    my @static;
    my @dynamic;

    #TODO:
    # - Arrays
    # - Bytes
    for my $param (@$params) {
        if ($param =~ /^0x[0-9A-F]+$/i) {
            push(@static, sprintf("%064s", substr($param, 2)));
        } elsif (looks_like_number($param)) {
            push(@static, sprintf("%064s", Math::BigInt->new($param)->to_hex));
        } else {
            push(@offset_indices, scalar @dynamic);
            my $hex_value = unpack("H*", $param);
            push(@dynamic, sprintf("%064s", Math::BigInt->new(length($param))->to_hex));
            push(@dynamic, $hex_value . "0" x (64 - length($hex_value)));
        }
    }

    my $offset_count = scalar @offset_indices + scalar @static;
    my @offset       = map { sprintf("%064s", Math::BigInt->new(($offset_count + $_) * 32)->to_hex) } @offset_indices;

    my $hex_response = join("", @offset, @static, @dynamic);
    return $hex_response;

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
                topics    => [$function_id]}]);

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
    return $self->_prepare_transaction($compiled_data, \@params);
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
