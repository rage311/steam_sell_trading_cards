# steam_sell_trading_cards
Script to automate selling your Steam trading cards for the current going rate

## Steps:

Install the package dependencies (on Ubuntu):

    $ apt-get install libssl-dev build-essential

Clone repo:

    $ git clone https://github.com/rage311/steam_sell_trading_cards.git
    $ cd steam_sell_trading_cards

Install plenv (https://github.com/tokuhirom/plenv).  This step is optional if your OS provides a modern version of Perl (5.26) and `cpanminus` as a package... and you don't mind messing with your system Perl environment.

    $ git clone https://github.com/tokuhirom/plenv.git ~/.plenv

    $ echo 'export PATH="$HOME/.plenv/bin:$PATH"' >> ~/.bash_profile
    Ubuntu note: Modify your ~/.profile instead of ~/.bash_profile.
    Zsh note: Modify your ~/.zshrc file instead of ~/.bash_profile.

    $ echo 'eval "$(plenv init -)"' >> ~/.bash_profile
    Same as in previous step, use ~/.profile on Ubuntu.
    Zsh note: Use echo 'eval "$(plenv init - zsh)"' >> ~/.zshrc

    $ exec $SHELL -l

    $ git clone https://github.com/tokuhirom/Perl-Build.git ~/.plenv/plugins/perl-build/
    $ plenv install 5.26.1

    $ plenv rehash
    $ plenv local 5.26.1
    $ plenv install-cpanm
    $ plenv rehash

Install carton (https://github.com/perl-carton/carton)

    $ cpanm Carton

Install Perl modules from the repo's cache:

    $ carton install --cached
(using --cached here mainly to work around Crypt::OpenSSL::RSA bug in v0.28 using OpenSSL v1.10+)

Create config

    $ cat > config.yml <<EOF
    username: YourSteamUserName
    password: YourSteamPassword
    id: YourSteamID64
    adjust: 0
    EOF

(You can find your "Steam ID 64" by searching for your username here: https://steamid.io/lookup)

Modify the `adjust` value to increase or decrease your card listing price in cents.


Run it

    $ carton exec perl steam_trading.pl

### Usage

    Usage: steam_trading.pl [OPTIONS]

    Options:
      -a, --adjust <value>   Adjust listing price (default 0)
      -n, --dry-run          Dry run without listing anything for sale
      -d, --debug            Output additional debugging messages
      -h, --help             Print this help message

