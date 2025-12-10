#!/bin/bash

# ==============================================================================
# 🩹 OOPUO VISUAL PATCH V8 - DIFF ENGINE
# Fixes: Eliminates flicker by only rendering changed pixels (Delta Updates).
# ==============================================================================

echo -e "\033[38;5;46m[OOPUO] INSTALLING DIFF ENGINE...\033[0m"

cat << 'EOF' > /opt/oopuo/main.py
import sys, os, time, math, random, threading, subprocess, json, shutil, select, tty, termios, datetime, atexit, traceback

# --- CONFIGURATION ---
CONF_DIR = "/etc/oopuo"
LOG_FILE = "/var/log/oopuo/system.log"
CRASH_FILE = "/var/log/oopuo/crash.log"

CONFIG = {
    "ids": {"brain_vm": 200, "guard_ct": 100},
    "network": {
        "bridge": "vmbr0",
        "host_ip": None, "gateway": None, "brain_ip": None, "guard_ip": None
    },
    "resources": {
        "brain": {"cores": 4, "mem": 8192, "disk": 80},
        "guard": {"cores": 1, "mem": 512, "disk": 4}
    },
    "credentials": {
        "user": "adminuser",
        "pass": "Oopuopu123!",
        "key_path": "/root/oopuo_vault/id_ed25519_vm200"
    },
    "assets": {
        "cloud_img_url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
        "lxc_template": "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    }
}

# --- STATE ---
STATE = {
    "mode": "DASHBOARD",
    "status": "SYSTEM IDLE",
    "progress": 0,
    "logs": [],
    "alerts": [],
    "metrics": {"cpu": 0, "ram": 0},
    "menu_idx": 0,
    "running": True,
    "confirm_exit": False
}

# --- COLORS ---
def col(txt, c): return f"\033[38;5;{c}m{txt}\033[0m"
C_CYAN = 51
C_GREEN = 46
C_RED = 196
C_GREY = 240
C_PINK = 198
C_WHITE = 255

# --- SAFE EXIT ---
def cleanup_terminal():
    os.system('reset')
    sys.stdout.write("\033[?25h")

atexit.register(cleanup_terminal)

# --- INFRASTRUCTURE ENGINE ---
class InfraEngine:
    def log(self, msg):
        ts = datetime.datetime.now().strftime('%H:%M:%S')
        STATE["status"] = msg
        STATE["logs"].append(f"[{ts}] {msg}")
        if len(STATE["logs"]) > 50: STATE["logs"] = STATE["logs"][-50:]
        with open(LOG_FILE, "a") as f: f.write(f"[{ts}] {msg}\n")

    def run_cmd(self, cmd):
        try:
            return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode().strip()
        except subprocess.CalledProcessError: return None

    def check_health(self):
        try:
            load = os.getloadavg()[0]
            STATE["metrics"]["cpu"] = int(load * 10)
            
            if not CONFIG['network']['brain_ip']:
                res = self.run_cmd(f"qm guest cmd {CONFIG['ids']['brain_vm']} network-get-interfaces 2>/dev/null")
                if res:
                    import re
                    ips = re.findall(r'192\.168\.\d+\.\d+', res)
                    if ips: CONFIG['network']['brain_ip'] = ips[0]
            
            if random.random() < 0.05:
                vm_stat = self.run_cmd(f"qm status {CONFIG['ids']['brain_vm']}")
                ct_stat = self.run_cmd(f"pct status {CONFIG['ids']['guard_ct']}")
                STATE["alerts"] = []
                if vm_stat and "stopped" in vm_stat: STATE["alerts"].append("BRAIN OFFLINE")
                if ct_stat and "stopped" in ct_stat: STATE["alerts"].append("GUARD OFFLINE")
        except: pass

    def deploy_stack(self):
        self.log("STARTING DEPLOYMENT SEQUENCE...")
        STATE["mode"] = "INSTALL"
        host_ip = self.run_cmd("hostname -I | awk '{print $1}'")
        gw = self.run_cmd("ip route | grep default | awk '{print $3}' | head -1")
        prefix = ".".join(host_ip.split('.')[:3])
        CONFIG['network']['host_ip'] = host_ip
        CONFIG['network']['gateway'] = gw
        CONFIG['network']['brain_ip'] = f"{prefix}.222"
        CONFIG['network']['guard_ip'] = f"{prefix}.250"
        STATE["progress"] = 10
        
        self.log("Downloading Assets...")
        iso_dir = "/var/lib/vz/template/iso"
        if not os.path.exists(iso_dir): os.makedirs(iso_dir)
        img = f"{iso_dir}/ubuntu-24.04-cloud.img"
        if not os.path.exists(img):
            self.run_cmd(f"wget -q {CONFIG['assets']['cloud_img_url']} -O {img}")
        
        key = CONFIG['credentials']['key_path']
        if not os.path.exists(key):
            self.run_cmd(f"ssh-keygen -t ed25519 -f {key} -N '' -q")
        STATE["progress"] = 30

        self.log("Building Guard (LXC)...")
        ctid = CONFIG['ids']['guard_ct']
        self.run_cmd(f"pct destroy {ctid} -purge >/dev/null 2>&1 || true")
        self.run_cmd("pveam update >/dev/null 2>&1")
        tpl = CONFIG['assets']['lxc_template']
        if not os.path.exists(f"/var/lib/vz/template/cache/{tpl}"):
            self.run_cmd(f"pveam download local {tpl} >/dev/null 2>&1")
            
        net = CONFIG['network']
        cmd = f"pct create {ctid} local:vztmpl/{tpl} --hostname oopuopu-gateway --memory 512 --cores 1 --net0 name=eth0,bridge={net['bridge']},ip={net['guard_ip']}/24,gw={net['gateway']} --storage local-lvm --password {CONFIG['credentials']['pass']} --features nesting=1 --unprivileged 1 --start 1"
        self.run_cmd(cmd)
        
        self.log("Installing Tunnel Agent...")
        setup_script = "apt-get update >/dev/null && apt-get install -y curl >/dev/null && curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb >/dev/null 2>&1 && dpkg -i cloudflared.deb >/dev/null 2>&1"
        self.run_cmd(f"pct exec {ctid} -- bash -c '{setup_script}'")
        STATE["progress"] = 50

        self.log("Building Brain (VM)...")
        vmid = CONFIG['ids']['brain_vm']
        self.run_cmd(f"qm stop {vmid} >/dev/null 2>&1 || true")
        self.run_cmd(f"qm destroy {vmid} >/dev/null 2>&1 || true")
        
        user = CONFIG['credentials']['user']
        pub = open(f"{key}.pub").read().strip()
        pwd_hash = self.run_cmd(f"openssl passwd -6 '{CONFIG['credentials']['pass']}'")
        
        yaml = f"#cloud-config\nhostname: oopuopu-cloud\nusers:\n  - name: {user}\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    shell: /bin/bash\n    ssh_authorized_keys: ['{pub}']\n    lock_passwd: false\n    passwd: {pwd_hash}\npackages: [qemu-guest-agent, curl, wget, git]\nruncmd:\n  - systemctl enable qemu-guest-agent\n  - systemctl start qemu-guest-agent"
        with open(f"/var/lib/vz/snippets/user-data-{vmid}.yaml", "w") as f: f.write(yaml)
        self.run_cmd(f"qm create {vmid} --name oopuopu-cloud --memory 8192 --cores 4 --net0 virtio,bridge={net['bridge']} --scsihw virtio-scsi-pci --agent enabled=1")
        self.run_cmd(f"qm importdisk {vmid} {img} local-lvm")
        self.run_cmd(f"qm set {vmid} --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-{vmid}-disk-0,ssd=1,discard=on")
        self.run_cmd(f"qm resize {vmid} scsi0 +80G")
        self.run_cmd(f"qm set {vmid} --boot c --bootdisk scsi0 --ide2 local-lvm:cloudinit --cicustom user=local:snippets/user-data-{vmid}.yaml --ciuser {user} --ipconfig0 ip={net['brain_ip']}/24,gw={net['gateway']}")
        self.run_cmd(f"qm start {vmid}")
        
        while True:
            if os.system(f"ping -c 1 -W 1 {net['brain_ip']} > /dev/null 2>&1") == 0: break
            time.sleep(2)
        STATE["progress"] = 70
        
        self.log("Injecting AI Forge...")
        payload = r'''#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
sudo apt-get update >/dev/null
sudo apt-get install -y curl wget git zip cmatrix >/dev/null
if ! [ -d /data/coolify ]; then curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash >/dev/null 2>&1; fi
mkdir -p ~/miniconda3
if ! [ -f ~/miniconda3/bin/conda ]; then
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda3/miniconda.sh
    bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3 >/dev/null
    ~/miniconda3/bin/conda init bash >/dev/null
fi
source ~/miniconda3/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu >/dev/null 2>&1
pip install langchain langgraph langchain-openai >/dev/null 2>&1
curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
'''
        with open("/tmp/payload.sh", "w") as f: f.write(payload)
        self.run_cmd(f"scp -i {key} -o StrictHostKeyChecking=no /tmp/payload.sh {user}@{net['brain_ip']}:/tmp/payload.sh")
        self.run_cmd(f"ssh -i {key} -o StrictHostKeyChecking=no {user}@{net['brain_ip']} 'chmod +x /tmp/payload.sh && /tmp/payload.sh'")
        STATE["progress"] = 100
        self.log("DEPLOYMENT COMPLETE.")
        time.sleep(2)
        STATE["mode"] = "DASHBOARD"

# --- TUI RENDERER (DIFF ENGINE) ---
class TUI:
    def __init__(self):
        self.stars = [{'x':random.randint(0,100),'y':random.randint(0,30),'s':random.uniform(0.1,0.5)} for _ in range(50)]
        self.font = {
            'O': ["   ▄██████▄   ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "   ▀██████▀   "],
            'P': ["   ▄███████▄  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  █████████▀  ", "  ███         ", "  ███         ", "  ▄████▀      "],
            'U': ["  ▄██    ██▄  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "  ███    ███  ", "   ▀██████▀   "]
        }
        self.prev_buf = [] # For Diff Engine
        self.last_size = (0,0)

    def draw(self, buf, x, y, text, color):
        h = len(buf)
        w = len(buf[0])
        for i, char in enumerate(text):
            if 0 <= y < h and 0 <= x+i < w:
                buf[y][x+i] = col(char, color)

    def render(self):
        w, h = shutil.get_terminal_size()
        
        # RESIZE CHECK
        if (w, h) != self.last_size:
            os.system('clear')
            self.prev_buf = [] # Force full redraw
            self.last_size = (w, h)

        # Build Current Buffer
        buf = [[" " for _ in range(w)] for _ in range(h)]
        
        # 1. STARS
        for s in self.stars:
            s['y'] += s['s']
            if s['y'] >= h-1: s['y'] = 0
            ix, iy = int(s['x']), int(s['y'])
            # Wrap X
            ix = ix % w
            if 0 <= iy < h and 0 <= ix < w: buf[iy][ix] = col(".", C_GREY)
            
        # 2. LOGO
        logo = "OOPUO"
        logo_w = len(logo) * 14
        lx = (w - logo_w) // 2
        ly = 2
        curr_x = lx
        for char in logo:
            for i, line in enumerate(self.font[char]):
                self.draw(buf, curr_x, ly+i, line, C_CYAN)
            curr_x += 14

        # 3. UI
        if STATE["confirm_exit"]: self._render_popup(buf, w, h)
        elif STATE["mode"] == "INSTALL": self._render_install(buf, w, h)
        else: self._render_dashboard(buf, w, h)

        # 4. DIFF RENDER (The Magic)
        out = ""
        for y in range(h-1): # Safety margin
            for x in range(w):
                new_char = buf[y][x]
                
                # Check cache
                should_draw = True
                if len(self.prev_buf) > y and len(self.prev_buf[y]) > x:
                    if self.prev_buf[y][x] == new_char:
                        should_draw = False
                
                if should_draw:
                    out += f"\033[{y+1};{x+1}H{new_char}"
        
        # Commit changes
        sys.stdout.write(out)
        sys.stdout.flush()
        
        # Save cache
        self.prev_buf = buf

    def _render_install(self, buf, w, h):
        bx = (w - 40) // 2
        by = h // 2 + 4
        
        self.draw(buf, bx, by, STATE['status'].center(40), C_CYAN)
        fill = int((STATE["progress"] / 100) * 40)
        bar = "█" * fill + "░" * (40 - fill)
        self.draw(buf, bx, by+1, bar, C_GREEN)
        
        for i, l in enumerate(STATE["logs"][-5:]):
            self.draw(buf, bx, by+3+i, l[:40], C_GREY)

    def _render_dashboard(self, buf, w, h):
        bx = (w - 70) // 2
        by = h // 2 + 2
        
        self.draw(buf, bx, by, "╔" + "═"*68 + "╗", C_CYAN)
        for i in range(14):
            self.draw(buf, bx, by+1+i, "║" + " "*68 + "║", C_CYAN)
        self.draw(buf, bx, by+15, "╚" + "═"*68 + "╝", C_CYAN)
        
        self.draw(buf, bx+4, by+2, "SYSTEM ONLINE", C_GREEN)
        self.draw(buf, bx+20, by+2, f"CPU: {STATE['metrics']['cpu']}%", C_GREEN)
        
        ip = CONFIG['network']['brain_ip'] or "Scanning..."
        self.draw(buf, bx+4, by+4, f"Coolify:  http://{ip}:8000", C_GREY)
        self.draw(buf, bx+4, by+5, f"Jupyter:  http://{ip}:8888", C_GREY)
        self.draw(buf, bx+4, by+6, f"SSH:      ssh adminuser@{ip}", C_GREY)
        
        opts = ["1. Install Infrastructure", "2. Connect Brain (SSH)", "3. Connect Guard (LXC)", "4. Exit"]
        for i, opt in enumerate(opts):
            color = C_PINK if i == STATE["menu_idx"] else C_CYAN
            pre = "➜ " if i == STATE["menu_idx"] else "  "
            self.draw(buf, bx+4, by+8+i, f"{pre}{opt:<40}", color)
            
        if STATE["alerts"]:
            self.draw(buf, bx+4, by+13, f"ALERT: {STATE['alerts'][0]}", C_RED)

    def _render_popup(self, buf, w, h):
        msg = " SYSTEM HALT REQUESTED. CONFIRM? [Y/n] "
        pw = len(msg) + 4
        ph = 5
        px = (w - pw) // 2
        py = (h - ph) // 2
        
        self.draw(buf, px, py, "╔" + "═"*(pw-2) + "╗", C_RED)
        for i in range(ph-2):
            self.draw(buf, px, py+1+i, "║" + " "*(pw-2) + "║", C_RED)
        self.draw(buf, px, py+ph-1, "╚" + "═"*(pw-2) + "╝", C_RED)
        self.draw(buf, px+2, py+2, msg, C_WHITE)

# --- MAIN LOOP ---
def main():
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    tty.setraw(fd)
    
    sys.stdout.write("\033[?25l") # Hide Cursor
    os.system('clear')
    
    engine = InfraEngine()
    ui = TUI()
    
    if os.path.exists(CONFIG['credentials']['key_path']):
        STATE["mode"] = "DASHBOARD"
        if not CONFIG['network']['brain_ip']:
             try:
                 host = subprocess.getoutput("hostname -I | awk '{print $1}'")
                 pre = ".".join(host.split('.')[:3])
                 CONFIG['network']['brain_ip'] = f"{pre}.222"
             except: pass

    try:
        while STATE["running"]:
            ui.render()
            engine.check_health()
            
            if select.select([sys.stdin], [], [], 0.1)[0]:
                k = sys.stdin.read(1)
                
                if STATE["confirm_exit"]:
                    if k.lower() == 'y' or k == '\r': STATE["running"] = False
                    elif k.lower() == 'n' or k == '\x1b':
                        STATE["confirm_exit"] = False
                        os.system('clear') 
                    continue

                if k == '\x03': STATE["confirm_exit"] = True # Ctrl+C
                
                elif STATE["mode"] == "DASHBOARD":
                    if k == '\x1b':
                        sys.stdin.read(1)
                        if sys.stdin.read(1) == 'A': STATE["menu_idx"] = max(0, STATE["menu_idx"]-1)
                        else: STATE["menu_idx"] = min(3, STATE["menu_idx"]+1)
                    
                    if k == '\r':
                        idx = STATE["menu_idx"]
                        if idx == 3: STATE["confirm_exit"] = True
                        else:
                            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
                            os.system("clear")
                            if idx == 0: threading.Thread(target=engine.deploy_stack).start()
                            elif idx == 1:
                                key = CONFIG['credentials']['key_path']
                                ip = CONFIG['network']['brain_ip']
                                os.system(f"ssh -i {key} -o StrictHostKeyChecking=no adminuser@{ip}")
                            elif idx == 2: os.system(f"pct enter {CONFIG['ids']['guard_ct']}")
                            tty.setraw(fd)
                            sys.stdout.write("\033[?25l")
            time.sleep(0.05)
            
    except Exception as e:
        with open(CRASH_FILE, "w") as f: f.write(traceback.format_exc())
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        os.system('reset')

if __name__ == "__main__":
    main()
EOF

# Restart Service
echo -e "\033[38;5;46m[OOPUO] RESTARTING INTERFACE...\033[0m"
systemctl restart oopuo
tmux attach-session -t oopuo