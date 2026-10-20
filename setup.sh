#!/usr/bin/env bash
# setup.sh — new-PC bootstrap for yihun-config (interactive, step by step, safe to re-run)
#
#   ./setup.sh                 menu (pick one step)
#   ./setup.sh all             run every step in order, asking before each
#   ./setup.sh <step>          run one step
#   ./setup.sh pack-secrets    (OLD PC) encrypt ssh keys + tokens into one file for a USB stick
#   ./setup.sh unpack-secrets  (NEW PC) decrypt that file back into place
#
# Steps (in order): base git configs secrets python node flutter docker rust go vscode packages check
# Secrets are asked at run time and stored only in ~/.config/yihun/secrets.env (chmod 600).
# They are NEVER written into this repo.

set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(dirname "$SELF")"
CFG="$HOME/.config/yihun"
SECRETS_ENV="$CFG/secrets.env"
SECRET_KEYS="$REPO/secrets.keys"      # NAMES only, safe to commit
NVM_VERSION="v0.40.3"                 # bump when a newer nvm is out
FLUTTER_DIR="$HOME/development/flutter"

STEPS=(base git configs secrets python node flutter docker rust go vscode packages check)

# ---------- helpers ----------
log()     { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
have()    { command -v "$1" >/dev/null 2>&1; }
confirm() { read -r -p "$1 [Y/n] " a; [[ ! "$a" =~ ^[Nn]$ ]]; }   # default yes
ask()     { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }     # default no
append_once() { touch "$1"; grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"; }
cfg_restore() { [ -x "$REPO/yihun-config.sh" ] && YIHUN_YES=1 "$REPO/yihun-config.sh" restore "$@" || warn "yihun-config.sh not found in $REPO"; }

# =====================================================================
step_base() {
  log "Base tools"
  sudo apt-get update
  sudo apt-get install -y git curl wget unzip zip xz-utils rsync vim build-essential \
    ca-certificates gnupg xclip htop tree jq software-properties-common
}

# =====================================================================
step_git() {
  log "Git identity, SSH key, GitHub login"
  local name email n e c k
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"
  read -r -p "Git name  [${name}]: " n;  name="${n:-$name}"
  read -r -p "Git email [${email}]: " e; email="${e:-$email}"
  [ -n "$name" ]  && git config --global user.name "$name"
  [ -n "$email" ] && git config --global user.email "$email"
  git config --global init.defaultBranch main

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    echo "SSH key already exists (~/.ssh/id_ed25519), keeping it."
  else
    echo "SSH key:  1) generate a new one   2) import from a file/USB   3) skip"
    read -r -p "Choose [1]: " c; c="${c:-1}"
    case "$c" in
      1) ssh-keygen -t ed25519 -C "$email" -f "$HOME/.ssh/id_ed25519" ;;
      2) read -r -p "Path to your PRIVATE key file: " k; k="${k/#\~/$HOME}"
         if [ -f "$k" ]; then
           cp "$k" "$HOME/.ssh/id_ed25519"; chmod 600 "$HOME/.ssh/id_ed25519"
           ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub"
         else warn "File not found."; fi ;;
      *) echo "Skipped." ;;
    esac
  fi

  if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    eval "$(ssh-agent -s)" >/dev/null; ssh-add "$HOME/.ssh/id_ed25519"
    echo; echo "Your public key (safe to share):"; cat "$HOME/.ssh/id_ed25519.pub"
    if have xclip; then xclip -selection clipboard < "$HOME/.ssh/id_ed25519.pub" && echo "(copied to clipboard)"; fi
    echo "Add it on GitHub: https://github.com/settings/keys  ->  New SSH key  ->  paste  ->  Add."
    read -r -p "Press Enter once it is added... " _
    ssh -o StrictHostKeyChecking=accept-new -T git@github.com
  fi

  if confirm "Also log in with GitHub CLI (gh)? (for private repos, issues, PRs)"; then
    have gh || sudo apt-get install -y gh
    gh auth login
  fi

  # switch the repo remote from https to ssh so pushes work without a password
  if [ -d "$REPO/.git" ]; then
    local url; url="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
    if [[ "$url" =~ ^https://github.com/(.+)$ ]]; then
      git -C "$REPO" remote set-url origin "git@github.com:${BASH_REMATCH[1]}" && echo "origin -> git@github.com:${BASH_REMATCH[1]}"
    fi
  fi
}

# =====================================================================
step_configs() {
  log "Restore configs: dotfiles, desktop, scripts, cron (old files are backed up first)"
  cfg_restore dotfiles gnome scripts cron
}

# =====================================================================
set_secret() {
  local name="$1" val
  if grep -q "^export $name=" "$SECRETS_ENV" 2>/dev/null; then
    ask "$name is already set. Replace it?" || return 0
  fi
  read -r -s -p "$name (paste value, Enter to skip): " val; echo
  [ -z "$val" ] && return 0
  sed -i "/^export $name=/d" "$SECRETS_ENV"
  printf 'export %s=%q\n' "$name" "$val" >> "$SECRETS_ENV"
  echo "  saved $name"
}
step_secrets() {
  log "Secrets and API keys (typed values are hidden and stored only on this PC)"
  mkdir -p "$CFG"; chmod 700 "$CFG"; touch "$SECRETS_ENV"; chmod 600 "$SECRETS_ENV"
  [ -f "$SECRET_KEYS" ] || cat > "$SECRET_KEYS" <<'EOF'
# Names of secrets to ask for on a new PC. NAMES ONLY, never put values here.
# Remove the leading # to enable a line, or add your own.
# GITHUB_TOKEN
# GEMINI_API_KEY
# OPENAI_API_KEY
# ADDIS_AI_API_KEY
# DATABASE_URL
EOF
  append_once "$HOME/.bashrc" '[ -f ~/.config/yihun/secrets.env ] && . ~/.config/yihun/secrets.env'

  local names=() name
  mapfile -t names < <(grep -vE '^[[:space:]]*(#|$)' "$SECRET_KEYS")
  for name in "${names[@]}"; do set_secret "$name"; done

  while true; do
    read -r -p "Another secret NAME to add, e.g. STRIPE_KEY (Enter to finish): " name
    [ -z "$name" ] && break
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "Use letters, digits, underscore."; continue; }
    grep -qxF "$name" "$SECRET_KEYS" || echo "$name" >> "$SECRET_KEYS"
    set_secret "$name"
  done
  echo "Open a new terminal (or: source ~/.bashrc) to load them. Use them as \$NAME."
}

