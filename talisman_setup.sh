#!/usr/bin/env bash
# Started with "sh talisman_setup.sh"? Restart with bash.
[ -z "$BASH_VERSION" ] && exec bash "$0" "$@" #
# Edited/uploaded from Windows? Remove the Windows line endings and restart. (The "#" at the end of this line keeps it working even with them.)
if [ -f "$0" ] && grep -q $'\r' "$0" 2>/dev/null; then sed -i 's/\r$//' "$0"; exec bash "$0" "$@"; fi #
# =============================================================================
#  Talisman Online - one-shot server setup for Ubuntu (20.04 / 22.04 / 24.04)
#
#  What it does:
#    * prepares Ubuntu (32-bit libraries, tools, swap, firewall, fail2ban)
#    * runs MySQL 5.7 in Docker with auto-generated passwords
#    * creates db_account / db_game / db_log / db_gmtool
#    * installs the "talisman" command to import SQL, start/stop servers,
#      view logs, back up the database and diagnose problems
#
#  Usage (as root):
#    bash talisman_setup.sh              normal install / safe to re-run
#    bash talisman_setup.sh --help       all options
#
#  Safe to run again at any time: nothing is deleted unless you ask for it.
# =============================================================================
set -Eeuo pipefail

SETUP_VERSION="2.0.0"

# ----------------------------------------------------------------------------
# Settings (can be overridden with environment variables, e.g.
#   TALISMAN_BASE=/opt/talisman bash talisman_setup.sh)
# ----------------------------------------------------------------------------
BASE="${TALISMAN_BASE:-/root/talisman}"
CONF_FILE="$BASE/talisman.conf"
ENV_FILE="$BASE/mysql.env"
MANAGER="/usr/local/bin/talisman"
REPO_RAW_URL="${TALISMAN_REPO_RAW_URL:-https://raw.githubusercontent.com/colordiscord/TalismanOnlineSetup/main}"

# Bump when the MySQL container options change: an older container is then
# re-created automatically (your data lives in the volume and is kept).
MYSQL_SPEC="2"

OPT_YES=0
OPT_RESET_MYSQL=0
OPT_NO_FIREWALL="${SKIP_FIREWALL:-0}"
OPT_NO_SWAP="${SKIP_SWAP:-0}"
OPT_NO_IMPORT=0

usage() {
  cat <<EOF
Talisman Online setup v$SETUP_VERSION

Usage: bash $0 [options]

Options:
  --yes            Do not ask questions (assume "yes").
  --reset-mysql    DELETE the MySQL container and ALL database data, then
                   start fresh with new passwords. Use this if you see
                   "Access denied" errors and have no data to keep.
  --no-firewall    Do not touch the firewall (ufw).
  --no-swap        Do not create a swap file on small servers.
  --no-import      Do not auto-import SQL files found in $BASE.
  -h, --help       Show this help.

Environment overrides:
  TALISMAN_BASE    Install folder (default /root/talisman)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        OPT_YES=1 ;;
    --reset-mysql)   OPT_RESET_MYSQL=1 ;;
    --no-firewall)   OPT_NO_FIREWALL=1 ;;
    --no-swap)       OPT_NO_SWAP=1 ;;
    --no-import)     OPT_NO_IMPORT=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_B=""; C_0=""
fi

STEP=0
TOTAL_STEPS=12
step() { STEP=$((STEP + 1)); echo; echo "${C_B}${C_BLU}[$STEP/$TOTAL_STEPS] $*${C_0}"; }
ok()   { echo "  ${C_GRN}OK${C_0}  $*"; }
info() { echo "  ..  $*"; }
warn() { echo "  ${C_YEL}WARN${C_0} $*"; }
die()  { echo; echo "${C_RED}${C_B}ERROR:${C_0} $*" >&2; exit 1; }

confirm() {
  # confirm "question" -> returns 0 for yes
  [[ $OPT_YES -eq 1 ]] && return 0
  local answer
  if [[ ! -t 0 ]]; then
    # Not interactive (e.g. curl | bash). Read from the terminal if possible.
    if [[ -r /dev/tty ]]; then
      read -r -p "  $1 [y/N] " answer </dev/tty || answer=""
    else
      return 1
    fi
  else
    read -r -p "  $1 [y/N] " answer || answer=""
  fi
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

on_error() {
  local code=$? line=${1:-?}
  echo
  echo "${C_RED}${C_B}Setup stopped because of an error (line $line, exit code $code).${C_0}"
  echo "  * The full log is in: $BASE/logs/setup.log"
  echo "  * The setup is safe to run again after fixing the problem."
  echo "  * If the 'talisman' command is installed, run: talisman doctor"
  exit "$code"
}
trap 'on_error $LINENO' ERR

# ----------------------------------------------------------------------------
# Must be root, must be bash (not sh), must not have Windows line endings
# ----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:"
  echo "  sudo bash $0"
  exit 1
fi

mkdir -p "$BASE/logs"
chmod 700 "$BASE"
# Keep a copy of everything printed in a log file.
exec > >(tee -a "$BASE/logs/setup.log") 2>&1
echo
echo "===== setup v$SETUP_VERSION started $(date '+%F %T') ====="

cat <<EOF
${C_B}==================================================
 Talisman Online server setup  v$SETUP_VERSION
==================================================${C_0}
EOF

# ----------------------------------------------------------------------------
step "Checking this server..."
# ----------------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "Cannot detect the operating system (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VER}"

if [[ "$OS_ID" != "ubuntu" ]]; then
  if [[ "$OS_ID" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
    warn "$OS_NAME is not Ubuntu. It will probably work, but only Ubuntu is tested."
  else
    die "$OS_NAME is not supported. Please use Ubuntu 20.04, 22.04 or 24.04."
  fi
else
  case "$OS_VER" in
    20.04|22.04|24.04) ok "Operating system: $OS_NAME" ;;
    *) warn "$OS_NAME is not tested (tested: 20.04, 22.04, 24.04). Continuing anyway." ;;
  esac
fi

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || die "This server is $ARCH. Talisman servers and MySQL 5.7 need a 64-bit Intel/AMD (x86_64) server."
ok "CPU architecture: $ARCH"

MEM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
SWAP_MB=$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo) / 1024 ))
if (( MEM_MB < 1500 )); then
  warn "Only ${MEM_MB} MB RAM. 2 GB or more is recommended (a swap file will help)."
else
  ok "Memory: ${MEM_MB} MB RAM, ${SWAP_MB} MB swap"
fi

DISK_FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
if (( DISK_FREE_MB < 3000 )); then
  die "Only ${DISK_FREE_MB} MB free disk space. At least 3 GB is needed."
elif (( DISK_FREE_MB < 8000 )); then
  warn "Only ${DISK_FREE_MB} MB free disk space. 10 GB+ is recommended for databases and backups."
else
  ok "Free disk: ${DISK_FREE_MB} MB"
fi

if ! getent hosts deb.debian.org archive.ubuntu.com >/dev/null 2>&1; then
  warn "DNS lookups seem to fail. Package downloads may not work."
fi

