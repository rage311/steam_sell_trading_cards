#!/usr/bin/env perl

use 5.026;

use Mojo::Base -strict, -signatures;
use Mojo::JSON::MaybeXS;
use Mojo::UserAgent;
use Mojo::Promise;
use DDP { class => { expand => 'all' } };
use Mojo::Util qw(b64_encode);
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Bignum;
use List::Util qw(first);
use FindBin qw($RealBin);
use YAML;

use constant {
  LOGIN_FAILURE     => undef,
  LOGIN_TWOFACTOR   => 0,
  LOGIN_SUCCESS     => 1,

  SELL_FAILURE      => undef,
  SELL_CONFIRMATION => 0,
  SELL_SUCCESS      => 1,
};


die 'Invalid config' unless my $config = read_config();

my $ua = Mojo::UserAgent->new->max_connections(0);

die 'No session id' unless my $sessionid  = sessionid($ua);

die 'Unable to login' unless defined(my $login_result = login_steps(undef));

until ($login_result == LOGIN_SUCCESS) {
  $login_result = login_steps(twofactor_prompt()) if
    $login_result == LOGIN_TWOFACTOR;

  die 'Unable to login' unless defined $login_result;
}

die 'Unable to retrieve inventory' unless
  my $inventory = inventory($ua, $config->{id}, 753);

die 'Nothing to sell' unless
  $inventory->{total_inventory_count} > 0 && $inventory->{assets};

say "Inventory count: $inventory->{total_inventory_count}";

my @tradable = tradable($inventory->{assets}, $inventory->{descriptions});

my %uniq_tradable;
%uniq_tradable = map {
    ! exists $uniq_tradable{$_->{market_hash_name}}
      ? ($_->{market_hash_name} => $_->{appid})
      : ()
  } @tradable;

my @price_promises;
push @price_promises, lowest_price($ua, $uniq_tradable{$_}, $_)
  for keys %uniq_tradable;

Mojo::Promise->all(@price_promises)->then(sub (@lowest_prices) {
  my %lowest_hash = map {
    $_->[0] => $_->[1]
  } @lowest_prices;

  $_->{lowest_price} = $lowest_hash{$_->{market_hash_name}} for @tradable;
})->catch(sub ($err_msg) {
  warn "Error getting lowest_price: $err_msg";
})->wait;

say 'Tradable:' and p @tradable if $ENV{DEBUG};


my $confirmation_needed;

