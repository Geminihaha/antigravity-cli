#!/data/data/com.termux/files/usr/bin/bash

# Antigravity CLI Reset and Initialization Script (Self-Updating glibc C Wrapper)
# Detects version updates, updates backend backup binary, and applies the C wrapper.

REAL_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39.real"
ORIG_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39"

echo "1. Securing backup of the original 160MB Go binary..."

ORIG_SIZE=$(stat -c%s "$ORIG_BIN" 2>/dev/null || echo 0)
REAL_SIZE=$(stat -c%s "$REAL_BIN" 2>/dev/null || echo 0)

# Check if ORIG_BIN is the large Go binary (size > 10MB)
if [ "$ORIG_SIZE" -gt 10000000 ]; then
    # Backup doesn't exist OR version updated (size mismatch)
    if [ ! -f "$REAL_BIN" ] || [ "$ORIG_SIZE" -ne "$REAL_SIZE" ]; then
        echo "Version update detected ($ORIG_SIZE bytes vs backup $REAL_SIZE bytes). Updating backup..."
        rm -f "$REAL_BIN"
        mv "$ORIG_BIN" "$REAL_BIN"
        echo "New Go binary backed up successfully to agy.va39.real."
    else
        echo "Go binary already backed up and sizes match. Skipping backup."
    fi
else
    # ORIG_BIN is the small wrapper binary
    if [ -f "$REAL_BIN" ]; then
        echo "Wrapper already installed. Using existing backup."
    else
        echo "Error: Both active and backup binaries are missing or invalid!"
        exit 1
    fi
fi

echo "2. Killing existing backend processes..."
pkill -9 -f agy.va39 || true
pkill -9 -f statusline.sh || true
pkill -9 -f dummy-keyring-daemon.py || true
pkill -9 -f dbus-daemon || true
rm -f /data/data/com.termux/files/usr/tmp/dbus-session.socket

# Wait for processes to free up files
echo "Waiting for process cleanup to settle..."
sleep 2

echo "3. Copying the native glibc C ELF wrapper into place..."
rm -f "$ORIG_BIN"
cp /data/data/com.termux/files/home/agy_wrapper "$ORIG_BIN"
chmod +x "$ORIG_BIN"
echo "C ELF Wrapper copied successfully to $ORIG_BIN."

echo "4. Giving execution permissions to helpers..."
chmod +x /data/data/com.termux/files/home/.local/bin/agy
chmod +x /data/data/com.termux/files/home/.local/bin/agy.helper
if [ -f "$REAL_BIN" ]; then
    chmod +x "$REAL_BIN"
fi

echo "5. Syncing environment variables and starting daemons..."
export GEMINI_DIR="/data/data/com.termux/files/home/.gemini"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/data/data/com.termux/files/usr/tmp/dbus-session.socket"

# 5.1. Configure glibc DNS resolver to prevent 5s timeout lags
GLIBC_RESOLV="/data/data/com.termux/files/usr/glibc/etc/resolv.conf"
mkdir -p "$(dirname "$GLIBC_RESOLV")"
if [ ! -f "$GLIBC_RESOLV" ] || ! grep -q "options timeout:1" "$GLIBC_RESOLV"; then
    echo "Writing optimized DNS configuration to $GLIBC_RESOLV..."
    cat << 'EOF' > "$GLIBC_RESOLV"
options timeout:1 attempts:1
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 9.9.9.9
EOF
fi


if ! pgrep -f "dbus-daemon.*session" > /dev/null; then
    /data/data/com.termux/files/usr/bin/dbus-daemon --session --address=unix:path=/data/data/com.termux/files/usr/tmp/dbus-session.socket --fork
fi

if ! pgrep -f "dummy-keyring-daemon.py" > /dev/null; then
    nohup python3 /data/data/com.termux/files/usr/libexec/dummy-keyring-daemon.py > /dev/null 2>&1 &
fi

sleep 1

echo "6. Performing diagnostic check..."
echo "Running 'agy models' (this might ask you to sign in for the first time since reset)..."
time agy models

echo "--------------------------------------------------------"
echo "Done! The C ELF wrapper deployment is complete."
echo "If it asked you to sign in, please do so. After that single login,"
echo "your session will be kept forever and start instantly without 5s lag."
