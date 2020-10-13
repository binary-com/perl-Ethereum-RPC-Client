requires 'perl', '5.014';
requires 'Moo';
requires 'Path::Tiny';
requires 'Mojo::UserAgent';
requires 'Math::BigInt', '>= 1.999814';
requires 'Math::BigFloat', '>= 1.999814';
requires 'JSON', '2.97001';
requires 'JSON::MaybeXS', '>= 1.003008';
requires 'List::Util';
requires 'Scalar::Util';
requires 'Future', '>= 0.37';

on configure => sub {
    requires 'ExtUtils::MakeMaker', '>= 7.1101';
};

on test => sub {
    requires 'Test::More', '0.96';
};
