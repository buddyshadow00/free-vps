#!/usr/bin/env bash
###############################################################################
#                                                                             #
#  ██╗ █████╗ ███╗   ███╗ ██████╗ ██╗   ██╗███╗   ██╗██████╗  ██████╗ ██╗    #
#  ██║██╔══██╗████╗ ████║██╔════╝ ██║   ██║████╗  ██║██╔══██╗██╔═══██╗██║    #
#  ██║███████║██╔████╔██║██║  ███╗██║   ██║██╔██╗ ██║██████╔╝██║   ██║██║    #
#  ██║██╔══██║██║╚██╔╝██║██║   ██║██║   ██║██║╚██╗██║██╔═══╝ ██║   ██║██║    #
#  ██║██║  ██║██║ ╚═╝ ██║╚██████╔╝╚██████╔╝██║ ╚████║██║     ╚██████╔╝██║    #
#  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═╝      ╚═════╝ ╚═╝    #
#                                                                             #
#        sshx auto-installer + 24/7 keep-alive    ::   by IamGunpoint         #
#                                                                             #
###############################################################################
#
#  WHAT IT DOES
#    1. Installs sshx (https://sshx.io) if it isn't already there.
#    2. Launches it detached so it survives logout / SSH disconnect
#       (NO systemd / systemctl — uses nohup + setsid + a respawn loop).
#    3. Grabs the live sshx link and shows it to you, big and clear.
#
#  USAGE
#    chmod +x IamGunpoint.sh
#    ./IamGunpoint.sh            # start it
#    ./IamGunpoint.sh stop       # kill the keep-alive + sshx
#    ./IamGunpoint.sh status     # show current link / state
#    ./IamGunpoint.sh link       # just print the link
#
###############################################################################

set -uo pipefail

# ─── colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'
    M=$'\e[1;35m'; C=$'\e[1;36m'; W=$'\e[1;37m'; D=$'\e[2m'; X=$'\e[0m'
else
    R=; G=; Y=; B=; M=; C=; W=; D=; X=
fi

# ─── paths ───────────────────────────────────────────────────────────────────
APP="IamGunpoint"
WORKDIR="${HOME}/.${APP}"
LOG="${WORKDIR}/sshx.log"
LINKFILE="${WORKDIR}/sshx.link"
PIDFILE="${WORKDIR}/keeper.pid"
SSHX_BIN=""

mkdir -p "$WORKDIR"

# ─── pretty printers ─────────────────────────────────────────────────────────
banner() {
cat <<EOF
${M}
 ██╗ █████╗ ███╗   ███╗ ██████╗ ██╗   ██╗███╗   ██╗██████╗  ██████╗ ██╗███╗   ██╗████████╗
 ██║██╔══██╗████╗ ████║██╔════╝ ██║   ██║████╗  ██║██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝
 ██║███████║██╔████╔██║██║  ███╗██║   ██║██╔██╗ ██║██████╔╝██║   ██║██║██╔██╗ ██║   ██║
 ██║██╔══██║██║╚██╔╝██║██║   ██║██║   ██║██║╚██╗██║██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║
 ██║██║  ██║██║ ╚═╝ ██║╚██████╔╝╚██████╔╝██║ ╚████║██║     ╚██████╔╝██║██║ ╚████║   ██║
 ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝
${X}${D}            s s h x   ·   2 4 / 7   ·   t e r m i n a l   i n   t h e   c l o u d${X}
EOF
}

info()  { printf "${C}[*]${X} %s\n" "$*"; }
ok()    { printf "${G}[✓]${X} %s\n" "$*"; }
warn()  { printf "${Y}[!]${X} %s\n" "$*"; }
err()   { printf "${R}[x]${X} %s\n" "$*" >&2; }
line()  { printf "${D}%s${X}\n" "──────────────────────────────────────────────────────────────────────"; }

