#!/usr/bin/env bash
set -euo pipefail

# ===== Logging & noninteractive apt =====
exec > >(tee -a /var/log/mint22-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
APT_GET="apt-get -y -o Dpkg::Options::=--force-confnew"

# ===== Root check =====
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# ===== Detect distro/codename/arch =====
source /etc/os-release
DIST_ID="${ID:-linuxmint}"
DIST_NAME="${NAME:-Linux Mint}"
DIST_VERSION_CODENAME="${VERSION_CODENAME:-}"
UBU_CODENAME="${UBUNTU_CODENAME:-}"
CODENAME="${UBU_CODENAME:-$DIST_VERSION_CODENAME}"
ARCH="$(dpkg --print-architecture)"

echo "Detected: ${DIST_NAME} (${DIST_ID}) codename=${CODENAME} arch=${ARCH}"

# ===== Helper: ensure a keyring and repository (deb822) exist =====
ensure_deb822_source() {
  local src_path="$1"      # e.g., /etc/apt/sources.list.d/vscode.sources
  local content="$2"       # full deb822 content
  if [[ -f "$src_path" ]]; then
    echo "[OK] Repo exists: $src_path"
  else
    echo "[ADD] Creating repo: $src_path"
    printf "%s\n" "$content" > "$src_path"
  fi
}

ensure_keyring() {
  local url="$1"           # URL to fetch the ASCII-armored or binary key
  local dest="$2"          # destination path in /etc/apt/keyrings or /usr/share/keyrings
  if [[ -f "$dest" ]]; then
    echo "[OK] Keyring exists: $dest"
  else
    echo "[ADD] Fetching key: $url -> $dest"
    install -d -m 0755 "$(dirname "$dest")"
    curl -fsSL "$url" -o "$dest"
    chmod 0644 "$dest"
  fi
}

# ===== Base tools & mirror sanity =====
$APT_GET update || true
$APT_GET install ca-certificates curl wget gnupg lsb-release software-properties-common apt-transport-https

echo "[NET] Checking network..."
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
  echo "[NET] OK"
else
  echo "[WARN] Network check failed; continuing anyway."
fi

# ===== Repositories =====
# VS Code (Microsoft)
MS_KEYRING="/etc/apt/keyrings/packages.microsoft.gpg"
ensure_keyring "https://packages.microsoft.com/keys/microsoft.asc" "$MS_KEYRING"
VSCODE_SOURCES="/etc/apt/sources.list.d/vscode.sources"
VSCODE_CONTENT="Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: ${ARCH}
Signed-By: ${MS_KEYRING}"
ensure_deb822_source "$VSCODE_SOURCES" "$VSCODE_CONTENT"

# DBeaver CE
DB_KEYRING="/usr/share/keyrings/dbeaver.gpg.key"
ensure_keyring "https://dbeaver.io/debs/dbeaver.gpg.key" "$DB_KEYRING"
DB_SOURCES="/etc/apt/sources.list.d/dbeaver.sources"
DB_CONTENT="Types: deb
URIs: https://dbeaver.io/debs/dbeaver-ce
Suites: /
Components: 
Architectures: ${ARCH}
Signed-By: ${DB_KEYRING}"
ensure_deb822_source "$DB_SOURCES" "$DB_CONTENT"

# Symfony CLI (Cloudsmith) - target Ubuntu codename for Mint (noble for Mint 22.x)
SYM_KEYRING="/usr/share/keyrings/symfony-stable-archive-keyring.gpg"
ensure_keyring "https://dl.cloudsmith.io/public/symfony/stable/gpg.key" "$SYM_KEYRING"
SYM_SOURCES="/etc/apt/sources.list.d/symfony-cli.sources"
SYM_CONTENT="Types: deb
URIs: https://dl.cloudsmith.io/public/symfony/stable/deb/ubuntu
Suites: ${CODENAME}
Components: main
Architectures: ${ARCH}
Signed-By: ${SYM_KEYRING}"
ensure_deb822_source "$SYM_SOURCES" "$SYM_CONTENT"

# ===== Update package lists =====
$APT_GET update

# ===== Core packages =====
$APT_GET install \
  build-essential git unzip zip \
  apache2 mariadb-server \
  php php-cli php-fpm libapache2-mod-php \
  php-mysql php-xml php-mbstring php-zip php-gd php-curl \
  code dbeaver-ce symfony-cli

# ===== PHP: determine version dynamically =====
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')"
echo "[PHP] Detected PHP ${PHP_VER}"
PHP_INI_APACHE="/etc/php/${PHP_VER}/apache2/php.ini"
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"

# Harden some sensible defaults if present
tweak_ini() {
  local ini="$1"
  if [[ -f "$ini" ]]; then
    sed -i 's/^;*\s*date.timezone\s*=.*/date.timezone = Europe\/Paris/g' "$ini" || true
    sed -i 's/^;*\s*memory_limit\s*=.*/memory_limit = 512M/g' "$ini" || true
    sed -i 's/^;*\s*upload_max_filesize\s*=.*/upload_max_filesize = 64M/g' "$ini" || true
    sed -i 's/^;*\s*post_max_size\s*=.*/post_max_size = 64M/g' "$ini" || true
    sed -i 's/^;*\s*max_execution_time\s*=.*/max_execution_time = 120/g' "$ini" || true
  fi
}
tweak_ini "$PHP_INI_APACHE"
tweak_ini "$PHP_INI_CLI"

# ===== Apache: ensure enabled & running =====
systemctl enable --now apache2

# ===== MariaDB: ensure enabled & running (without interactive hardening here) =====
systemctl enable --now mariadb

# ===== Composer install (with basic signature verification) =====
if ! command -v composer >/dev/null 2>&1; then
  echo "[Composer] Installing..."
  EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
  if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      >&2 echo 'ERROR: Invalid composer installer signature'
      rm -f composer-setup.php
      exit 1
  fi
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f composer-setup.php
else
  echo "[Composer] Already installed."
fi

# ===== Restart services to pick up PHP config =====
systemctl restart apache2

# ===== Print versions =====
echo "===== VERSIONS ====="
apache2 -v || true
mariadb --version || true
php -v | head -n1 || true
composer -V || true
code --version | head -n1 || true
dbeaver --version || true
symfony -V || true

echo "===== DONE ====="
echo "Test Apache: http://localhost"
