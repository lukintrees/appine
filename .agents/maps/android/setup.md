# android/setup Map

> Static understanding snapshot, not a decision history.
> See `.agents/decisions/android/setup.md` for the paired decision history (it still holds the decisions on the Settings screen made before it was split out into `android/settings`).
>
> Verified: 2026-11-26 (full mapping, 15 claims independently checked across package verification, store publication, per-start setup, OpenRC, account selection and shell integration)
>
> Maintained: 2026-11-27 (targeted verification only since the full mapping; latest change: Arch Linux ARM as a third distro — pinned release tarball, pacman sources, login.sh's wheel/sudo branch, and the bash/zsh rc hooks now covering every non-Alpine store)

## Responsibilities

`android/setup` provides the guest system and its account setup:

- the distributions (Alpine from the APK, Debian and Arch Linux ARM downloaded), downloading and
  verifying tarballs, importing them into a new store, and writing first-boot configuration, which
  on Alpine makes bash the login shell;
- files refreshed before every kernel start (network interfaces, rootless podman's network, the
  bundled doas package, the profile script and the files of ash's, bash's and zsh's prompt marks for the
  terminal's shell integration), one-time OpenRC setup on Alpine, the osclock script run before boot and the boot log's failed services;
- package mirrors: built-in lists, concurrent throughput probes during import and one sources write in the
  temporary store;
- resolving the login account and the per-tab login script (`login.sh`), including the first-login
  admin setup, installing the bundled bash, procps-ng and bubblewrap, and the NOPASSWD rules;
- the store lock shared by the kernel start, store deletion and the Files provider.

Root: `android/app/src/main/java/io/github/mthli/appine/Rootfs.kt`,
`android/app/src/main/assets/login.sh`, `android/app/src/main/assets/install-openrc.sh`, `android/app/src/main/assets/profile.sh`,
`android/app/src/main/assets/ashrc.sh`, `android/app/src/main/assets/bashrc.sh`,
`android/app/src/main/assets/zshrc.sh`, `android/app/src/main/assets/xdg-open.sh`, `android/app/src/main/assets/appine-gpu.sh`, `scripts/fetch-rootfs`,
`scripts/build-arch-rootfs`.

Outside the module: the settings screen (`android/settings`); when imports, switches, restarts and
logins happen, and the `settings` preferences (`android/service`); the import and
`write_file`/`read_file` implementations (`kernel/store`, `kernel/vfs`); bundling the assets
(`android/build`); what the terminal does with the prompt marks (`android/vtcore`, `android/vtview`,
`android/vtgestures`) and the Kotlin session consuming their state and events (`android/vt`).

## Key types

- `Rootfs` — object: `Distro` (`ALPINE`, `DEBIAN`, `ARCH`: label, download, mirrors, probe path),
  `Download` (urls, sha256, size), `Cancelled` and the private `Oversize` (both `IOException`s),
  `Account` (name, uid, gid, home from `/etc/passwd`), `StartPreparation` (`browserReady`,
  `openRcDone`), internal `StoreAccess` (session read/write abstraction), `access` (a `ReentrantReadWriteLock`).
  - `ALPINE`: labelled with the branch the APK bundles (`BuildConfig.ALPINE_BRANCH`); no download;
    mirrors are URLs ending in `/alpine` (dl-cdn, Tsinghua, USTC, Aliyun), probed at the branch's
    `main/aarch64/APKINDEX.tar.gz`.
  - `DEBIAN`: "Debian 13"; one pinned GitHub URL (debuerreotype's `debian:trixie`) with fixed
    length and sha256; mirrors are host names (deb.debian.org, Tsinghua, USTC, Aliyun), probed at
    `debian/dists/trixie/InRelease` over https.
  - `ARCH`: "Arch Linux ARM"; one pinned GitHub release asset of this fork
    (`arch-rootfs-20261126/archlinuxarm-aarch64-minimal.tar.gz`, built by
    `scripts/build-arch-rootfs`) with fixed length and sha256; mirrors are URLs ending in
    `/archlinuxarm` (Tsinghua, USTC, Aliyun, Nanjing — the official host is left out because its
    https certificate names `archlinuxarm.org` and its http redirects to a 404), probed at
    `aarch64/core/core.db` over https.
  - The first mirror of each list is the official one: the importer uses it when no successful probe is ready.
- Preferences: file `rootfs`, owned here (`distro`); the `settings` file is `android/service`'s
  `Settings`, displayed and edited through `android/settings`.
- `login.sh` — `sh -c <script> appine-login <login> <cwd>`, run as root on each tab's console, or
  without a console with `--refresh-rules`.
- `profile.sh` — copied verbatim, comments included, into the guest as
  `/etc/profile.d/appine.sh`; `Rootfs` keeps the texts of the versions without prompt marks
  (`OLD_PROFILE`, `UNMARKED_PROFILE`) and the sha256s of the later ones (`REPLACED_PROFILES`) to
  recognise them.
- `ashrc.sh` — copied verbatim into the guest as `/etc/profile.d/appine.ashrc` (not `.sh`, so
  `/etc/profile` does not read it): ash's prompt marks, read through `ENV`.
- `bashrc.sh` — copied verbatim into the guest as `/etc/profile.d/appine.bashrc`: bash's prompt
  marks (including `k=c` continuation marks on multi-line `PS1` and scalar/array `PROMPT_COMMAND`
  handling), read by the profile, by `/etc/bash/appine.sh` (`BASH_HOOK`) on Alpine, and via
  `DEBIAN_BASH_HOOK` appended once to `/etc/bash.bashrc` on Debian and Arch.
- `zshrc.sh` — copied verbatim into the guest as `/etc/profile.d/appine.zshrc`, read by the
  profile (on Alpine via `/etc/zsh/zprofile`, on Debian via `/etc/appine/zsh/.zshenv` written from
  `ZSHENV` and selected by `login.sh` via `ZDOTDIR`), and by `/etc/zsh/zshrc` (`ZSH_RC_HOOK`,
  installed once after `zsh` is present) for nested interactive zsh. Its anonymous function
  registers the hooks in local zsh emulation, preserving the caller's options, and wraps `PS1`
  (with `k=c` continuation marks on multi-line prompts), `PS2`, non-empty `RPROMPT` (`k=r` on
  single-line `PS1`, `k=c` on multi-line `PS1`) and `RPS2` (`k=s`), restoring clean prompts before
  commands and respecting `nopromptpercent`. `Rootfs.writeProfile(context, store, distro)` writes
  the three companion files, `/etc/appine/zsh/.zshenv`, Alpine's `/etc/bash/appine.sh`, and then
  the profile, and runs `ensureShellRcHooks`.
- Guest-side state: `/var/lib/appine/admins` (recorded admins), `/var/lib/appine/doas-installed`,
  `sudo-installed`, `bash-startup-done`, `debian-bashrc-hook-done` and `zsh-rc-hook-done`
  (markers), `/etc/doas.d/20-wheel.conf`, the NOPASSWD rules (`/etc/doas.d/30-appine.conf` or
  `/etc/sudoers.d/appine`), `/etc/appine/zsh/.zshenv`, `/var/cache/appine/doas.apk`,
  `/var/cache/appine/{bash,procps,bubblewrap,openrc}/` (packages until installed),
  `/run/appine-install.lock` and `/run/appine-rules.lock`.

## Public entry points

- `Rootfs.prepare(distro)` (with an optional store, used by the instrumentation tests), `download`,
  `fetch`, `tarball`, `deleteTarball`, `isReady`, `installed`, `importing`, `store`, `reset`, `access`.
- Before every start: `prepareStart` (opening one `Native.withStore` session to run
  `ensureNetworkConfig`, `ensureContainersConfig`, `ensureLoginTools`, `ensureBashStartup`,
  `ensureGpuCommand`, `ensureBrowser`, `updateProfile` and the Alpine `openrc-setup-done` precheck
  in order, fatal on fresh imports, degrading each step independently on existing stores, and
  returning `StartPreparation`); around boot: `ensureOpenRc`, `boot`, `PREFER_OSCLOCK`,
  `failedServices`.
- Mirrors: the service supplies `probeMirrors` to `prepare`. The default imports offline with official sources when the tarball is local.
- Accounts: `loginAccount`, `regularAccounts`, `LoginRules.poll` (with `REFRESH_RULES`).
- `scripts/fetch-rootfs [outdir]` (build-time download of the Alpine minirootfs and the bundled
  packages into `target/rootfs` by default; prints each package's path, then the tarball's last).
  `--assets` lists their pinned filenames, SHA-256 digests and APK destinations offline.
- `login.sh` arguments: login setting (`auto`, `root` or an account name) and an optional start
  directory; or `--refresh-rules`.

## Data flow / lifecycle

### Tarballs

- Alpine: `scripts/fetch-rootfs` downloads the bundled packages from the branch's `main`
  repository (doas, and bash with readline, libncursesw and ncurses-terminfo-base, each checked by
  its pinned sha256 only; also procps-ng, libproc2, libintl, utmps-libs and skalibs-libs, sharing
  the ncurses dependencies; also bubblewrap and libcap2, openrc, openrc-user, ifupdown-ng and bridge; apk checks signatures at install) and, unless a copy with the
  pinned sha256 is already there, the minirootfs: its GPG signature is
  checked when both gpg and gpgv are installed (a failed signature download counts as bad; without
  gpg a warning), then its pinned sha256. `--assets` lists bundle inputs offline. Gradle verifies those inputs and bundles
  them as `rootfs.tgz`, `doas.apk` and `{bash,procps,bubblewrap,openrc}/<file name>`.
  `BuildConfig.ALPINE_BRANCH` comes from the pinned tarball name. `prepare` copies the tarball asset to the cache.
- Debian (`download`): a cached `cacheDir/<distro>.tar.gz` with the pinned length and sha256 is
  reused; else `fetch` tries the sources in order (probed by speed when there are several; Debian
  has one), checking for cancellation before each, moving to the next on any error but a cancel,
  and throwing the last error.
- One source: 30 s timeouts; written to `.part` while hashing (64 KiB reads, cancellation checked
  before each, progress every 0.5%); an attempt that failed after getting data is resumed with
  `Range` up to 5 times, and one that got none ends the source. A resume answered 206 continues,
  one answered 200 starts again from zero, and any other status ends the source like an attempt
  that got no data. An attempt that broke off with the whole pinned length received is not resumed
  but verified at once (a `Range` from the end would be answered 416). More than the pinned length
  stops the source at once (no resume). Length and sha256
  are checked and `.part` is renamed into place; any other exit deletes `.part` (a kill can leave
  it), and every call starts from zero, truncating it, so nothing resumes across calls or kills. A
  206 reply's range is not checked; the final hash catches a wrong one.
- A switch's download can be cancelled (between reads; a blocked connect or read waits for its
  timeout); a download inside `prepare` cannot.

### Import

- `prepare` (does nothing for a ready store, one whose `meta.db` exists):
  1. for the app's store, commit the distro it imports (`distro`), the only record;
  2. delete `<store>.tmp`;
  3. get the tarball into the cache: Alpine's asset copied over it, unchecked; others through
     `download`;
  4. start the supplied mirror probes, import into `<store>.tmp` (`Native.importRootfs`),
     `configure` it and write package sources from the results available then;
  5. sync the store (`syncfs`), rename it to the real store, fsync `files/` (a failure only
     logged) and only then delete the tarball.
- `installed` is the recorded distro of a ready store (Alpine when there is no record); while
  there is no store, `importing` names the distro an import was last started for (Alpine when
  there is none), which the service imports at the next launch. `reset` deletes `rootfs.tmp` and
  the store under the write lock and leaves the preferences and the cache alone.
- `configure` writes, with mode 0644 for new files (an overwritten file keeps its mode, and an
  existing entry that is not a regular file fails the import):
  - always: `hostname` (`localhost`), `motd`, and
    `/etc/profile.d/appine.ashrc`, `/etc/profile.d/appine.bashrc`, `/etc/profile.d/appine.zshrc`, on Alpine
    `/etc/bash/appine.sh`, and then `/etc/profile.d/appine.sh` (the assets' `ashrc.sh`,
    `bashrc.sh`, `zshrc.sh` and `profile.sh`: motd, `TERM`, `LANG`, `NMAP_UNPRIVILEGED`, the browser default below,
    `ENV` naming the ash file unless one is set or the file is unreadable, and for bash, busybox ash and zsh only a
    coloured prompt with prompt marks, below; other shells keep the distro's prompt);
  - Alpine: `hosts` only when absent (the minirootfs ships one, so nothing is written), and no
    `resolv.conf` (the kernel writes one pointing at the DNS stub at every start when it is
    missing); bash as the login shell (`useBash`): the bundled packages from the assets' `bash/`
    into `/var/cache/appine/bash/`, and, when there were any, root's `/etc/passwd` shell changed
    from `/bin/sh` to `/bin/bash` (any other shell is kept) and `ensureBashStartup` run so
    `/etc/skel` and `/root` receive `.bash_profile` (sourcing `~/.bashrc`) and `.bashrc` (an
    interactive guard leaving `PS1` and history unchanged) and `/var/lib/appine/bash-startup-done`
    is recorded. Systems imported before keep busybox ash; accounts busybox's `adduser` makes
    later take the shell of `$SHELL` or of the account running it (so from a root tab they get
    bash too) and copy `/etc/skel`; procps-ng and its six dependencies are
    staged in `/var/cache/appine/procps/` by `cachePackages`, also used for bash and bubblewrap
    with libcap2 (`/var/cache/appine/bubblewrap/`). Existing stores do not receive these import-time files;
  - Debian: `hosts` and `resolv.conf` (the DNS stub) always.
  - Arch: `hosts` only when absent (the rootfs ships one) and `resolv.conf` pointed at the DNS
    stub. The rootfs is built by `scripts/build-arch-rootfs` and carries pacman with the Arch Linux
    ARM keyring, bash, coreutils, util-linux, shadow, curl, gnupg and sudo; it has no systemd, so
    wheel and users are written by the script and PAM's systemd modules are removed. Nothing is
    staged from the APK.

### Before every start and boot

- `ensureGpuCommand` installs `/usr/local/bin/appine-gpu` (0755) when missing, called before
  kernel start only when Vulkan GPU is enabled, skipping asset reads and writes when a regular
  file is already present. The launcher
  finds the packaged Alpine or Debian Venus manifest and execs the supplied command with
  `VK_DRIVER_FILES` set for that invocation.
- `ensureBrowser` installs `xdg-open.sh` as `/usr/local/bin/xdg-open` (0755) on either distro.
  It preserves custom launchers, replacing only the known previous Appine OSC helper by SHA-256
  and skipping asset reads and writes when a non-legacy regular file is already present.
  Before every kernel start it refreshes the static `/usr/local/libexec/appine-open-url` (0755,
  skipping the write when existing bytes match)
  and `/etc/appine/browser` (0644: current loopback port and capability, shared by guest users).
  The shim execs that client; `ConsolePty` sets `BROWSER` to the shim (android/vt).
  The login profile also exports that default when `BROWSER` is unset or empty and the shim is
  executable, restoring browser discovery after `su -` clears the inherited environment.
  Nonempty custom values are preserved. When Appine starts zsh with its `ZDOTDIR` shim, an
  interactive Debian login also sources the Appine profile. A separately launched shell that
  reads neither profile nor shim needs its own browser configuration.
  Each invocation rereads the configuration and sends one HTTP(S) URL without using a TTY or
  inherited tab token; success acknowledges Android intent acceptance, not page loading or login.
- After import, `TerminalService.startKernel` calls `Rootfs.prepareStart` before opening the kernel
  under the provider write lock: in one `Native.withStore` session it runs network configuration,
  container defaults, login tools, bash startup files, GPU launcher (when enabled), browser
  endpoint/launcher, profile/rc-hook updates and an Alpine `openrc-setup-done` precheck.
  On fresh imports (`importing = true`), the first I/O failure aborts startup. On existing stores
  (`importing = false`), each helper and independent sub-step (e.g., `doas.apk` vs `20-wheel.conf`,
  `/etc/skel` vs per-user bash homes, `appine-open-url`/`browser`/`xdg-open`, profile companion
  writes, Debian bash vs zsh rc hooks, or opening the store itself) catches `IOException`, reports it to the caller's `onFailure`
  callback and continues so a symlinked directory, custom file or full disk cannot lock the user
  out of a repair terminal. `prepareStart` returns `StartPreparation(browserReady, openRcDone)` so
  `TerminalService` can close an unconfigured `BrowserBridge` and skip calling `ensureOpenRc` on
  normal Alpine starts when `openrc-setup-done` is already a regular file (an absent or obstructed
  marker leaves `openRcDone` false for `ensureOpenRc` to handle). Unreadable one-time markers
  (`bash-startup-done`, `debian-bashrc-hook-done`, `zsh-rc-hook-done`) report to `onFailure` and
  skip their one-time migration rather than aborting startup or re-seeding user-deleted files;
  `ensureBashStartup` writes `bash-startup-done` only when every seeding write succeeded.
  The network file defaults to loopback only. The rootless Podman fragment selects host networking
  because pasta and slirp4netns require a TUN device. Both defaults preserve an existing file.
- Alpine refreshes the bundled doas APK (skipping the write when the existing file is
  byte-identical) and upgrades the stock wheel rule to preserve ash's
  `ENV`. Once per store, `ensureBashStartup` seeds missing startup files in `/etc/skel` and in
  existing absolute homes for root and UID 1000–65533 bash accounts with valid ownership.
  Existing `.bash_profile`, `.bash_login` or `.profile` takes precedence. The marker lets a
  later user deletion persist.
- `updateProfile` upgrades known stock profile contents. It writes the companion scripts
  before the profile, preserving a user's edited version. A readable edited profile still gets
  the independent one-time interactive rc hooks. An unreadable or missing profile skips those
  hooks. Direct callers of `updateProfile` run Alpine's stock doas-rule migration first;
  `prepareStart` skips the duplicate check because `ensureLoginTools` already ran it.
- Storage is left to the packages: podman's overlay driver and docker's (containerd's) overlayfs
  snapshotter run on the kernel's overlayfs, rootful and rootless. A `storage.conf` choosing vfs or
  a `daemon.json` choosing native that an earlier build wrote stays until the user removes it.
- On Alpine, `ensureOpenRc` checks the per-store marker `/var/lib/appine/openrc-setup-done`.
  On an unmarked store it checks apk offline. If OpenRC is already installed, it writes only the
  marker and leaves boot asynchronous. A staged `/var/cache/appine/install-openrc.sh` (including
  one left by an older app) resumes an incomplete installation even if the package is present.
- For a missing or pending install, setup rebuilds its private package cache from the APK's
  OpenRC bundle and libcap2 from its bubblewrap assets. The installer uses a temporary virtual
  package for missing dependencies, records openrc by name in world and removes the virtual package.
  Setup runs inittab before tabs open, verifies the lock directory and default runlevel, removes the
  cache and installer and writes the marker. Later removal persists. A failed migration on an
  existing store reports the error and allows a login for repairs. The next start retries.
  Failure during a new import propagates to startup.
- Both first and subsequent boots run `PREFER_OSCLOCK` without a console. It adds osclock to the boot runlevel when
  `rc-update` and the osclock service exist and no runlevel has hwclock, osclock or swclock (a
  dangling link counts); the thread waits for it, ignores its exit status and only logs an
  exception. On subsequent boots tabs can log in while inittab runs. After boot, `failedServices` lists the services `/var/log/boot.log` says failed to
  start, for the service's notification.

### Prompt marks

- Integrated bash, ash and zsh set OSC 2 to the full current `$PWD` at each primary prompt, with
  control characters replaced by `?`. Before execution, bash and zsh set OSC 2 to the submitted
  command line, also sanitized, once for the whole pipeline or compound command; for busybox ash
  (which has no preexec hook) and unmarked shells, `android/vtcore` falls back to the console's
  foreground process command line when a command sets no OSC 0/2 title. Programs can replace it with
  OSC 0/2 between prompts; the next primary prompt restores the directory.
  Bash sends the directory from `__appine_prompt`, zsh from precmd,
  and ash after the visible PS1 and B mark. Secondary prompts do not replace the title.
  Bash appends `$(__appine_preexec)` to PS0 once and snapshots `HISTCMD` at each prompt. The
  preexec function reads `history 1` with no timestamp only when history is enabled and its
  counter advanced; otherwise it reports `bash`, including ignored duplicate/space-prefixed
  commands, HISTIGNORE matches and disabled history. It does not install a DEBUG trap or
  change history settings. Zsh uses preexec's command argument, independent of history storage.
  The tab bar still shows numbers; these titles are available through long presses and TalkBack.
  Existing shells retain their loaded hooks until a new shell starts or the full profile is
  reloaded. Sourcing ashrc alone into an already-marked old PS1 skips its existing-mark guard.
- For the terminal's shell integration (android/vtcore) the profile has login shells mark their
  prompts with OSC 133:
  - bash: the profile sets the coloured PS1 and reads `appine.bashrc`, whose `__appine_prompt`
    function, put first in `PROMPT_COMMAND` (scalar or bash 5.1+ array, once, however often the
    file is read), prints, before each prompt, the last command's end with its status (D) and the
    prompt's start on a fresh line (A, `redraw=last;cl=line`), wraps PS1 (P with `k=i`, `k=c`
    after `\n` escapes and command-substitution-free literal newlines, … B, the input starting)
    and PS2 (`k=s`), and appends the output's start (C) to PS0, each again whenever it is missing,
    so a PS1 that `~/.bashrc` or anything later sets is wrapped from the next prompt on; a later
    plain assignment to `PROMPT_COMMAND` drops the function and with it every mark. On Alpine,
    `/etc/bash/bashrc` reads `/etc/bash/appine.sh`, hence `appine.bashrc`, in every interactive
    bash; on Debian and Arch, `ensureShellRcHooks` appends `DEBIAN_BASH_HOOK` once to
    `/etc/bash.bashrc` (gated by `/var/lib/appine/debian-bashrc-hook-done`), so a nested bash
    (`bash`, `su` without `-l`) marks its own prompt on every distro;
  - busybox ash, which has no hook before a command or a prompt (1.37 has no `PROMPT_COMMAND`):
    PS1 itself carries D with `$?` (expanded at each prompt and redraw), A with `cl=line`, `P;k=c`
    with `appine_lf=output` after `\n` escapes in multi-line prompts, and after the prompt B (the
    input starts); PS2 is P with `k=s` and B. ash marks no output start
    and breaks a command longer than the screen's width into rows itself, so A and P also carry
    `appine_lf=output`, the app's own option, asking the terminal to read ash's line feeds
    (android/vtcore): one ash breaks a line with continues the input, any other ends it. `appine.ashrc`
    calls `__appine_ash_path` to show the physical directory in the stock visible prompt
    (abbreviated under `HOME`) and the full logical `PWD` in the title. Both replace controls with
    `?` and double backslashes before BusyBox interprets the prompt escapes. Custom prompt text
    keeps its own path formatting. The script wraps unmarked PS1 and PS2 only in busybox ash.
    The profile sources it after setting its coloured PS1, and every interactive ash reads it through
    `ENV`, a login shell after `/etc/profile` and `~/.profile`, so a PS1 that `~/.profile` sets is
    marked; one set later (typed, or by a file the user's own `ENV` names) goes without.
  - zsh: the profile sets the coloured PS1 and reads `appine.zshrc`. On Debian (where
    `/etc/zsh/zprofile` does not read `/etc/profile`), `login.sh` starts login `zsh` with
    `ZDOTDIR=/etc/appine/zsh` when `ZDOTDIR` is unset; `/etc/appine/zsh/.zshenv` unsets `ZDOTDIR`
    immediately, sources `~/.zshenv`, and for interactive login shells on non-Alpine systems
    sources `/etc/profile.d/appine.sh` in sh emulation (with `__appine_profile_seen` guarding
    `cat /etc/motd` against double display if `~/.zprofile` also sources it). Once `zsh` is
    installed, `ensureShellRcHooks` appends `ZSH_RC_HOOK` to `/etc/zsh/zshrc` (Debian) or writes
    `/etc/zsh/zshrc` beside Alpine's `/etc/zsh/zprofile` once (gated by
    `/var/lib/appine/zsh-rc-hook-done`), so nested interactive `zsh` (`zsh`, `su` without `-l`)
    also loads `appine.zshrc`. `__appine_precmd`, appended to `precmd_functions`, prints D with
    the status before each prompt, restores saved clean prompts, wraps PS1 (A with `cl=line`,
    `k=c` after `$'\n'` on multi-line prompts, … B), PS2 (`k=s`, `k=c` after `$'\n'`, … B),
    non-empty `RPROMPT` (`k=r` on single-line PS1, `k=c` on multi-line PS1 so it keeps the
    continuation row mark, … B so right-prompt cells are prompt rather than input) and non-empty
    `RPS2` (`k=s` … B) in `%{ %}` (doubling a trailing bare `%`, or emitting `A;cl=line` directly
    when `prompt_percent` is unset), and moves itself last in `precmd_functions`;
    `__appine_preexec`, appended to `preexec_functions`, restores the clean prompts before
    commands and prints the output's start (C) and the command title. Reloading the profile or
    companion file deduplicates both hook registrations while preserving other hooks, including
    when sourced in sh emulation. A and B are in PS1, so every redraw by zle sends them again; D
    is sent once per prompt.
  - `cl=line` tells the terminal that the three line editors move the cursor with the left and
    right arrows, so a tap on the typed command moves the cursor there.
- Every login shell of a tab reads the profile (root's shell `-l`, and `su <account> -c … exec "$SHELL" -l`
  for others), including login `zsh` on Debian through `/etc/appine/zsh/.zshenv`. `ENV` is
  exported from every shell that reads the profile (and from `appine.ashrc` when unset), so a
  nested interactive ash that inherits it (`ash`, `sh` on Alpine, `su` without `-l`, also under
  bash or zsh) marks its own prompt, the distro's; on Alpine, Appine's `doas.d` rules
  (`20-wheel.conf` and `30-appine.conf`) pin `setenv { ENV=/etc/profile.d/appine.ashrc }` so
  `doas -s` / `doas sh` keeps ash's prompt marks too. Nested non-login `bash` (both distros) and
  `zsh` (once `ensureShellRcHooks` runs after `zsh` is installed) also get prompt marks. Other
  shells get no marks from it (fish and nushell send their own, and `android/vtcore` falls back to
  foreground-process detection for unmarked shells and overwritten ash `PS1`), and shells that do
  not read it still have `TERM`, `LANG` and `NMAP_UNPRIVILEGED` from the console's fixed login
  environment (android/vt), but show no motd.
- The shared profile contains no zsh array syntax; only zsh sources `appine.zshrc`. The companion
  uses an anonymous function with `emulate -L zsh` for registration, so Alpine's sh emulation
  does not change array filtering or indexing and the caller's options are restored afterwards.
  Both hooks also use local zsh emulation when invoked.

### Mirrors

- After obtaining the tarball, `prepare` starts the service's `probeMirrors` measurements in
  distro list order, one task per mirror. Each measures throughput, checking the 512 KiB and
  5 s thresholds between reads. The import proceeds while these tasks run.
- After local configuration, the importer chooses the highest completed successful speed, breaking
  ties in distro list order and falling back to the official mirror if no speed is available.
  It writes Alpine's `main` and `community` to `/etc/apk/repositories`, Debian's deb822
  HTTP sources for trixie, updates and security to `/etc/apt/sources.list.d/debian.sources`, or
  Arch's `/etc/pacman.d/mirrorlist` with `Server = <base>/$arch/$repo` lines, the selected mirror
  first and the rest after it, since pacman walks the list in order.
- The importer requests cancellation of outstanding probes before syncing and renaming the
  temporary store. Probe tasks only measure throughput. A ready store skips the entire import,
  so users can edit or remove sources in the guest.

### Accounts and login

- `loginAccount`: `auto` is the regular account (UID 1000–65533, a shell other than empty,
  `nologin` or `false`) with the lowest UID, else root; `root`; or a named passwd entry, falling
  back to root. `regularAccounts` lists the same accounts for `android/settings`. `login.sh` picks
  the account by the same rules, except that it does not require a numeric GID or all seven fields.
- `login.sh` ignores `SIGINT` (`trap '' INT`) by default so Ctrl-C cannot disrupt short setup
  commands (passwd lookup, group checks, shadow reads, rules publication, or the `su --help`
  probe), temporarily catches `SIGINT` (`trap 'interrupted=1' INT`, restoring default disposition
  in child processes) only around cancellable package-lock waits (`flock 9` in `locked`, `apk add
  --wait 3600`) and Debian `apt-get` update/sleep/install calls, and restores `trap - INT` right
  before `exec` into the user shell or `su`. It chooses wheel, doas and
  `/etc/doas.d/30-appine.conf` on Alpine (`/etc/alpine-release`), wheel, sudo and
  `/etc/sudoers.d/appine` on Arch Linux ARM (`/etc/arch-release`; Arch has no `addgroup`, so the
  group is joined with `usermod`), else sudo, sudo and `/etc/sudoers.d/appine`, picks the account, and:
  - every login, root's included: rewrite the NOPASSWD rules for recorded admins still in the
    group that have no password: a shadow field that, after any leading `!`s, is empty or `*`
    (`adduser -D` writes `!`); `passwd -l`'s `!` before a hash still counts as a password, and so
    do a missing shadow entry and an unreadable `/etc/shadow`. Duplicate or blank rows in
    `/var/lib/appine/admins` are skipped defensively. The file is written beside it,
    made 0440 and renamed into place; with nobody qualifying, or without the rules' directory
    (on Debian, until sudo is installed), it is deleted;
  - the first service poll for each machine runs `--refresh-rules` as root without a console.
    Later polls compare the inode, size, mtime and ctime of `/etc`, `/etc/passwd`, `/etc/group`,
    `/etc/shadow` and `/var/lib/appine/admins`. A changed or unavailable sample triggers
    another refresh. The worker starts the process and a separate thread waits for its exit.
    While the waiter is alive, polling starts no second refresh. A successful exit stores the
    sample taken before spawn. The next poll samples again. A missing sample always retries;
  - before choosing the account: install procps-ng, then bubblewrap offline when their cache directories
    exist, under the install lock, testing `apk info -e <package>` (BusyBox already provides ps/top/free),
    re-add each by name for upgrades, and delete its cache under the lock only on success. Failure
    leaves the cache for the next login and still opens a shell; later user removal is respected.
    This works with any login shell; `--refresh-rules` returns before installing;
  - every login whose account's passwd shell is `/bin/bash` while `/var/cache/appine/bash` exists:
    under the install lock, recheck the bundle, install its packages offline if `bash` is absent
    (`! apk info -e bash` or `[ ! -x /bin/bash ]`), add `bash` by name (so world records it and
    `apk upgrade` upgrades it), and delete the bundle only after that succeeds, so bash removed
    later is not reinstalled. If registration fails after the local packages installed, the session
    still execs `/bin/bash` and retries on the next login; if `/bin/bash` is missing, it falls back
    to `/bin/sh` and retries next login;
  - root: `cd` to the directory (else root's home, else `/`) and `exec` root's passwd shell (or
    `/bin/sh` when it is not executable) as a login shell;
  - any selected account other than `root` absent from `/var/lib/appine/admins` (matched literally):
    under `/run/appine-rules.lock`, recheck `admins`, add it to wheel (Alpine, atomically writing
    `permit persist setenv { ENV=/etc/profile.d/appine.ashrc } :wheel` to `20-wheel.conf` when
    absent or still the unmodified stock `permit persist :wheel`, or appending it once to a custom
    file lacking both; `refresh_rules` and `Rootfs.ensureLoginTools`/`updateProfile` also upgrade
    the unmodified stock file) or sudo (Debian), and append it to `admins` once it really is in the
    group (else warn and retry at the next login);
  - a selected non-root account (whether or not just made an admin) while its marker is missing:
    on Alpine (`/var/lib/appine/doas-installed`), under the install lock, recheck the marker,
    install `/var/cache/appine/doas.apk` if `doas` is not on PATH, run `apk_add doas` if just
    installed or apk-managed (`apk info -e doas`, leaving a custom non-apk `doas` alone), and
    create the marker only after that succeeds (retrying partial installs while respecting later
    user removal); on Debian and Arch (`/var/lib/appine/sudo-installed`), if `sudo` is not on PATH,
    install it from the network showing apt's progress (Ctrl-C skips until the next login; no install
    lock: `apt_update` retries `apt-get update` every 2 s while another apt holds the package lists'
    lock, saying so once and showing other errors and warnings afterward, and `apt-get install` waits
    up to an hour for dpkg's lock via `DPkg::Lock::Timeout`), then touch the marker once `sudo` is on
    PATH. Arch ships sudo, so there `sudo` is always on PATH and the apt branch (gated on
    `apt-get`) never runs: the marker is written at once;
  - the install lock: a `flock` on `/run/appine-install.lock` held around each install of a bundled
    package (`locked` runs `cancellable flock 9 && "$@"` so commands never run if acquiring the lock
    fails), so concurrent logins install bash, doas, procps-ng and bubblewrap one after another,
    each first rechecking completion state under the lock; each `apk add` (`apk_add`) that fails
    on apk's own lock, held by an apk the user runs, prints that another apk is running and is
    retried with `--wait 3600`, so the login waits until that apk ends; Ctrl-C stops the wait and
    skips the install until the next login;
  - switch with `su <account> -c '<cd dir or home>; exec "$SHELL" -l'` (`--session-command` when
    util-linux su offers it), adding `-s /bin/sh` when the account's shell is not executable (su
    would otherwise fail and the tab close); package commands read from `/dev/null` so early typing
    reaches the shell.

## Dependencies (inbound / outbound)

### Inbound

- `TerminalService` (`android/service`: start, import, switch, reset, the mirror probe, per-start
  files, boot, the poll's `LoginRules`, login accounts), `SettingsFragment` (`android/settings`:
  `Distro`, `installed`, `regularAccounts`, `loginAccount`), `Documents` (`android/documents`:
  `loginAccount`, `installed`, `isReady`, `access`), `ConsolePty` (`android/vt`: runs `login.sh`),
  the instrumentation tests (`fetch`, `prepare` into another store with supplied probe results, `updateProfile`,
  `PREFER_OSCLOCK`).

### Outbound

- `Native.importRootfs`, `syncRootfs`, `withStore`, `storeWriteFile`, `storeReadFile`,
  `writeFile` (creates parent directories, does not follow symlinks), `readFile` (null when
  missing), `loginRuleInputs`, `spawn` and `waitFor` (`android/native`);
  `HttpURLConnection` (system proxy); `BuildConfig` (Alpine branch); the bundled assets
  (`android/build`).

## Invariants and gotchas

- Reset advances the in-process rootfs generation under the write lock. Terminal imports check
  this generation before publishing a staged file.
- `Rootfs.access`: provider calls hold the read lock; starting the kernel and deleting the store
  hold the write lock, so the kernel's exclusive boot open never overlaps a provider open. The
  import (including package sources in the temporary store) and the per-start files run without it.
- A store becomes ready only when the synced import is renamed into place, so a half-imported
  `rootfs.tmp` never counts and is deleted by the next `prepare` or `reset`.
- An import interrupted by a kill (a first run, a distro switch, a reset) is redone with the same
  distro on the next launch, from the verified tarball still in the cache or by downloading it
  again with the usual progress; if that fails and the service falls back to Alpine,
  `Rootfs.deleteTarball` deletes the abandoned cached tarball (and any `.part` file) before
  starting the Alpine fallback import.
- Current imports into the default app store commit the distro record before importing.
  Legacy stores without the preference default to Alpine. An import into a separate test store
  leaves the preference alone but still uses and deletes the shared cached tarball.
- `writeFile` while the kernel runs is seen at once (the store's commit counter invalidates kernel
  caches).
- `updateProfile` replaces only the versions it knows, compared whole (`OLD_PROFILE` and
  `UNMARKED_PROFILE` by text, later ones by sha256 in `REPLACED_PROFILES`): changing `profile.sh`
  must add the sha256 of the text it replaces (the committed asset, byte for byte), or stores keep
  the version they have; `ashrc.sh`, `bashrc.sh` and `zshrc.sh` are written only with the profile,
  so a change to any companion alone reaches no existing store (change `profile.sh` with it); and
  the motd is written only at import, so it is never updated.
- apk takes its database lock without waiting unless given `--wait` (which apk 3 accepts though
  its help does not list it): hence the install lock and the retry with `--wait`; a tab whose login
  waits for an apk the user runs shows only that line until the apk ends or Ctrl-C. apt 3's
  `DPkg::Lock::Timeout` covers dpkg's frontend lock but not the package lists' lock, which
  `apt-get update` takes, hence the retries there; apt shows its own wait only on a terminal. The
  branch's mirrors keep only each package's latest build, so a rebuild of a pinned package makes a
  fresh `scripts/fetch-rootfs` fail until it is pinned anew.
- The marks rely on the shell redrawing its prompt on SIGWINCH (the terminal clears the prompt's
  rows on a resize; `android/vtcore`): bash, busybox ash and zsh do.
- First-login admin setup (`ensure_admin`) and the writer of the generated NOPASSWD rules
  (`refresh_rules`) share the root-only `/run/appine-rules.lock` (never nested with
  `/run/appine-install.lock`; both lockfiles are created under `umask 077`, with `ensure_admin` and
  `locked` restoring the caller's umask before modifying files or running commands). `refresh_rules`
  holds the lock from reading the accounts through publication or removal, and deduplicates repeated
  rows in `/var/lib/appine/admins`. A failed publication attempts to remove stale grants.
  Reading account files and publishing in the rules subdirectory do not change the sampled
  inputs. The service polls every 2 s independently of the Files app's directory notifications.
- `login.sh` runs without job control (its children share its process group), so `SIGINT` stays
  ignored except inside `cancellable` waits/installs (`locked` uses a braced group rather than a
  subshell so `interrupted=1` propagates while fd 9 still closes on exit) and is reset with
  `trap - INT` immediately before every `exec`.

## Confirmed bugs / technical debt

None.

## Open questions

None.

## To verify

- Alpine `.bash_profile`/`.bashrc` seeding on 16 KB-page devices and live `TerminalService`
  upgrade cold starts (4 KB-page API 36 instrumentation tests passed).
- Android device execution and end-to-end migration of the extracted `zshrc.sh` companion (host
  zsh native/sh-emulation and ash/dash profile checks passed).
- Browser defaults and Codex authorization flow on Android (host container PTY checks passed;
  existing stores receive the profile update at restart only when unmodified).
- Shell command titles with custom prompt frameworks, history changes in later `PROMPT_COMMAND`
  entries and live upgrades of already-running shells.
- That Alpine's doas reads `/etc/doas.d/*.conf` in lexical order (the NOPASSWD file relies on coming
  after `20-wheel.conf`), and that doas reads only `*.conf` and sudo skips names with a dot (the
  temporary rules files rely on it).
- The profile's bash marks in the app on Debian (verified in Debian trixie container for nested
  bash and on Pixel 4a API 34 emulator for Alpine multi-line PS1/hook installation) and with a
  prompt tool that rewrites PS1 after it each time.
- The profile's zsh marks in the app (verified in macOS zsh 5.9 PTY, Alpine/Debian trixie
  containers, and `VtShellIntegrationTest` on Pixel 4a API 34 emulator for right prompts,
  multi-line PS1 continuations, `nopromptpercent` and Debian `ZDOTDIR`/rc hooks) with third-party
  prompt frameworks (oh-my-zsh, powerlevel10k).
