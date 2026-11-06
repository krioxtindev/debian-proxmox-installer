# Debian Proxmox Installer

Automatizovaný bash skript pro čistou a bezobslužnou instalaci **Proxmox Virtual Environment (PVE)** na čistý server s operačním systémem **Debian**.

Skript automaticky vyřeší klíčové závislosti, správnou konfiguraci FQDN a lokálního mapování v `/etc/hosts`, import oficiálních GPG klíčů Proxmoxu, přidání repozitářů bez předplatného (*no-subscription*) a instalaci kompletního prostředí PVE včetně PVE jádra.

---

## ⚡ Rychlé spuštění (One-Liner)

Přihlaste se na svůj Debian server jako uživatel `root` a spusťte:

```bash
curl -fsSL https://raw.githubusercontent.com/krioxtindev/debian-proxmox-installer/refs/heads/main/install.sh | bash
