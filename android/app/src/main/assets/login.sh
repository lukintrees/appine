# Login for an Appine terminal tab (the android/setup map): runs as root, and $1 is the login
# account from Settings: auto, root or an account name. auto uses the first regular user created
# (the one with the smallest UID among those with UID 1000–65533 and a login shell), or root when
# there is none; a named account that no longer exists is root too. $2 is the directory to start in
# (for tabs restored after the app was killed, the android/service map); when it is missing or
# cannot be entered, the account's home directory.
#
# When a regular user first becomes the login account, it is added to the admin group and the
# privilege tool is installed, as Alpine's setup-user -a does: on Alpine the wheel group and doas
# (the app bundles that package, so it installs offline too), on Debian the sudo group and sudo
# (needs the network; if it cannot be installed, it is retried at every later login), on Arch Linux
# ARM the wheel group and sudo (both already in the rootfs). Accounts added
# to the group are recorded in /var/lib/appine/admins; if the user later takes one out of the group,
# it is not added back. With a password set, escalating asks for the password, following the
# distro's convention; without one (adduser -D) it does not ask. The rule is rewritten at every
# login according to the password at that time, and, while Appine runs, within a few seconds of the
# account files changing (including in-place writes): the app then runs this script with
# --refresh-rules as $1, which only rewrites the rules.
# On a system the app imported from Alpine, the login shell is bash (root's, and that of the
# accounts busybox's adduser makes after it): the app puts bash's packages in
# /var/cache/appine/bash, and the first login with an account whose shell is /bin/bash installs
# them offline and deletes them, so bash is not installed again if the user removes it. While bash
# cannot be installed (Ctrl-C, below), the login uses /bin/sh, and the next one tries again.
# procps-ng and its libraries are staged at import in /var/cache/appine/procps. Any first login
# installs them offline and removes the cache on success, so user removal is respected.
# bubblewrap and libcap follow the same rule, with their own /var/cache/appine/bubblewrap bundle.
# apk takes its database lock without waiting, so logins install the bundled packages
# one at a time, and while an apk the user runs holds the lock, a login says so and waits for it;
# Ctrl-C then skips installing until the next login. Installing sudo waits for an apt the user runs
# in the same way.
# The install commands all read from /dev/null: what the user types before the prompt appears is
# left for the login shell.
#
# Ctrl-C must not end the login or interrupt short setup commands (passwd lookup, group checks,
# shadow reads, rules publication, or the su --help probe): SIGINT is ignored by default and only
# caught around the cancellable package-lock waits and apt installs (setting interrupted=1 while
# letting the child be interrupted). Before exec into the user's shell or su, SIGINT is restored to
# default so interactive Ctrl-C works normally.
set -u
interrupted=
trap '' INT
want=${1:-auto}
dir=${2:-}
user=root

# Runs "$@" with SIGINT caught in this shell (and default in the child) so Ctrl-C interrupts a
# long-running install or lock wait and records it in interrupted, then ignores SIGINT again.
cancellable() {
    trap 'interrupted=1' INT
    "$@"
    cancellable_rc=$?
    trap '' INT
    return "$cancellable_rc"
}

# The first regular user created
first() {
    best=
    bestuid=
    while IFS=: read -r name _ uid _ _ _ shell; do
        case $shell in '' | */nologin | */false) continue ;; esac
        case $uid in '' | *[!0-9]*) continue ;; esac
        [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || continue
        if [ -z "$bestuid" ] || [ "$uid" -lt "$bestuid" ]; then
            best=$name
            bestuid=$uid
        fi
    done </etc/passwd
    echo "$best"
}

field() { awk -F: -v u="$1" -v f="$2" '$1 == u { print $f; exit }' "$3"; }

admins=/var/lib/appine/admins
if [ -f /etc/alpine-release ]; then
    group=wheel
    tool=doas
    rules=/etc/doas.d/30-appine.conf
    wheel_conf=/etc/doas.d/20-wheel.conf
    stock_wheel_rule='permit persist :wheel'
    wheel_rule='permit persist setenv { ENV=/etc/profile.d/appine.ashrc } :wheel'