# ----------------------------------------------------------------------------
step "Installing Ubuntu packages (this can take a few minutes)..."
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a           # stop Ubuntu 22.04+ from asking about service restarts
APT=(apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

dpkg --add-architecture i386
info "Updating package lists (waits if automatic updates are running)..."
"${APT[@]}" update >/dev/null

pkg_available() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Install the first available package from each "a|b|c" group.
install_groups() {
  local required="$1"; shift
  local group pkg picked to_install=()
  for group in "$@"; do
    picked=""
    IFS='|' read -r -a alts <<<"$group"
    for pkg in "${alts[@]}"; do
      if pkg_available "$pkg"; then picked="$pkg"; break; fi
    done
    if [[ -n "$picked" ]]; then
      to_install+=("$picked")
    elif [[ "$required" == "required" ]]; then
      die "Required package not available: $group"
    fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    if ! "${APT[@]}" install --no-install-recommends "${to_install[@]}" >/dev/null; then
      # One broken package should not block the others: retry one by one.
      for pkg in "${to_install[@]}"; do
        "${APT[@]}" install --no-install-recommends "$pkg" >/dev/null \
          || { [[ "$required" == "required" ]] && die "Could not install $pkg"; warn "Could not install optional package $pkg"; }
      done
    fi
  fi
}

REQUIRED_PKGS=(
  ca-certificates curl wget openssl gnupg
  unzip "7zip|p7zip-full" file lsof iproute2 net-tools psmisc
  nano tmux screen logrotate cron
  ufw fail2ban
  libc6:i386 "libgcc-s1:i386|libgcc1:i386" libstdc++6:i386 zlib1g:i386
)
# Extra 32/64-bit libraries that some Talisman server builds need.
OPTIONAL_PKGS=(
  git htop "unrar|unrar-free"
  "libncurses6:i386" "libncurses5:i386" "libtinfo5:i386"
  "libssl3:i386|libssl1.1:i386"
  "libmysqlclient21:i386|libmysqlclient20:i386" "libmariadb3:i386"
  "libstdc++5:i386" "libcurl4:i386" "libxml2:i386"
)
install_groups required "${REQUIRED_PKGS[@]}"
ok "Base tools and 32-bit libraries installed"
install_groups optional "${OPTIONAL_PKGS[@]}"
ok "Optional compatibility libraries installed (where available)"

systemctl enable --now cron >/dev/null 2>&1 || true
systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban protects SSH against password guessing" || warn "fail2ban could not start (not critical)"

# ----------------------------------------------------------------------------
step "Checking memory / swap..."
# ----------------------------------------------------------------------------
if [[ "$OPT_NO_SWAP" == "1" ]]; then
  info "Skipped (--no-swap)"
elif (( SWAP_MB > 0 )); then
  ok "Swap already exists (${SWAP_MB} MB)"
elif (( MEM_MB >= 4000 )); then
  ok "Enough RAM, no swap needed"
elif [[ -e /swapfile ]]; then
  warn "/swapfile exists but is not active; leaving it alone"
else
  info "Creating a 2 GB swap file so MySQL and the servers do not run out of memory..."
  if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    if swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "2 GB swap file created"
    else
      rm -f /swapfile
      warn "This VPS does not allow swap files (common on OpenVZ). Continuing without swap."
    fi
  else
    warn "Could not create a swap file. Continuing without swap."
  fi
fi

# ----------------------------------------------------------------------------
step "Installing / starting Docker..."
# ----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  ok "Docker already installed ($(docker --version 2>/dev/null | head -n1))"
else
  install_groups required docker.io
  ok "Docker installed"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
for _ in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Try: systemctl restart docker ; journalctl -u docker -n 50"
ok "Docker is running"

# ----------------------------------------------------------------------------
step "Creating folders, settings and passwords..."
# ----------------------------------------------------------------------------
mkdir -p "$BASE"/{server,lib,sql,backup,logs,run} "$BASE"/server/{db_server,login_server,game_server}
chmod 700 "$BASE"
chmod 755 "$BASE"/{server,lib,sql,backup,logs,run}

# talisman.conf: user-editable settings. Only missing keys are added,
# existing values are never overwritten.
touch "$CONF_FILE"
chmod 600 "$CONF_FILE"
conf_default() {
  local key="$1" value="$2" comment="${3:-}"
  if ! grep -q "^${key}=" "$CONF_FILE"; then
    [[ -n "$comment" ]] && printf '\n# %s\n' "$comment" >> "$CONF_FILE"
    printf '%s=%q\n' "$key" "$value" >> "$CONF_FILE"
  fi
}
if [[ ! -s "$CONF_FILE" ]]; then
  cat > "$CONF_FILE" <<'EOF'
# =============================================================
#  Talisman server settings. Edit with:  nano /root/talisman/talisman.conf
#  After editing, run:  talisman restart
# =============================================================
EOF
fi

# Is this a brand-new database, or does data exist from an earlier install?
MYSQL_VOLUME_EXISTS=0
docker volume inspect talisman_mysql >/dev/null 2>&1 && MYSQL_VOLUME_EXISTS=1

conf_default BASE "$BASE" "Install folder"
conf_default MYSQL_CONTAINER "talisman-mysql" "Docker container / volume / image used for MySQL"
conf_default MYSQL_VOLUME "talisman_mysql"
conf_default MYSQL_IMAGE "mysql:5.7"
conf_default MYSQL_PORT "3306" "MySQL port on this machine (only reachable from the server itself, never from the internet)"
# New installs ignore table-name case (Windows dumps often mix Account/account).
# Existing data keeps the old behaviour so no tables "disappear".
if [[ $MYSQL_VOLUME_EXISTS -eq 1 ]]; then
  conf_default MYSQL_LOWER_CASE_TABLE_NAMES "0" "1 = table names are case-insensitive (only change on a fresh database!)"
else
  conf_default MYSQL_LOWER_CASE_TABLE_NAMES "1" "1 = table names are case-insensitive (only change on a fresh database!)"
fi
conf_default PUBLIC_PORTS "8885 8886 8888" "Ports players connect to (opened in the firewall). Change to match your server configs, then run: talisman firewall sync"
conf_default DB_SERVER_NAMES "db_server dbserver DBServer db_svr" "Program file names to look for (first match wins). Or set DB_SERVER_BIN / LOGIN_SERVER_BIN / GAME_SERVER_BIN to an exact path."
conf_default LOGIN_SERVER_NAMES "login_server loginserver LoginServer login_svr"
conf_default GAME_SERVER_NAMES "game_server gameserver GameServer game_svr"
conf_default DB_SERVER_BIN ""
conf_default LOGIN_SERVER_BIN ""
conf_default GAME_SERVER_BIN ""
conf_default START_DELAY "5" "Seconds to wait between starting db -> login -> game"
conf_default AUTOSTART "yes" "Start the servers automatically after a reboot (yes/no)"
conf_default BACKUP_KEEP_DAYS "14" "Daily database backups are kept this many days"
conf_default REPO_RAW_URL "$REPO_RAW_URL" "Where 'talisman self-update' downloads the latest setup from"
# shellcheck disable=SC1090
source "$CONF_FILE"
ok "Settings file: $CONF_FILE"

# mysql.env: passwords. Created once, never overwritten.
NEW_PASSWORDS=0
gen_pw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24; }
if [[ $OPT_RESET_MYSQL -eq 1 ]]; then
  echo
  warn "--reset-mysql will PERMANENTLY DELETE all Talisman databases (accounts, characters, logs)."
  if [[ $OPT_YES -ne 1 ]]; then
    confirm "Type y to delete the MySQL data and start fresh" || die "Cancelled. Nothing was deleted."
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$MYSQL_CONTAINER"; then
    info "Making a last backup first (if the database is reachable)..."
    if [[ -f "$ENV_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE"
      LAST_BACKUP="$BASE/backup/before-reset-$(date +%Y%m%d-%H%M%S).sql.gz"
      if docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" "$MYSQL_CONTAINER" \
           mysqldump -uroot -h127.0.0.1 --all-databases --single-transaction 2>/dev/null \
           | gzip > "$LAST_BACKUP.part"; then
        mv "$LAST_BACKUP.part" "$LAST_BACKUP"
        ok "Last backup saved: $LAST_BACKUP"
      else
        rm -f "$LAST_BACKUP.part"
        warn "Could not back up (password did not work) - continuing with the reset."
      fi
    fi
    docker rm -f "$MYSQL_CONTAINER" >/dev/null
  fi
  docker volume rm "$MYSQL_VOLUME" >/dev/null 2>&1 || true
  MYSQL_VOLUME_EXISTS=0
  rm -f "$ENV_FILE"
  sed -i 's/^MYSQL_LOWER_CASE_TABLE_NAMES=.*/MYSQL_LOWER_CASE_TABLE_NAMES=1/' "$CONF_FILE"
  MYSQL_LOWER_CASE_TABLE_NAMES=1
  ok "Old MySQL data removed"
fi

if [[ ! -s "$ENV_FILE" ]]; then
  if [[ $MYSQL_VOLUME_EXISTS -eq 1 ]]; then
    warn "A MySQL data volume exists from an earlier install, but its password file is missing."
    warn "The old password will still be required. If you do not know it, re-run with:"
    warn "  bash $0 --reset-mysql      (deletes the old database data!)"
  fi
  umask 077
  cat > "$ENV_FILE" <<EOF
# MySQL passwords for your Talisman server. KEEP THIS FILE PRIVATE.
# Show them any time with:  talisman passwords
MYSQL_ROOT_PASSWORD=$(gen_pw)
MYSQL_APP_USER=talisman
MYSQL_APP_PASSWORD=$(gen_pw)
EOF
  umask 022
  NEW_PASSWORDS=1
  ok "New random MySQL passwords saved in $ENV_FILE"
else
  ok "Using existing passwords from $ENV_FILE"
fi
chmod 600 "$ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${MYSQL_ROOT_PASSWORD:?missing in $ENV_FILE}"
: "${MYSQL_APP_USER:=talisman}"
: "${MYSQL_APP_PASSWORD:?missing in $ENV_FILE}"

# ----------------------------------------------------------------------------
step "Starting MySQL 5.7 (Docker container '$MYSQL_CONTAINER')..."
# ----------------------------------------------------------------------------
# Many Talisman configs use host "localhost", which makes the MySQL client use
# a socket file instead of TCP. Share the container's socket folder with the
# host so "localhost" works exactly like a normal MySQL install.
cat > /etc/tmpfiles.d/talisman-mysql.conf <<'EOF'
d /run/mysqld 1777 root root -
L+ /tmp/mysql.sock - - - - /run/mysqld/mysqld.sock
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/talisman-mysql.conf >/dev/null 2>&1 || { mkdir -p /run/mysqld; chmod 1777 /run/mysqld; }

container_exists() { docker ps -a --format '{{.Names}}' | grep -qx "$MYSQL_CONTAINER"; }

if container_exists; then
  CURRENT_SPEC="$(docker inspect -f '{{ index .Config.Labels "talisman.spec" }}' "$MYSQL_CONTAINER" 2>/dev/null || true)"
  if [[ "$CURRENT_SPEC" != "$MYSQL_SPEC" ]]; then
    info "Upgrading the MySQL container settings (your data is kept in volume '$MYSQL_VOLUME')..."
    docker rm -f "$MYSQL_CONTAINER" >/dev/null
  fi
fi

if ! container_exists; then
  # Something else already using the MySQL port? (e.g. a MySQL installed directly on Ubuntu)
  if ss -Hltn "sport = :$MYSQL_PORT" 2>/dev/null | grep -q .; then
    echo
    ss -Hltnp "sport = :$MYSQL_PORT" || true
    die "Port $MYSQL_PORT is already used by another program (probably MySQL/MariaDB installed on Ubuntu).
       Stop it with:  systemctl disable --now mysql mariadb
       or set MYSQL_PORT to another port in $CONF_FILE, then run this setup again."
  fi
  # MySQL 5.7 uses huge amounts of RAM when the open-file limit is "infinity"
  # (default on new Docker versions), so cap it - but never above what the host allows.
  NOFILE="$(ulimit -Hn)"
  [[ "$NOFILE" =~ ^[0-9]+$ ]] && (( NOFILE < 65535 )) || NOFILE=65535
  if ! docker image inspect "$MYSQL_IMAGE" >/dev/null 2>&1; then
    info "Downloading $MYSQL_IMAGE (about 150 MB)..."
    docker pull -q "$MYSQL_IMAGE" >/dev/null
  fi
  docker run -d \
    --name "$MYSQL_CONTAINER" \
    --label "talisman.spec=$MYSQL_SPEC" \
    --restart unless-stopped \
    --ulimit "nofile=$NOFILE:$NOFILE" \
    -p "127.0.0.1:$MYSQL_PORT:3306" \
    -v "$MYSQL_VOLUME:/var/lib/mysql" \
    -v /run/mysqld:/var/run/mysqld \
    -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
    -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
    "$MYSQL_IMAGE" \
    --sql-mode="" \
    --character-set-server=utf8 \
    --collation-server=utf8_general_ci \
    --lower-case-table-names="$MYSQL_LOWER_CASE_TABLE_NAMES" \
    --max-allowed-packet=256M \
    --max-connections=500 \
    --skip-name-resolve \
    --explicit-defaults-for-timestamp=0 \
    --innodb-buffer-pool-size=256M >/dev/null
  ok "MySQL container created"
else
  docker start "$MYSQL_CONTAINER" >/dev/null
  ok "MySQL container already exists, started it"
fi

# Wait for MySQL to really accept our password. (A plain "ping" is NOT enough:
# it succeeds before the root password is set on the first start.)
mysql_login_ok() {
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
    mysql -uroot -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1
}
mysql_alive() {
  docker exec "$MYSQL_CONTAINER" mysqladmin -h127.0.0.1 ping --silent >/dev/null 2>&1
}
info "Waiting for MySQL to finish starting (the first start takes up to 1-2 minutes)..."
READY=0
for i in $(seq 1 150); do
  if mysql_login_ok; then READY=1; break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null)" != "true" ]]; then
    echo; docker logs --tail 40 "$MYSQL_CONTAINER" 2>&1 | sed 's/^/     /'
    die "The MySQL container stopped. See the log lines above. Common causes: not enough memory (add swap) or a damaged data volume (re-run with --reset-mysql)."
  fi
  (( i % 10 == 0 )) && info "still waiting... (${i}x2 s)"
  sleep 2
done
if [[ $READY -ne 1 ]]; then
  if mysql_alive; then
    die "MySQL is running but refuses the root password in $ENV_FILE ('Access denied').
       This happens when the database was created by an earlier install with a different password.
       If you have NO data to keep, fix it with:   bash $0 --reset-mysql
       If you DO have data, put the old root password into $ENV_FILE and run this setup again."
  fi
  echo; docker logs --tail 40 "$MYSQL_CONTAINER" 2>&1 | sed 's/^/     /'
  die "MySQL did not become ready in 5 minutes. See the log lines above."
fi
ok "MySQL is ready and the root password works"

# ----------------------------------------------------------------------------
step "Creating Talisman databases and MySQL user..."
# ----------------------------------------------------------------------------
# NOTE: "-i" is required, otherwise the SQL below never reaches MySQL.
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" mysql -uroot -h127.0.0.1 <<SQL
CREATE DATABASE IF NOT EXISTS db_account CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS db_game    CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS db_log     CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS db_gmtool  CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON db_account.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON db_game.*    TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON db_log.*     TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON db_gmtool.*  TO '${MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
# Verify instead of trusting the exit code.
DB_COUNT="$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" mysql -uroot -h127.0.0.1 -N -e \
  "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ('db_account','db_game','db_log','db_gmtool')")"
