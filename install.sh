#!/bin/bash

# Meshtasticd Docker Compose installer
# Usage: chmod +x install.sh && ./install.sh

if [ "$EUID" -ne 0 ]; then
    test_file=".meshtasticd_install_write_test_$$"
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        echo "-> Current directory is writable. Running as current user."
    else
        echo "-> Current directory is not writable by the current user."
        echo "-> Re-running installation script with sudo..."

        if ! command -v sudo >/dev/null 2>&1; then
            echo "!! Error: sudo is not installed or cannot be found."
            echo "!! Please run this script as root or install sudo."
            exit 1
        fi

        exec sudo "$0" "$@"
    fi
fi

CONFIG_URL="https://raw.githubusercontent.com/meshtastic/firmware/refs/heads/develop/bin/config-dist.yaml"
CONFIG_FILE="config.yaml"

port_in_use() {
    local port="$1"
    if [ -z "$port" ]; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | awk '{print $5}' | grep -E ":[.:]?$port$" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            return 0
        else
            return 1
        fi
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            return 0
        else
            return 1
        fi
    fi

    return 2
}

ensure_port() {
    local var_name="$1"
    local prompt="$2"
    local default_port="$3"
    local port=""

    while true; do
        read -r -p "$prompt" port
        port=${port:-$default_port}

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "!! Error: Please enter a valid numeric port between 1 and 65535."
            continue
        fi

        port_in_use "$port"
        case $? in
            0)
                echo "Port $port is already in use on the host."
                ;;
            1)
                eval "$var_name=$port"
                return 0
                ;;
            2)
                echo "-> Warning: cannot verify port usage because neither ss nor lsof is installed."
                eval "$var_name=$port"
                return 0
                ;;
        esac
    done
}

echo "Checking for configuration template..."
if [ -f "$CONFIG_FILE" ]; then
    echo "-> '$CONFIG_FILE' already exists. Skipping download to preserve your settings."
else
    echo "-> Downloading official config template from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$CONFIG_URL" -o "$CONFIG_FILE"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$CONFIG_URL" -O "$CONFIG_FILE"
    else
        echo "!! Error: Neither curl nor wget was found. Please install one to download the config."
        exit 1
    fi

    if [ $? -ne 0 ] || [ ! -f "$CONFIG_FILE" ]; then
        echo "!! Error: Failed to download the configuration template file."
        exit 1
    fi

    chmod 644 "$CONFIG_FILE"
    echo "-> Success! Saved as $CONFIG_FILE"
fi

mkdir -p config.d data

echo "Enter a unique name for this container instance (default: meshtasticd_node1):"
read -r container_name
container_name=${container_name:-meshtasticd_node1}

echo ""
echo "Select the Meshtasticd image track:"
echo "  1) daily"
echo "  2) alpha"
echo "  3) beta"
read -r -p "Track [1-3] (default: 1): " track_choice
case "$track_choice" in
    2) image_track="alpha";;
    3) image_track="beta";;
     *) image_track="daily";;
    esac

echo ""
echo "Select the image variant:"
echo "  1) alpine"
echo "  2) debian"
read -r -p "Variant [1-2] (default: 1): " variant_choice
case "$variant_choice" in
    2) image_variant="debian";;
     *) image_variant="alpine";;
    esac

image_name="meshtastic/meshtasticd:${image_track}-${image_variant}"

echo "Using image: $image_name"

echo ""
echo "Do you need UDP multicast meshing support? This requires host network mode. (y/N):"
read -r ask_host_network
if [[ "$ask_host_network" =~ ^[Yy]$ ]]; then
    use_host_network="yes"
else
    use_host_network="no"
fi

host_meshtastic_port=4403
ensure_port host_meshtastic_port "Enter host port for Meshtasticd TCP service [default: 4403]: " 4403

web_server_enabled="no"
host_web_port=9443
if [[ "$image_variant" == "debian" ]]; then
    echo "Do you plan to enable the Meshtasticd web server? (y/N):"
    read -r ask_web
    if [[ "$ask_web" =~ ^[Yy]$ ]]; then
        web_server_enabled="yes"
        ensure_port host_web_port "Enter host port for the optional web server [default: 9443]: " 9443
    fi
