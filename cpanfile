requires 'Moo';
requires 'MojoX::JSON::RPC';
requires 'Math::BigInt', '>= 1.999811';
requires 'Math::BigFloat', '>= 1.999811';
requires 'perl', '5.014';
requires 'JSON', '2.97001';

on configure => sub {
    requires 'ExtUtils::MakeMaker', '>= 7.1101';
};

on test => sub {
    requires 'Test::More', '0.96';
};