[[ "$DB_COUNT" == "4" ]] || die "The databases were not created (found $DB_COUNT of 4)."
docker exec -e MYSQL_PWD="$MYSQL_APP_PASSWORD" "$MYSQL_CONTAINER" mysql -u"$MYSQL_APP_USER" -h127.0.0.1 -e "SELECT 1" db_account >/dev/null \
  || die "The MySQL user '$MYSQL_APP_USER' cannot log in."
ok "Databases db_account, db_game, db_log, db_gmtool exist"
ok "MySQL user '$MYSQL_APP_USER' can log in"

# ----------------------------------------------------------------------------
step "Installing the 'talisman' command..."
# ----------------------------------------------------------------------------
cat > "$MANAGER" <<'__TALISMAN_MANAGER_EOF__'
#!/usr/bin/env bash
# =============================================================================
#  talisman - manage your Talisman Online server.   Run "talisman help".
#  Installed by talisman_setup.sh. Settings: /root/talisman/talisman.conf
# =============================================================================
set -Eeuo pipefail

BASE="${TALISMAN_BASE:-/root/talisman}"
CONF_FILE="$BASE/talisman.conf"
ENV_FILE="$BASE/mysql.env"

# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
: "${MYSQL_CONTAINER:=talisman-mysql}"
: "${MYSQL_VOLUME:=talisman_mysql}"
: "${MYSQL_PORT:=3306}"
: "${PUBLIC_PORTS:=8885 8886 8888}"
: "${DB_SERVER_NAMES:=db_server dbserver DBServer db_svr}"
: "${LOGIN_SERVER_NAMES:=login_server loginserver LoginServer login_svr}"
: "${GAME_SERVER_NAMES:=game_server gameserver GameServer game_svr}"
: "${DB_SERVER_BIN:=}"
: "${LOGIN_SERVER_BIN:=}"
: "${GAME_SERVER_BIN:=}"
: "${START_DELAY:=5}"
: "${AUTOSTART:=yes}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${REPO_RAW_URL:=https://raw.githubusercontent.com/colordiscord/TalismanOnlineSetup/main}"
LOGS="$BASE/logs"
DATABASES=(db_account db_game db_log db_gmtool)
ROLES=(db login game)

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_B=""; C_0=""
fi
ok()   { echo "  ${C_GRN}OK${C_0}   $*"; }
bad()  { echo "  ${C_RED}FAIL${C_0} $*"; }
warn() { echo "  ${C_YEL}WARN${C_0} $*"; }
info() { echo "  ..   $*"; }
hint() { echo "       ${C_BLU}-> $*${C_0}"; }
die()  { echo "${C_RED}${C_B}ERROR:${C_0} $*" >&2; exit 1; }
title(){ echo; echo "${C_B}$*${C_0}"; }

need_root() { [[ $EUID -eq 0 ]] || die "Please run as root (sudo -i first)."; }

