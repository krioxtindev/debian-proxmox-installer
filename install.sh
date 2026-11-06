#!/usr/bin/env bash
#
# Automatizovaná instalace Proxmox VE na Debian (Bookworm / Trixie)
# Určeno pro uložení na GitHub a spuštění přes curl / bash
#

set -o pipefail

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
        eval "$cmd"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}[OK] Úspěšně dokončeno: ${desc}${NC}"
            break
        else
            echo -e "${RED}[CHYBA] Krok '${desc}' selhal s chybovým kódem ${exit_code}!${NC}"
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
    echo -ne "${YELLOW}Bylo vše v pořádku? Chcete pokračovat dál? [A/n]: ${NC}"
    read -r resp < /dev/tty
    if [[ "$resp" =~ ^[nN]$ ]]; then
        echo -e "${RED}Skript byl pozastaven uživatelem.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}------------------------------------------------------------\n${NC}"
}

clear
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}           Instalace Proxmox VE na čistý Debian             ${NC}"
echo -e "${BLUE}============================================================${NC}"

# 0. Detekce distribuce Debianu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-bookworm}"
else
    CODENAME="bookworm"
fi
echo -e "Detekovaná distribuce Debianu: ${GREEN}${CODENAME}${NC}"

# 1. Kontrola a konfigurace /etc/hosts a hostname
HOSTNAME=$(hostname)
IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

if [ -z "$IP" ]; then
    IP=$(hostname -I | awk '{print $1}')
fi

if [ -z "$IP" ]; then
    echo -e "${RED}[CHYBA] Nepodařilo se detekovat veřejnou IP adresu serveru!${NC}"
    exit 1
fi

FQDN="${HOSTNAME}.localdomain"

echo -e "Detekovaný hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "Detekovaná IP:       ${GREEN}${IP}${NC}"
echo -e "Nastavené FQDN:      ${GREEN}${FQDN}${NC}"

# Odstranění starého pve repo souboru, pokud zbyl z předchozího neúspěšného pokusu
rm -f /etc/apt/sources.list.d/pve-install-repo.list

# Úprava /etc/hosts
cp /etc/hosts /etc/hosts.bak
sed -i "/127\.0\.1\.1/d" /etc/hosts
sed -i "/$IP/d" /etc/hosts
echo "$IP $FQDN $HOSTNAME" >> /etc/hosts

echo -e "${GREEN}[OK] /etc/hosts nastaven: $IP $FQDN $HOSTNAME${NC}"

confirm_stage "Příprava hostname a hosts"

# 2. Instalace prerekvizit a stažení PGP klíče PŘED přidáním repozitáře
echo -e "\n${BLUE}[1/4] Příprava repozitářů a GPG klíčů Proxmox VE${NC}"

run_step "Instalace základních nástrojů pro správu balíčků" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg debconf-utils"

run_step "Stažení oficiálního Proxmox GPG klíče" \
  "curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-${CODENAME}.gpg -o /etc/apt/trusted.gpg.d/proxmox-release-${CODENAME}.gpg 2>/dev/null || curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -o /etc/apt/trusted.gpg.d/proxmox-release-${CODENAME}.gpg"

run_step "Přidání Proxmox VE No-Subscription repozitáře" \
  "echo 'deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription' > /etc/apt/sources.list.d/pve-install-repo.list"

confirm_stage "Repozitáře Proxmox VE"

# 3. Aktualizace a instalace balíčků Proxmox VE
echo -e "\n${BLUE}[2/4] Instalace Proxmox jádra a balíčků${NC}"

run_step "Aktualizace seznamu balíčků s novým repozitářem" \
  "apt-get update"

# Tichá konfigurace postfixu proti zablokování instalátoru v dialogovém okně
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $FQDN" | debconf-set-selections

run_step "Instalace Proxmox VE balíčků a jádra" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi chrony"

confirm_stage "Instalace Proxmox VE"

# 4. Bezpečné odstranění Debian jádra a aktualizace GRUB
echo -e "\n${BLUE}[3/4] Odstranění výchozího Debian jádra a aktualizace zavaděče${NC}"

run_step "Odstranění původního debian linux-image jádra" \
  "apt-get remove -y linux-image-amd64 'linux-image-*-amd64' 2>/dev/null || true"

run_step "Aktualizace zavaděče GRUB" \
  "update-grub"

confirm_stage "Zavaděč a jádro"

# 5. Zakázání placeného enterprise repozitáře
echo -e "\n${BLUE}[4/4] Finalizace konfigurace repozitářů${NC}"

if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}       INSTALACE PROXMOX VE BYLA ÚSPĚŠNĚ DOKONČENA!         ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Webové rozhraní Proxmox VE:"
echo -e "   URL:           ${BLUE}https://${IP}:8006${NC}"
echo -e "   Přihlášení:    root + vaše systémové heslo"
echo -e "   Realm:         Linux PAM standard authentication"
echo -e ""
echo -e "${YELLOW}DOPORUČENÍ: Restartujte server příkazem 'reboot' pro naběhnutí PVE jádra.${NC}"
echo -e "${GREEN}============================================================${NC}\n"
