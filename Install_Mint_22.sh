#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  SUDO=sudo
else
  SUDO=
fi

# -------------------------
# Gestion des arguments
# -------------------------
UNINSTALL=false
PURGE_FULL=false
STRICT=false
QUIET=false

# -------------------------
# Codes couleurs pour la lisibilité (vert, rouge, reset)
# -------------------------
COLOR_GREEN="\033[1;32m"
COLOR_RED="\033[1;31m"
COLOR_RESET="\033[0m"

for arg in "$@"; do
  case "$arg" in
    -u|--uninstall)   UNINSTALL=true   ;;
    -p|--purge-full)  PURGE_FULL=true  ;;
    -s|--strict)      STRICT=true      ;;
    -q|--quiet)       QUIET=true       ;;
  esac
done

# -------------------------
# Mode strict
# -------------------------
if $STRICT; then 
  echo " ****** MODE STRICT ACTIVÉ ****** "
  set -e
fi

export DEBIAN_FRONTEND=noninteractive

# -------------------------
# purge totale
# -------------------------
if $PURGE_FULL; then
  echo " ! ! !  MODE PURGE TOTALE ACTIVÉ ! ! ! "
  read -p "Écrasez-vous TOUT (config, données, logs) ? (o/N) : " CONF
  [[ ! "${CONF:-N}" =~ ^[Oo]$ ]] && { echo "Annulé."; exit 1; }


  echo "⚠️ Cette étape va PURGER Apache/MariaDB/PHP des paquets installés."
  read -p "Confirmer la purge des paquets (o/N) ? " CONF_PKGS
  [[ "${CONF_PKGS:-N}" =~ ^[oO]$ ]] || { echo "Abandon."; exit 1; }


  # Purger uniquement les paquets PHP installés
  mapfile -t PHP_PKGS < <(dpkg -l | awk '/^ii\s+php/ {print $2}')
  if ((${#PHP_PKGS[@]})); then
    sudo apt-get -y purge "${PHP_PKGS[@]}"
  fi

  # Purger uniquement les paquets Apache installés
  mapfile -t APACHE_PKGS < <(dpkg -l | awk '/^ii\s+apache2/ {print $2}')
  if ((${#APACHE_PKGS[@]})); then
    sudo apt-get -y purge "${APACHE_PKGS[@]}"
  fi

  # Purger uniquement les paquets MariaDB installés
  mapfile -t MARIADB_PKGS < <(dpkg -l | awk '/^ii\s+(mariadb|mysql)/ {print $2}')
  if ((${#MARIADB_PKGS[@]})); then
    sudo apt-get -y purge "${MARIADB_PKGS[@]}"
  fi

  # Nettoyage des résidus
  sudo apt-get -y autoremove --purge
  sudo apt-get -y autoclean

  # Dossiers potentiels à nettoyer
  sudo rm -rf /etc/php /var/lib/php /var/log/php* \
              /etc/apache2 /var/www/html \
              /var/lib/mysql /etc/mysql


  echo " ****** Suppression des dépôts et clés VSCode/VSCodium/DBeaver ****** "

  sudo rm -f /usr/share/keyrings/{vscode.gpg,packages.microsoft.gpg,microsoft.gpg,dbeaver.gpg,vscodium-archive-keyring.gpg}
  sudo rm -f /etc/apt/sources.list.d/{vscode.list,code.list,vscodium.list,dbeaver.list}


  echo " ****** RÉPARATION DÉPENDANCES ****** "
  sudo apt -y --fix-broken install || true
  sudo apt update

  echo " ****** Purge complète terminée ****** "
  exit 0
fi

# -------------------------
# désinstallation simple
# -------------------------
if $UNINSTALL; then
  echo " ****** MODE DÉSINSTALLATION ACTIVÉ ****** "

  echo " ****** Purge des paquets LAMP et outils dev ****** "
  
  
  sudo apt purge --autoremove -y \
    php8.3-cli php8.3-common php8.3-fpm \
    php8.3-mysql php8.3-xml php8.3-mbstring \
    libapache2-mod-php8.3 \
    apache2 apache2-bin apache2-utils apache2-data \
    mariadb-server mariadb-client

  echo " ****** Nettoyage manuel des configs PHP/Apache résiduelles ****** "
  sudo rm -rf /etc/php/*/mods-available /etc/php/* /etc/apache2 /var/lib/apache2

  echo " ****** Suppression de Composer et Symfony CLI ****** "
  sudo rm -f /usr/local/bin/composer /usr/local/bin/symfony
  rm -rf ~/.symfony*

  echo " ****** Nettoyage des données MariaDB ****** "
  sudo rm -rf /var/lib/mysql /etc/mysql /var/log/mysql

  echo " ****** Nettoyage du webroot et des logs Apache ****** "
  sudo rm -rf /var/www/html /var/log/apache2

  echo " ****** Suppression conditionnelle de VSCode, VSCodium et DBeaver ****** "
  for pkg in code codium dbeaver-ce; do
    if dpkg -l | grep -E "^ii[[:space:]]+$pkg[[:space:]]" >/dev/null; then
      echo "  → Suppression $pkg"
      sudo apt purge --autoremove -y "$pkg"
    else
      echo " ******   • $pkg non installé ****** "
    fi
  done

  echo " ****** Suppression des clés & dépôts ****** "
  sudo rm -f /usr/share/keyrings/{vscode.gpg,packages.microsoft.gpg,microsoft.gpg,dbeaver.gpg,vscodium-archive-keyring.gpg}
  sudo rm -f /etc/apt/sources.list.d/{vscode.list,code.list,vscodium.list,dbeaver.list}

  echo " ****** Nettoyage final APT ****** "
  sudo apt autoremove --purge -y
  sudo apt clean

  echo " ****** Désinstallation terminée ****** "
  exit 0
fi

# -------------------------
# installation
# -------------------------
echo " ****** MODE INSTALLATION ****** "

echo " ****** PURGE COMPLÈTE DE PHP, MARIADB, MYSQL ET APACHE2 ****** "

sudo apt purge --autoremove -y \
  php8.3-cli php8.3-common php8.3-fpm \
  php8.3-mysql php8.3-xml php8.3-mbstring \
  libapache2-mod-php8.3 \
  apache2 apache2-bin apache2-utils apache2-data \
  mariadb-server mariadb-client

echo " ****** NETTOYAGE DES FICHIERS DE CONFIGURATION RÉSIDUELS ****** "
sudo apt autoremove --purge -y || true
sudo apt clean

echo " ****** RÉPARATION DÉPENDANCES ****** "
sudo apt -y --fix-broken install || true
sudo apt update

echo " ****** SUPPRESSION DES DONNÉES ET DES LOGS MARIADB/MYSQL ****** "
echo "⚠️ ATTENTION : cette procédure va supprimer TOUTES les bases et configurations locales."
read -p "Continuer (o/N) ? " REP
if [[ "${REP:-N}" != "o" && "${REP:-N}" != "O" ]]; then
  echo "Abandon."
  exit 1
fi
sudo rm -rf /var/lib/mysql /etc/mysql /var/log/mysql || true

echo " ****** MISE À JOUR DES DÉPÔTS ****** "
sudo apt update

echo " ****** INSTALLATION DE LA PILE LAMP (Apache, MariaDB, PHP) ****** "
sudo apt install -y \
  apache2 \
  mariadb-server \
  mariadb-client \
  php-cli \
  php-curl \
  php-dev \
  php-gd \
  php-gmp \
  php-imagick \
  php-imap \
  php-intl \
  php-mbstring \
  php-mysql \
  php-soap \
  php-sqlite3 \
  php-xml \
  php-zip \
  libapache2-mod-php

echo " ****** INSTALLATION DES OUTILS DE DÉVELOPPEMENT ****** "
sudo apt install -y unzip git curl make gcc wget gpg software-properties-common

echo "Activation des services Apache et MariaDB"
sudo systemctl enable --now apache2
sudo systemctl enable --now mariadb

# (optionnel) durcissement MariaDB interactif
# echo "Lancement de mysql_secure_installation..."
# sudo mysql_secure_installation

# --- Installation de Composer (signature dynamique + binaire global) ---
echo "Installation de Composer…"

# vérifier qu'on a un téléchargeur
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "ERREUR: ni curl ni wget n'est installé (requis pour récupérer la signature Composer)."
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
else
  EXPECTED_SIGNATURE="$(wget -qO- https://composer.github.io/installer.sig)"
fi

php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
trap 'rm -f composer-setup.php' EXIT

ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
  echo "ERREUR: signature de l'installeur Composer invalide."
  exit 1
fi

sudo php composer-setup.php --install-dir=/usr/local/bin --filename=composer > /dev/null
echo "[OK] $(composer --version)"
rm -f composer-setup.php
trap - EXIT

# --- Installation de la Symfony CLI (rép. officielle Debian/Ubuntu) ---
echo "Installation de symfony-cli…"
curl -1sLf 'https://dl.cloudsmith.io/public/symfony/stable/setup.deb.sh' | sudo -E bash
sudo apt install -y symfony-cli
echo "[OK] $(symfony -V)"

# (optionnel) activer mod_rewrite et redémarrer Apache
sudo a2enmod rewrite || true
sudo systemctl restart apache2



sudo rm -f /etc/apt/sources.list.d/{vscode.list,code.list,vscode.sources}
sudo rm -f /usr/share/keyrings/{microsoft.gpg,packages.microsoft.gpg}
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | \
  sudo tee /usr/share/keyrings/packages.microsoft.gpg >/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
  sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
sudo apt update






# Ajouter la clé Microsoft
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor \
| sudo tee /usr/share/keyrings/packages.microsoft.gpg > /dev/null

# Ajouter le dépôt VS Code
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
| sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

# Installer VS Code
sudo apt update
sudo apt install -y code

# Vérification
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" code --version
else
  code --version
fi



# Installation Dbeaver-ce
sudo  wget -O /usr/share/keyrings/dbeaver.gpg.key https://dbeaver.io/debs/dbeaver.gpg.key
echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg.key] https://dbeaver.io/debs/dbeaver-ce /" | sudo tee /etc/apt/sources.list.d/dbeaver.list
sudo apt-get update && sudo apt-get install dbeaver-ce




# Liste des commandes à tester
COMMANDS=( curl wget gpg git php mysql code composer symfony dbeaver )

for cmd in "${COMMANDS[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "***** $cmd -> ${COLOR_GREEN}TRUE${COLOR_RESET} *****"
  else
    echo -e "***** $cmd -> ${COLOR_RED}FALSE${COLOR_RESET} *****"
  fi
done

echo "PHP : $(php -v | head -n1)"
echo "MariaDB : $(mariadb --version || mysql --version)"
echo "Composer : $(composer --version)"
echo "Symfony CLI : $(symfony version)"

echo -e "${COLOR_GREEN}✅ Tous les composants sont installés et prêts à l'emploi.${COLOR_RESET}"

echo " ****** INSTALLATION TERMINÉE ****** "


