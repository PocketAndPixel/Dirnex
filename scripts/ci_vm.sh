#!/bin/bash

# The self-hosted CI runner, in a macOS VM of its own (docs/RELEASING.md ▸ The Mac runner).
#
# Why a VM and not a second macOS user: every user logged in on a Mac shares one WindowServer. On
# 2026-11-12 the app tests, running as a background user on Oleg's laptop, kept WindowServer busy for
# 25 minutes, so his own session barely moved. When the job's watchdog killed the test host,
# WindowServer spent 40 s tearing down its windows, macOS's watchdog killed WindowServer, and every
# session on the Mac was logged out. A VM has a WindowServer of its own, so nothing it runs can reach
# the host's session.
#
# Two VMs, both in ~/.tart/vms:
#   dirnex-ci-base  the clean machine: macOS, this Mac's Xcode, the registered runner. It is only
#                   ever started by `create` and `register`, and never takes a job.
#   dirnex-ci       a fresh clone of the base, made at every start by `run` (an APFS clone, so it
#                   costs no time and no space). Nothing a job leaves behind outlives a restart, and
#                   `run` restarts it every night, so no state builds up the way it did in the
#                   runner user's 13-day-old session.
#
# Usage:
#   scripts/ci_vm.sh create      # download the base image and copy this Mac's Xcode into it
#   scripts/ci_vm.sh register    # Oleg: install the runner, asking for the token GitHub shows
#   scripts/ci_vm.sh install     # start `run` at every login, through a LaunchAgent
#   scripts/ci_vm.sh uninstall   # stop it and remove the LaunchAgent
#   scripts/ci_vm.sh status      # the VMs, and whether the runner is up or in a job
#   scripts/ci_vm.sh shell       # a shell in the running clone
#   scripts/ci_vm.sh run         # what the LaunchAgent runs: clone, boot, start the runner, repeat
#
# Requires Tart (`brew install openai/tools/tart`).

set -euo pipefail

TART="${TART:-/opt/homebrew/bin/tart}"
IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
BASE="dirnex-ci-base"
VM="dirnex-ci"
CPUS=8
MEMORY_MB=16384
DISK_GB=100
REPO_URL="https://github.com/PocketAndPixel/Dirnex"
RUNNER_LABELS="dirnex-mac"
RUNNER_NAME="dirnex-vm"
# Pinned with its digest, as CI pins its tools. The runner updates itself once it is running, so a
# newer release only costs that update at the clone's first job.
RUNNER_VERSION="2.338.2"
RUNNER_SHA256="25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388"
# The runner's LaunchAgent is kept here inside the VM rather than in ~/Library/LaunchAgents, so
# the base never loads it: `run` bootstraps it in each clone once that clone has booted.
RUNNER_PLIST="actions-runner/runner.plist"
AGENT_LABEL="app.dirnex.ci-vm"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG="$HOME/Library/Logs/Dirnex-CI-VM.log"
# Local time. A job that is running then is left to finish, and the restart waits for it.
RECYCLE_AT="04:30"

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

vm_exists() { "$TART" list --format json | /usr/bin/python3 -I -c '
import json, sys
sys.exit(0 if any(v.get("Name") == sys.argv[1] for v in json.load(sys.stdin)) else 1)' "$1"; }

vm_running() { "$TART" list --format json | /usr/bin/python3 -I -c '
import json, sys
sys.exit(0 if any(v.get("Name") == sys.argv[1] and v.get("Running") for v in json.load(sys.stdin)) else 1)' "$1"; }

# Boot `$1` headless in the background, with any extra `tart run` arguments, and wait until its
# guest agent answers, which is what `tart exec` needs.
boot() {
    local name="$1"
    shift
    "$TART" run "$name" --no-graphics "$@" >> "$LOG" 2>&1 &
    local waited=0
    until "$TART" exec "$name" true > /dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge 300 ]; then
            say "$name did not answer within 5 minutes; see $LOG" >&2
            return 1
        fi
    done
}

in_vm() { "$TART" exec "$1" /bin/bash -lc "$2"; }

# Shut `$1` down from inside and wait for it. `tart stop` alone asks the guest to stop and pulls the
# plug after 30 s, and what the guest had not yet written out is lost: on 2026-11-12 the base came
# back from `register` with the runner's `.runner`, `.credentials` and LaunchAgent missing, all
# written in the last second before the stop.
halt() {
    local name="$1"
    vm_running "$name" || return 0
    "$TART" exec "$name" /bin/bash -c 'sync; sudo shutdown -h now' > /dev/null 2>&1 &
    local waited=0
    while vm_running "$name"; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge 120 ]; then
            "$TART" stop "$name" || true
            break
        fi
    done
}

