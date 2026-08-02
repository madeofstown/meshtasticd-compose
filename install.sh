#!/bin/bash
## Usage Instructions:
# 1. Place this script in the directory where you want to set up the meshtasticd container.
# 2. chmod +x install.sh to make the script executable.
# 3. Run the script: ./install.sh

## 1. Ensure the current directory is writable
#
# The script normally runs as the current user.
# If the current directory is not writable, automatically re-run
# the script with sudo so files can be created there.

if [ "$EUID" -ne 0 ]; then
    # Test whether we can create a temporary file in the current directory
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

## 2. Download the config.yaml template file
CONFIG_URL="https://raw.githubusercontent.com/meshtastic/firmware/refs/heads/develop/bin/config-dist.yaml"
CONFIG_FILE="config.yaml"

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

    if [ $? -eq 0 ] && [ -f "$CONFIG_FILE" ]; then
        echo "-> Success! Saved as $CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
    else
        echo "!! Error: Failed to download the configuration template file."
        exit 1
    fi
fi

## 3. Create necessary persistent directories explicitly
echo "Ensuring required folders exist..."
mkdir -p config.d data

## 4. Gather container instance name first
echo "Enter a unique name for this container instance (default: meshtasticd_node1):"
read container_name
container_name=${container_name:-meshtasticd_node1}

## 5. Optional USB Device Verification Block
echo "Are you using a USB-connected radio? (y/N):"
read ask_usb

usb_path=""
if [[ "$ask_usb" =~ ^[Yy]$ ]]; then
    echo "Scanning for CH341-based radio..."
    TARGET_DEVICE="QinHeng Electronics CH341 in EPP/MEM/I2C mode, EPP/I2C adapter"

    if command -v lsusb >/dev/null 2>&1; then
        usb_info=$(lsusb | grep "$TARGET_DEVICE")
    else
        usb_info=""
        echo "-> 'lsusb' command not found. Skipping auto-detection."
    fi

    if [ ! -z "$usb_info" ]; then
        bus_num=$(echo "$usb_info" | awk '{print $2}')
        dev_num=$(echo "$usb_info" | awk '{print $4}' | tr -d ':')
        detected_path="/dev/bus/usb/${bus_num}/${dev_num}"
        echo "-> Success! Found radio at: ${detected_path}"
        usb_path=$detected_path
    else
        echo "-> Radio not automatically detected."
        echo "Enter the USB device path from 'lsusb' manually (default: /dev/bus/usb/001/003):"
        read manual_path
        usb_path=${manual_path:-/dev/bus/usb/001/003}
    fi
fi

## 6. Ask about SPI
echo "Do you need to enable the main SPI bus? (y/N):"
read ask_spi

# Track the downloaded SPI config file
spi_config_file=""

# Handle SPI configuration
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
    echo "https://raw.githubusercontent.com/meshtastic/firmware/develop/bin/config.d/lora-LoRaPi-900M2213S.yaml"
    echo ""
    echo "Press [ENTER] to skip downloading an additional configuration file."
    echo ""

    read -p "Config file URL (optional): " spi_config_url

    # Only download a config file if a URL was provided
    if [ -n "$spi_config_url" ]; then

        # Extract filename from URL
        spi_config_file=$(basename "${spi_config_url%%\?*}")

        if [ -z "$spi_config_file" ] || [[ "$spi_config_file" != *.yaml ]]; then
            echo "!! Error: The provided URL does not appear to point to a .yaml file."
            exit 1
        fi

        echo "-> Downloading SPI radio configuration..."
        echo "-> URL: $spi_config_url"
        echo "-> Destination: config.d/$spi_config_file"

        if command -v curl >/dev/null 2>&1; then
            curl -fSL "$spi_config_url" -o "config.d/$spi_config_file"
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$spi_config_url" -O "config.d/$spi_config_file"
        else
            echo "!! Error: Neither curl nor wget was found. Please install one to download the config."
            exit 1
        fi

        if [ $? -eq 0 ] && [ -s "config.d/$spi_config_file" ]; then
            chmod 644 "config.d/$spi_config_file"
            echo "-> Success! SPI configuration saved to config.d/$spi_config_file"
        else
            echo "!! Error: Failed to download the SPI configuration file."
            rm -f "config.d/$spi_config_file"
            exit 1
        fi

    else
        echo "-> No additional SPI configuration file specified."
        echo "-> Continuing without downloading an SPI configuration profile."
    fi

else
    # Only ask about GPIO manually when SPI is not being used
    echo "Do you need to enable GPIO controller chips manually? (y/N):"
    read ask_gpio
fi

## 7. Ask about remaining hardware interfaces
echo "Do you need to enable the I2C bus? (y/N):"
read ask_i2c

echo "Do you need to enable the serial port? (y/N):"
read ask_serial

## 8. Start generating the docker-compose file
cat <<EOF > docker-compose.yaml
services:
    meshtasticd:
        container_name: $container_name
        image: meshtastic/meshtasticd:daily-alpine
        stdin_open: true
        tty: true
        network_mode: "host"
        restart: unless-stopped
EOF

## 9. Append devices section conditionally
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

## 10. Append static volumes block to finish the file
cat <<EOF >> docker-compose.yaml
        volumes:
            - ./config.yaml:/etc/meshtasticd/config.yaml:ro
            - ./config.d:/etc/meshtasticd/config.d:ro
            - ./data:/var/lib/meshtasticd
EOF

echo ""
echo "========================================================================"
echo " Success!"
echo "========================================================================"
echo "Your custom docker-compose.yaml file and config structures are ready."

if [ -n "$spi_config_file" ]; then
    echo "SPI configuration: config.d/$spi_config_file"
fi

echo "Container name: $container_name"
echo "========================================================================"