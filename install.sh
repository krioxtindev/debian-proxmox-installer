#!/usr/bin/env bash
#
# Automatizovaná instalace Proxmox VE 9 na Debian 13 (Trixie)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[CHYBA] Tento skript musí běžet pod uživatelem root (sudo ./install_proxmox.sh)${NC}"
    exit 1
fi

run_step() {
    local desc="$1"
    local cmd="$2"

    while true; do
        echo -e "\n${BLUE}==>${NC} ${desc}..."
        if eval "$cmd"; then
            echo -e "${GREEN}[OK] Hotovo: ${desc}${NC}"
            break
        else
            local exit_code=$?
            echo -e "${RED}[CHYBA] Krok '${desc}' selhal s kódem ${exit_code}!${NC}"
            echo -ne "${YELLOW}Chcete krok [o]pakovat, [p]řeskočit, nebo skript [u]končit? (o/p/u): ${NC}"
            read -r choice < /dev/tty
            case "$choice" in
                o|O ) echo "Opakuji krok...";;
                p|P ) echo -e "${YELLOW}Krok přeskočen.${NC}"; break;;
                * ) echo -e "${RED}Skript ukončen.${NC}"; exit 1;;
            esac
        fi
    done
}

confirm_stage() {
    local stage_name="$1"
    echo -e "\n${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${YELLOW}Fáze dokončena: ${stage_name}${NC}"
    echo -ne "${YELLOW}Pokračovat na další krok? [A/n]: ${NC}"
    read -r resp < /dev/tty
    if [[ "$resp" =~ ^[nN]$ ]]; then
        echo -e "${RED}Skript byl zastaven uživatelem.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}------------------------------------------------------------\n${NC}"
}

clear
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     Instalace Proxmox VE 9 na Debian 13 (Trixie)           ${NC}"
echo -e "${BLUE}============================================================${NC}"

# Kontrola verze distribuce
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-trixie}"
else
    echo -e "${RED}[CHYBA] Nelze načíst soubor /etc/os-release.${NC}"
    exit 1
fi

if [ "$CODENAME" != "trixie" ]; then
    echo -e "${YELLOW}[VAROVÁNÍ] Zjištěná verze systému je '${CODENAME}', nikoliv 'trixie' (Debian 13).${NC}"
fi

# 1. Konfigurace sítě a /etc/hosts
HOSTNAME=$(hostname -s)
DOMAIN=$(hostname -d 2>/dev/null || echo "lan")
FQDN="${HOSTNAME}.${DOMAIN}"

# Detekce aktivní LAN IP adresy
PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

if [ -z "$PRIMARY_IP" ]; then
    echo -e "${RED}[CHYBA] Nebyla nalezena žádná platná síťová IP adresa.${NC}"
    exit 1
fi

echo -e "Hostname : ${GREEN}${HOSTNAME}${NC}"
echo -e "FQDN     : ${GREEN}${FQDN}${NC}"
echo -e "LAN IP   : ${GREEN}${PRIMARY_IP}${NC}"

# Vyčištění 127.0.1.1 a zajištění správného mapování FQDN -> lokální IP
sed -i '/127\.0\.1\.1/d' /etc/hosts
if ! grep -qE "^${PRIMARY_IP}[[:space:]]" /etc/hosts; then
    echo -e "${PRIMARY_IP} ${FQDN} ${HOSTNAME}" >> /etc/hosts
fi

confirm_stage "Příprava /etc/hosts"

# 2. Nastavení repozitářů a GPG klíče pro Proxmox VE 9 (Trixie)
echo -e "\n${BLUE}[1/4] Přidání repozitářů Proxmox VE 9 (Trixie)${NC}"

run_step "Instalace základních utilit" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg wget"

run_step "Stažení oficiálního GPG klíče pro Trixie" \
  "install -m 0755 -d /usr/share/keyrings && wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"

run_step "Přidání Proxmox no-subscription repozitáře" \
  "echo 'deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription' > /etc/apt/sources.list.d/pve-install-repo.list"

confirm_stage "Nastavení repozitářů"

# 3. Instalace a zavedení Proxmox jádra a balíčků
echo -e "\n${BLUE}[2/4] Aktualizace a instalace balíčků Proxmox VE${NC}"

run_step "Aktualizace seznamu balíčků z repozitářů" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y"

run_step "Instalace Proxmox jádra (proxmox-default-kernel)" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-default-kernel"

run_step "Instalace hlavního balíku proxmox-ve a závislostí" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi chrony"

confirm_stage "Instalace balíčků Proxmox VE"

# 4. Úklid starého Debian jádra
echo -e "\n${BLUE}[3/4] Odstranění původního Debian kernelu${NC}"

run_step "Odstranění původního jádra (ponechá pouze Proxmox kernel)" \
  "apt-get remove -y linux-image-amd64 'linux-image-6.12*' || true"

run_step "Aktualizace zavaděče GRUB" \
  "update-grub"

confirm_stage "Úprava zavaděče"

# 5. Odstavení enterprise repozitáře
echo -e "\n${BLUE}[4/4] Dokončení konfigurace${NC}"

if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}      PROXMOX VE 9 BYL ÚSPĚŠNĚ NAINSTALOVÁN!               ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Webové rozhraní:"
echo -e "   URL:           ${BLUE}https://${PRIMARY_IP}:8006${NC}"
echo -e "   Uživatel:      root"
echo -e "   Heslo:         vaše stávající heslo uživatele root"
echo -e ""
echo -e "${YELLOW}NUTNÝ KROK: Nyní restartujte systém příkazem 'reboot', aby se načetl PVE kernel.${NC}"
echo -e "${GREEN}============================================================${NC}\n"
