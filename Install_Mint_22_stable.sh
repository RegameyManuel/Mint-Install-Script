#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Script d’installation LAMP + DBeaver CE + Symfony CLI pour Linux Mint 22
# (basé sur Ubuntu 24.04 "noble")
#
# Points clés :
# - Journalisation complète dans /var/log/mint22-setup.log
# - Mode non interactif pour APT (installations automatisées)
# - Ajout des dépôts APT en format deb822 + keyrings (DBeaver, Symfony CLI)
# - Installation Apache, MariaDB, PHP (+ extensions), Composer
# - Activation du module rewrite et réglage de ServerName pour Apache
# - Tuning basique du php.ini (timezone, memory limit, etc.)
# - Affichage des versions en fin de script
# ──────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
# set -E : propage le trap ERR dans les fonctions
# set -e : stoppe le script au premier échec d’une commande
# set -u : échec si une variable non définie est utilisée
# set -o pipefail : propage les erreurs à travers les pipes

# ===== Logging & noninteractive apt =====
exec > >(tee -a /var/log/mint22-setup.log) 2>&1
# Redirige stdout et stderr vers tee -> log concomitant à l’écran + dans le fichier.

# Trap d'erreur (log ligne + commande + code de sortie)
trap 'rc=$?; echo "[ERROR] line $LINENO: $BASH_COMMAND (exit $rc)" >&2' ERR
# Si une erreur survient, on log la ligne, la commande fautive et le code de retour.

export DEBIAN_FRONTEND=noninteractive
APT_GET="apt-get -y -o Dpkg::Options::=--force-confnew"
# Force l’acceptation des nouveaux fichiers de conf (évite prompts) et -y pour tout valider.

# ===== Root check =====
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi
# On exige les droits root car le script modifie le système (APT, services, fichiers système).

# ===== Detect distro/codename/arch =====
source /etc/os-release
DIST_ID="${ID:-linuxmint}"
DIST_NAME="${NAME:-Linux Mint}"
DIST_VERSION_CODENAME="${VERSION_CODENAME:-}"
UBU_CODENAME="${UBUNTU_CODENAME:-}"
CODENAME="${UBU_CODENAME:-$DIST_VERSION_CODENAME}"
ARCH="$(dpkg --print-architecture)"

echo "Detected: ${DIST_NAME} (${DIST_ID}) codename=${CODENAME} arch=${ARCH}"
# Détermine la base Ubuntu (CODENAME) et l’architecture (amd64, arm64…) pour configurer les dépôts.

# ===== Helper: ensure a keyring and repository (deb822) exist =====
ensure_deb822_source() {
  # Utilitaire : crée un fichier source APT au format deb822 si absent.
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
  # Utilitaire : installe un keyring APT (binaire .gpg si nécessaire).
  local url="$1"
  local dest="$2"
  if [[ -f "$dest" ]]; then
    echo "[OK] Keyring exists: $dest"
  else
    echo "[ADD] Fetching key: $url -> $dest"
    install -d -m 0755 "$(dirname "$dest")"
    if curl -fsSL "$url" | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then
      # Si clé ASCII-armored -> on la convertit en binaire .gpg
      curl -fsSL "$url" | gpg --dearmor > "$dest"
    else
      # Sinon on la prend telle quelle (souvent déjà binaire)
      curl -fsSL "$url" -o "$dest"
    fi
    chmod 0644 "$dest"
  fi
}

# ===== Base tools & mirror sanity =====
$APT_GET update || true
$APT_GET install ca-certificates curl wget gnupg lsb-release software-properties-common
# Outils de base requis (TLS, téléchargement, gestion de clés, infos distro…).

echo "[NET] Checking network..."
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
  echo "[NET] OK"
else
  echo "[WARN] Network check failed; continuing anyway."