elif [ -f /etc/arch-release ]; then
    # Arch Linux ARM: the wheel group and sudo, both of which the rootfs ships. Arch has no
    # addgroup, so ensure_admin uses usermod; sudo's stock file leaves `%wheel` commented out, so
    # the rule goes to /etc/sudoers.d/appine like Debian's
    group=wheel
    tool=sudo
    rules=/etc/sudoers.d/appine
else
    group=sudo
    tool=sudo
    rules=/etc/sudoers.d/appine
fi
ingroup() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -Fqx "$group"; }

# Only a regular file containing the original rule alone is eligible for replacement.
has_stock_wheel_rule() {
    [ -f "$wheel_conf" ] && [ ! -L "$wheel_conf" ] &&
        [ "$(cat "$wheel_conf" 2>/dev/null)" = "$stock_wheel_rule" ]
}

# Atomically writes the Appine wheel rule (caller holds /run/appine-rules.lock).
write_wheel_rule() {
    wt=$rules.wheel.$$
    printf '%s\n' "$wheel_rule" >"$wt" && chmod 0644 "$wt" && mv -f "$wt" "$wheel_conf" || rm -f "$wt"
}

# Serializes bundled package installs across logins; each command rechecks completion state under
# the lock. Creates the lockfile root-only under umask 077, then restores the caller's umask. Uses
# a braced group rather than a subshell so interrupted=1 propagates while fd 9 closes on exit.
locked() {
    locked_umask=$(umask)
    umask 077
    {
        umask "$locked_umask"
        cancellable flock 9 && "$@"
    } 9>/run/appine-install.lock
    locked_rc=$?
    umask "$locked_umask"
    return "$locked_rc"
}

# apk add, offline (without reading the repository index). When another apk holds apk's lock (the
# user's, in another tab), says so and adds again, this time waiting for the lock (an hour at
# most: Ctrl-C stops waiting before that)
apk_add() {
    apk_errors=$(apk add -q --no-network --repositories-file /dev/null "$@" </dev/null 2>&1) && return 0
    case $apk_errors in
    *'Unable to lock database'*)
        echo "appine: another apk is running; waiting for it to finish (Ctrl-C skips installing until the next login)" >&2
        cancellable apk add -q --wait 3600 --no-network --repositories-file /dev/null "$@" </dev/null
        ;;
    *)
        printf '%s\n' "$apk_errors" >&2
        return 1
        ;;
    esac
}

# Installs the bundled doas; then adds it once more by name, so world records doas rather than the
# file and apk upgrade upgrades it as usual. Recheck and write the marker under the same lock so a
# partial install retries recording doas by name and concurrent logins do not reinstall it.
install_doas() {
    [ -e "$installed" ] && return 0
    if ! command -v doas >/dev/null 2>&1; then
        apk_add /var/cache/appine/doas.apk || return 1
        apk_add doas || return 1
    elif apk info -e doas >/dev/null 2>&1; then
        apk_add doas || return 1
    fi
    mkdir -p "${installed%/*}" && : >"$installed"
}

