# steam_sell_trading_cards
Script to automate selling your Steam trading cards for the current going rate

## Steps:

Clone repo

    $ git clone https://github.com/rage311/steam_sell_trading_cards.git
    $ cd steam_sell_trading_cards

Install plenv (https://github.com/tokuhirom/plenv)

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
    
Install app dependencies

You will need the OpenSSL header files -- available in Ubuntu as `libssl-dev`.

    $ carton install --cached
(using --cached here mainly to work around Crypt::OpenSSL::RSA bug in v0.28 using OpenSSL v1.10+)

Create config

    $ cat > config.yml <<EOF
    username: YourSteamUserName
    password: YourSteamPassword
    id: YourSteamID
    EOF

Run it

    $ carton exec perl steam_trading.pl