fi

if [[ "$use_host_network" == "yes" ]] && [ -f "$CONFIG_FILE" ]; then
    if grep -q '^[[:space:]]*#[[:space:]]*APIPort:' "$CONFIG_FILE"; then
        sed -i "s/^[[:space:]]*#[[:space:]]*APIPort:.*/  APIPort: $host_meshtastic_port/" "$CONFIG_FILE"
    elif grep -q '^[[:space:]]*APIPort:' "$CONFIG_FILE"; then
        sed -i "s/^[[:space:]]*APIPort:.*/  APIPort: $host_meshtastic_port/" "$CONFIG_FILE"
    else
        echo "  APIPort: $host_meshtastic_port" >> "$CONFIG_FILE"
    fi
fi

if [[ "$image_variant" == "debian" ]] && [[ "$web_server_enabled" == "yes" ]] && [ -f "$CONFIG_FILE" ]; then
    sed -i \
        -e 's/^[[:space:]]*#[[:space:]]*Webserver:/Webserver:/' \
        -e 's/^[[:space:]]*#[[:space:]]*\(Port:.*\)/  \1/' \
        -e 's/^[[:space:]]*#[[:space:]]*\(RootPath:.*\)/  \1/' \
        -e 's/^[[:space:]]*#[[:space:]]*\(SSLKey:.*\)/  \1/' \
        -e 's/^[[:space:]]*#[[:space:]]*\(SSLCert:.*\)/  \1/' \
        "$CONFIG_FILE"
    if [[ "$use_host_network" == "yes" ]] && [ "$host_web_port" != "9443" ]; then
        sed -i "s/^[[:space:]]*Port:[[:space:]]*9443/  Port: $host_web_port/" "$CONFIG_FILE"
    fi
fi

echo "Do you have a USB-connected radio? (y/N):"
read -r ask_usb
usb_path=""
if [[ "$ask_usb" =~ ^[Yy]$ ]]; then
    echo "Scanning for CH341-based radio..."
    TARGET_DEVICE="QinHeng Electronics CH341 in EPP/MEM/I2C mode, EPP/I2C adapter"

    if command -v lsusb >/dev/null 2>&1; then
        usb_info=$(lsusb | grep "$TARGET_DEVICE" || true)
    else
        usb_info=""
        echo "-> 'lsusb' command not found. Skipping auto-detection."
    fi

    if [ -n "$usb_info" ]; then
        bus_num=$(echo "$usb_info" | awk '{print $2}')
        dev_num=$(echo "$usb_info" | awk '{print $4}' | tr -d ':')
        detected_path="/dev/bus/usb/${bus_num}/${dev_num}"
        echo "-> Success! Found radio at: ${detected_path}"
        usb_path=$detected_path
    else
        echo "-> Radio not automatically detected."
        read -r -p "Enter the USB device path manually (default: /dev/bus/usb/001/003): " manual_path
        usb_path=${manual_path:-/dev/bus/usb/001/003}
    fi
fi

echo "Do you need to enable the main SPI bus for your radio? (y/N):"
read -r ask_spi
spi_config_file=""

if [[ "$ask_spi" =~ ^[Yy]$ ]]; then
    echo "-> SPI enabled. GPIO chips will be automatically enabled for radio pins."
    ask_gpio="y"

    echo ""
    echo "========================================================================"
    echo " SPI Radio Configuration Profile"
    echo "========================================================================"
    echo "If your SPI radio requires an additional configuration file, enter"
    echo "the direct URL to the .yaml file below."
    echo ""
    echo "Example:"
    echo "https://raw.githubusercontent.com/meshtastic/firmware/refs/heads/develop/bin/config.d/lora-ZebraHat_1W.yaml"
    echo ""
    echo "Press [ENTER] to skip downloading an additional configuration file."
    echo ""

    read -r -p "Config file URL (optional): " spi_config_url
    if [ -n "$spi_config_url" ]; then
        spi_config_file=$(basename "${spi_config_url%%\?*}")
        if [ -z "$spi_config_file" ] || [[ "$spi_config_file" != *.yaml ]]; then
            echo "!! Error: The provided URL does not appear to point to a .yaml file."
            exit 1
        fi

        echo "-> Downloading SPI radio configuration..."
        echo "   URL: $spi_config_url"
        echo "   Destination: config.d/$spi_config_file"

        if command -v curl >/dev/null 2>&1; then
            curl -fSL "$spi_config_url" -o "config.d/$spi_config_file"
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$spi_config_url" -O "config.d/$spi_config_file"
        else
            echo "!! Error: Neither curl nor wget was found. Please install one to download the config."
            exit 1
        fi

        if [ $? -ne 0 ] || [ ! -s "config.d/$spi_config_file" ]; then
            echo "!! Error: Failed to download the SPI configuration file."
            rm -f "config.d/$spi_config_file"
            exit 1
        fi

        chmod 644 "config.d/$spi_config_file"
        echo "-> Success! SPI configuration saved to config.d/$spi_config_file"
    else
        echo "-> No additional SPI configuration file specified."
    fi