# Installs bash from the bundled packages; then adds it once more by name, as for doas. Recheck and
# remove the cache under the same lock so a partial install retries recording bash by name and
# concurrent logins do not reinstall a completed bundle.
bundle=/var/cache/appine/bash
install_bash() {
    [ -d "$bundle" ] || return 0
    if ! apk info -e bash >/dev/null 2>&1 || [ ! -x /bin/bash ]; then
        apk_add "$bundle"/*.apk || return 1
    fi
    apk_add bash || return 1
    rm -rf "$bundle"
}

# A separate bundle so procps-ng also installs when the login shell is not bash. Check the package
# database: busybox already provides ps/top/free. Recheck and remove the cache under the same lock
# so concurrent first logins cannot reinstall a completed bundle.
install_procps() {
    procps_bundle=/var/cache/appine/procps
    [ -d "$procps_bundle" ] || return 0
    if ! apk info -e procps-ng >/dev/null 2>&1; then
        apk_add "$procps_bundle"/*.apk || return 1
    fi
    apk_add procps-ng || return 1
    rm -rf "$procps_bundle"
}

# Independent of bash and procps; keep failed bundles for retry and respect later user removal.
install_bubblewrap() {
    bubblewrap_bundle=/var/cache/appine/bubblewrap
    [ -d "$bubblewrap_bundle" ] || return 0
    if ! apk info -e bubblewrap >/dev/null 2>&1; then
        apk_add "$bubblewrap_bundle"/*.apk || return 1
    fi
    apk_add bubblewrap || return 1
    rm -rf "$bubblewrap_bundle"
}

# apt-get update, its progress shown as usual. apt-get fails at once when another apt holds the lock
# of the package lists (the user's, in another tab; DPkg::Lock::Timeout does not cover that lock),
# so this then says so and tries again every two seconds until it gets through, or until Ctrl-C.
# apt's errors and warnings are shown after it ends, without those about the lock
apt_update() {
    apt_errors=$(mktemp) || return 1
    waiting=
    while :; do
        if cancellable apt-get update </dev/null 2>"$apt_errors"; then
            status=0
            break
        fi
        status=1
        [ -z "$interrupted" ] && grep -q 'Could not get lock' "$apt_errors" || break
        if [ -z "$waiting" ]; then
            echo "appine: another apt is running; waiting for it to finish (Ctrl-C skips installing until the next login)" >&2
            waiting=1
        fi
        cancellable sleep 2
        [ -z "$interrupted" ] || break
    done
    grep -q 'Could not get lock' "$apt_errors" || cat "$apt_errors" >&2
    rm -f "$apt_errors"
    return "$status"
}

# Installs bash when $1, an account's login shell, is /bin/bash and the staged bundle is still
# present, removing the bundle under the install lock only after bash is recorded by name.
ensure_shell() {
    [ "$1" = /bin/bash ] && [ -d "$bundle" ] || return 0
    if ! locked install_bash; then
        if [ -x /bin/bash ]; then
            echo "appine: cannot finish registering bash now; Appine tries again at the next login" >&2
        else
            echo "appine: cannot install bash now, using /bin/sh; Appine tries again at the next login" >&2
        fi
    fi
}

# Adds $user to the admin group on first login and records it in $admins under /run/appine-rules.lock
# so simultaneous first logins and refresh_rules never race on $admins or $wheel_conf.
ensure_admin() {
    old_umask=$(umask)
    umask 077
    {
        umask "$old_umask"
        flock 9 || return 1
        grep -Fqsx -- "$user" "$admins" && return 0
        if [ "$tool" = doas ]; then
            addgroup "$user" wheel
            mkdir -p /etc/doas.d
            if has_stock_wheel_rule || { [ ! -e "$wheel_conf" ] && [ ! -L "$wheel_conf" ]; }; then
                write_wheel_rule
            elif ! grep -Fqsx -- "$wheel_rule" "$wheel_conf" &&
                ! grep -Fqsx -- "$stock_wheel_rule" "$wheel_conf"; then
                printf '%s\n' "$wheel_rule" >>"$wheel_conf"
            fi
        else
            usermod -aG "$group" "$user"
        fi
        ingroup "$user" && mkdir -p "${admins%/*}" && printf '%s\n' "$user" >>"$admins" && fresh=1
    } 9>/run/appine-rules.lock
    rc=$?
    umask "$old_umask"
    return "$rc"
}

# Admins without a password (still in the group) are not asked for a password when escalating. The
# rules are rewritten at every login, root's included, and with --refresh-rules, according to the
# passwords at that time. No password means a shadow field that is empty or only "!" or "*"
# (adduser -D writes "!"); passwd -l puts "!" in front of a hash, and that account still has a
# password. Without a shadow entry, or without a readable /etc/shadow, an account counts as having
# a password. Serialize the reads and publication across logins and the service refresh so an
# older decision cannot overwrite a newer one. Readers see only complete files.
refresh_rules() (
    # An unprivileged reader could otherwise take this lock exclusively and stall revocation.
    umask 077
    exec 9>/run/appine-rules.lock || exit 1
    flock 9 || exit 1
    # Upgrade an unmodified stock wheel rule so `doas -s` preserves busybox ash's ENV hook.
    if [ "$tool" = doas ] && has_stock_wheel_rule; then
        write_wheel_rule
    fi
    nopass=
    seen=
    if [ -f "$admins" ]; then
        while read -r u || [ -n "$u" ]; do
            [ -n "$u" ] || continue
            case " $seen " in *" $u "*) continue ;; esac
            seen="$seen $u"
            ingroup "$u" || continue
            pw=$(awk -F: -v u="$u" '$1 == u { sub(/^!+/, "", $2); print "=" $2; exit }' /etc/shadow 2>/dev/null)
            case $pw in '=' | '=*') nopass="$nopass $u" ;; esac
        done <"$admins"
    fi
    if [ -n "$nopass" ] && [ -d "${rules%/*}" ]; then
        tmp=$rules.new.$$
        {
            echo "# Written by Appine at each login and when /etc changes: administrators without a password ($admins)."
            for u in $nopass; do
                if [ "$tool" = doas ]; then
                    echo "permit nopass setenv { ENV=/etc/profile.d/appine.ashrc } $u"
                else
                    echo "$u ALL=(ALL:ALL) NOPASSWD: ALL"
                fi
            done
        } >"$tmp" && chmod 0440 "$tmp" && mv -f "$tmp" "$rules" || {
            # The previous file may still grant an account that now needs a password.
            rm -f "$tmp" "$rules"
            exit 1
        }
    else
        rm -f "$rules"
    fi
)

# Only the rules: the service retries failed refreshes on its next poll.
if [ "$want" = --refresh-rules ]; then
    refresh_rules
    exit $?
fi

if [ -d /var/cache/appine/procps ]; then
    locked install_procps ||
        echo "appine: cannot install procps-ng now; Appine tries again at the next login" >&2
fi

if [ -d /var/cache/appine/bubblewrap ]; then
    locked install_bubblewrap ||
        echo "appine: cannot install bubblewrap now; Appine tries again at the next login" >&2
fi

case $want in
auto)
    u=$(first)
    [ -n "$u" ] && user=$u
    ;;
root) ;;
*)
    if [ -n "$(field "$want" 1 /etc/passwd)" ]; then
        user=$want
    else
        echo "appine: there is no user $want any more, logging in as root" >&2
    fi
    ;;
esac

if [ "$user" = root ]; then
    refresh_rules
    # Start in the restored directory, otherwise the home directory
    home=$(field root 6 /etc/passwd)
    { [ -n "$dir" ] && cd "$dir"; } 2>/dev/null || cd "$home" 2>/dev/null || cd /
    shell=$(field root 7 /etc/passwd)
    ensure_shell "$shell"
    [ -x "$shell" ] || shell=/bin/sh
    export SHELL="$shell" HOME="$home"
    case ${shell##*/} in
    zsh) [ -z "${ZDOTDIR+x}" ] && [ -r /etc/appine/zsh/.zshenv ] && export ZDOTDIR=/etc/appine/zsh ;;
    esac
    trap - INT
    exec "$shell" -l
