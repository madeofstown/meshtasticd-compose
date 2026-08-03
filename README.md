# meshtasticd-compose

A helper script for setting up `meshtasticd` with Docker Compose.

This repository contains an interactive installer that generates `docker-compose.yaml`, downloads the Meshtastic config template, and creates the required local directories.

## Usage

Place `install.sh` in the directory where you want to keep the generated Docker and Meshtastic files.

1. Make the installer executable:
   ```bash
   chmod +x install.sh
   ```
2. Run the installer in this directory:
   ```bash
   ./install.sh
   ```

### Quick install

Download and run the installer in one command:
```bash
curl -fsSL https://raw.githubusercontent.com/madeofstown/meshtasticd-compose/main/install.sh | bash
```

## Generated files and directories

- `docker-compose.yaml` — generated compose file for `meshtasticd`
- `config.yaml` — Meshtastic service configuration
- `config.d/` — optional radio-specific config profiles
- `data/` — persistent Meshtastic runtime data
