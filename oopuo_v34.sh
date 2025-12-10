#!/bin/bash

# ==============================================================================
# 🚀 OOPUO DESKTOP ENVIRONMENT V34 - FULL INSTALLER
# Tmux-based Terminal Operating System
# ==============================================================================

set -e  # Exit on error

echo -e "\033[38;5;46m╔═══════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[38;5;46m║                                                           ║\033[0m"
echo -e "\033[38;5;46m║        OOPUO DESKTOP ENVIRONMENT - INSTALLER V34          ║\033[0m"
echo -e "\033[38;5;46m║                                                           ║\033[0m"
echo -e "\033[38;5;46m╚═══════════════════════════════════════════════════════════╝\033[0m"
echo ""

# --- 1. CHECK REQUIREMENTS ---
echo -e "\033[38;5;51m[1/7] Checking requirements...\033[0m"

if ! command -v tmux &> /dev/null; then
    echo "  Installing tmux..."
    apt-get update -qq
    apt-get install -y tmux > /dev/null 2>&1
fi

if ! command -v python3 &> /dev/null; then
    echo "  ERROR: Python 3 not found"
    exit 1
fi

echo "  ✓ Requirements met"

# --- 2. CREATE DIRECTORIES ---
echo -e "\033[38;5;51m[2/7] Creating directory structure...\033[0m"

mkdir -p /opt/oopuo
mkdir -p /etc/oopuo
mkdir -p /var/log/oopuo
mkdir -p /root/oopuo_vault

echo "  ✓ Directories created"

# --- 3. INSTALL PYTHON MODULES ---
echo -e "\033[38;5;51m[3/7] Installing Python modules...\033[0m"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if modules directory exists
if [ -d "${SCRIPT_DIR}/modules" ]; then
    # Copy all Python modules
    cp -r "${SCRIPT_DIR}/modules/"* /opt/oopuo/
    echo "  ✓ Copied $(ls "${SCRIPT_DIR}/modules" | wc -l) modules"
else
    echo "  ERROR: modules/ directory not found"
    echo "  Expected path: ${SCRIPT_DIR}/modules"
    exit 1
fi

# Make main.py executable
chmod +x /opt/oopuo/main.py

# --- 4. CREATE SYSTEMD SERVICE ---
echo -e "\033[38;5;51m[4/7] Creating systemd service...\033[0m"

cat << 'EOF' > /etc/systemd/system/oopuo.service
[Unit]
Description=OOPUO Desktop Environment
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/python3 /opt/oopuo/main.py
ExecStop=/usr/bin/tmux kill-session -t oopuo-desktop
RemainAfterExit=yes
Restart=on-failure
User=root
WorkingDirectory=/opt/oopuo
Environment="PYTHONPATH=/opt/oopuo"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "  ✓ Service installed"

# --- 5. CREATE TMUX CONFIGURATION ---
echo -e "\033[38;5;51m[5/7] Creating tmux configuration...\033[0m"

cat << 'EOF' > /root/.tmux.conf
# OOPUO Desktop Environment - Tmux Configuration

# F10 = Return to sidebar
bind-key -n F10 select-pane -t oopuo-desktop:0.1

# Ctrl+Left/Right = Switch panes
bind-key -n C-Left select-pane -t oopuo-desktop:0.1
bind-key -n C-Right select-pane -t oopuo-desktop:0.2

# Disable mouse
set -g mouse off

# No status bar (we have custom header)
set -g status off

# Pane borders
set -g pane-border-style fg=colour240
set -g pane-active-border-style fg=colour51

# Focus events
set -g focus-events on

# Scrollback
set -g history-limit 10000

# No escape delay
set -sg escape-time 0

# Change prefix to Ctrl+A
unbind C-b
set -g prefix C-a
bind C-a send-prefix
EOF

echo "  ✓ Tmux config created"

# --- 6. CREATE AUTO-SNAPSHOT CRON ---
echo -e "\033[38;5;51m[6/7] Setting up auto-snapshots...\033[0m"

cat << 'EOF' > /usr/local/bin/oopuo-snapshot
#!/bin/bash
# Auto-snapshot script for OOPUO
VMID=200
TIMESTAMP=$(date +"%Y-%m-%d_%H:%M")
SNAPNAME="auto-snap-${TIMESTAMP}"

qm snapshot ${VMID} ${SNAPNAME} --description "Automatic daily snapshot"

# Clean old snapshots (keep last 30)
qm listsnapshot ${VMID} | grep "auto-snap-" | head -n -30 | while read snap; do
    snapname=$(echo "$snap" | awk '{print $1}')
    qm delsnapshot ${VMID} ${snapname}
done
EOF

chmod +x /usr/local/bin/oopuo-snapshot

# Add cron job (daily at midnight)
(crontab -l 2>/dev/null | grep -v "oopuo-snapshot"; echo "0 0 * * * /usr/local/bin/oopuo-snapshot") | crontab -

echo "  ✓ Auto-snapshot enabled (daily)"

# --- 7. FINALIZE ---
echo -e "\033[38;5;51m[7/7] Finalizing installation...\033[0m"

# Enable service (but don't start yet - let user choose)
systemctl enable oopuo.service

echo "  ✓ Service enabled"
echo ""
echo -e "\033[38;5;46m╔═══════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[38;5;46m║                                                           ║\033[0m"
echo -e "\033[38;5;46m║              ✓ INSTALLATION COMPLETE!                     ║\033[0m"
echo -e "\033[38;5;46m║                                                           ║\033[0m"
echo -e "\033[38;5;46m╚═══════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[38;5;51mNext steps:\033[0m"
echo ""
echo -e "  1. Start OOPUO:    \033[38;5;198msystemctl start oopuo\033[0m"
echo -e "  2. Or run manually: \033[38;5;198mpython3 /opt/oopuo/main.py\033[0m"
echo ""
echo -e "\033[38;5;240m  Logs: /var/log/oopuo/system.log\033[0m"
echo -e "\033[38;5;240m  Config: /etc/oopuo/config.json\033[0m"
echo ""
