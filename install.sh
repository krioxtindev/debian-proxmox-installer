#!/usr/bin/env bash
#
# Automatizovaná instalace Proxmox VE na Debian
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
echo -e "${BLUE}          Instalace Proxmox VE na čistý Debian             ${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. Kontrola /etc/hosts a hostname
HOSTNAME=$(hostname)
FQDN=$(hostname -f 2>/dev/null || echo "${HOSTNAME}.local")

echo -e "Detekovaný hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "Detekované FQDN:     ${GREEN}${FQDN}${NC}"

# Ověření, že hostname směruje na IP rozhraní a ne na 127.0.1.1
if grep -q "127.0.1.1" /etc/hosts; then
    echo -e "${YELLOW}[UPOZORNĚNÍ] Nalezen záznam 127.0.1.1 v /etc/hosts. Proxmox vyžaduje směrování na reálnou IP.${NC}"
    sed -i '/127.0.1.1/d' /etc/hosts
fi

confirm_stage "Příprava hostname a hosts"

# 2. Přidání GPG klíče a repozitáře Proxmox VE
echo -e "\n${BLUE}[1/4] Přidání oficiálního Proxmox repozitáře${NC}"

run_step "Instalace prerekvizit pro repozitáře" \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg"

run_step "Stáhnutí Proxmox GPG klíče" \
  "curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg"

run_step "Přidání Proxmox VE No-Subscription repozitáře" \
  "echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' > /etc/apt/sources.list.d/pve-install-repo.list"

confirm_stage "Repozitáře Proxmox VE"

# 3. Aktualizace a instalace Proxmox jádra a balíčků
echo -e "\n${BLUE}[2/4] Instalace Proxmox jádra a balíčků${NC}"

run_step "Aktualizace seznamu balíčků s novým repozitářem" \
  "apt-get update"

run_step "Instalace Proxmox VE balíčků a jádra" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi chrony"

confirm_stage "Instalace Proxmox VE"

# 4. Odstranění původního Debian kernelu a úprava GRUBu
echo -e "\n${BLUE}[3/4] Odstranění výchozího Debian jádra a aktualizace zavaděče${NC}"

run_step "Odstranění původního linux-image jádra" \
  "apt-get remove -y linux-image-amd64 'linux-image-6*' || true"

run_step "Aktualizace zavaděče GRUB" \
  "update-grub"

confirm_stage "Zavaděč a jádro"

# 5. Odstranění enterprise repozitáře (který vyžaduje placenou licenci)
echo -e "\n${BLUE}[4/4] Finalizace konfigurace repozitářů${NC}"

if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}       INSTALACE PROXMOX VE BYLA ÚSPĚŠNĚ DOKONČENA!         ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Webové rozhraní Proxmox VE:"
echo -e "   URL:           ${BLUE}https://<VASE_IP>:8006${NC}"
echo -e "   Přihlášení:    root + vaše systémové heslo"
echo -e "   Realm:         Linux PAM standard authentication"
echo -e ""
echo -e "${YELLOW}DOPORUČENÍ: Pro zavedení nového Proxmox kernelu nyní restartujte systém (reboot).${NC}"
echo -e "${GREEN}============================================================${NC}\n"
