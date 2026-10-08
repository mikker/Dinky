#!/bin/bash
# Rebuild the dinky Tart VM from the base template and replay the test setup.
set -u
SSH_OPTS="-i $HOME/.ssh/id_rsa -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/dinky-known-hosts"
log() { echo "[$(date +%H:%M:%S)] $*"; }

pkill -9 -f 'MacOS/tart run --no-graphics --no-clipboard dinky' 2>/dev/null; sleep 3
tart delete dinky 2>&1; sleep 1
tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest dinky || { log "clone failed"; exit 1; }
log "cloned"
nohup tart run --no-graphics --no-clipboard dinky > /tmp/dinky-vm.log 2>&1 &
sleep 5
for i in $(seq 1 60); do tart exec dinky /usr/bin/true >/dev/null 2>&1 && { log "guest agent up after ${i}x5s"; break; }; sleep 5; done
pub="$(cat ~/.ssh/id_rsa.pub)"
tart exec dinky /bin/zsh -lc "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys" && log "key installed"
IP=$(tart ip dinky --wait 120); log "ip=$IP"
for i in $(seq 1 30); do ssh $SSH_OPTS -o ConnectTimeout=5 admin@$IP true 2>/dev/null && { log "ssh up after ${i}x5s"; break; }; sleep 5; done

ssh $SSH_OPTS admin@$IP 'bash -s' <<'EOF'
sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' <<'SQL'
INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('kTCCServiceAccessibility', '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1, 0, strftime('%s','now'));
INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('kTCCServiceScreenCapture', '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1, 0, strftime('%s','now'));
INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('kTCCServicePostEvent', '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1, 0, strftime('%s','now'));
INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceAppleEvents', '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1, 0, 'com.apple.systemevents', 0, strftime('%s','now'));
INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('kTCCServiceAccessibility', 'com.brnbw.dinky', 0, 2, 4, 1, 0, strftime('%s','now'));
SQL
sudo killall tccd
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock workspaces-auto-swoosh -bool false
killall Dock; sleep 4
cat > /tmp/click.swift <<'SWIFT'
import CoreGraphics
import Foundation
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
func post(_ t: CGEventType) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
for _ in 0..<4 { post(.mouseMoved); usleep(250_000) }
if CommandLine.arguments.count > 3 { post(.leftMouseDown); usleep(80_000); post(.leftMouseUp) }
SWIFT
swiftc -O /tmp/click.swift -o /tmp/click 2>&1 | grep error
echo "tools built"
EOF
log "guest configured"
scp $SSH_OPTS /Users/mikker/dev/dinky/.build/debug/dinky admin@$IP:/Users/admin/dinky && log "binary copied"

# No Spaces to set up: the app creates the configured number of workspaces when it starts.
log "done"