# =====================================================================
step_python() {
  log "Python"
  sudo apt-get install -y python3 python3-pip python3-venv python3-dev pipx
  pipx ensurepath
  pipx install uv 2>/dev/null || true
  python3 --version
}

# =====================================================================
step_node() {
  log "Node.js via nvm (LTS)"
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] || curl -fsSo- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
  set +u; . "$NVM_DIR/nvm.sh"
  nvm install --lts && nvm alias default 'lts/*'
  corepack enable 2>/dev/null || true       # pnpm / yarn
  set -u
  node --version; npm --version
}

# =====================================================================
step_flutter() {
  log "Flutter + Android toolchain"
  sudo apt-get install -y curl git unzip xz-utils zip libglu1-mesa clang cmake ninja-build \
    pkg-config libgtk-3-dev default-jdk adb
  if [ ! -d "$FLUTTER_DIR" ]; then
    mkdir -p "$(dirname "$FLUTTER_DIR")"
    git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_DIR"
  fi
  export PATH="$FLUTTER_DIR/bin:$PATH"
  append_once "$HOME/.bashrc" 'export PATH="$HOME/development/flutter/bin:$PATH"'
  flutter precache

  if confirm "Install Android Studio (snap)?"; then
    sudo snap install android-studio --classic
    cat <<'EOF'

  Do this once by hand:
   1. Open Android Studio -> follow the first-run wizard (installs the Android SDK).
   2. More Actions -> SDK Manager -> SDK Tools -> tick "Android SDK Command-line Tools" -> Apply.
   3. Back in the terminal:  flutter doctor --android-licenses   (press y for each)
EOF
    read -r -p "Press Enter when done (or to skip for now)... " _
    flutter doctor --android-licenses || true
  fi
  flutter doctor
}

