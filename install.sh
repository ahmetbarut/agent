#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Agent configuration
AGENT_USER="forge-clone"
AGENT_DIR="/opt/forge-clone"
CONFIG_DIR="/etc/forge-clone-agent"
SERVICE_NAME="forge-clone-agent"
BINARY_NAME="forge-clone-agent"

# Download URLs (can be overridden via environment variables)
DOWNLOAD_BASE_URL="${FORGE_CLONE_DOWNLOAD_URL:-FORGE_CLONE_DOWNLOAD_URL=https://raw.githubusercontent.com/ahmetbarut/agent/refs/heads/main/forge-clone-agent}"
echo "DOWNLOAD_BASE_URL: ${DOWNLOAD_BASE_URL}"
exit 1;
BINARY_URL="${DOWNLOAD_BASE_URL}"

echo -e "${GREEN}Forge Clone Agent Installation${NC}"
echo "=================================="

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
        OS_VERSION=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        OS=debian
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    echo -e "${GREEN}Detected OS: ${OS} ${OS_VERSION}${NC}"
}

# Install dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    case $OS in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y nginx openssh-server curl wget
            systemctl enable nginx
            systemctl enable ssh
            ;;
        centos|rhel|fedora)
            yum install -y nginx openssh-server curl wget || dnf install -y nginx openssh-server curl wget
            systemctl enable nginx
            systemctl enable sshd
            ;;
        *)
            echo -e "${RED}Unsupported OS: ${OS}${NC}"
            exit 1
            ;;
    esac

    echo -e "${GREEN}Dependencies installed successfully${NC}"
}

# Create user
create_user() {
    echo -e "${YELLOW}Creating user ${AGENT_USER}...${NC}"
    
    if id "$AGENT_USER" &>/dev/null; then
        echo -e "${YELLOW}User ${AGENT_USER} already exists${NC}"
    else
        useradd -r -s /bin/bash -d "$AGENT_DIR" "$AGENT_USER"
        mkdir -p "$AGENT_DIR"
        chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR"
        echo -e "${GREEN}User ${AGENT_USER} created${NC}"
    fi
    
    # Add user to sudo group (for system operations)
    usermod -aG sudo "$AGENT_USER" 2>/dev/null || usermod -aG wheel "$AGENT_USER" 2>/dev/null || true
}

# Setup nginx
setup_nginx() {
    echo -e "${YELLOW}Setting up nginx...${NC}"
    
    if [ -f "$(dirname "$0")/scripts/setup-nginx.sh" ]; then
        bash "$(dirname "$0")/scripts/setup-nginx.sh"
    else
        # Basic nginx setup
        if [ ! -f /etc/nginx/sites-enabled/default ]; then
            systemctl start nginx || systemctl start httpd
        fi
    fi
    
    echo -e "${GREEN}Nginx configured${NC}"
}

# Setup SSH
setup_ssh() {
    echo -e "${YELLOW}Setting up SSH...${NC}"
    
    if [ -f "$(dirname "$0")/scripts/setup-ssh.sh" ]; then
        bash "$(dirname "$0")/scripts/setup-ssh.sh" "$AGENT_USER"
    else
        # Basic SSH setup
        systemctl start ssh || systemctl start sshd || true
    fi
    
    echo -e "${GREEN}SSH configured${NC}"
}

# Download agent binary
download_binary() {
    local url="$1"
    local output="$2"
    
    echo -e "${YELLOW}Downloading agent binary from ${url}...${NC}"
    
    # Try curl first, then wget
    if command -v curl &> /dev/null; then
        if curl -fSL "$url" -o "$output" --progress-bar; then
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget "$url" -O "$output" --progress=bar; then
            return 0
        fi
    else
        echo -e "${RED}Neither curl nor wget found. Cannot download binary.${NC}"
        return 1
    fi
    
    return 1
}

