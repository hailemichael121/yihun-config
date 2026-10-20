#!/usr/bin/env bash
# yihun-config — back up and restore my Ubuntu setup (dotfiles, VS Code, GNOME, packages, scripts)
#
# Usage:
#   ./yihun-config.sh init                 create ~/yihun-config, git init, copy this script in
#   ./yihun-config.sh backup [modules...]  collect configs into the repo and git commit
#   ./yihun-config.sh restore [modules...] apply the repo to this machine (new PC)
#   ./yihun-config.sh remote <git-url>     set the GitHub remote
#   ./yihun-config.sh push                 push to GitHub
#   ./yihun-config.sh status               git status of the repo
#   ./yihun-config.sh modules              list modules
#
# Modules: dotfiles sshconfig vscode browsers packages gnome scripts services cron sysinfo
# Adding a new module = write mod_<name>() and restore_<name>(), add <name> to MODULES.

set -uo pipefail

# ---------- locations ----------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
if [ -n "${YIHUN_DIR:-}" ]; then
  REPO="$YIHUN_DIR"
elif [ -f "$SELF_DIR/.yihun-config" ]; then
  REPO="$SELF_DIR"                      # running from inside the repo (new PC)
else
  REPO="$HOME/yihun-config"
fi
C="$REPO/configs"
P="$REPO/packages"
S="$REPO/scripts"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODULES=(dotfiles sshconfig vscode browsers packages gnome scripts services cron sysinfo)

# Files/dirs (relative to $HOME) saved by the dotfiles module. Add yours here.
DOTFILES=(
  .bashrc .bash_aliases .profile .zshrc .inputrc
  .gitconfig .gitignore_global
  .vimrc .vim .config/nvim
  .tmux.conf
  .config/terminator .config/htop .config/fontconfig
  .config/mimeapps.list .config/autostart .config/systemd/user
  .config/gtk-3.0/bookmarks
)
EXCLUDES=(--exclude=.vim/plugged --exclude=.vim/bundle --exclude='*.swp' --exclude=.netrwhist --exclude=.git)