# selling fee is 15% (you receive ~87% of listed price)
# sell "price" param is what you receive, not actual listed price
for my $asset (@tradable) {
  my $sell_price = int(int($asset->{lowest_price} =~ s/[^\d]//gr) * 0.87);

  warn "$asset->{market_hash_name} sell price would be 0" and next unless
    $sell_price > 0;

  my $list_success = list_asset(
    $ua,
    $config->{username},
    $sessionid,
    $asset,
    $sell_price
  );

  print "Listing: $asset->{type} - $asset->{name} for ";
  printf "\$%.2f\n", $sell_price / 100;

  if (! defined $list_success) {
    say '  FAILED';
  }
  elsif ($list_success == SELL_CONFIRMATION) {
    say '  requires confirmation';
  }
  elsif ($list_success == SELL_SUCCESS) {
    say '  successful';
  }

  print "\n";

  $confirmation_needed |= 1 if
    $list_success && $list_success == SELL_CONFIRMATION;
}

say "NOTE: These listings require confirmation before being listed on market\n"
  if $confirmation_needed;






sub read_config {
  my $config = YAML::LoadFile("$RealBin/config.yml") or die "$!";

  warn 'username, password, and id are required in config.yml' and return undef
    unless $config
      && ref $config eq 'HASH'
      && $config->{username}
      && $config->{password}
      && $config->{id};

  return $config;
}


sub sessionid ($ua) {
  my $result = $ua->get('https://steamcommunity.com/login/')->result;

  return (
    first {
      $_->name eq 'sessionid'
    } $ua->cookie_jar->find(Mojo::URL->new('https://steamcommunity.com'))->@*
  )->value;
}


sub steam_rsa ($ua, $username) {
  my $rsa = $ua->post(
    'https://steamcommunity.com/login/getrsakey/',
    form => {
      username   => $username,
      donotcache => time * 1000,
    })->result->json;

  return $rsa && $rsa->{success}
    ? { mod => $rsa->{publickey_mod},
        exp => $rsa->{publickey_exp},
        ts  => $rsa->{timestamp} }
    : undef;
}


sub rsa_encrypt ($mod, $exp, $plaintext) {
  my $rsa = Crypt::OpenSSL::RSA->new_key_from_parameters(
    Crypt::OpenSSL::Bignum->new_from_hex($mod),
    Crypt::OpenSSL::Bignum->new_from_hex($exp)
  );
  $rsa->use_pkcs1_padding();

  return b64_encode $rsa->encrypt($plaintext), '';
}


sub steam_login ($ua, $username, $password_encrypted, $two_factor, $rsa_ts) {
  my $login = $ua->post(
    'https://steamcommunity.com/login/dologin/',
    form => {
      donotcache     => time * 1000,
      password       => $password_encrypted,
      username       => $username,
      twofactorcode  => $two_factor,
      rsatimestamp   => $rsa_ts,
      captchagid     => -1,
      remember_login => 'true',
      captcha_text   => '',
      emailsteamid   => '',
    })->result->json;

  warn "$!" and return LOGIN_FAILURE unless $login;

  if (!$login->{success}) {
    # no message when requires_twofactor is true
    say 'Requires two factor code' and return
      LOGIN_TWOFACTOR if $login->{requires_twofactor};

    say 'Login unsuccessful';
    say $login->{message} if $login->{message};

    return LOGIN_FAILURE;
  }

  return LOGIN_SUCCESS if $login->{login_complete};
}


sub login_steps ($twofactor) {
  die 'No steam_rsa result' unless
    my $rsa_params = steam_rsa($ua, $config->{username});

  die "Unable to encrypt password: $!" unless
    my $password_encrypted = rsa_encrypt(
      $rsa_params->{mod},
      $rsa_params->{exp},
      $config->{password}
    );

  #die 'Unable to login' unless
  return steam_login(
    $ua,
    $config->{username},
    $password_encrypted,
    $twofactor,
    $rsa_params->{ts}
  );
}


sub twofactor_prompt {
  # prompt for Steam two factor code
  print 'Two factor code: ';# (Ctrl+D if not required): ';
  my $twofactor = <STDIN>;
  # print "\n";
  chomp $twofactor if defined $twofactor;
  return $twofactor;
}


sub inventory ($ua, $steamid, $appid) {
  # get "Steam app" (753) inventory
  my $inventory = $ua->get(
   "https://steamcommunity.com/inventory/$steamid/$appid/6",
    form => {
      l     => 'english',
      count => 75,
    })->result->json;

  #die 'Unable to retrieve inventory' unless $inventory->{success};
  return $inventory;
}


sub tradable ($assets, $descriptions) {
  my @tradable;

  for my $asset (@$assets) {
    my $desc_match = first {
      $_->{tradable}
      && index($_->{type}, 'Trading Card') > -1
      && $_->{classid} == $asset->{classid}
    } $inventory->{descriptions}->@*;

    next unless $desc_match;

    # name, type, market_hash_name (to get pricing)
    $asset->{$_} = $desc_match->{$_} for qw(name type market_hash_name);
    push @tradable, $asset;
  }

  return @tradable;
}


# non-blocking -- returns promise
sub lowest_price ($ua, $appid, $market_hash_name) {
  my $promise = Mojo::Promise->new;

  $ua->get(
    'https://steamcommunity.com/market/priceoverview/',
    form => {
      country          => 'US',
      currency         => 1,
      appid            => $appid,
      market_hash_name => $market_hash_name,
    } => sub ($ua, $tx) {
      my $err = $tx->error;
      my $lowest_price = $tx->result->json->{lowest_price};

      $promise->resolve($market_hash_name, $lowest_price)
        if !$err || $err->{code} && defined $lowest_price;

      $promise->reject($err->{message});
    });

  return $promise;
}


# $asset->{qw(appid contextid asset)} required
sub list_asset ($ua, $username, $sessionid, $asset, $price_cents) {
  # these requests have to be non-concurrent, otherwise Steam gives an error
  my $sell_result = $ua->post(
    'https://steamcommunity.com/market/sellitem/',
    { Referer => "https://steamcommunity.com/id/$username/inventory/" },
    form => {
      sessionid => $sessionid,
      appid     => $asset->{appid},
      contextid => $asset->{contextid},
      assetid   => $asset->{assetid},
      amount    => 1,
      price     => $price_cents,
  })->result->json;

  return undef unless $sell_result;

  p $sell_result if $ENV{DEBUG};

  say "Listing failed: $sell_result->{message}" if
    $sell_result && !$sell_result->{success};

  return !$sell_result->{success}
    ? undef
    : ($sell_result->{needs_email_confirmation}
       || $sell_result->{needs_mobile_confirmation})
      ? SELL_CONFIRMATION()
      : SELL_SUCCESS();
}