confirm() {
  [[ "${TALISMAN_YES:-0}" == "1" ]] && return 0
  local a; read -r -p "$1 [y/N] " a </dev/tty || a=""
  [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run the setup first: bash talisman_setup.sh"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${MYSQL_APP_USER:=talisman}"
}

# ---------------------------------------------------------------- MySQL -----
mysql_root() {  # mysql_root [mysql args...]  (stdin is passed through)
  load_env
  docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
    mysql -uroot -h127.0.0.1 --max-allowed-packet=256M "$@"
}
mysql_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null)" == "true" ]]; }
mysql_ok() { mysql_running && mysql_root -N -e "SELECT 1" >/dev/null 2>&1; }

wait_mysql() {
  mysql_running || docker start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    mysql_ok && return 0
    sleep 2
  done
  return 1
}

table_count() {
  mysql_root -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$1'" 2>/dev/null || echo "?"
}

sql_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\\\'}"; }

# -------------------------------------------------------------- servers -----
role_label() {
  case "$1" in db) echo "DB server";; login) echo "Login server";; game) echo "Game server";; esac
}
role_unit() { echo "talisman-$1.service"; }
role_logname() { case "$1" in db) echo db_server;; login) echo login_server;; game) echo game_server;; esac; }
role_log() { echo "$LOGS/$(role_logname "$1").log"; }
norm_role() {
  case "${1:-}" in
    db|1|db_server|dbserver) echo db ;;
    login|2|login_server|loginserver) echo login ;;
    game|3|game_server|gameserver) echo game ;;
    *) die "Unknown server '${1:-}'. Use: db, login or game." ;;
  esac
}

is_elf() { [[ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]; }

# Find the program file for a role. Prints the path or nothing.
find_binary() {
  local role="$1" override names name f
  case "$role" in
    db)    override="$DB_SERVER_BIN";    names="$DB_SERVER_NAMES" ;;
    login) override="$LOGIN_SERVER_BIN"; names="$LOGIN_SERVER_NAMES" ;;
    game)  override="$GAME_SERVER_BIN";  names="$GAME_SERVER_NAMES" ;;
  esac
  if [[ -n "$override" ]]; then
    [[ -f "$override" ]] && echo "$override"
    return 0
  fi
  for name in $names; do
    while IFS= read -r f; do
      if is_elf "$f"; then echo "$f"; return 0; fi
    done < <(find "$BASE" -maxdepth 6 \( -path "$BASE/backup" -o -path "$BASE/logs" -o -path "$BASE/sql" \) -prune \
               -o -type f -iname "$name" -print 2>/dev/null | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-)
  done
}

# Library search path: next to the program, its lib folder, $BASE/lib and any
# folder under $BASE that contains .so files (server packs often ship libs).
lib_path() {
  local bin_dir="$1" dirs=() d
  dirs+=("$bin_dir" "$bin_dir/lib" "$bin_dir/libs" "$BASE/lib")
  while IFS= read -r d; do dirs+=("$d"); done < <(
    find "$BASE" -maxdepth 6 \( -path "$BASE/backup" -o -path "$BASE/logs" -o -path "$BASE/sql" \) -prune \
      -o -type f \( -name '*.so' -o -name '*.so.*' \) -printf '%h\n' 2>/dev/null | sort -u)
  local IFS=:
  echo "${dirs[*]}"
}

# A program wants libfoo.so.15 but only libfoo.so.15.0.0 was uploaded: link it
# into $BASE/lib. Prints the libraries that are still missing.
fix_libs() {
  local bin="$1" lib alt
  command -v ldd >/dev/null || return 0
  for lib in $(cd "$(dirname "$bin")" && LD_LIBRARY_PATH="$(lib_path "$(dirname "$bin")")" ldd "$bin" 2>&1 | awk '/not found/{print $1}' | sort -u); do
    alt="$(find "$BASE" \( -path "$BASE/backup" -o -path "$BASE/logs" \) -prune -o -type f -name "$lib.*" -print 2>/dev/null | head -n1)"
    if [[ -n "$alt" ]]; then
      mkdir -p "$BASE/lib"; ln -sf "$alt" "$BASE/lib/$lib"
      echo "linked:$lib:$alt"
    else
      echo "missing:$lib"
    fi
  done
}

# Internal: used by systemd to run one server in the foreground.
cmd_run() {
  local role; role="$(norm_role "${1:-}")"
  local bin; bin="$(find_binary "$role")"
  [[ -n "$bin" ]] || { echo "$(role_label "$role"): program not found under $BASE"; exit 78; }
  chmod +x "$bin"
  fix_libs "$bin" | sed -n 's/^linked:\([^:]*\):/linked missing library \1 -> /p'
  cd "$(dirname "$bin")"
  echo "===== $(date '+%F %T') starting $bin ====="
  export LD_LIBRARY_PATH; LD_LIBRARY_PATH="$(lib_path "$(dirname "$bin")")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  exec "./$(basename "$bin")"
}

service_active() { systemctl is-active --quiet "$(role_unit "$1")"; }
service_pid() { systemctl show -p MainPID --value "$(role_unit "$1")" 2>/dev/null || echo 0; }

listening_ports() {  # listening_ports PID -> "9002 8885"
  local pid="$1"
  [[ -n "$pid" && "$pid" != "0" ]] || return 0
  ss -Hltnp 2>/dev/null | awk -v p="pid=$pid," 'index($0,p){n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' '
}