# Build or copy agent binary
install_agent() {
    echo -e "${YELLOW}Installing agent binary...${NC}"
    
    # Create directories
    mkdir -p "$AGENT_DIR"
    mkdir -p "$CONFIG_DIR"
    
    local binary_found=false
    local temp_binary=""
    
    # Check if binary exists in script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/$BINARY_NAME" ]; then
        echo -e "${GREEN}Found binary in script directory${NC}"
        cp "$SCRIPT_DIR/$BINARY_NAME" "$AGENT_DIR/$BINARY_NAME"
        binary_found=true
    elif [ -f "$SCRIPT_DIR/build/$BINARY_NAME" ]; then
        echo -e "${GREEN}Found binary in build directory${NC}"
        cp "$SCRIPT_DIR/build/$BINARY_NAME" "$AGENT_DIR/$BINARY_NAME"
        binary_found=true
    elif [ -n "$BINARY_URL" ] && [ "$BINARY_URL" != "none" ]; then
        # Try to download binary
        temp_binary=$(mktemp)
        if download_binary "$BINARY_URL" "$temp_binary"; then
            mv "$temp_binary" "$AGENT_DIR/$BINARY_NAME"
            binary_found=true
            echo -e "${GREEN}Binary downloaded successfully${NC}"
        else
            rm -f "$temp_binary"
            echo -e "${YELLOW}Failed to download binary from ${BINARY_URL}${NC}"
        fi
    fi
    
    # If still no binary, try to build
    if [ "$binary_found" = false ]; then
        echo -e "${YELLOW}Binary not found, attempting to build...${NC}"
        if command -v go &> /dev/null; then
            if [ -d "$SCRIPT_DIR" ]; then
                cd "$SCRIPT_DIR"
            fi
            if go build -o "$AGENT_DIR/$BINARY_NAME" . 2>&1; then
                echo -e "${GREEN}Agent built successfully${NC}"
                binary_found=true
            else
                echo -e "${RED}Failed to build agent${NC}"
            fi
        else
            echo -e "${RED}Go not found and no pre-built binary available${NC}"
            exit 1
        fi
    fi
    
    if [ "$binary_found" = false ]; then
        echo -e "${RED}Failed to obtain agent binary${NC}"
        exit 1
    fi
    
    chmod +x "$AGENT_DIR/$BINARY_NAME"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/$BINARY_NAME"
    
    echo -e "${GREEN}Agent binary installed${NC}"
}

# Create config file
create_config() {
    echo -e "${YELLOW}Creating configuration...${NC}"
    
    # Default configuration
    cat > "$CONFIG_DIR/config.json" << EOF
{
  "webhook_url": "https://webhook.site/2b1cc1ce-a6c0-47fd-8b2b-1734af075bb9/app",
  "metrics_interval_seconds": 60,
  "agent_id": "$(hostname)"
}
EOF
    
    chmod 0640 "$CONFIG_DIR/config.json"
    chown root:"$AGENT_USER" "$CONFIG_DIR/config.json"
    
    echo -e "${GREEN}Configuration created${NC}"
}

# Create systemd service
create_systemd_service() {
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Forge Clone Agent
After=network.target

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$AGENT_DIR
ExecStart=$AGENT_DIR/$BINARY_NAME
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    echo -e "${GREEN}Systemd service created${NC}"
}

# Start service
start_service() {
    echo -e "${YELLOW}Starting agent service...${NC}"
    
    systemctl start "$SERVICE_NAME"
    
    # Wait a bit and check status
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Agent service started successfully${NC}"
        systemctl status "$SERVICE_NAME" --no-pager -l
    else
        echo -e "${RED}Failed to start agent service${NC}"
        systemctl status "$SERVICE_NAME" --no-pager -l
        exit 1
    fi
}

# Main installation flow
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root (use sudo)${NC}"
        exit 1
    fi
    
    detect_os
    install_dependencies
    create_user
    setup_nginx
    setup_ssh
    install_agent
    create_config
    create_systemd_service
    start_service
    
    echo ""
    echo -e "${GREEN}==================================${NC}"
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo -e "${GREEN}Agent is running as user: ${AGENT_USER}${NC}"
    echo -e "${GREEN}Service: ${SERVICE_NAME}${NC}"
    echo -e "${GREEN}Config: ${CONFIG_DIR}/config.json${NC}"
    echo -e "${GREEN}==================================${NC}"
}

main "$@"

