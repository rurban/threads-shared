package threads::shared;

use 5.7.2;
use strict;
use warnings;

require Exporter;
require DynaLoader;

use attributes qw(reftype);

use Scalar::Util qw(weaken);

use threads 0.03;

our @ISA = qw(Exporter DynaLoader);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use threads::shared ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	share lock unlock cond_signal cond_wait cond_broadcast
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(share cond_signal cond_wait cond_broadcast lock unlock);
	
use Carp qw(croak);

our $VERSION = '0.02';

our %shared;

sub share ($) {
    my $value = shift;
    my $ref = reftype($value);
    croak "Need a reference" unless($ref);
    if($ref eq 'SCALAR') {
	my $obj = bless \threads::shared::sv->new(),'threads::shared::sv';
	$obj->attach($$value);
    } elsif($ref eq 'ARRAY') {
	tie @$value, 'threads::shared';
    } elsif($ref eq 'HASH') {
	tie %$value, 'threads::shared';
    }
    return $value;
}

sub shared_ref ($) {
	my $value = shift;
	return undef unless(ref($value));
	my $ref = reftype($value);
	if($ref eq 'REF') {
		$value = $$value;
		$ref = reftype($value);
      	}
	return $value if(UNIVERSAL::isa($value, 'threads::shared'));
	return tied $$value if($ref eq 'SCALAR' && tied $$value);
	return tied @$value if($ref eq 'ARRAY' && tied @$value);
	return undef;
}

sub lock ($) {
	my $ref = shift;
	my $self = shared_ref($ref);
	croak "$ref is not usable" unless($self);
	$self->_lock();
}

sub unlock ($) {
	my $ref = shift;
	my $self = shared_ref($ref);
	croak "$ref is not usable" unless($self);
	$self->_unlock();
}

sub cond_wait ($) {
	my $ref = shift;
	my $self = shared_ref($ref);
	croak "$ref is not usable" unless($self);
	$self->_cond_wait();
}

sub cond_broadcast ($) {
	my $ref = shift;
	my $self = shared_ref($ref);
	croak "$ref is not usable" unless($self);
	$self->_cond_broadcast();
}

sub cond_signal ($) {
	my $ref = shift;
	my $self = shared_ref($ref);
	croak "$ref is not usable" unless($self);
	$self->_cond_signal();
}

sub TIEARRAY {
	my $class = shift;
	my $self = bless \threads::shared::av->new(),'threads::shared::av';
	$shared{$self->ptr} = $self;
	weaken($shared{$self->ptr});
	return $self;
}


sub TIEHASH {
	my $class = shift;
	my $self = bless \threads::shared::hv->new(),'threads::shared::hv';
	$shared{$self->ptr} = $self;
	weaken($shared{$self->ptr});


	return $self;
}

sub CLONE {

	foreach my $ptr (keys %shared) {
	    if($ptr) {
		my $foo; #workaround for scalar leak!
		$shared{$ptr}->thrcnt_inc();
	    }
	}
}

sub DESTROY {
    my $self = shift;
    my $ref = $$self;
    $self->thrcnt_dec();
    delete($shared{$self->ptr});
}

package threads::shared::sv;
use base 'threads::shared';

package threads::shared::av;
use base 'threads::shared';

package threads::shared::hv;
use base 'threads::shared';


bootstrap threads::shared $VERSION;


1;
__END__

=head1 NAME

threads::shared - Perl extension for sharing data structures between threads

=head1 SYNOPSIS

  use threads::shared;

  my($foo, @foo, %foo);
  share(\$foo);
  share(\@foo);
  share(\%hash);
  my $bar = share([]);
  $hash{bar} = share({});

  lock(\%hash);
  unlock(\%hash);
  cond_wait($scalar);
  cond_broadcast(\@array);
  cond_signal($scalar);

=head1 DESCRIPTION

 This modules allows you to share() variables. These variables will then be shared across different threads (and pseudoforks on win32). They are used together with the threads module.

=head2 EXPORT

share(), lock(), unlock(), cond_wait, cond_signal, cond_broadcast

=head1 BUGS

Not stress tested!
Does not support references
Does not support splice on arrays!
The exported functions need a reference due to unsufficent prototyping!

=head1 AUTHOR

Artur Bergman <lt>artur at contiller.se<gt>

threads is released under the same license as Perl

=head1 SEE ALSO

L<perl> L<threads>

=cut
