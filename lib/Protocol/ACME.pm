package Protocol::ACME;

use 5.006;
use strict;
use warnings;

=head1 NAME

Protocol::ACME - Perl interface to the Let's Encrypt ACME API

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Protocol::ACME;

    my $foo = Protocol::ACME->new();
    ...


=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=cut

package Log::Any::Adapter::AcmeLocal;

use Log::Any::Adapter::Util ();
use Time::HiRes qw( gettimeofday );
use base qw/Log::Any::Adapter::Base/;

my $trace_level = Log::Any::Adapter::Util::numeric_level('trace');

sub init {
    my ($self) = @_;
    if ( exists $self->{log_level} ) {
        $self->{log_level} =
          Log::Any::Adapter::Util::numeric_level( $self->{log_level} )
          unless $self->{log_level} =~ /^\d+$/;
    }
    else {
        $self->{log_level} = $trace_level;
    }
}

foreach my $method ( Log::Any::Adapter::Util::logging_methods() ) {
    no strict 'refs';
    my $method_level = Log::Any::Adapter::Util::numeric_level($method);
    *{$method} = sub {
        my ( $self, $text ) = @_;
        return if $method_level > $self->{log_level};

        my ( $sec, $usec ) = gettimeofday();

        printf STDOUT "%d.%06d %s\n", $sec, $usec, $text;
    };
}

foreach my $method ( Log::Any::Adapter::Util::detection_methods() ) {
    no strict 'refs';
    my $base = substr( $method, 3 );
    my $method_level = Log::Any::Adapter::Util::numeric_level($base);
    *{$method} = sub {
        return !!( $method_level <= $_[0]->{log_level} );
    };
}


package Protocol::ACME::Exception;

sub new
{
  my $class = shift;

  my $error = shift;
  my $self = { status => 0, detail => "", type => "unknown" };

  if ( ref $error eq "HASH" )
  {
    @$self{keys %$error} = values %$error;
  }
  elsif ( ref $error )
  {
    $self->{detail} = "double error: bad arg passed to exception constructor";
  }
  else
  {
    $self->{detail} = $error;
  }

  bless $self, $class;

  return $self;
}


package Protocol::ACME;

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Bignum;
use MIME::Base64 qw( encode_base64url decode_base64url decode_base64 encode_base64 );
use Digest::SHA2;
use Log::Any qw( $log );
use Log::Any::Adapter ('AcmeLocal', log_level => 'debug' );

use Data::Dumper;


my $NONCE_HEADER = "Replay-Nonce";

sub new
{
  my $class = shift;
  my $self = {};
  bless $self, $class;
  $self->_init( @_ );
  return $self;
}

sub _init
{
  my $self = shift;

  my $args;

  if ( ref $_[0] eq "HASH" )
  {
    $args = $_[0];
  }
  else
  {
    %$args = @_;
  }

  $self->{host} = $args->{host} if exists $args->{host};

  if ( ! exists $self->{ua} )
  {
    $self->{ua} = LWP::UserAgent->new();
  }

  if ( ! exists $self->{host} )
  {
    die Protocol::ACME::Exception->new( { detail => "host parameter is required for Protocol::ACME::new" } );
  }

  if ( exists $args->{account_key} )
  {
    if ( ref $args->{account_key} eq "Crypt::OpenSSL::RSA" )
    {
      $self->{key} = $args->{account_key};
      # TODO: add derivitiaves
    }
    else
    {
      $self->load_key( $args->{account_key}, $args->{account_key_format} );
    }
  }

  $self->{links}->{directory} = "https://" . $self->{host} . '/directory';

  $self->{nonce} = undef;
}

sub load_key
{
  my $self   = shift;
  my $path   = shift;
  my $format = shift || "PEM";

  my $fh = IO::File->new( $path );
  if ( ! $fh )
  {
    die Protocol::ACME::Exception->new( { detail => "Could not open the key file ($path): $!" } );
  }

  my $keystring;
  while( <$fh> )
  {
    $keystring .= $_;
  }
  $fh->close();

  if ( $format eq "DER" )
  {
    $keystring = der2pem( $keystring, "RSA PRIVATE KEY" );
    print $keystring;
  }

  my $key = Crypt::OpenSSL::RSA->new_private_key($keystring);

  if ( ! $key )
  {
    die Protocol::ACME::Exception->new( { detail => "Could not load key into key structure" } );
  }

  $key->use_sha256_hash();

  $self->{key}->{key} = $key;
  my ( $n_b64, $e_b64 ) = map { encode_base64url($_->to_bin()) } $key->get_key_parameters();
  $self->{key}->{n} = $n_b64;
  $self->{key}->{e} = $e_b64;

  $log->debug( "Private key loaded" );
}