create() {
    if ! vm_exists "$BASE"; then
        say "Downloading $IMAGE (about 25 GB)…"
        "$TART" clone "$IMAGE" "$BASE"
    fi
    "$TART" set "$BASE" --cpu "$CPUS" --memory "$MEMORY_MB" --disk-size "$DISK_GB"
    local xcode carry
    xcode="$(xcode-select -p)"
    xcode="${xcode%/Contents/Developer}"
    # Xcode travels as one archive. A shared folder cannot carry it as it is: copied straight out of
    # the share, every framework's `Versions/Current` link failed with "Too many levels of symbolic
    # links" (2026-11-12).
    carry="$(mktemp -d)"
    # Expanded now: `carry` is local, and gone by the time the trap runs.
    # shellcheck disable=SC2064
    trap "rm -rf '$carry'" EXIT
    say "Packing $xcode…"
    aa archive -D "$xcode" -o "$carry/Xcode.aar" -include-field xat
    say "Booting $BASE…"
    boot "$BASE" --dir="carry:$carry:ro"
    # The image's 50 GB disk leaves 12 GB free, too little for Xcode and a build, so `tart set` has
    # grown it. The image grows its APFS container to the disk at boot by itself (seen 2026-11-12:
    # 93 GiB, 64 free, after one boot), and the disk file is sparse: on this Mac it takes only what
    # is written.
    in_vm "$BASE" '
        set -e
        sudo rm -rf /Applications/Xcode.app
        sudo aa extract -d /Applications -i "/Volumes/My Shared Files/carry/Xcode.aar"
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
        sudo xcodebuild -license accept
        sudo xcodebuild -runFirstLaunch
        # SwiftTerm compiles a Metal shader. The 840 MB download broke off twice in the VM on
        # 2026-11-12 ("a general networking error") and went through on the next try.
        for try in 1 2 3; do
            xcodebuild -downloadComponent MetalToolchain && break
        done
        xcodebuild -showComponent MetalToolchain | grep -q "Status: installed"
        xcodebuild -version
        df -h /
    '
    halt "$BASE"
    say "$BASE is ready. Next: scripts/ci_vm.sh register"
}

register() {
    vm_exists "$BASE" || { say "No $BASE yet: run scripts/ci_vm.sh create first." >&2; exit 1; }
    if vm_running "$VM"; then
        say "The runner is up in $VM. Run scripts/ci_vm.sh uninstall first, so two copies of one runner never run at once." >&2
        exit 1
    fi
    echo "On GitHub: Settings ▸ Actions ▸ Runners ▸ New self-hosted runner. Copy the token from its"
    echo "./config.sh line (it expires within an hour), and paste it here. It is not shown."
    local token
    read -r -s -p "Token: " token
    echo
    [ -n "$token" ] || { echo "No token given." >&2; exit 1; }
    boot "$BASE"
    in_vm "$BASE" "
        set -e
        rm -rf ~/actions-runner && mkdir ~/actions-runner && cd ~/actions-runner
        curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz
        echo '$RUNNER_SHA256  runner.tar.gz' | shasum -a 256 -c -
        tar xzf runner.tar.gz && rm runner.tar.gz
    "
    # The token travels on standard input, so it is in no command line on this Mac.
    printf '%s\n' "$token" | "$TART" exec -i "$BASE" /bin/bash -lc "
        set -e
        read -r token
        cd ~/actions-runner
        ./config.sh --url $REPO_URL --token \"\$token\" --labels $RUNNER_LABELS --name $RUNNER_NAME --unattended --replace
        ./svc.sh install
        mv ~/Library/LaunchAgents/actions.runner.*.plist ~/$RUNNER_PLIST
        test -s .runner && test -s .credentials && test -s ~/$RUNNER_PLIST
    "
    halt "$BASE"
    say "The runner is registered in $BASE. Next: scripts/ci_vm.sh install"
}

# The LaunchAgent's loop. Each pass starts from a fresh clone of the base.
run() {
    while true; do
        if vm_running "$VM"; then "$TART" stop "$VM" || true; fi
        if vm_exists "$VM"; then "$TART" delete "$VM"; fi
        "$TART" clone "$BASE" "$VM"
        say "Booting $VM…"
        if boot "$VM" && in_vm "$VM" "launchctl bootstrap gui/\$(id -u) ~/$RUNNER_PLIST"; then
            say "The runner is up."
            local recycle
            recycle="$(date -j -f '%H:%M' "$RECYCLE_AT" +%s)"
            [ "$recycle" -gt "$(date +%s)" ] || recycle=$((recycle + 86400))
            while vm_running "$VM"; do
                sleep 60
                if [ "$(date +%s)" -ge "$recycle" ] && ! in_vm "$VM" 'pgrep -x Runner.Worker' > /dev/null 2>&1; then
                    say "Nightly restart."
                    halt "$VM"
                fi
            done
            say "$VM stopped."
        else
            say "$VM did not come up; trying again in a minute."
            "$TART" stop "$VM" > /dev/null 2>&1 || true
            sleep 60
        fi
    done
}

install_agent() {
    vm_exists "$BASE" || { say "No $BASE yet: run scripts/ci_vm.sh create first." >&2; exit 1; }
    local script
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    mkdir -p "$(dirname "$AGENT_PLIST")"
    cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2> /dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    say "Installed. The VM starts now and at every login; its log is $LOG"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2> /dev/null || true
    rm -f "$AGENT_PLIST"
    halt "$VM"
    say "Removed. The VMs stay in ~/.tart/vms; tart delete $VM $BASE removes them."
}

status() {
    "$TART" list
    if vm_running "$VM"; then
        if in_vm "$VM" 'pgrep -x Runner.Worker' > /dev/null 2>&1; then
            echo "The runner is in a job."
        elif in_vm "$VM" 'pgrep -x Runner.Listener' > /dev/null 2>&1; then
            echo "The runner is waiting for a job."
        else
            echo "$VM is running, without the runner."
        fi
    else
        echo "$VM is not running."
    fi
}

case "${1:-}" in
    create) create ;;
    register) register ;;
    run) run ;;
    install) install_agent ;;
    uninstall) uninstall_agent ;;
    status) status ;;
    shell) "$TART" exec -i -t "$VM" /bin/zsh -l ;;
    *)
        sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
