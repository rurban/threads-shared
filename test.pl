# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';
use strict;
use ExtUtils::testlib;
use threads;
use threads::shared;

use Test;
BEGIN { plan tests => 5 };

sub foo {};

tie my %hash, 'threads::shared';

ok(1);

my @threads;
for my $i (1..5) {
    push @threads, threads->create(sub { for ( 1..10000) { $hash{$i} = $_ }});
}
for(@threads) {
    $_->join;
}

ok(keys %hash, 5);
ok($hash{2}, 10000);



my $foo;
tie $foo,'threads::shared';

my @threads;
for my $i (1..5) {
    push @threads, threads->create(sub { for ( 1..10000) { $foo = $_ }});
}
for(@threads) {
    $_->join;
}


ok($foo, 10000);

my @foo;
tie @foo,'threads::shared';

my @threads;
for my $i (1..5) {
    push @threads, threads->create(sub { for ( 1..10000) { $foo[$i] = $_ }});
}
for(@threads) {
    $_->join;
}

ok($foo[4], 10000);


























