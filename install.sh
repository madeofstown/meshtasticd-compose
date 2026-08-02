#!/bin/bash

# 1. Ensure the script is running with root privileges (required for /opt/)
if [ "$EUID" -ne 0 ]; then
    echo "!! Error: Please run this script with sudo (e.g., sudo ./setup-mesh.sh)."
    echo "This ensures files in /opt/ are created with correct root permissions."
    exit 1
fi

# 2. Download the config.yaml template file
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
        # Ensure root ownership
        chmod 644 "$CONFIG_FILE"
    else
        echo "!! Error: Failed to download the configuration template file."
        exit 1
    fi
fi

# 3. Create necessary persistent directories explicitly
echo "Ensuring required folders exist..."
mkdir -p config.d data
chmod 755 config.d data

# 4. Look for the CH341 device using lsusb
echo "Scanning for CH341-based radio..."
TARGET_DEVICE="QinHeng Electronics CH341 in EPP/MEM/I2C mode, EPP/I2C adapter"

if command -v lsusb >/dev/null 2>&1; then
    usb_info=$(lsusb | grep "$TARGET_DEVICE")
else
    usb_info=""
    echo "-> 'lsusb' command not found. Skipping auto-detection."
fi

if [ ! -z "$usb_info" ]; then
    # Parse the Bus and Device numbers
    bus_num=$(echo "$usb_info" | awk '{print $2}')
    dev_num=$(echo "$usb_info" | awk '{print $4}' | tr -d ':')
    
    # Format into the actual system path
    detected_path="/dev/bus/usb/${bus_num}/${dev_num}"
    echo "-> Success! Found radio at: ${detected_path}"
    usb_path=$detected_path
else
    echo "-> Radio not automatically detected."
    echo "Enter the USB device path from 'lsusb' manually (default: /dev/bus/usb/001/003):"
    read manual_path
    usb_path=${manual_path:-/dev/bus/usb/001/003}
fi

# 5. Gather remaining configuration inputs
echo "Enter a unique name for this container instance (default: meshtasticd_node1):"
read container_name
container_name=${container_name:-meshtasticd_node1}

echo "Do you need to enable the main SPI bus? (y/N):"
read ask_spi

# Automatically handle the SPI/GPIO dependency
if [[ "$ask_spi" =~ ^[Yy]$ ]]; then
    echo "-> SPI enabled. GPIO chips will be automatically enabled for radio pins."
    ask_gpio="y"
else
    echo "Do you need to enable GPIO controller chips manually? (y/N):"
    read ask_gpio
fi

echo "Do you need to enable the I2C bus? (y/N):"
read ask_i2c

echo "Do you need to enable the serial port? (y/N):"
read ask_serial

# 6. Start generating the docker-compose file
cat <<EOF > docker-compose.yml
services:
    meshtasticd:
        container_name: $container_name
        image: meshtastic/meshtasticd:daily-alpine
        stdin_open: true
        tty: true
        network_mode: "host"
        restart: unless-stopped
        devices:
            - $usb_path
EOF

# 7. Append optional hardware lines based on answers
if [[ "$ask_spi" =~ ^[Yy]$ ]]; then
    echo "            - /dev/spidev0.0:/dev/spidev0.0" >> docker-compose.yml
fi

if [[ "$ask_gpio" =~ ^[Yy]$ ]]; then
    echo "            - /dev/gpiochip0:/dev/gpiochip0" >> docker-compose.yml
    echo "            - /dev/gpiochip4:/dev/gpiochip4" >> docker-compose.yml
fi

if [[ "$ask_i2c" =~ ^[Yy]$ ]]; then
    echo "            - /dev/i2c-1:/dev/i2c-1" >> docker-compose.yml
fi

if [[ "$ask_serial" =~ ^[Yy]$ ]]; then
    echo "            - /dev/ttyS0:/dev/ttyS0" >> docker-compose.yml
fi

# 8. Append static volumes block to finish the file
cat <<EOF >> docker-compose.yml
        volumes:
            - ./config.yaml:/etc/meshtasticd/config.yaml:ro
            - ./config.d:/etc/meshtasticd/config.d:ro
            - ./data:/var/lib/meshtasticd
EOF

echo "Success! Your custom docker-compose.yml file and config structures are ready."