sub directory
{
  my $self = shift;

  my $resp = $self->_request_get( $self->{links}->{directory} );

  if ( $resp->code() != 200 )
  {
    die Protocol::ACME::Exception->new( { detail => "Failed to fetch the directory for $self->{host}" } );
  }

  my $data = decode_json( $resp->content() );

  @{$self->{links}}{keys %$data} = values %$data;

  $log->debug( "Let's Encrypt Directories loaded." );
}

#
# Register the account or load the reg url for an existing account ( new-reg or reg )
#
sub register
{
  my $self = shift;

  my $msg = encode_json( { resource => 'new-reg' } );
  my $json = $self->_create_jws( $msg );

  $log->debug( "Sending registration message" );

  my $resp = $self->_request_post( $self->{links}->{'new-reg'}, $json );

  if ( $resp->code() == 409 )
  {
    $self->{links}->{'reg'} = $resp->header( 'location' );

    $log->debug( "Known key used" );
    $log->debug( "Refetching with location URL" );

    my $json = $self->_create_jws( encode_json( { "resource" => 'reg' } ) );

    $resp = $self->_request_post( $self->{links}->{'reg'}, $json );

    if ( $resp->code() == 202 )
    {
      my $links = link_to_hash( $resp->header( 'link' ) );

      @{$self->{links}}{keys %$links} = values %$links;
    }
    else
    {
      die Protocol::ACME::Exception->new( $self->{content} );
    }
  }
  elsif ( $resp->code() == 201 )
  {
    my $links = link_to_hash( $resp->header( 'link' ) );

    @{$self->{links}}{keys %$links} = values %$links;

    $self->{links}->{'reg'} = $resp->header( 'location' );
    $log->debug( "New key used" );
  }
  else
  {
    die Protocol::ACME::Exception->new( $self->{content} );
  }

  $self->{reg} = $self->{content};
}

sub accept_tos
{
  my $self = shift;

  if ( exists $self->{reg}->{agreement} )
  {
    $log->debug( "TOS already accepted. Skipping" );
    return;
  }

  $log->debug( "Accepting TOS" );
  # TODO: how needed is this?
  # TODO: check for existance of terms-of-service link
  # TODO: assert on reg url being present

  my $msg = hash_to_json( { "resource"  => "reg",
                            "agreement" => $self->{links}->{'terms-of-service'},
                            "key"       => { "e"   => $self->{key}->{e},
                                             "kty" => "RSA",
                                             "n"   => $self->{key}->{n} } } );


  my $json = $self->_create_jws( $msg );

  my $resp = $self->_request_post( $self->{links}->{'reg'}, $json );

  if ( $resp->code() == 202 )
  {
    $log->debug( "Accepted TOS" );
  }
  else
  {
    die Protocol::ACME::Exception->new( $self->{content} );
  }
}

sub authz
{
  my $self   = shift;
  my $domain = shift;

  $log->debug( "Sending authz message for $domain" );
  # TODO: check for 'next' URL and that is it authz

  my $msg = hash_to_json( { "identifier" => { "type" => "dns", "value" => $domain },
                            "resource"   => "new-authz" } );

  my $json = $self->_create_jws( $msg );

  my $resp = $self->_request_post( $self->{links}->{next}, $json );

  if ( $resp->code() == 201 )
  {
    $self->{challenges} = $self->{content}->{challenges};
  }
  else
  {
    die Protocol::ACME::Exception->new( $self->{content} );
  }
}

sub handle_challenge
{
  my $self = shift;
  my $cb = shift;
  my @args = @_;

  my $key = $self->{key};

  my $jwk = hash_to_json( { "e" => $key->{e}, "kty" => "RSA", "n" => $key->{n} } );
  my $token;
  my $challenge_url;

  # TODO: this is feeling hardcoded and messy - and fragile
  #       how do we handle other auth challenges?
  #       This is hardcoded for http-01
  for ( @{$self->{challenges}} )
  {
    if ( $_->{type} eq "http-01" )
    {
      $token = $_->{token};
      $challenge_url = $_->{uri};
    }
  }

  my $sha2obj = new Digest::SHA2 256;
  $sha2obj->add( $jwk );

  my $fingerprint = encode_base64url($sha2obj->digest());

  $log->debug( "Handing challenge for token: $token.$fingerprint" );

  my $ret = $cb->( $token, $fingerprint, @args );

  if ( $ret == 0 )
  {
    $self->{fingerprint} = $fingerprint;
    $self->{token} = $token;
    $self->{links}->{challenge} = $challenge_url;
  }
  else
  {
    die Protocol::ACME::Exception->new( { status => 0, detail => $ret, type => "challenge_exec" } );
  }
}