stop_legacy() {  # processes started by the old ./1 ./2 ./3 scripts
  local pf pid
  for pf in "$LOGS"/*.pid; do
    [[ -f "$pf" ]] || continue
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "Stopping old-style process $(basename "$pf" .pid) (PID $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  done
}

start_role() {
  local role="$1" label bin pid ports
  label="$(role_label "$role")"
  bin="$(find_binary "$role")"
  if [[ -z "$bin" ]]; then
    bad "$label: program not found."
    hint "Upload it into $BASE/server/${role}_server/ (Bitvise: New SFTP window)."
    local names_var="${role^^}_SERVER_NAMES"
    hint "Looked for file names: ${!names_var}"
    hint "If yours has another name, set ${role^^}_SERVER_BIN=/full/path in $CONF_FILE"
    return 1
  fi
  if service_active "$role"; then
    ok "$label already running (PID $(service_pid "$role"))"
    return 0
  fi
  systemctl reset-failed "$(role_unit "$role")" >/dev/null 2>&1 || true
  systemctl start "$(role_unit "$role")"
  sleep 3
  if service_active "$role"; then
    pid="$(service_pid "$role")"
    ports="$(listening_ports "$pid")"
    ok "$label started (PID $pid${ports:+, ports: $ports})"
  else
    bad "$label stopped right after starting. Last log lines:"
    tail -n 25 "$(role_log "$role")" 2>/dev/null | sed 's/^/       /'
    hint "Run 'talisman doctor' to find missing libraries or config problems."
    hint "Run 'talisman console $role' to see the program's output live."
    return 1
  fi
}

cmd_start() {
  need_root
  local targets=("$@") role
  [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]] && targets=("${ROLES[@]}")
  title "Starting Talisman..."
  stop_legacy
  if ! wait_mysql; then
    bad "MySQL is not reachable."; hint "Run: talisman doctor"; return 1
  fi
  ok "MySQL is running"
  # (login/game services wait START_DELAY seconds themselves before starting)
  for role in "${targets[@]}"; do
    role="$(norm_role "$role")"
    start_role "$role" || return 1
  done
  if [[ "$AUTOSTART" == "yes" ]]; then
    systemctl enable talisman.target >/dev/null 2>&1 || true
  fi
  echo
  echo "Check with: talisman status    Logs: talisman logs game"
}

cmd_stop() {
  need_root
  local targets=("$@") role
  [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]] && targets=(game login db)
  title "Stopping Talisman..."
  for role in "${targets[@]}"; do
    role="$(norm_role "$role")"
    if service_active "$role"; then
      systemctl stop "$(role_unit "$role")"
      ok "$(role_label "$role") stopped"
    else
      info "$(role_label "$role") was not running"
    fi
  done
  stop_legacy
}

cmd_restart() {
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]]; then
    cmd_stop; cmd_start
  else
    cmd_stop "${targets[@]}"; cmd_start "${targets[@]}"
  fi
}

public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

cmd_status() {
  title "Talisman status"
  if mysql_ok; then
    ok "MySQL            running (container $MYSQL_CONTAINER, 127.0.0.1:$MYSQL_PORT)"
  elif mysql_running; then
    bad "MySQL            running but login fails -> talisman doctor"
  else
    bad "MySQL            not running -> docker start $MYSQL_CONTAINER"
  fi
  local role label pid ports bin
  for role in "${ROLES[@]}"; do
    label="$(printf '%-16s' "$(role_label "$role")")"
    if service_active "$role"; then
      pid="$(service_pid "$role")"; ports="$(listening_ports "$pid")"
      ok "$label running  PID $pid${ports:+  ports: $ports}"
    else
      bin="$(find_binary "$role")"
      if [[ -z "$bin" ]]; then
        warn "$label stopped  (program not uploaded yet)"
      else
        warn "$label stopped  ($bin)"
      fi
    fi
  done
  echo
  echo "  Server IP   : $(public_ip)"
  echo "  Autostart   : $(autostart_state)"
  echo "  Open ports  : $PUBLIC_PORTS"
  echo "  Last backup : $(ls -1t "$BASE"/backup/*.sql.gz 2>/dev/null | head -n1 || echo none)"
}

cmd_logs() {
  local what="${1:-game}"
  case "$what" in
    mysql) docker logs --tail 100 -f "$MYSQL_CONTAINER" ;;
    setup) less +G "$LOGS/setup.log" ;;
    all)   tail -n 30 -F "$LOGS"/db_server.log "$LOGS"/login_server.log "$LOGS"/game_server.log ;;
    *)     local f; f="$(role_log "$(norm_role "$what")")"; touch "$f"; echo "(Ctrl+C to exit)"; tail -n 100 -F "$f" ;;
  esac
}

cmd_console() {
  need_root
  local role; role="$(norm_role "${1:-}")"
  local bin; bin="$(find_binary "$role")"
  [[ -n "$bin" ]] || die "$(role_label "$role") program not found under $BASE"
  if service_active "$role"; then
    info "Stopping the background $(role_label "$role") first..."
    systemctl stop "$(role_unit "$role")"
  fi
  echo "Running $(role_label "$role") in the foreground. Press Ctrl+C to stop."
  echo "Afterwards start it normally again with: talisman start $role"
  echo
  chmod +x "$bin"
  cd "$(dirname "$bin")"
  LD_LIBRARY_PATH="$(lib_path "$(dirname "$bin")")" "./$(basename "$bin")" || true
}

# ----------------------------------------------------------------- import ---
db_for_file() {  # guess the database from a file name
  local n; n="$(basename "$1" | tr 'A-Z' 'a-z')"
  n="${n%.gz}"; n="${n%.sql}"
  case "$n" in
    *gmtool*|*gm_tool*)                  echo db_gmtool ;;
    *account*)                           echo db_account ;;
    *login*)                             echo "" ;;   # "login" contains "log" - never guess
    db_log|*_log|log|*db_log*|*gamelog*|*game_log*) echo db_log ;;
    *game*)                              echo db_game ;;
    *log*)                               echo db_log ;;
    *) echo "" ;;
  esac
}

find_sql_files() {
  find "$BASE" -maxdepth 6 \( -path "$BASE/backup" -o -path "$BASE/logs" \) -prune \
    -o -type f \( -iname '*.sql' -o -iname '*.sql.gz' \) -print 2>/dev/null | sort
}

import_file() {  # import_file FILE DB FORCE
  local file="$1" db="$2" force="${3:-0}" n used
  n="$(table_count "$db")"
  if [[ "$n" != "0" && "$force" != "1" ]]; then
    info "$db already has $n tables - skipped $(basename "$file") (already imported)"
    hint "To import anyway (tables with the same name are replaced): talisman import --force"
    return 0
  fi
  used="$( (if [[ "$file" == *.gz ]]; then gzip -dc "$file"; else cat "$file"; fi) 2>/dev/null \
            | head -c 2000000 | grep -aoiE '^[[:space:]]*USE[[:space:]]+`?[A-Za-z0-9_]+' | head -n1 \
            | sed -E 's/.*[Uu][Ss][Ee][[:space:]]+`?//' || true)"
  local filter=(sed -e '1s/^\xEF\xBB\xBF//')   # strip a Windows "BOM" at the start
  if [[ -n "$used" && "$used" != "$db" ]]; then
    warn "$(basename "$file") says 'USE $used' - importing into '$db' instead."
    # Drop the dump's own CREATE DATABASE / USE lines so everything lands in $db.
    filter+=(-e '/^[[:space:]]*[Uu][Ss][Ee][[:space:]]/d' -e '/^[[:space:]]*CREATE[[:space:]]\+\(DATABASE\|SCHEMA\)/Id')
  fi
  info "Importing $(basename "$file") -> $db (large files take a while)..."
  local start=$SECONDS
  if ! (if [[ "$file" == *.gz ]]; then gzip -dc "$file"; else cat "$file"; fi) \
       | "${filter[@]}" | mysql_root --default-character-set=utf8 "$db"; then
    bad "Import of $(basename "$file") failed (see the MySQL error above)."
    hint "Common causes: the file is not a MySQL dump, it was cut off during upload, or it needs another database."
    return 1
  fi
  ok "$(basename "$file") imported into $db ($(table_count "$db") tables, $((SECONDS - start)) s)"
}

cmd_import() {
  need_root
  local force=0 args=()
  for a in "$@"; do
    case "$a" in --force|-f) force=1 ;; *) args+=("$a") ;; esac
  done
  wait_mysql || die "MySQL is not reachable. Run: talisman doctor"
  title "Importing SQL files"
  if [[ ${#args[@]} -ge 1 ]]; then
    local file="${args[0]}" db="${args[1]:-}"
    [[ -f "$file" ]] || die "File not found: $file"
    [[ -n "$db" ]] || db="$(db_for_file "$file")"
    [[ -n "$db" ]] || die "Cannot guess the database for $(basename "$file"). Use: talisman import $file db_game"
    mysql_root -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8 COLLATE utf8_general_ci"
    import_file "$file" "$db" "$force"
    return 0
  fi
  local files=() f db found=0 failed=0
  mapfile -t files < <(find_sql_files)
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .sql or .sql.gz files found under $BASE"
    hint "Upload your database dumps to $BASE/sql (e.g. db_account.sql, db_game.sql, db_log.sql)"
    hint "Zip/rar/7z archive? Run: talisman unpack /path/to/file.zip"
    return 1
  fi
  for f in "${files[@]}"; do
    db="$(db_for_file "$f")"
    if [[ -z "$db" ]]; then
      warn "Not sure which database $f belongs to - skipped."
      hint "Import it by hand: talisman import \"$f\" db_game   (or db_account / db_log / db_gmtool)"
      continue
    fi
    if import_file "$f" "$db" "$force"; then found=1; else failed=$((failed + 1)); fi
  done
  echo
  if [[ $failed -gt 0 ]]; then
    warn "$failed file(s) failed to import - see above."
    return 1
  fi
  if [[ $found -eq 1 ]]; then echo "Done. Check with: talisman status"; fi
}

# ---------------------------------------------------------------- backup ----
cmd_backup() {
  need_root
  wait_mysql || die "MySQL is not reachable."
  mkdir -p "$BASE/backup"
  local out dbs=() db
  out="$BASE/backup/talisman-$(date +%Y%m%d-%H%M%S).sql.gz"
  for db in "${DATABASES[@]}"; do
    [[ "$(mysql_root -N -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db'")" == "1" ]] && dbs+=("$db")
  done
  info "Backing up ${dbs[*]}..."
  load_env
  if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
       mysqldump -uroot -h127.0.0.1 --single-transaction --quick --routines --triggers --events \
       --default-character-set=utf8 --databases "${dbs[@]}" | gzip > "$out.part"; then
    mv "$out.part" "$out"
    chmod 600 "$out"
    ok "Backup saved: $out ($(du -h "$out" | cut -f1))"
  else
    rm -f "$out.part"
    die "Backup failed."
  fi
  find "$BASE/backup" -name 'talisman-*.sql.gz' -mtime +"$BACKUP_KEEP_DAYS" -delete 2>/dev/null || true
}

cmd_restore() {
  need_root
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    echo "Available backups (newest first):"
    ls -1t "$BASE"/backup/*.sql.gz 2>/dev/null | head -n 20 | sed 's/^/  /' || echo "  none"
    echo; echo "Usage: talisman restore /root/talisman/backup/<file>.sql.gz"
    return 0
  fi
  [[ -f "$file" ]] || die "File not found: $file"
  echo "${C_YEL}This REPLACES the current databases with the backup:${C_0} $file"
  confirm "Continue?" || die "Cancelled."
  wait_mysql || die "MySQL is not reachable."
  local was_running=0 r
  for r in "${ROLES[@]}"; do service_active "$r" && was_running=1; done
  [[ $was_running -eq 1 ]] && cmd_stop
  info "Saving a safety backup of the current data first..."
  cmd_backup
  info "Restoring..."
  if [[ "$file" == *.gz ]]; then gzip -dc "$file" | mysql_root; else mysql_root < "$file"; fi
  ok "Restore finished"
  [[ $was_running -eq 1 ]] && cmd_start
  return 0
}

# ------------------------------------------------------------- utilities ----
cmd_passwords() {
  need_root
  load_env
  title "Database connection details (use these in your server config files)"
  cat <<EOF
  Host      : 127.0.0.1   (or "localhost" - both work)
  Port      : $MYSQL_PORT
  User      : $MYSQL_APP_USER
  Password  : $MYSQL_APP_PASSWORD
  Databases : ${DATABASES[*]}

  Admin (root) user  : root
  Admin password     : $MYSQL_ROOT_PASSWORD

  Your configs already use another user/password (e.g. root / 123456)?
  Make MySQL match them instead:   talisman db-user <user> <password>
EOF
}

cmd_db_user() {
  need_root
  local user="${1:-}" pass="${2:-}"
  [[ -n "$user" && -n "$pass" ]] || die "Usage: talisman db-user <user> <password>"
  [[ "$user" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "User name may only contain letters, digits, _ . -"
  wait_mysql || die "MySQL is not reachable."
  local p; p="$(sql_escape "$pass")"
  if [[ "$user" == "root" ]]; then
    mysql_root -e "ALTER USER 'root'@'%' IDENTIFIED BY '$p'; ALTER USER 'root'@'localhost' IDENTIFIED BY '$p'; FLUSH PRIVILEGES;"
    local tmp; tmp="$(mktemp)"
    grep -v '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" > "$tmp"
    printf 'MYSQL_ROOT_PASSWORD=%q\n' "$pass" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
    ok "Root password changed (saved in $ENV_FILE)"
  else
    local sql="CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$p'; ALTER USER '$user'@'%' IDENTIFIED BY '$p';" db
    for db in "${DATABASES[@]}"; do sql+=" GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%';"; done
    mysql_root -e "$sql FLUSH PRIVILEGES;"
    ok "MySQL user '$user' can now use ${DATABASES[*]} with the given password"
  fi
}

cmd_sql() {
  need_root
  load_env
  docker exec -it -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" mysql -uroot -h127.0.0.1 "${1:-db_account}"
}

cmd_unpack() {
  need_root
  local file="${1:-}" dest="${2:-$BASE/server}"
  [[ -f "$file" ]] || die "Usage: talisman unpack <file.zip|.rar|.7z|.tar.gz> [folder]"
  mkdir -p "$dest"
  info "Extracting $(basename "$file") into $dest ..."
  case "${file,,}" in
    *.zip)                  unzip -o -q "$file" -d "$dest" ;;
    *.tar.gz|*.tgz)         tar -xzf "$file" -C "$dest" ;;
    *.tar)                  tar -xf "$file" -C "$dest" ;;
    *.sql.gz)               cp "$file" "$BASE/sql/" ;;
    *.rar|*.7z)
      if command -v 7z >/dev/null; then 7z x -y -o"$dest" "$file" >/dev/null
      elif command -v 7zz >/dev/null; then 7zz x -y -o"$dest" "$file" >/dev/null
      elif command -v unrar >/dev/null; then unrar x -o+ "$file" "$dest/" >/dev/null
      else die "No 7z/unrar tool installed."; fi ;;
    *) die "Unknown archive type: $file" ;;
  esac
  ok "Extracted"
  # Windows zips lose the "executable" flag; fix it on real programs.
  find "$dest" -type f -size +10k -print0 2>/dev/null | while IFS= read -r -d '' f; do is_elf "$f" && chmod +x "$f"; done
  cmd_scan
}

cmd_scan() {
  title "What was found under $BASE"
  local role bin f
  for role in "${ROLES[@]}"; do
    bin="$(find_binary "$role")"
    if [[ -n "$bin" ]]; then ok "$(printf '%-13s' "$(role_label "$role")") $bin ($(file -b "$bin" | cut -d, -f1))"
    else warn "$(printf '%-13s' "$(role_label "$role")") not found"; fi
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local db; db="$(db_for_file "$f")"
    ok "SQL file      $f -> ${db:-?? (import by hand)}"
  done < <(find_sql_files)
}

cmd_find_config() {
  title "Config files that seem to contain database settings"
  local files=() f
  mapfile -t files < <(grep -rIilE --exclude='*.sql' --exclude='*.log' --exclude='*.gz' \
      '(3306|db_account|db_game|dbname|db_name|database|mysql)' \
      "$BASE/server" "$BASE"/{db,login,game} 2>/dev/null | head -n 30 || true)
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "Nothing found. Upload your server files first (into $BASE/server)."
    return 0
  fi
  for f in "${files[@]}"; do
    echo; echo "  ${C_B}$f${C_0}"
    grep -inE '(host|port|user|pass|pwd|db|database|ip|addr)' "$f" 2>/dev/null | head -n 15 | sed 's/^/     /'
    echo "     ${C_BLU}edit: nano \"$f\"${C_0}"
  done
  echo
  echo "Tip: put the values from 'talisman passwords' in these files, and your"
  echo "server's public IP ($(public_ip)) wherever the client connection IP is set."
}

cmd_firewall() {
  need_root
  local action="${1:-status}" port="${2:-}"
  case "$action" in
    open)  [[ "$port" =~ ^[0-9]+$ ]] || die "Usage: talisman firewall open <port>"
           ufw allow "$port/tcp" >/dev/null; ok "Port $port/tcp opened" ;;
    close) [[ "$port" =~ ^[0-9]+$ ]] || die "Usage: talisman firewall close <port>"
           ufw delete allow "$port/tcp" >/dev/null || true; ok "Port $port/tcp closed" ;;
    sync)  for port in $PUBLIC_PORTS; do ufw allow "$port/tcp" >/dev/null; done
           ok "Opened PUBLIC_PORTS: $PUBLIC_PORTS" ;;
    *)     ufw status numbered ;;
  esac
}

autostart_state() {
  if systemctl is-enabled --quiet talisman.target >/dev/null 2>&1; then echo on; else echo off; fi
}

cmd_autostart() {
  need_root
  case "${1:-}" in
    on|yes)  systemctl enable talisman.target >/dev/null 2>&1; sed -i 's/^AUTOSTART=.*/AUTOSTART=yes/' "$CONF_FILE"; ok "Servers will start after a reboot" ;;
    off|no)  systemctl disable talisman.target >/dev/null 2>&1; sed -i 's/^AUTOSTART=.*/AUTOSTART=no/' "$CONF_FILE"; ok "Servers will NOT start after a reboot" ;;
    *) echo "Autostart is: $(autostart_state)"; echo "Usage: talisman autostart on|off" ;;
  esac
}

