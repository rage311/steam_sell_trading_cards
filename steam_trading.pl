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



die 'Invalid config' unless my $config = read_config();

my $ua = Mojo::UserAgent->new->max_connections(0);

die 'No session id' unless my $sessionid  = sessionid($ua);
die 'No steam_rsa result' unless
  my $rsa_params = steam_rsa($ua, $config->{username});

die "Unable to encrypt password: $!" unless
  my $pw_encrypted = rsa_encrypt(
    $rsa_params->{mod},
    $rsa_params->{exp},
    $config->{password}
  );

# prompt for Steam two factor code
print 'Two factor code: ';
my $two_factor = <STDIN>;
chomp $two_factor;

die 'Unable to login' unless
  steam_login(
    $ua,
    $config->{username},
    $pw_encrypted,
    $two_factor,
    $rsa_params->{ts}
  );

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

if ($ENV{DEBUG}) {
  say 'Tradable:';
  p @tradable;
}


my $confirmation_needed;

# selling fee is 15% (you receive ~86.96% of listed price)
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

  say $list_success
    ? '  Successful'
    : '  FAILED';
  print "\n";

  #$confirmation_needed |= $result->{requires_confirmation};
}








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
  $ua->get('https://steamcommunity.com/login/');

  return (
    first {
      $_->name eq 'sessionid'
    } $ua->cookie_jar->find(Mojo::URL->new('https://steamcommunity.com'))->@*
  )->value;

  #return (first { $_->name eq 'sessionid' } $result->cookies->@*)->value;
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


sub steam_login ($ua, $username, $password, $two_factor, $rsa_ts) {
  my $login = $ua->post(
    'https://steamcommunity.com/login/dologin/',
    form => {
      donotcache     => time * 1000,
      password       => $password,
      username       => $username,
      twofactorcode  => $two_factor,
      rsatimestamp   => $rsa_ts,
      captchagid     => -1,
      remember_login => 'true',
      captcha_text   => '',
      emailsteamid   => '',
    })->result->json;

  return $login->{success} && $login->{login_complete};
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

  p $sell_result if $ENV{DEBUG};
  say "Listing failed: $sell_result->{message}" if
    $sell_result && !$sell_result->{success};

  return $sell_result && $sell_result->{success};
}

