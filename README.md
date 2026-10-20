# yihun-config
My Ubuntu setup. One script backs it up, one command restores it.

## New PC
    sudo apt install -y git
    git clone <this-repo-url> ~/yihun-config
    cd ~/yihun-config && ./yihun-config.sh restore

## Update after changing something
    ./yihun-config.sh backup && ./yihun-config.sh push

Keep this repo **private**. Do not add SSH keys, tokens or passwords.