missing_lib_hint() {
  case "$1" in
    libmysqlclient.so.*|libmysqlclient_r.so.*)
      hint "$1 is an old MySQL client library that Ubuntu no longer ships."
      hint "Server packs usually include it (look for a 'lib' folder). Copy it into $BASE/lib"
      hint "Search your upload: find / -name 'libmysqlclient*' 2>/dev/null | grep -v docker" ;;
    libstdc++.so.5)  hint "Install it: apt-get install libstdc++5:i386   (or copy libstdc++.so.5 into $BASE/lib)" ;;
    libstdc++.so.6)  hint "Install it: apt-get install libstdc++6:i386" ;;
    libz.so.1)       hint "Install it: apt-get install zlib1g:i386" ;;
    libncurses.so.5|libtinfo.so.5) hint "Install it: apt-get install libncurses5:i386 libtinfo5:i386  (or copy it into $BASE/lib)" ;;
    libssl.so.*|libcrypto.so.*) hint "Old OpenSSL library. Copy it from your server pack into $BASE/lib" ;;
    *) hint "Copy $1 (from your server pack or an older Linux) into $BASE/lib" ;;
  esac
}

cmd_doctor() {
  need_root
  local problems=0
  title "1) System"
  if docker info >/dev/null 2>&1; then ok "Docker is running"; else bad "Docker is not running"; hint "systemctl restart docker"; problems=$((problems+1)); fi
  local free_mb; free_mb=$(df -Pm "$BASE" | awk 'NR==2{print $4}')
  if (( free_mb < 1000 )); then bad "Only ${free_mb} MB disk space left"; hint "Delete old backups in $BASE/backup"; problems=$((problems+1)); else ok "Disk space: ${free_mb} MB free"; fi
  local avail_mb; avail_mb=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
  if (( avail_mb < 200 )); then warn "Only ${avail_mb} MB memory available"; else ok "Memory available: ${avail_mb} MB"; fi
  if dpkg --print-foreign-architectures | grep -qx i386; then ok "32-bit (i386) support enabled"; else bad "32-bit support missing"; hint "Re-run the setup"; problems=$((problems+1)); fi
  if grep -q $'\r' "$CONF_FILE" 2>/dev/null; then
    bad "$CONF_FILE has Windows line endings"; hint "Fix: sed -i 's/\\r\$//' $CONF_FILE"; problems=$((problems+1))
  fi

  title "2) MySQL"
  if ! mysql_running; then
    bad "MySQL container '$MYSQL_CONTAINER' is not running"
    hint "Start it: docker start $MYSQL_CONTAINER    Logs: talisman logs mysql"
    problems=$((problems+1))
  elif ! mysql_ok; then
    bad "MySQL is running but the root password in $ENV_FILE is rejected (Access denied)"
    hint "No data to keep? Re-run: bash talisman_setup.sh --reset-mysql"
    hint "Or wait a minute if MySQL was just started, then try again."
    problems=$((problems+1))
  else
    ok "MySQL is running and the root password works"
    local db n
    for db in "${DATABASES[@]}"; do
      n="$(table_count "$db")"
      if [[ "$n" == "0" ]]; then
        if [[ "$db" == "db_gmtool" ]]; then info "$db is empty (only needed if you use the GM tool)"
        else warn "$db has no tables yet"; hint "Upload the SQL dump to $BASE/sql and run: talisman import"; fi
      else ok "$db: $n tables"; fi
    done
    load_env
    if docker exec -e MYSQL_PWD="$MYSQL_APP_PASSWORD" "$MYSQL_CONTAINER" mysql -u"$MYSQL_APP_USER" -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1; then
      ok "App user '$MYSQL_APP_USER' can log in"
    else
      bad "App user '$MYSQL_APP_USER' cannot log in"; hint "Re-run the setup to repair it"; problems=$((problems+1))
    fi
    if [[ -S /run/mysqld/mysqld.sock ]]; then ok "Socket /run/mysqld/mysqld.sock available (host 'localhost' works)"
    else warn "MySQL socket not visible on the host - use host 127.0.0.1 in configs"; hint "Re-run the setup to fix"; fi
  fi

  title "3) Server programs"
  local role bin pid ports
  for role in "${ROLES[@]}"; do
    bin="$(find_binary "$role")"
    if [[ -z "$bin" ]]; then
      bad "$(role_label "$role"): program not found under $BASE"
      hint "Upload it, or set ${role^^}_SERVER_BIN=/full/path in $CONF_FILE"
      problems=$((problems+1)); continue
    fi
    ok "$(role_label "$role"): $bin"
    info "type: $(file -b "$bin" | cut -d, -f1-2)"
    [[ -x "$bin" ]] || { chmod +x "$bin"; info "made it executable"; }
    if ldd "$bin" 2>&1 | grep -q 'not a dynamic executable'; then
      if file -b "$bin" | grep -q '32-bit'; then
        bad "32-bit program but 32-bit system libraries are missing"; hint "apt-get install libc6:i386 libstdc++6:i386"; problems=$((problems+1))
      fi
    else
      local line libs_ok=1
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
          linked:*) line="${line#linked:}"; ok "Linked ${line%%:*} -> ${line#*:} (auto-fixed)" ;;
          missing:*) libs_ok=0; bad "Missing library: ${line#missing:}"; missing_lib_hint "${line#missing:}"; problems=$((problems+1)) ;;
        esac
      done < <(fix_libs "$bin")
      [[ $libs_ok -eq 1 ]] && ok "All libraries found"
    fi
    if service_active "$role"; then
      pid="$(service_pid "$role")"; ports="$(listening_ports "$pid")"
      ok "running, PID $pid, listening on: ${ports:-nothing yet}"
      local p
      for p in $ports; do
        if ufw status 2>/dev/null | grep -qE "^$p(/tcp)?[[:space:]]+ALLOW"; then :
        elif [[ "$(ss -Hltn "sport = :$p" | awk '{print $4}' | head -n1)" == 127.0.0.1:* ]]; then :
        else info "port $p is used by this server but NOT open in the firewall (fine if it is internal)"
             hint "If players must reach it: talisman firewall open $p"; fi
      done
    else
      info "not running"
      if grep -qiE 'error|fail|cannot|can.t|denied|refused' "$(role_log "$role")" 2>/dev/null; then
        info "recent problems in its log:"
        grep -iE 'error|fail|cannot|can.t|denied|refused' "$(role_log "$role")" | tail -n 5 | sed 's/^/         /'
      fi
    fi
  done

  title "4) Network"
  echo "  Server IP: $(public_ip)"
  if ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "Firewall active. Open ports:"; ufw status | awk '/ALLOW/{print "         "$1}' | sort -u
  else warn "Firewall (ufw) is not active"; fi
  info "OVH/Hetzner/etc. may have an extra firewall in their web panel - open the same ports there."

  echo
  if [[ $problems -eq 0 ]]; then echo "${C_GRN}${C_B}No problems found.${C_0}"
  else echo "${C_YEL}${C_B}$problems problem(s) found - see the -> hints above.${C_0}"; fi
}