fi
# Petit check réseau ; on continue quand même si ping échoue (certaines politiques réseau bloquent ICMP).

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
# Ajoute le dépôt officiel DBeaver CE (format deb822) + son keyring pour signatures APT.

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
# Ajoute le dépôt Cloudsmith pour Symfony CLI, calé sur le codename Ubuntu (noble pour Mint 22).

# ===== Update package lists =====
$APT_GET update
# Recharge les index APT après l’ajout des nouveaux dépôts.

# ===== Core packages =====
$APT_GET install \
  build-essential git unzip zip \
  apache2 mariadb-server \
  php php-cli libapache2-mod-php \
  php-mysql php-xml php-mbstring php-zip php-gd php-curl \
  dbeaver-ce symfony-cli
# Installe :
# - outils de build, Git, utilitaires d’archives
# - Apache2, MariaDB
# - PHP (CLI + module Apache) et extensions usuelles (MySQL, XML, mbstring, zip, gd, curl)
# - DBeaver CE (client DB) et Symfony CLI

# ===== PHP: determine version dynamically =====
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
echo "[PHP] Detected PHP ${PHP_VER}"
PHP_INI_APACHE="/etc/php/${PHP_VER}/apache2/php.ini"
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"
# Détecte la version de PHP (ex: 8.3) pour cibler les bons php.ini.

# Harden some sensible defaults if present
tweak_ini() {
  # Fonction : applique des réglages utiles dans php.ini s’ils existent, sinon ajoute timezone.
  local ini="$1"
  if [[ -f "$ini" ]]; then
    sed -i 's/^;*\s*date.timezone\s*=.*/date.timezone = Europe\/Paris/g' "$ini" || true
    sed -i 's/^;*\s*memory_limit\s*=.*/memory_limit = 512M/g' "$ini" || true
    sed -i 's/^;*\s*upload_max_filesize\s*=.*/upload_max_filesize = 64M/g' "$ini" || true
    sed -i 's/^;*\s*post_max_size\s*=.*/post_max_size = 64M/g' "$ini" || true
    sed -i 's/^;*\s*max_execution_time\s*=.*/max_execution_time = 120/g' "$ini" || true
    grep -q '^date.timezone' "$ini" || echo 'date.timezone = Europe/Paris' >> "$ini"
  fi
}
tweak_ini "$PHP_INI_APACHE"
tweak_ini "$PHP_INI_CLI"
# Applique les tweaks au php.ini d’Apache et au php.ini CLI.

# ===== Apache: ensure enabled & running =====
systemctl enable --now apache2
# Active Apache au boot et démarre le service maintenant.

apachectl -t || true
# Vérifie la validité de la config Apache (n’arrête pas le script si warning).

if ! apache2ctl -M 2>/dev/null | grep -q rewrite_module; then
  a2enmod rewrite
  systemctl reload apache2
fi
# Active le module rewrite (souvent requis par des frameworks ou CMS) puis recharge Apache.

if ! grep -q '^ServerName ' /etc/apache2/conf-available/servername.conf 2>/dev/null; then
  printf "ServerName localhost\n" > /etc/apache2/conf-available/servername.conf
  a2enconf servername
  systemctl reload apache2
fi
# Ajoute une conf ServerName pour éviter l’avertissement FQDN et recharge Apache.

# ===== MariaDB: ensure enabled & running (without interactive hardening here) =====
systemctl enable --now mariadb
# Active/démarre MariaDB. Le durcissement (mysql_secure_installation) se fera à la main.

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
# Installe Composer en vérifiant la signature SHA-384 de l’installateur (sécurité).

# ===== Restart services to pick up PHP config =====
systemctl restart apache2
# Redémarre Apache pour prendre en compte les modifications PHP/Apache.

# ===== Print versions =====
echo "===== VERSIONS ====="
apache2 -v || true
mariadb --version || true
php -v | head -n1 || true
composer -V || true
dbeaver --version || true
symfony -V || true
# Affiche les versions pour valider rapidement l’installation.

echo "===== DONE ====="
echo "Test Apache: http://localhost"
# Indication finale : le serveur web local doit répondre.