# =====================================================================
step_docker() {
  log "Docker"
  have docker || { curl -fsSL https://get.docker.com | sudo sh; }
  sudo usermod -aG docker "$USER"
  echo "Log out and back in so you can run docker without sudo."
}

step_rust() {
  log "Rust"
  have rustc || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  rustc --version
}

step_go() {
  log "Go"
  have go || sudo snap install go --classic
  go version
}

step_vscode() {
  log "VS Code + your settings and extensions"
  have code || sudo snap install code --classic
  cfg_restore vscode
}

step_packages() {
  log "Your other apps (apt, snap, flatpak, pipx, npm, cargo lists)"
  warn "If this PC has different hardware, apt may list drivers that do not apply. Review packages/apt-manual.txt first."
  confirm "Install everything from the saved lists?" && cfg_restore packages
}

step_check() {
  log "What is installed"
  local t
  for t in git gh python3 pipx uv node npm pnpm flutter java docker rustc go code; do
    if have "$t"; then printf '  %-8s %s\n' "$t" "$("$t" --version 2>&1 | head -1)"
    else printf '  %-8s (not installed)\n' "$t"; fi
  done
  echo; ssh -o BatchMode=yes -T git@github.com 2>&1 | head -1
}

# =====================================================================
# Move auth between PCs without ever touching git
# =====================================================================
step_pack_secrets() {
  log "Encrypt keys and tokens into one file (store it on a USB stick, NEVER in git)"
  have gpg || sudo apt-get install -y gnupg
  local out="$HOME/yihun-secrets-$(date +%Y%m%d).tar.gz.gpg" items=() p
  for p in .ssh .gnupg .config/gh .config/yihun .aws .kube .docker/config.json .npmrc .pypirc; do
    [ -e "$HOME/$p" ] && items+=("$p")
  done
  echo "Will include: ${items[*]}"
  confirm "Continue? (you will choose a passphrase, do not forget it)" || return 0
  tar -czf - -C "$HOME" "${items[@]}" 2>/dev/null | gpg --symmetric --cipher-algo AES256 --yes -o "$out"
  chmod 600 "$out"
  echo "Saved: $out"
  echo "Copy it to a USB stick or private cloud, then delete it from this PC."
}
step_unpack_secrets() {
  log "Decrypt your secrets bundle onto this PC"
  local f; read -r -p "Path to yihun-secrets-*.tar.gz.gpg: " f; f="${f/#\~/$HOME}"
  [ -f "$f" ] || { warn "File not found."; return 1; }
  gpg --decrypt "$f" | tar -xzf - -C "$HOME" || { warn "Decrypt failed."; return 1; }
  chmod 700 "$HOME/.ssh" "$HOME/.gnupg" 2>/dev/null
  chmod 600 "$HOME"/.ssh/id_* 2>/dev/null
  chmod 644 "$HOME"/.ssh/*.pub 2>/dev/null
  echo "Done. Now run: ./setup.sh git   (it will keep the restored SSH key)"
}

# ---------- dispatcher ----------
usage() { sed -n '2,13p' "$SELF"; }
run_one() {
  local fn="step_${1//-/_}"
  if declare -F "$fn" >/dev/null; then "$fn"; else warn "Unknown step: $1"; usage; fi
}

case "${1:-menu}" in
  menu)
    echo "Pick a step (number):"
    select s in "${STEPS[@]}" all pack-secrets unpack-secrets quit; do
      case "$s" in
        quit|"") break ;;
        all) exec "$SELF" all ;;
        *) run_one "$s"; break ;;
      esac
    done ;;
  all)
    for s in "${STEPS[@]}"; do confirm "Run step: $s ?" && run_one "$s"; done
    log "All done. Open a new terminal, then log out/in once for docker and desktop settings." ;;
  help|-h|--help) usage ;;
  *) run_one "$1" ;;
esac