else
    echo "Do you need to enable GPIO controller chips manually? (y/N):"
    read -r ask_gpio
fi

echo "Do you need to enable the I2C bus? (y/N):"
read -r ask_i2c

echo "Do you need to enable the serial port? (y/N):"
read -r ask_serial

cat <<EOF > docker-compose.yaml
services:
    meshtasticd:
        container_name: $container_name
        image: $image_name
        stdin_open: true
        tty: true
        restart: unless-stopped
EOF

if [[ "$use_host_network" == "yes" ]]; then
    echo "        network_mode: \"host\"" >> docker-compose.yaml
else
    echo "        ports:" >> docker-compose.yaml
    echo "            - \"${host_meshtastic_port}:4403\"" >> docker-compose.yaml
    if [[ "$web_server_enabled" == "yes" ]]; then
        echo "            - \"${host_web_port}:9443\"" >> docker-compose.yaml
    fi
fi

if [ -n "$usb_path" ] || [[ "$ask_spi" =~ ^[Yy]$ ]] || [[ "$ask_gpio" =~ ^[Yy]$ ]] || [[ "$ask_i2c" =~ ^[Yy]$ ]] || [[ "$ask_serial" =~ ^[Yy]$ ]]; then
    echo "        devices:" >> docker-compose.yaml

    if [ -n "$usb_path" ]; then
        echo "            - $usb_path" >> docker-compose.yaml
    fi

    if [[ "$ask_spi" =~ ^[Yy]$ ]]; then
        echo "            - /dev/spidev0.0:/dev/spidev0.0" >> docker-compose.yaml
    fi

    if [[ "$ask_gpio" =~ ^[Yy]$ ]]; then
        echo "            - /dev/gpiochip0:/dev/gpiochip0" >> docker-compose.yaml
        echo "            - /dev/gpiochip4:/dev/gpiochip4" >> docker-compose.yaml
    fi

    if [[ "$ask_i2c" =~ ^[Yy]$ ]]; then
        echo "            - /dev/i2c-1:/dev/i2c-1" >> docker-compose.yaml
    fi

    if [[ "$ask_serial" =~ ^[Yy]$ ]]; then
        echo "            - /dev/ttyS0:/dev/ttyS0" >> docker-compose.yaml
    fi
fi

cat <<EOF >> docker-compose.yaml
        volumes:
            - ./config.yaml:/etc/meshtasticd/config.yaml:ro
            - ./config.d:/etc/meshtasticd/config.d:ro
            - ./data:/var/lib/meshtasticd
EOF

echo ""
echo "========================================================================"
echo "Success!"
echo "========================================================================"
echo "Generated docker-compose.yaml and configuration files in the current directory."
if [ -n "$spi_config_file" ]; then
    echo "SPI configuration: config.d/$spi_config_file"
fi
if [ -n "$usb_path" ]; then
    echo "USB device path: $usb_path"
fi
if [[ "$web_server_enabled" == "yes" ]]; then
    echo "Web server enabled on host port $host_web_port."
fi
if [[ "$use_host_network" == "yes" ]]; then
    echo "Host networking is enabled."
fi
echo "Meshtasticd TCP service is enabled on host port $host_meshtastic_port."
echo "Run 'docker compose up -d' to start the container after you are finished making changes to the configuration files."