cmd_info() {
  load_env 2>/dev/null || true
  cat <<EOF
${C_B}Where things are${C_0}
  Server files  : $BASE/server/db_server  /login_server  /game_server
  SQL dumps     : $BASE/sql
  Extra libs    : $BASE/lib       (.so files the programs need)
  Logs          : $LOGS
  Backups       : $BASE/backup    (daily at 04:30, kept $BACKUP_KEEP_DAYS days)
  Settings      : $CONF_FILE
  Passwords     : $ENV_FILE       (talisman passwords)
  Server IP     : $(public_ip)
EOF
}

cmd_self_update() {
  need_root
  local tmp; tmp="$(mktemp)"
  info "Downloading latest setup from $REPO_RAW_URL ..."
  curl -fsSL "$REPO_RAW_URL/talisman_setup.sh" -o "$tmp" || die "Download failed."
  bash -n "$tmp" || die "Downloaded file is broken, not running it."
  bash "$tmp" --yes --no-import
  rm -f "$tmp"
}

cmd_uninstall() {
  need_root
  local purge=0; [[ "${1:-}" == "--purge" ]] && purge=1
  echo "This removes the talisman command, services and the MySQL container."
  [[ $purge -eq 1 ]] && echo "${C_RED}--purge: ALSO DELETES all database data and $BASE (server files, backups)!${C_0}"
  confirm "Continue?" || die "Cancelled."
  cmd_stop || true
  systemctl disable --now talisman.target talisman-backup.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/talisman-{db,login,game,backup}.service /etc/systemd/system/talisman.target \
        /etc/systemd/system/talisman-backup.timer /etc/logrotate.d/talisman /etc/tmpfiles.d/talisman-mysql.conf \
        /root/1 /root/2 /root/3 /root/stop-talisman
  systemctl daemon-reload
  docker rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  if [[ $purge -eq 1 ]]; then
    docker volume rm "$MYSQL_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$BASE"
  else
    echo "Kept: database volume '$MYSQL_VOLUME' and $BASE (re-run the setup to reinstall)."
  fi
  rm -f /usr/local/bin/talisman
  ok "Uninstalled"
}

cmd_help() {
  cat <<EOF
${C_B}talisman${C_0} - manage your Talisman Online server

${C_B}Everyday${C_0}
  talisman start              start db -> login -> game (in the right order)
  talisman stop               stop all servers
  talisman restart            stop + start
  talisman status             what is running, ports, IP
  talisman logs [db|login|game|mysql|all]   live log (Ctrl+C to exit)

${C_B}First-time setup${C_0}
  talisman info               where to upload files
  talisman unpack <archive>   extract a .zip/.rar/.7z server pack into $BASE/server
  talisman scan               show which programs and SQL files were found
  talisman import             import all SQL dumps found (db_account/db_game/db_log/db_gmtool)
  talisman import <file> <db> import one file into one database
  talisman passwords          database user/password for your server config files
  talisman find-config        show config files that contain database settings
  talisman db-user <u> <p>    create/update a MySQL user to match your configs

${C_B}When something is wrong${C_0}
  talisman doctor             check everything and explain how to fix problems
  talisman console <db|login|game>   run a server in the foreground to see errors

${C_B}Maintenance${C_0}
  talisman backup             back up all databases now (also runs daily)
  talisman restore [file]     list backups / restore one
  talisman sql [database]     open a MySQL prompt
  talisman firewall [open|close <port> | sync]
  talisman autostart on|off   start servers after reboot
  talisman self-update        download and apply the latest setup
  talisman uninstall [--purge]

Individual servers: talisman start game   /   talisman restart login   /   talisman stop db
Old shortcuts still work: cd /root && ./1 ./2 ./3   and   /root/stop-talisman
EOF
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    start)         cmd_start "$@" ;;
    stop)          cmd_stop "$@" ;;
    restart)       cmd_restart "$@" ;;
    status|st)     cmd_status ;;
    logs|log)      cmd_logs "$@" ;;
    console)       cmd_console "$@" ;;
    import)        cmd_import "$@" ;;
    backup)        cmd_backup ;;
    restore)       cmd_restore "$@" ;;
    passwords|pw)  cmd_passwords ;;
    db-user)       cmd_db_user "$@" ;;
    sql)           cmd_sql "$@" ;;
    unpack)        cmd_unpack "$@" ;;
    scan)          cmd_scan ;;
    find-config)   cmd_find_config ;;
    firewall|fw)   cmd_firewall "$@" ;;
    autostart)     cmd_autostart "$@" ;;
    doctor|check)  cmd_doctor ;;
    info)          cmd_info ;;
    self-update)   cmd_self_update ;;
    uninstall)     cmd_uninstall "$@" ;;
    __run)         cmd_run "$@" ;;
    help|-h|--help) cmd_help ;;
    *) echo "Unknown command: $cmd"; echo; cmd_help; exit 1 ;;
  esac
}
main "$@"
__TALISMAN_MANAGER_EOF__
chmod 755 "$MANAGER"
bash -n "$MANAGER" || die "Internal error: the talisman command has a syntax error."
ln -sf "$MANAGER" "$BASE/talisman"
ok "Installed: talisman   (run 'talisman help')"