fi

# The first time: add to the admin group and record it (if the user later takes it out of the group,
# it is not added back). Recorded only once it really is in the group, so a failure is retried at
# the next login
fresh=
if ! grep -Fqsx -- "$user" "$admins"; then
    ensure_admin ||
        echo "appine: cannot add $user to the $group group; Appine tries again at the next login" >&2
fi

# Privilege tool: once installed (or already present) it is recorded, and if the user uninstalls it
# later it is not installed again; if it could not be installed (Debian had no network then, or
# Alpine failed before recording doas by name), it is retried at every later login
installed=/var/lib/appine/$tool-installed
tried=
interrupted=
if [ ! -e "$installed" ]; then
    command -v "$tool" >/dev/null 2>&1 || tried=1
    if [ "$tool" = doas ]; then
        locked install_doas
    else
        # Debian installs sudo from the network; Arch ships it, so a missing one there is left alone
        if [ -n "$tried" ] && command -v apt-get >/dev/null 2>&1; then
            # Downloading the index and the package from the network takes a few minutes, so apt's
            # output (the progress) is shown as usual. Ctrl-C during the download interrupts apt-get and
            # skips installing this time; for the dpkg step apt starts a new session in a
            # pseudo-terminal of its own, so Ctrl-C cannot reach it, and apt stops only after it has
            # finished installing. While another apt runs, apt-get install waits for dpkg's lock itself
            # (an hour at most), saying so
            echo "appine: installing sudo so that $user can become root (Ctrl-C skips it until the next login)"
            if apt_update && [ -z "$interrupted" ]; then
                cancellable env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=3600 install -y sudo </dev/null
            fi
        fi
        if command -v sudo >/dev/null 2>&1; then
            mkdir -p "${installed%/*}" && : >"$installed"
        fi
    fi
