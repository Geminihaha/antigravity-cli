#!/data/data/com.termux/files/usr/bin/bash

# Antigravity CLI Reset and Initialization Script (glibc C Wrapper Native)
# Run this script to kill current processes (including this CLI server), apply the C wrapper, and reboot.

REAL_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39.real"
ORIG_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39"

echo "1. Securing backup of the original 160MB Go binary..."
# Check if the backup binary already exists.
# If not, and the current orig_bin is the large Go binary (size > 10MB), back it up.
if [ ! -f "$REAL_BIN" ]; then
    if [ -f "$ORIG_BIN" ]; then
        FILESIZE=$(stat -c%s "$ORIG_BIN" 2>/dev/null || echo 0)
        if [ "$FILESIZE" -gt 10000000 ]; then
            mv "$ORIG_BIN" "$REAL_BIN"
            echo "Original Go binary backed up successfully to agy.va39.real."
        else
            echo "Error: Original binary is too small (might be an old wrapper). Cannot backup!"
            exit 1
        fi
    else
        echo "Error: Original Go binary not found at $ORIG_BIN."
        exit 1
    fi
else
    echo "Backup already exists. Skipping backup."
fi

echo "2. Killing existing backend processes (including this CLI server)..."
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
