#!/usr/bin/env perl

use 5.026;

use Mojo::Base -strict, -signatures;
use Mojo::UserAgent;
use Mojo::Promise;
use Mojo::Util qw(b64_encode dumper getopt extract_usage);
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


binmode STDOUT, ':encoding(UTF-8)';

getopt(
  'a|adjust=i' => \my $adjust,
  'n|dry-run'  => \my $dry_run,
  'd|debug'    => \my $debug,
  'h|help'     => sub { print extract_usage() and exit; },
);

$debug ||= $debug;

if ($debug) {
  say 'CLI Options:';
  say "  adjust:  ", $adjust  // 0;
  say "  dry-run: ", $dry_run // 0;
  say "  debug:   ", $debug   // 0;
}

die 'Invalid config' unless my $config = read_config();

$config->{price_adjust} = $adjust if defined $adjust;
say dumper $config if $debug;

my $ua = Mojo::UserAgent->new->max_connections(0)->connect_timeout(15);

die 'No session id' unless my $sessionid  = sessionid($ua);

die 'Unable to login' unless defined(my $login_result = login_steps());

until ($login_result == LOGIN_SUCCESS) {
  $login_result = login_steps(twofactor_prompt()) if
    $login_result == LOGIN_TWOFACTOR;

  die 'Unable to login' unless defined $login_result;
}

die 'Unable to retrieve inventory' unless
  my $inventory = inventory($ua, $config->{id}, 753);

die 'No Steam items to sell' unless
  $inventory->{total_inventory_count} > 0 && $inventory->{assets};

say "Inventory count: $inventory->{total_inventory_count}";

if ($debug) {
  say $_->{type} for $inventory->{descriptions}->@*;
}

die 'No tradable items' unless
  my @tradable = tradable($inventory->{assets}, $inventory->{descriptions});

say dumper @tradable if $debug;

my %uniq_tradable = map { $_->{market_hash_name} => $_->{appid} } @tradable;

say dumper %uniq_tradable if $debug;

my @price_promises = map {
  lowest_price($ua, $uniq_tradable{$_}, $_)
} keys %uniq_tradable;

say dumper @price_promises if $debug;

Mojo::Promise->all(@price_promises)->then(sub (@lowest_prices) {
  my %lowest_hash = map { $_->[0] => $_->[1] } @lowest_prices;
  $_->{lowest_price} = $lowest_hash{$_->{market_hash_name}} for @tradable;
})->catch(sub ($err_msg) {
  warn "Error getting lowest_price: $err_msg";
})->wait;

say 'Tradable:', dumper @tradable if $debug;

printf "Listing with adjustment of \$ %+.2f\n", $config->{price_adjust} / 100;

my $confirmation_needed;
my ($total_gross_cents, $total_net_cents) = (0, 0);

# bc .08/2
# .04000000000000000000
# bc .175/2
# .08750000000000000000

# selling fee is 15% (you receive ~87% of listed price)
# sell "price" param is what you receive, not actual listed price
for my $asset (@tradable) {
  (my $gross_price_cents = $asset->{lowest_price}) =~ s/[^\d]//g;
  $gross_price_cents += $config->{price_adjust};

  my $net_price_cents = $gross_price_cents - int($gross_price_cents * 0.87) <= 2
    ? $gross_price_cents - 2
    : int($gross_price_cents * 0.87) + 1;

  unless ($net_price_cents > 0) {
    say $asset->{market_hash_name}, ' net price would\'ve been $0.00,',
      ' increasing to $0.01';
    $net_price_cents = 1;
  }

  if ($debug) {
    say dumper $asset;
    say "Gross c: ", $gross_price_cents;
    say "Net c:   ", $net_price_cents;
  }

  my ($list_success, $message) = list_asset(
    $ua,
    $config->{username},
    $sessionid,
    $asset,
    $net_price_cents,
    $dry_run,
  );

  print "\nListing: $asset->{type} - $asset->{name}\n";
  printf "  ~\$%.2f (\$%.2f)\n",
    $gross_price_cents / 100,
    $net_price_cents   / 100;

  if (defined $list_success) {
    if ($list_success == SELL_CONFIRMATION) {
      say '  Requires Confirmation';
      $confirmation_needed++;
    }
    elsif ($list_success == SELL_SUCCESS) {
      say '  Successful';
    }

    $total_gross_cents += $gross_price_cents;
    $total_net_cents   += $net_price_cents;
  }
  else {
    say "  FAILED: $message";
  }
}

say "\nNOTE: These listings require confirmation before being listed on market"
  if $confirmation_needed;

printf "\nTotal listings: ~\$%.2f (\$%.2f)\n",
  $total_gross_cents / 100,
  $total_net_cents   / 100;






sub read_config {
  my $config = YAML::LoadFile("$RealBin/config.yml") or die "$!";

  warn 'username, password, and id are required in config.yml' and return
    unless $config
      && ref $config eq 'HASH'
      && $config->{username}
      && $config->{password}
      && $config->{id};

  die "Invalid price_adjust value in config: $config->{price_adjust}" if
    defined $config->{price_adjust} && $config->{price_adjust} !~ /^-?\s*\d+$/;
  $config->{price_adjust} //= 0;

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
    return LOGIN_TWOFACTOR if $login->{requires_twofactor};

    say 'Login unsuccessful';
    say $login->{message} if $login->{message};

    return LOGIN_FAILURE;
  }

  return LOGIN_SUCCESS if $login->{login_complete};
}


sub login_steps ($twofactor = undef) {
  die 'No steam_rsa result' unless
    my $rsa_params = steam_rsa($ua, $config->{username});

  die "Unable to encrypt password: $!" unless
    my $password_encrypted = rsa_encrypt(
      $rsa_params->{mod},
      $rsa_params->{exp},
      $config->{password}
    );

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
  print 'Two factor code (case insensitive): ';
  my $twofactor = <STDIN>;
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
      #&& index($_->{type}, 'Trading Card') > -1
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
sub list_asset ($ua, $username, $sessionid, $asset, $price_cents, $dry_run) {
  return (undef, 'DRY_RUN') if $dry_run;

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

  return unless $sell_result;

  say dumper $sell_result if $debug;

  return $sell_result->{success}
    ? $sell_result->{needs_email_confirmation}
        || $sell_result->{needs_mobile_confirmation}
      ? SELL_CONFIRMATION()
      : SELL_SUCCESS()
    : (undef, $sell_result->{message} // '');
}


__END__

=head1 SYNOPSIS

  Usage: steam_trading.pl [OPTIONS]

  Options:
    -a, --adjust <value>   Adjust listing price (default 0)
    -n, --dry-run          Dry run without listing anything for sale
    -d, --debug            Output additional debugging messages
    -h, --help             Print this help message

=cut