# ─── find an existing sshx binary ──────────────────────────────────────────────
find_sshx() {
    if command -v sshx >/dev/null 2>&1; then
        SSHX_BIN="$(command -v sshx)"
        return 0
    fi
    for p in "$HOME/.local/bin/sshx" "/usr/local/bin/sshx" "$WORKDIR/sshx"; do
        if [ -x "$p" ]; then SSHX_BIN="$p"; return 0; fi
    done
    return 1
}

# ─── install sshx ──────────────────────────────────────────────────────────────
install_sshx() {
    if find_sshx; then
        ok "sshx already installed → ${W}${SSHX_BIN}${X}"
        return 0
    fi

    info "sshx not found — installing…"

    # Preferred: official one-liner installer (drops binary in /usr/local/bin).
    if command -v curl >/dev/null 2>&1; then
        if curl -sSf https://sshx.io/get | sh >>"$LOG" 2>&1; then
            if find_sshx; then ok "Installed via sshx.io/get → ${W}${SSHX_BIN}${X}"; return 0; fi
        fi
    fi

    warn "Official installer didn't land a binary — trying manual download…"

    # Manual fallback: detect arch and pull the static musl build.
    local arch tarurl tmp
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l)        arch="armv7"  ;;
        *) err "Unsupported CPU arch: $(uname -m)"; return 1 ;;
    esac
    tarurl="https://s3.amazonaws.com/sshx/sshx-${arch}-unknown-linux-musl.tar.gz"
    tmp="$(mktemp -d)"

    if command -v curl >/dev/null 2>&1; then
        curl -sSfL "$tarurl" -o "$tmp/sshx.tar.gz" >>"$LOG" 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp/sshx.tar.gz" "$tarurl" >>"$LOG" 2>&1
    else
        err "Need curl or wget to download sshx."; rm -rf "$tmp"; return 1
    fi

    if tar -xzf "$tmp/sshx.tar.gz" -C "$tmp" >>"$LOG" 2>&1; then
        mkdir -p "$HOME/.local/bin"
        # binary may be named 'sshx' inside the tarball
        local found
        found="$(find "$tmp" -type f -name sshx | head -n1)"
        if [ -n "$found" ]; then
            install -m 0755 "$found" "$HOME/.local/bin/sshx"
            SSHX_BIN="$HOME/.local/bin/sshx"
            rm -rf "$tmp"
            ok "Installed manually → ${W}${SSHX_BIN}${X}"
            warn "Make sure ${W}\$HOME/.local/bin${X} is on your PATH."
            return 0
        fi
    fi

    rm -rf "$tmp"
    err "Could not install sshx automatically. Install it from https://sshx.io and re-run."
    return 1
}

# ─── extract the sshx link from the log ────────────────────────────────────────
grab_link() {
    # sshx prints a line like:  https://sshx.io/s/xxxx#yyyy
    grep -Eo 'https://sshx\.io/s/[^[:space:]]+' "$LOG" 2>/dev/null | tail -n1
}

# ─── the keep-alive supervisor (runs in background, no systemd) ────────────────
# It re-launches sshx forever if it ever dies, so you stay 24/7.
keeper_loop() {
    find_sshx || exit 1
    while true; do
        # truncate-ish: keep log from growing forever
        if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1000000 ]; then
            tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        fi
        echo "[$(date '+%F %T')] starting sshx ($SSHX_BIN)" >> "$LOG"
        "$SSHX_BIN" >> "$LOG" 2>&1
        echo "[$(date '+%F %T')] sshx exited (code $?), respawning in 3s…" >> "$LOG"
        sleep 3
    done
}

