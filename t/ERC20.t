use strict;
use warnings;

use Test::More;
use Math::BigInt;

use Ethereum::RPC::Client;
use Ethereum::RPC::Contract::Helper::ImportHelper;

BEGIN {
    plan skip_all => 'Needs Travis setup'
        unless $ENV{TRAVIS};
}

my $rpc_client = Ethereum::RPC::Client->new;

my $coinbase = $rpc_client->eth_coinbase;

my $truffle_project = Ethereum::RPC::Contract::Helper::ImportHelper::from_truffle_build("./t/builds/SimpleToken.json");

die "can't read json" unless $truffle_project;

my $contract = $rpc_client->contract({
    contract_abi    => $truffle_project->{abi},
    from            => $coinbase,
    gas             => 4000000,
});

my $response = $contract->invoke_deploy($truffle_project->{bytecode})->get_contract_address(35);
die $response->get if $response->is_failed;

$contract->contract_address($response->get->response);

$rpc_client->personal_newAccount("test");

my @account_list = @{$rpc_client->eth_accounts()};

$response = $contract->invoke("name")->call_transaction();
ok !$response->is_failed;
is $response->get->to_string, "SimpleToken";

$response = $contract->invoke("symbol")->call_transaction();
ok !$response->is_failed;
is $response->get->to_string, "SIM";

$response = $contract->invoke("decimals")->call_transaction();
ok !$response->is_failed;
is $response->get->to_big_int, 18;

$response = $contract->invoke("balanceOf", $coinbase)->call_transaction();
ok !$response->is_failed;
my $coinbase_balance = $response->get->to_big_int;

$response = $contract->invoke("balanceOf", $account_list[1])->call_transaction();
ok !$response->is_failed;
my $account_one_balance = $response->get->to_big_int;

$response = $contract->invoke("approve", $account_list[1], 1000)->send_transaction();
ok !$response->is_failed;

sleep 2;

$response = $contract->invoke("allowance", $coinbase, $account_list[1])->call_transaction();
ok !$response->is_failed;
is $response->get->to_big_int, 1000;

$response = $contract->invoke("transfer", $account_list[1], 1000)->send_transaction();
ok !$response->is_failed;

sleep 2;

$response = $contract->invoke("balanceOf", $coinbase)->call_transaction();
ok !$response->is_failed;
is $response->get->to_big_int, Math::BigInt->new($coinbase_balance - 1000);

$response = $contract->invoke("balanceOf", $account_list[1])->call_transaction();
ok !$response->is_failed;
is $response->get->to_big_int, Math::BigInt->new($account_one_balance + 1000);

done_testing();