# ---------- helpers ----------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
need_repo() { [ -f "$REPO/.yihun-config" ] || { warn "No repo at $REPO. Run: $0 init"; exit 1; }; }
ask() { [ "${YIHUN_YES:-}" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

ask_real() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }   # ignores YIHUN_YES

# keep setup.sh and this script in the repo
sync_self() {
  local f
  [ "$SELF_DIR" = "$REPO" ] && return
  for f in yihun-config.sh setup.sh; do
    [ -f "$SELF_DIR/$f" ] && cp "$SELF_DIR/$f" "$REPO/$f" && chmod +x "$REPO/$f"
  done
}

# warn if files about to be committed look like they contain secrets
scan_secrets() {
  local pat='(ghp_|gho_|github_pat_)[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(api_?key|secret|token|passw(or)?d)[A-Za-z_]*=[^[:space:]]{12,}'
  local hits
  hits="$(grep -rInEi --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=local-share --exclude-dir=gnome-extensions "$pat" "$C" "$S" "$P" 2>/dev/null | cut -d: -f1,2 | sed "s|$REPO/||" | head -20)"
  [ -z "$hits" ] && return 0
  warn "Possible secrets in files about to be committed (file:line):"; echo "$hits" >&2
  warn "Move them to ~/.config/yihun/secrets.env (./setup.sh secrets) and use \$NAME in your configs."
  [ -t 0 ] && ask "Commit anyway?"
}

# ---------- git / repo ----------
cmd_init() {
  mkdir -p "$C" "$P" "$S"
  cd "$REPO" || exit 1
  [ -d .git ] || git init -q -b main
  touch .yihun-config

  [ -f .gitignore ] || cat > .gitignore <<'EOF'
# never commit secrets
*.pem
*.key
id_rsa*
id_ed25519*
.env
.env.*
*.swp
.DS_Store
EOF

  [ -f scripts.list ] || cat > scripts.list <<'EOF'
# Extra scripts/folders to back up (one path per line, ~ allowed). Examples:
# ~/dockmon
# ~/projects/portmon/portmon.sh
EOF

  [ -f README.md ] || cat > README.md <<'EOF'
# yihun-config
My Ubuntu setup. One script backs it up, one command restores it.

## New PC
    sudo apt install -y git
    git clone <this-repo-url> ~/yihun-config
    cd ~/yihun-config && ./yihun-config.sh restore

## Update after changing something
    ./yihun-config.sh backup && ./yihun-config.sh push

Keep this repo **private**. Do not add SSH keys, tokens or passwords.
EOF

  sync_self
  git add -A && git commit -qm "init yihun-config" 2>/dev/null
  log "Repo ready at $REPO"
  log "Next: $REPO/yihun-config.sh backup"
}

git_commit() {
  cd "$REPO" || exit 1
  sync_self
  scan_secrets || { warn "Commit skipped. Fix the files above, then run backup again."; return; }
  git add -A
  if git diff --cached --quiet; then log "No changes since last backup."; return; fi
  git commit -qm "backup $(hostname) $(date '+%F %H:%M')" && log "Committed."
}

cmd_remote() {
  need_repo; cd "$REPO" || exit 1
  [ -n "${1:-}" ] || { warn "Usage: $0 remote <git-url>"; exit 1; }
  git remote remove origin 2>/dev/null
  git remote add origin "$1" && log "origin -> $1"
}
cmd_push()   { need_repo; cd "$REPO" || exit 1; git push -u origin main; }
cmd_status() { need_repo; cd "$REPO" || exit 1; git status -sb; }

# =====================================================================
# MODULE: dotfiles (vim, bash, git, tmux, ...)
# =====================================================================
mod_dotfiles() {
  log "dotfiles"
  have rsync || { warn "rsync missing: sudo apt install rsync"; return; }
  mkdir -p "$C/home"
  local f
  for f in "${DOTFILES[@]}"; do
    [ -e "$HOME/$f" ] || continue
    rsync -aR --delete "${EXCLUDES[@]}" "$HOME/./$f" "$C/home/"
  done
}
restore_dotfiles() {
  log "restore dotfiles (existing files saved to ~/.yihun-backup-$STAMP)"
  [ -d "$C/home" ] || return
  rsync -a --backup --backup-dir="$HOME/.yihun-backup-$STAMP" "$C/home/" "$HOME/"
  # vim-plug: reinstall plugins if used
  if [ -f "$HOME/.vimrc" ] && grep -q 'plug#begin' "$HOME/.vimrc" && have vim; then
    [ -f "$HOME/.vim/autoload/plug.vim" ] || curl -fsSLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    vim +PlugInstall +qall </dev/null || true
  fi
}

# =====================================================================
# MODULE: vscode (settings, keybindings, snippets, extensions)
# =====================================================================
VSC_USER="$HOME/.config/Code/User"
mod_vscode() {
  log "vscode"
  [ -d "$VSC_USER" ] || { warn "VS Code user dir not found, skipping"; return; }
  mkdir -p "$C/vscode"
  local f
  for f in settings.json keybindings.json tasks.json; do
    [ -f "$VSC_USER/$f" ] && cp "$VSC_USER/$f" "$C/vscode/"
  done
  [ -d "$VSC_USER/snippets" ] && rsync -a --delete "$VSC_USER/snippets/" "$C/vscode/snippets/"
  if have code; then code --list-extensions 2>/dev/null | sort > "$C/vscode/extensions.txt"
  else warn "'code' CLI not in PATH, extensions list not updated"; fi
}
restore_vscode() {
  log "restore vscode"
  mkdir -p "$VSC_USER"
  local f
  for f in settings.json keybindings.json tasks.json; do
    [ -f "$C/vscode/$f" ] && cp "$C/vscode/$f" "$VSC_USER/"
  done
  [ -d "$C/vscode/snippets" ] && rsync -a "$C/vscode/snippets/" "$VSC_USER/snippets/"
  if have code && [ -f "$C/vscode/extensions.txt" ]; then
    while read -r ext; do [ -n "$ext" ] && code --install-extension "$ext" --force >/dev/null 2>&1 && echo "  + $ext"; done < "$C/vscode/extensions.txt"
  else warn "Install VS Code first, then run: $0 restore vscode"; fi
}

# =====================================================================
# MODULE: packages (apt, snap, flatpak, pipx/pip, npm, cargo)
# =====================================================================
mod_packages() {
  log "packages"
  mkdir -p "$P/apt-sources"

  # apt: only packages YOU installed (minus the base Ubuntu install)
  local init=/var/log/installer/initial-status.gz
  if [ -f "$init" ]; then
    comm -23 <(apt-mark showmanual | sort -u) <(gzip -dc "$init" | sed -n 's/^Package: //p' | sort -u) > "$P/apt-manual.txt"
  else
    apt-mark showmanual | sort -u > "$P/apt-manual.txt"
  fi

  # apt repositories (keys are NOT saved; re-add PPAs by hand or with add-apt-repository)
  rm -rf "$P/apt-sources"/*
  cp /etc/apt/sources.list.d/* "$P/apt-sources/" 2>/dev/null
  cp /etc/apt/sources.list "$P/apt-sources/" 2>/dev/null

  have snap && snap list 2>/dev/null | awk 'NR>1 && $1!~/^(core|core[0-9]+|snapd|bare|gnome-.*|gtk-common-themes|mesa-.*)$/ {print $1}' > "$P/snap.txt"
  have flatpak && flatpak list --app --columns=application 2>/dev/null > "$P/flatpak.txt"
  have pipx && pipx list --short 2>/dev/null | awk '{print $1}' > "$P/pipx.txt"
  have pip3 && pip3 list --user --not-required --format=freeze 2>/dev/null > "$P/pip-user.txt"
  have npm && npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | sed 's|.*/node_modules/||' | grep -vxE 'npm|corepack' > "$P/npm-global.txt"
  have cargo && cargo install --list 2>/dev/null | grep -E '^[A-Za-z0-9_-]+ v' | awk '{print $1}' > "$P/cargo.txt"
  find "$P" -maxdepth 1 -type f -empty -delete
}
restore_packages() {
  log "restore packages"
  if [ -f "$P/apt-manual.txt" ]; then
    local ok=() missing=() pkg
    while read -r pkg; do
      [ -z "$pkg" ] && continue
      if apt-cache show "$pkg" >/dev/null 2>&1; then ok+=("$pkg"); else missing+=("$pkg"); fi
    done < "$P/apt-manual.txt"
    [ ${#missing[@]} -gt 0 ] && warn "Not in current repos (add PPA from packages/apt-sources?): ${missing[*]}"
    sudo apt-get update && sudo apt-get install -y "${ok[@]}"
  fi
  if have snap && [ -f "$P/snap.txt" ]; then
    while read -r s; do [ -n "$s" ] && { sudo snap install "$s" || sudo snap install --classic "$s"; }; done < "$P/snap.txt"
  fi
  if have flatpak && [ -f "$P/flatpak.txt" ]; then
    while read -r f; do [ -n "$f" ] && flatpak install -y flathub "$f"; done < "$P/flatpak.txt"
  fi
  if have pipx && [ -f "$P/pipx.txt" ]; then
    while read -r p; do [ -n "$p" ] && pipx install "$p"; done < "$P/pipx.txt"
  fi
  if have npm && [ -f "$P/npm-global.txt" ]; then
    while read -r n; do [ -n "$n" ] && npm install -g "$n"; done < "$P/npm-global.txt"
  fi
  if have cargo && [ -f "$P/cargo.txt" ]; then
    while read -r c; do [ -n "$c" ] && cargo install "$c"; done < "$P/cargo.txt"
  fi
  [ -f "$P/pip-user.txt" ] && warn "pip --user packages are listed in packages/pip-user.txt (Ubuntu 24+ needs venv/pipx, so install manually)"
}

# =====================================================================
# MODULE: gnome (Ubuntu desktop: dock, shortcuts, theme, extensions)
# =====================================================================
mod_gnome() {
  log "gnome / ubuntu desktop"
  have dconf || { warn "dconf missing, skipping"; return; }
  mkdir -p "$C/dconf" "$C/gnome-extensions" "$C/local-share"
  dconf dump / > "$C/dconf/full.dconf"
  have gnome-extensions && gnome-extensions list --enabled > "$C/gnome-extensions/enabled.txt" 2>/dev/null
  [ -d "$HOME/.local/share/gnome-shell/extensions" ] && \
    rsync -a --delete "$HOME/.local/share/gnome-shell/extensions/" "$C/gnome-extensions/user/"
  # themes / icons / fonts installed by hand (can be big; comment out if repo grows too much)
  for d in themes icons fonts; do
    [ -d "$HOME/.local/share/$d" ] && rsync -a --delete "$HOME/.local/share/$d/" "$C/local-share/$d/"
  done
  [ -d "$HOME/.themes" ] && rsync -a --delete "$HOME/.themes/" "$C/local-share/.themes/"
  [ -d "$HOME/.icons" ]  && rsync -a --delete "$HOME/.icons/"  "$C/local-share/.icons/"
}
restore_gnome() {
  log "restore gnome"
  [ -d "$C/local-share" ] && {
    for d in themes icons fonts; do
      [ -d "$C/local-share/$d" ] && { mkdir -p "$HOME/.local/share/$d"; rsync -a "$C/local-share/$d/" "$HOME/.local/share/$d/"; }
    done
    [ -d "$C/local-share/.themes" ] && rsync -a "$C/local-share/.themes/" "$HOME/.themes/"
    [ -d "$C/local-share/.icons" ]  && rsync -a "$C/local-share/.icons/"  "$HOME/.icons/"
    have fc-cache && fc-cache -f >/dev/null 2>&1
  }
  [ -d "$C/gnome-extensions/user" ] && { mkdir -p "$HOME/.local/share/gnome-shell/extensions"; rsync -a "$C/gnome-extensions/user/" "$HOME/.local/share/gnome-shell/extensions/"; }
  [ -f "$C/dconf/full.dconf" ] && dconf load / < "$C/dconf/full.dconf"
  if have gnome-extensions && [ -f "$C/gnome-extensions/enabled.txt" ]; then
    while read -r u; do [ -n "$u" ] && gnome-extensions enable "$u" 2>/dev/null; done < "$C/gnome-extensions/enabled.txt"
  fi
  warn "Log out and back in to fully apply desktop settings."
}

# =====================================================================
# MODULE: scripts (~/bin, ~/.local/bin, plus anything in scripts.list: dockmon, portmon, ...)
# =====================================================================
copy_text_files() {  # $1 = source dir, $2 = dest dir (regular, non-symlink text files only)
  local f
  [ -d "$1" ] || return
  mkdir -p "$2"
  for f in "$1"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && grep -Iq . "$f" 2>/dev/null && cp -p "$f" "$2/"
  done
}
mod_scripts() {
  log "scripts"
  rm -rf "$S/bin" "$S/local-bin" "$S/extra"
  copy_text_files "$HOME/bin" "$S/bin"
  copy_text_files "$HOME/.local/bin" "$S/local-bin"
  if [ -f "$REPO/scripts.list" ]; then
    local line p
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      p="${line/#\~/$HOME}"
      if [ -e "$p" ]; then mkdir -p "$S/extra"; rsync -a "${EXCLUDES[@]}" --exclude=node_modules --exclude=__pycache__ "$p" "$S/extra/"
      else warn "scripts.list: not found: $p"; fi
    done < "$REPO/scripts.list"
  fi
}
restore_scripts() {
  log "restore scripts"
  [ -d "$S/bin" ]       && { mkdir -p "$HOME/bin";        rsync -a "$S/bin/" "$HOME/bin/"; }
  [ -d "$S/local-bin" ] && { mkdir -p "$HOME/.local/bin"; rsync -a "$S/local-bin/" "$HOME/.local/bin/"; }
  [ -d "$S/extra" ]     && { mkdir -p "$HOME/.local/bin"; rsync -a "$S/extra/" "$HOME/.local/bin/"; }
  chmod +x "$HOME"/bin/* "$HOME"/.local/bin/* 2>/dev/null
  warn "Extra scripts from scripts.list were copied to ~/.local/bin; move them if they lived elsewhere."
}

# =====================================================================
# MODULE: cron (user crontab)
# =====================================================================
mod_cron() {
  log "cron"
  mkdir -p "$C"
  crontab -l > "$C/crontab.txt" 2>/dev/null || rm -f "$C/crontab.txt"
}
restore_cron() {
  log "restore cron"
  [ -f "$C/crontab.txt" ] && crontab "$C/crontab.txt"
}

# =====================================================================
# MODULE: sysinfo (reference only: which Ubuntu/hardware this came from)
# =====================================================================
mod_sysinfo() {
  log "sysinfo"
  mkdir -p "$REPO/info"
  { cat /etc/os-release; echo; uname -r; echo; echo "host: $(hostname)"; echo "saved: $(date -Is)"; } > "$REPO/info/system.txt"
}
restore_sysinfo() { :; }

# =====================================================================
# MODULE: sshconfig (~/.ssh/config only. Private keys are NEVER copied.)
# =====================================================================
mod_sshconfig() {
  log "ssh config (no keys)"
  [ -f "$HOME/.ssh/config" ] || [ -d "$HOME/.ssh/config.d" ] || { warn "no ~/.ssh/config, skipping"; return; }
  rm -rf "$C/ssh"; mkdir -p "$C/ssh"
  [ -f "$HOME/.ssh/config" ] && cp "$HOME/.ssh/config" "$C/ssh/config"
  [ -d "$HOME/.ssh/config.d" ] && rsync -a "$HOME/.ssh/config.d/" "$C/ssh/config.d/"
  return 0
}
restore_sshconfig() {
  log "restore ssh config"
  [ -d "$C/ssh" ] || return 0
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$C/ssh/config" ]; then
    [ -f "$HOME/.ssh/config" ] && cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak-$STAMP"
    cp "$C/ssh/config" "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  fi
  [ -d "$C/ssh/config.d" ] && rsync -a "$C/ssh/config.d/" "$HOME/.ssh/config.d/"
  warn "Keys are not in the repo. Use ./setup.sh unpack-secrets, or make a new key with ./setup.sh git"
  return 0
}

# =====================================================================
# MODULE: browsers (bookmarks: Chrome/Chromium/Brave/Edge + Firefox)
#   Chromium family -> raw JSON + a universal bookmarks .html (importable anywhere)
#   Firefox         -> newest automatic bookmark backup (.jsonlz4)
# =====================================================================
BROWSER_BOOKMARKS=(
  "chrome:$HOME/.config/google-chrome"
  "chromium:$HOME/.config/chromium"
  "chromium-snap:$HOME/snap/chromium/common/chromium"
  "brave:$HOME/.config/BraveSoftware/Brave-Browser"
  "edge:$HOME/.config/microsoft-edge"
)
mod_browsers() {
  log "browser bookmarks"
  local out="$C/browsers" entry name base prof pname f d latest
  rm -rf "$out"; mkdir -p "$out"
  for entry in "${BROWSER_BOOKMARKS[@]}"; do
    name="${entry%%:*}"; base="${entry#*:}"
    for prof in "$base"/Default "$base"/Profile\ *; do
      f="$prof/Bookmarks"; [ -f "$f" ] || continue
      pname="$(basename "$prof" | tr ' ' '-')"
      cp "$f" "$out/$name-$pname.json"
      have python3 && python3 - "$f" "$out/$name-$pname.html" <<'PY'
import json, sys, html
src, dst = sys.argv[1:3]
data = json.load(open(src, encoding="utf-8"))
out = ['<!DOCTYPE NETSCAPE-Bookmark-file-1>',
       '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
       '<TITLE>Bookmarks</TITLE>', '<H1>Bookmarks</H1>', '<DL><p>']
def walk(node, depth):
    pad = "    " * depth
    for ch in node.get("children", []):
        if ch.get("type") == "folder":
            out.append(f'{pad}<DT><H3>{html.escape(ch.get("name", ""))}</H3>')
            out.append(f'{pad}<DL><p>')
            walk(ch, depth + 1)
            out.append(f'{pad}</DL><p>')
        elif ch.get("type") == "url":
            out.append(f'{pad}<DT><A HREF="{html.escape(ch.get("url", ""), quote=True)}">{html.escape(ch.get("name", ""))}</A>')
for root in data.get("roots", {}).values():
    if isinstance(root, dict) and root.get("children") is not None:
        out.append(f'    <DT><H3>{html.escape(root.get("name", ""))}</H3>')
        out.append('    <DL><p>')
        walk(root, 2)
        out.append('    </DL><p>')
out.append('</DL><p>')
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
    done
  done
  # Firefox (deb or snap): newest automatic backup per profile
  for d in "$HOME"/.mozilla/firefox/*/bookmarkbackups "$HOME"/snap/firefox/common/.mozilla/firefox/*/bookmarkbackups; do
    [ -d "$d" ] || continue
    latest="$(ls -1t "$d"/bookmarks-*.jsonlz4 2>/dev/null | head -1)"
    [ -n "$latest" ] && cp "$latest" "$out/firefox-$(basename "$(dirname "$d")").jsonlz4"
  done
  rmdir "$out" 2>/dev/null
  return 0
}
restore_browsers() {
  log "restore bookmarks"
  [ -d "$C/browsers" ] || { echo "  no bookmarks saved"; return 0; }
  local dest="$HOME/yihun-bookmarks"
  mkdir -p "$dest"; cp "$C"/browsers/* "$dest/"
  cat <<EOF
  Bookmarks copied to: $dest
  Open the browser once, then import:
   Chrome / Brave / Edge : Ctrl+Shift+O -> menu (three dots) -> Import bookmarks -> pick a .html file
   Firefox               : Ctrl+Shift+O -> Import and Backup -> Restore -> Choose File -> the .jsonlz4
                           (or Import Bookmarks from HTML with any .html file there)
  If you sign in with a Google or Firefox account, sync brings them back by itself.
EOF
  return 0
}

# =====================================================================
# MODULE: services (your own systemd units, enabled user services, docker daemon.json)
# =====================================================================
mod_services() {
  log "systemd services + docker config"
  local out="$C/services" f
  rm -rf "$out"; mkdir -p "$out/system"
  for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do   # units YOU wrote (regular files)
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [[ "$(basename "$f")" == snap.* ]] && continue
    cp "$f" "$out/system/"
  done
  systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$out/enabled-system.txt"
  systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$out/enabled-user.txt"
  [ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json "$out/docker-daemon.json"
  rmdir "$out/system" 2>/dev/null
  return 0
}
restore_services() {
  log "restore services"
  local s="$C/services" f u
  if [ -d "$s/system" ]; then
    echo "  system units saved:"; for f in "$s"/system/*; do echo "   - $(basename "$f")"; done
    if ask_real "Install these into /etc/systemd/system and enable them?"; then
      sudo cp "$s"/system/* /etc/systemd/system/ && sudo systemctl daemon-reload
      for f in "$s"/system/*; do sudo systemctl enable --now "$(basename "$f")" || warn "could not start $(basename "$f")"; done
    fi
  fi
  if [ -f "$s/docker-daemon.json" ] && ask_real "Install Docker daemon.json?"; then
    sudo mkdir -p /etc/docker && sudo cp "$s/docker-daemon.json" /etc/docker/daemon.json
    have docker && sudo systemctl restart docker
  fi
  # user services themselves come back with the dotfiles module (.config/systemd/user); enable them
  if [ -f "$s/enabled-user.txt" ]; then
    systemctl --user daemon-reload 2>/dev/null
    while read -r u; do
      [ -f "$HOME/.config/systemd/user/$u" ] && systemctl --user enable "$u" 2>/dev/null && echo "  enabled (user): $u"
    done < "$s/enabled-user.txt"
  fi
  return 0
}

# ---------- dispatcher ----------
run_modules() {  # $1 = prefix (mod_|restore_), rest = module names
  local prefix="$1"; shift
  local list=("$@") m
  [ ${#list[@]} -eq 0 ] && list=("${MODULES[@]}")
  for m in "${list[@]}"; do
    if declare -F "${prefix}${m}" >/dev/null; then "${prefix}${m}"
    else warn "Unknown module: $m (see: $0 modules)"; fi
  done
}

cmd_backup() {
  need_repo
  run_modules mod_ "$@"
  git_commit
  log "Done. Push with: $0 push"
}
cmd_restore() {
  need_repo
  warn "This will overwrite configs on this machine (dotfiles are backed up first)."
  ask "Continue?" || exit 0
  run_modules restore_ "$@"
  log "Restore finished."
}

case "${1:-help}" in
  init)    cmd_init ;;
  backup)  shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  remote)  shift; cmd_remote "$@" ;;
  push)    cmd_push ;;
  status)  cmd_status ;;
  modules) printf '%s\n' "${MODULES[@]}" ;;
  *)       sed -n '2,15p' "$SELF" ;;
esac