# ─── start everything ──────────────────────────────────────────────────────────
do_start() {
    banner
    line

    # already running?
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        warn "Already running (keeper PID $(cat "$PIDFILE"))."
        do_link
        return 0
    fi

    install_sshx || exit 1

    : > "$LOG"   # fresh log for this session

    info "Launching sshx in 24/7 keep-alive mode (nohup + setsid, no systemd)…"

    # Re-exec THIS script as the background keeper, fully detached:
    #   setsid    → new session, survives terminal close
    #   nohup     → ignore SIGHUP on logout
    #   </dev/null & disown → no controlling tty, not a job of this shell
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$0" __keeper__ </dev/null >>"$LOG" 2>&1 &
    else
        nohup "$0" __keeper__ </dev/null >>"$LOG" 2>&1 &
    fi
    local kpid=$!
    echo "$kpid" > "$PIDFILE"
    disown 2>/dev/null || true

    ok "Keep-alive supervisor started → PID ${W}${kpid}${X}"

    # wait for the link to show up in the log
    info "Waiting for sshx session link…"
    local link="" i=0
    while [ $i -lt 40 ]; do
        link="$(grab_link)"
        [ -n "$link" ] && break
        sleep 0.5; i=$((i+1))
    done

    if [ -z "$link" ]; then
        err "Didn't catch the link in time. Check the log:"
        printf "    ${D}tail -f %s${X}\n" "$LOG"
        return 1
    fi

    echo "$link" > "$LINKFILE"
    show_link_box "$link"
}

# ─── big pretty link box ───────────────────────────────────────────────────────
show_link_box() {
    local link="$1"
    echo
    line
    printf "  ${G}YOUR SSHX SESSION IS LIVE${X}  ${D}(running 24/7 until you stop it)${X}\n"
    line
    echo
    printf "    ${W}${B}>>>${X}  ${C}${link}${X}\n"
    echo
    line
    printf "  ${D}stop   :${X}  ${W}%s stop${X}\n"   "$0"
    printf "  ${D}status :${X}  ${W}%s status${X}\n" "$0"
    printf "  ${D}log    :${X}  ${W}tail -f %s${X}\n" "$LOG"
    line
}

# ─── stop ──────────────────────────────────────────────────────────────────────
do_stop() {
    local stopped=0
    if [ -f "$PIDFILE" ]; then
        local kpid; kpid="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$kpid" ] && kill -0 "$kpid" 2>/dev/null; then
            # kill the whole process group of the keeper
            kill -- "-${kpid}" 2>/dev/null || kill "$kpid" 2>/dev/null
            stopped=1
        fi
        rm -f "$PIDFILE"
    fi
    # mop up any stray sshx
    pkill -f '[s]shx' 2>/dev/null && stopped=1
    rm -f "$LINKFILE"
    if [ "$stopped" -eq 1 ]; then ok "Stopped sshx + keep-alive."; else warn "Nothing was running."; fi
}

# ─── status ────────────────────────────────────────────────────────────────────
do_status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        ok "Running — keeper PID ${W}$(cat "$PIDFILE")${X}"
        local link; link="$(grab_link)"
        [ -z "$link" ] && [ -f "$LINKFILE" ] && link="$(cat "$LINKFILE")"
        [ -n "$link" ] && printf "  ${D}link:${X} ${C}%s${X}\n" "$link"
    else
        warn "Not running."
    fi
}

# ─── link only ─────────────────────────────────────────────────────────────────
do_link() {
    local link; link="$(grab_link)"
    [ -z "$link" ] && [ -f "$LINKFILE" ] && link="$(cat "$LINKFILE")"
    if [ -n "$link" ]; then show_link_box "$link"; else warn "No link yet. Start it first: ${W}$0${X}"; fi
}

# ─── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-start}" in
    __keeper__)        keeper_loop ;;          # internal: background supervisor
    start|"")          do_start ;;
    stop|kill|down)    do_stop ;;
    status|st)         do_status ;;
    link|url)          do_link ;;
    restart)           do_stop; sleep 1; do_start ;;
    -h|--help|help)
        banner
        printf "\n  ${W}Usage:${X} %s ${C}[start|stop|status|link|restart]${X}\n\n" "$0"
        ;;
    *) err "Unknown command: $1  (try: start | stop | status | link | restart)"; exit 1 ;;
esac
