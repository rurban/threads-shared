# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';
use strict;
use ExtUtils::testlib;
use threads;
use threads::shared;

use Devel::Peek;

use Test;
BEGIN { plan tests => 5 };



sub foo {};


my %hash;
share(\%hash);
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
share(\$foo);


my @threads;
for my $i (1..5) {
    push @threads, threads->create(sub { for ( 1..10000) { $foo = $_ }});
}
for(@threads) {
    $_->join;
}


ok($foo, 10000);


my @foo;
share(\@foo);

my @threads;
for my $i (1..5) {
    push @threads, threads->create(sub { for ( 1..10000) { $foo[$i] = $_ }});
}
for(@threads) {
    $_->join;
}

ok($foo[4], 10000);


my $test = share({});
$test->{hi} = share([]);
threads->create(sub { $test->{hi}->[0] = share([]); $test->{hi}[0][5] = "yeah"})->join();
ok($test->{hi}[0][5],"yeah");