# ----------------------------------------------------------------------------
step "Creating services (auto-restart on crash, start on boot, daily backup)..."
# ----------------------------------------------------------------------------
make_unit() {
  local role="$1" label="$2" logname="$3" after="$4"
  cat > "/etc/systemd/system/talisman-$role.service" <<EOF
[Unit]
Description=Talisman Online $label
After=docker.service network-online.target $after
Wants=docker.service network-online.target
PartOf=talisman.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStart=$MANAGER __run $role
Restart=always
RestartSec=5
# 78 = program not uploaded yet: do not restart in a loop.
RestartPreventExitStatus=78
StandardInput=null
StandardOutput=append:$BASE/logs/$logname.log
StandardError=append:$BASE/logs/$logname.log
LimitNOFILE=65535
LimitCORE=0
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=talisman.target
EOF
}
make_unit db    "DB Server"    db_server    ""
make_unit login "Login Server" login_server "talisman-db.service"
make_unit game  "Game Server"  game_server  "talisman-login.service"

cat > /etc/systemd/system/talisman.target <<EOF
[Unit]
Description=Talisman Online (all servers)
Wants=talisman-db.service talisman-login.service talisman-game.service
After=docker.service

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/talisman-backup.service <<EOF
[Unit]
Description=Talisman Online database backup
After=docker.service

[Service]
Type=oneshot
ExecStart=$MANAGER backup
EOF
cat > /etc/systemd/system/talisman-backup.timer <<'EOF'
[Unit]
Description=Daily Talisman Online database backup

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/talisman <<EOF
$BASE/logs/*.log {
    daily
    rotate 14
    maxsize 100M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# Boot order: servers need MySQL, which lives in Docker. The db service waits for it.
mkdir -p /etc/systemd/system/talisman-db.service.d
cat > /etc/systemd/system/talisman-db.service.d/wait-mysql.conf <<EOF
[Service]
ExecStartPre=/bin/bash -c 'for i in \$\$(seq 1 90); do docker exec $MYSQL_CONTAINER mysqladmin -h127.0.0.1 ping --silent >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'
ExecStartPre=/bin/sleep 3
TimeoutStartSec=240
EOF
for role in login game; do
  mkdir -p "/etc/systemd/system/talisman-$role.service.d"
  cat > "/etc/systemd/system/talisman-$role.service.d/delay.conf" <<EOF
[Service]
ExecStartPre=/bin/sleep ${START_DELAY:-5}
EOF
done

systemctl daemon-reload
systemctl enable --now talisman-backup.timer >/dev/null 2>&1 || warn "Could not enable the daily backup timer"
if [[ "${AUTOSTART:-yes}" == "yes" ]]; then
  systemctl enable talisman.target >/dev/null 2>&1 || true
fi
ok "Services: talisman-db, talisman-login, talisman-game (restart automatically if they crash)"
ok "Daily database backup at 04:30 into $BASE/backup"
ok "Log files rotate daily (no full disk from logs)"

# Old shortcuts from the previous version of this setup keep working.
for pair in "1:db" "2:login" "3:game"; do
  n="${pair%%:*}"; r="${pair#*:}"
  printf '#!/usr/bin/env bash\nexec %s start %s\n' "$MANAGER" "$r" > "/root/$n"
  chmod 755 "/root/$n"
done
printf '#!/usr/bin/env bash\nexec %s stop "$@"\n' "$MANAGER" > /root/stop-talisman
chmod 755 /root/stop-talisman

# ----------------------------------------------------------------------------
step "Configuring the firewall..."
# ----------------------------------------------------------------------------
if [[ "$OPT_NO_FIREWALL" == "1" ]]; then
  info "Skipped (--no-firewall)"
else
  SSH_PORTS="$( (sshd -T 2>/dev/null || true) | awk '/^port /{print $2}' | sort -u | tr '\n' ' ')"
  [[ -n "${SSH_PORTS// /}" ]] || SSH_PORTS="$( (ss -Hltnp 2>/dev/null || true) | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ')"
  [[ -n "${SSH_PORTS// /}" ]] || SSH_PORTS="22"
  # SSH first, so you can never lock yourself out.
  for p in $SSH_PORTS; do ufw allow "$p/tcp" comment 'SSH' >/dev/null; done
  for p in $PUBLIC_PORTS; do ufw allow "$p/tcp" comment 'Talisman' >/dev/null; done
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  ok "Firewall on. Open: SSH ($SSH_PORTS) + Talisman ($PUBLIC_PORTS)"
  info "MySQL ($MYSQL_PORT) stays private to this server."
  info "Need another port? talisman firewall open <port>"
fi

# ----------------------------------------------------------------------------
step "Looking for uploaded server files and SQL dumps..."
# ----------------------------------------------------------------------------
SCAN_OUT="$("$MANAGER" scan 2>&1 || true)"
echo "$SCAN_OUT"
if [[ $OPT_NO_IMPORT -eq 0 ]]; then
  if [[ "$SCAN_OUT" == *"SQL file"* ]]; then
    info "Importing SQL files into empty databases..."
    "$MANAGER" import || warn "Some SQL files were not imported - see above."
  fi
fi

# ----------------------------------------------------------------------------
# README next to the files
# ----------------------------------------------------------------------------
cat > "$BASE/README-FIRST.txt" <<EOF
TALISMAN ONLINE SERVER  (setup v$SETUP_VERSION)
==========================================

Type "talisman help" to see every command.

1. Upload your server files (Bitvise SSH Client -> New SFTP window, user root):
     db_server folder contents    -> $BASE/server/db_server/
     login_server folder contents -> $BASE/server/login_server/
     game_server folder contents  -> $BASE/server/game_server/
   Archives (.zip/.rar/.7z) can be extracted with:  talisman unpack <file>

2. Upload your database files into $BASE/sql/
     db_account.sql, db_game.sql, db_log.sql (db_gmtool.sql optional)
   Then import them:  talisman import

3. Put the database login into your server config files:
     talisman passwords      (shows user/password)
     talisman find-config    (shows which files to edit)

4. Start:   talisman start
   Check:   talisman status
   Problem: talisman doctor

MySQL runs in Docker ("$MYSQL_CONTAINER"), reachable only from this server
at 127.0.0.1:$MYSQL_PORT (or "localhost"). Backups: $BASE/backup (daily).
EOF

# ----------------------------------------------------------------------------
step "Done!"
# ----------------------------------------------------------------------------
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
cat <<EOF

${C_GRN}${C_B}==================================================
 SETUP COMPLETE
==================================================${C_0}

 Server IP        : ${SERVER_IP:-unknown}
 Talisman folder  : $BASE
 DB user/password : talisman passwords
 Setup log        : $BASE/logs/setup.log

${C_B} Next steps:${C_0}
  1) Upload with Bitvise (New SFTP window):
       db_server    ->  $BASE/server/db_server/
       login_server ->  $BASE/server/login_server/
       game_server  ->  $BASE/server/game_server/
  2) Upload db_account.sql, db_game.sql, db_log.sql  ->  $BASE/sql/
     then run:  talisman import
  3) Edit server configs  ->  talisman passwords  +  talisman find-config
  4) Start                ->  talisman start
  5) Check                ->  talisman status   /   talisman doctor

 All commands: talisman help
EOF
if [[ $NEW_PASSWORDS -eq 1 ]]; then
  echo
  echo " New MySQL passwords were created. See them any time with: talisman passwords"
fi
echo