sub check_challenge
{
  my $self = shift;

  my $msg = hash_to_json( { "resource" => "challenge", "keyAuthorization" => $self->{token} . '.' . $self->{fingerprint} } );

  my $json = $self->_create_jws( $msg );


  my $resp = $self->_request_post( $self->{links}->{challenge}, $json );

  my $status_url = $self->{content}->{uri};

  # TODO: check for failuer of challenge check
  # todo - check for other HTTP failures

  $log->debug( "Polling for challenge fullfillment" );
  while( 1 )
  {
    $log->debug( "Status: $self->{content}->{status}" );
    if ( $self->{content}->{status} eq "pending" )
    {
      sleep(2);
      $resp = $self->_request_get( $status_url );
    }
    else
    {
      last;
    }
  }
}

sub sign
{
  my $self = shift;
  my $csr = shift;

  my $fh = IO::File->new( $csr ) || die $!;
  my $der;
  while( <$fh> )
  {
    $der .= $_;
  }
  $fh->close();


  my $msg = hash_to_json( { "resource" => "new-cert", "csr" => encode_base64url( $der ) } );

  my $json = $self->_create_jws( $msg );

  my $resp = $self->_request_post( $self->{links}->{'new-cert'}, $json );

  if ( $resp->code() != 201 )
  {
    die Protocol::ACME::Exception->new( $self->{content} );
  }

  my $cert = $resp->content();

  # TODO: do not just write this out to a file
#  my $cert_fh = IO::File->new( "cert.der", "w" ) || die $!;
#  print $cert_fh $cert;
#  $cert_fh->close();

  return $cert;
}

#############################################################
### Private functions

sub _request_get
{
  my $self = shift;
  my $url  = shift;

  my $resp = $self->{ua}->get( $url );

  $self->{nonce} = $resp->header( $NONCE_HEADER );
  $self->{json} = $resp->content();

    eval {
$self->{content} = decode_json( $resp->content() );
};
  return $resp;
}

sub _request_post
{
  my $self    = shift;
  my $url     = shift;
  my $content = shift;

  my $resp = $self->{ua}->post( $url, Content => $content );

  $self->{nonce} = $resp->header( $NONCE_HEADER );
  $self->{json} = $resp->content();

  eval {
  $self->{content} = decode_json( $resp->content() );
};
  
  return $resp;
}

sub _create_jws
{
  my $self = shift;
  my $msg = shift;
  return create_jws( $self->{key}, $msg, $self->{nonce} );
}


#############################################################
### Helper functions - not class methods

sub link_to_hash
{
  my $links;

  for my $link ( @_ )
  {
    my ( $value, $key ) = split( ';', $link );
    my ($url) = $value =~ /<([^>]*)>/;
    my ($rel) = $key =~ /rel=\"([^"]*)"/;

    if ( $url && $rel )
    {
      $links->{$rel} = $url;
    }
    else
    {
      # TODO: Something wonderful
    }
  }

  return $links;
}

sub hash_to_json
{
  my $hash = shift;
  my $json = "{";
  my $quote = '"';
  my $colon = ':';
  my $comma = ',';

  for ( sort keys %$hash )
  {
    # die "hash_to_json does not handle nested references yet" if ref $hash->{$_};
    if ( ref $hash->{$_} eq "HASH" )
    {
      $json .= $quote . $_ . $quote . $colon . hash_to_json($hash->{$_}) . $comma;
    }
    else
    {
      $json .= $quote . $_ . $quote . $colon . $quote . $hash->{$_} . $quote . $comma;
    }
  }

  $json =~ s/,$//;

  $json .= '}';
}


sub create_jws
{
  my $key = shift;
  my $msg = shift;
  my $nonce = shift;

  my $protected_header = '{"nonce": "' . $nonce . '"}';

  my $sig = encode_base64url( $key->{key}->sign( encode_base64url($protected_header) . "." . encode_base64url($msg) ) );

  my $jws = { header    => { alg => "RS256", jwk => { "e" => $key->{e}, "kty" => "RSA", "n" => $key->{n} } },
              protected => encode_base64url( $protected_header ),
              payload   => encode_base64url( $msg ),
              signature => $sig };

  my $json = hash_to_json( $jws );

  return $json;

}


sub pem2der
{
  my $pem = shift;
  $pem =~ s/^\-\-\-[^\n]*\n//mg;
  return decode_base64( $pem );
}

sub der2pem
{
  my $der = shift;
  my $tag = shift;

  my $pem = encode_base64( $der );
  $pem = "-----BEGIN $tag-----\n" . $pem . "-----END $tag-----\n";

  return $pem;
}


=head1 SUBROUTINES/METHODS

=head2 function1

=cut


=head2 function2

=cut


=head1 AUTHOR

Stephen Ludin, C<< <sludin at ludin.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-protocol-acme at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Protocol-ACME>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Protocol::ACME


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Protocol-ACME>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Protocol-ACME>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Protocol-ACME>

=item * Search CPAN

L<http://search.cpan.org/dist/Protocol-ACME/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2015 Stephen Ludin.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of Protocol::ACME