fi
if [ -e "$installed" ] && command -v "$tool" >/dev/null 2>&1; then
    # Say so when the user was first added to the group, or when the tool was installed only this
    # time (no network before, skipped)
    if [ -n "$fresh" ] || [ -n "$tried" ]; then
        echo "appine: $user is in the $group group and can become root with $tool"
    fi
elif [ -n "$interrupted" ]; then
    # The progress line of the interrupted apt stopped halfway
    printf '\nappine: skipped installing %s; Appine tries again at the next login\n' "$tool" >&2
elif [ ! -e "$installed" ]; then
    if command -v "$tool" >/dev/null 2>&1; then
        echo "appine: cannot finish registering $tool now; Appine tries again at the next login" >&2
    else
        echo "appine: $user is in the $group group, but $tool is not installed yet; Appine tries again at the next login" >&2
    fi
fi

refresh_rules

# The account's shell, installed first if it is the bundled bash; while it is missing, su runs
# /bin/sh instead (its arguments are kept in "$@"), as otherwise it would fail and close the tab
shell=$(field "$user" 7 /etc/passwd)
ensure_shell "$shell"
set --
zdot=
if [ -x "$shell" ]; then
    case ${shell##*/} in
    zsh) [ -r /etc/appine/zsh/.zshenv ] && zdot='[ -z "${ZDOTDIR+x}" ] && export ZDOTDIR=/etc/appine/zsh; ' ;;
    esac
else
    set -- -s /bin/sh
fi

# Run as a login shell (reads /etc/profile); su sets HOME, SHELL, USER and LOGNAME. su -l is not
# used: it always goes to the home directory. The restored directory is entered as this account (a
# directory root can enter is not necessarily enterable by it); when it cannot be entered, go to the
# home directory
cd /
q=$(printf '%s' "$dir" | sed "s/'/'\\\\''/g")
cmd="{ [ -n '$q' ] && cd '$q'; } 2>/dev/null || cd 2>/dev/null; ${zdot}exec \"\$SHELL\" -l"
# util-linux's su (Debian) starts a new session for the -c command (to stop TIOCSTI from pushing
# input into root's terminal): the shell has no controlling terminal and no job control, and on
# Ctrl-C su ends the whole session, closing the tab. Its --session-command starts no new session;
# here su is the session leader, and when it exits the session ends too, so no process goes on
# reading the terminal as root. busybox su (Alpine) never starts a new session and has no such
# option
if su --help 2>&1 | grep -q -- --session-command; then
    set -- "$@" --session-command="$cmd" "$user"
else
    set -- "$@" "$user" -c "$cmd"
fi
trap - INT
exec su "$@"
