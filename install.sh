#!/usr/bin/env bash
#
# Automatizovaná instalace Proxmox VE na Debian
# Určeno pro uložení na GitHub a spuštění přes curl / bash
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[CHYBA] Tento skript musí být spuštěn jako root (sudo ./install_proxmox.sh)${NC}"
    exit 1
fi

run_step() {
    local desc="$1"
    local cmd="$2"

    while true; do
        echo -e "\n${BLUE}==>${NC} ${desc}..."
        if eval "$cmd"; then
            echo -e "${GREEN}[OK] Úspěšně dokončeno: ${desc}${NC}"
            break
        else
            local exit_code=$?
            echo -e "${RED}[CHYBA] Krok '${desc}' selhal s kódem ${exit_code}!${NC}"
            echo -ne "${YELLOW}Chcete krok [o]pakovat, [p]řeskočit, nebo skript [u]končit? (o/p/u): ${NC}"
            read -r choice < /dev/tty
            case "$choice" in
                o|O ) echo "Opakuji krok...";;
                p|P ) echo -e "${YELLOW}Krok přeskočen.${NC}"; break;;
                * ) echo -e "${RED}Skript ukončen uživatelem.${NC}"; exit 1;;
            esac
        fi
    done
}

confirm_stage() {
    local stage_name="$1"
    echo -e "\n${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${YELLOW}Fáze dokončena: ${stage_name}${NC}"
    echo -ne "${YELLOW}Chcete pokračovat dál? [A/n]: ${NC}"
    read -r resp < /dev/tty
    if [[ "$resp" =~ ^[nN]$ ]]; then
        echo -e "${RED}Skript byl pozastaven uživatelem.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}------------------------------------------------------------\n${NC}"
}

clear
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}          Instalace Proxmox VE na čistý Debian             ${NC}"
echo -e "${BLUE}============================================================${NC}"

# Kontrola distribuce
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-bookworm}"
else
    echo -e "${RED}[CHYBA] Nelze načíst /etc/os-release.${NC}"
    exit 1
fi

if [ "$CODENAME" != "bookworm" ]; then
    echo -e "${RED}[VAROVÁNÍ] Detekována verze Debianu: '${CODENAME}'.${NC}"
    echo -e "${RED}Proxmox VE 8 oficiálně vyžaduje výhradně Debian 12 (bookworm).${NC}"
    echo -ne "${YELLOW}Chcete přesto pokračovat na vlastní riziko? [a/N]: ${NC}"
    read -r force_run < /dev/tty
    if [[ ! "$force_run" =~ ^[aAyY]$ ]]; then
        exit 1
    fi
fi

# 1. Konfigurace /etc/hosts a FQDN
HOSTNAME=$(hostname -s)
DOMAIN=$(hostname -d 2>/dev/null || echo "lan")
FQDN="${HOSTNAME}.${DOMAIN}"

# Detekce primární IP adresy
PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

echo -e "Detekovaný hostname : ${GREEN}${HOSTNAME}${NC}"
echo -e "Detekované FQDN     : ${GREEN}${FQDN}${NC}"
echo -e "Detekovaná LAN IP   : ${GREEN}${PRIMARY_IP}${NC}"

if [ -z "$PRIMARY_IP" ]; then
    echo -e "${RED}[CHYBA] Nebyla nalezena žádná platná síťová IP adresa.${NC}"
    exit 1
fi

# Odstranění starého 127.0.1.1 a zajištění správného mapování na LAN IP
sed -i '/127\.0\.1\.1/d' /etc/hosts
if ! grep -qE "^${PRIMARY_IP}[[:space:]]" /etc/hosts; then
    echo -e "${PRIMARY_IP} ${FQDN} ${HOSTNAME}" >> /etc/hosts
fi

confirm_stage "Příprava sítě a /etc/hosts"

# 2. Přidání GPG klíče a repozitáře Proxmox VE
echo -e "\n${BLUE}[1/4] Příprava repozitářů Proxmox VE${NC}"

run_step "Instalace prerekvizit pro repozitáře" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg"

run_step "Stáhnutí Proxmox GPG klíče do /etc/apt/keyrings" \
  "install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-${CODENAME}.gpg -o /etc/apt/keyrings/proxmox-release-${CODENAME}.gpg"

run_step "Přidání Proxmox VE No-Subscription repozitáře" \
  "echo 'deb [signed-by=/etc/apt/keyrings/proxmox-release-${CODENAME}.gpg] http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription' > /etc/apt/sources.list.d/pve-install-repo.list"

confirm_stage "Repozitáře Proxmox VE"

# 3. Aktualizace a instalace balíčků
echo -e "\n${BLUE}[2/4] Instalace Proxmox jádra a balíčků${NC}"

run_step "Aktualizace seznamu balíčků a upgrade systému" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"

run_step "Instalace Proxmox VE balíčků a jádra" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi chrony"

confirm_stage "Instalace Proxmox VE"

# 4. Odstranění výchozího jádra Debianu
echo -e "\n${BLUE}[3/4] Odstranění výchozího Debian jádra a úprava zavaděče${NC}"

run_step "Odstranění původního linux-image balíčku" \
  "apt-get remove -y linux-image-amd64 'linux-image-6.1*' || true"

run_step "Aktualizace zavaděče GRUB" \
  "update-grub"

confirm_stage "Zavaděč a jádro"

# 5. Zakázání enterprise repozitáře a vytvoření síťového Linux Bridge (vmbr0)
echo -e "\n${BLUE}[4/4] Finalizace konfigurace${NC}"

if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}       INSTALACE PROXMOX VE BYLA ÚSPĚŠNĚ DOKONČENA!         ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Webové rozhraní Proxmox VE:"
echo -e "   URL:           ${BLUE}https://${PRIMARY_IP}:8006${NC}"
echo -e "   Přihlášení:    root + vaše systémové heslo"
echo -e "   Realm:         Linux PAM standard authentication"
echo -e ""
echo -e "${YELLOW}DOPORUČENÍ: Restartujte server příkazem 'reboot', aby naběhlo Proxmox jádro.${NC}"
echo -e "${GREEN}============================================================${NC}\n"
