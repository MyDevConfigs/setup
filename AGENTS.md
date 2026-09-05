# AGENTS.md

Instructions for AI agents working in this repository. Read this before
changing anything.

`CLAUDE.md` is a symlink to this file.

---

## What this repository is

A provisioning script for a development machine. Running `./setup.sh` on a
fresh install brings it to a working state: shell, CLI tools, compilers,
language toolchains, applications.

**It is not the dotfiles repository.** Configuration files live in a separate
repo, deployed with GNU Stow. Keep the boundary sharp:

| This repo (`setup`) | The dotfiles repo |
| --- | --- |
| Installs *software* | Deploys *configuration* |
| `apt`, `rustup`, release tarballs | Symlinks into `~/.config` |
| Runs once per machine | Tracked, edited continuously |

If a change is about *what file lives where in `~`*, it belongs in dotfiles,
not here. The one exception is the shell rc file (`~/.zshrc` or
`~/.bashrc`, depending on the configured shell), which this repo writes
`PATH` and environment lines into — see below.

---

## Hard requirements

These are settled decisions. Do not revisit them without being asked.

### A configured shell is mandatory; which shell is a choice

`modules/00-shell.sh` is marked `# module-required: true`, so it runs on
every invocation and `--skip shell` cannot exclude it.

It is required rather than merely first because it *guarantees the file the
rest of the repo writes to exists*. oh-my-zsh generates `~/.zshrc`; if a
later module wrote its PATH line into a `~/.zshrc` that did not yet exist,
oh-my-zsh would later back that file up and replace it, silently discarding
the line.

**The requirement is "a configured shell", not "zsh".** Do not hard-code zsh
anywhere. The choice resolves in this order, highest first:

1. `SETUP_SHELL` in the environment — `SETUP_SHELL=bash ./setup.sh`
2. `.setup.local` in the repo root, written by a previous interactive run
3. An interactive prompt, asked once by `shell::choose`
4. `SHELL_DEFAULT` (zsh), with a warning, when there is no terminal

`.setup.local` is gitignored on purpose: it records what *this machine*
answered, so a fresh clone asks again rather than inheriting the answer.

`shell::load` runs during bootstrap and **must never prompt** — `--list` and
standalone module runs both reach it. Only `shell::choose`, called once by
`setup.sh` before any module, is allowed to ask.

A second knob, `SETUP_ZSH_FRAMEWORK` (`oh-my-zsh` | `none`), selects the zsh
framework so bare zsh is reachable without being a different shell.

### Everything shell-related goes through `lib/shell.sh`

A module that needs to extend `PATH`, export a variable, or source an env
file **must** use these. Never append with a bare `>>`, never name an rc
file, never assume `~/.zshrc`:

```bash
shell::add_path   "$HOME/.local/bin"
shell::set_env    EDITOR nvim
shell::source_file "$HOME/.cargo/env"
```

These are **semantic**, not raw text, and that is deliberate. fish is not
POSIX: `export PATH="x:$PATH"` is a syntax error there and the equivalent is
`fish_add_path x`. Describing the intent lets the per-shell backend render
it, so adding fish never touches a module. Prefer these three over anything
else.

Pass a **real, expanded path** — `"$HOME/.local/bin"`, not `'$HOME/.local/bin'`.
The renderers fold a leading `$HOME` back into the literal string at print
time, so the rc file ends up with `$HOME/.local/bin` while the module still
has a path it can hand to `util::ensure_dir` or test with `[[ -f ]]`. The
predicates fold identically, and also recognize the expanded form written by
older versions of this repo, so the change did not duplicate anyone's lines.

Two escape hatches take opaque text and are therefore **POSIX-only**. Both
abort on a non-POSIX shell rather than writing something broken:

```bash
shell::add_line  '<raw posix line>'
shell::add_block 'nvm' "$content"     # multi-line, fenced with markers
```

Matching predicates exist for all of them — `shell::has_path`,
`has_env`, `has_source`, `has_line`, `has_block`. The writers already skip a
line that is present, so these are not needed to avoid a duplicate append.
Use them to skip the *work that produces* the line when that work is
expensive — downloading an installer, cloning a plugin repo:

```bash
if ! shell::has_source "$HOME/.nvm/nvm.sh"; then
    install_nvm
    shell::source_file "$HOME/.nvm/nvm.sh"
fi
```

They are pure reads, so unlike the writers they carry no POSIX guard.

Everything here is idempotent and honors `--dry-run`. It is centralized
because rustup, nvm and pyenv all append their loader line *unconditionally*,
so letting each do its own thing means a second run duplicates them.

When a third-party installer offers a flag to suppress its own rc editing,
use it — `rustup ... --no-modify-path`, `oh-my-zsh ... --unattended` — and
add the line through this interface instead.

### Adding a shell

`lib/shell.sh` dispatches on `SETUP_SHELL`, exactly like `lib/pkg.sh`
dispatches on `OS_FAMILY`. zsh and bash are implemented. fish has a complete
backend that is **gated off** by `_shell::fish::assert_supported` because it
is untested; enabling it means verifying it and removing that guard, not
writing new code, and no module changes.

A backend implements: `rc_path`, `is_posix`, `render_path`, `render_env`,
`render_source`, `assert_supported`.

### Where things get installed

**`~/.local/bin` belongs to the user.** It holds their own scripts. Nothing
this repository installs may be placed there, ever — not a release binary,
not a symlink, not a shim. `00-shell.sh` creates it and puts it on PATH, and
that is the only involvement this repo has with it.

Everything else goes where its own documentation says to put it:

| Destination | For | Examples |
| --- | --- | --- |
| The tool's own home | Version managers that own a directory | `~/.nvm`, `~/.pyenv`, `~/.sdkman`, `~/.bun`, `~/.cargo` |
| `/opt/<name>` | Self-contained upstream trees | neovim → `/opt/nvim` |
| `/usr/local/bin` | Single binaries installed system-wide | lazygit, starship, task, uv |
| `/usr/bin` | Anything from the distro archive | delta, bat, eza, gh |

When an installer defaults to `~/.local/bin`, override it — `uv` takes
`UV_INSTALL_DIR`, most others take a `-b` or `--bin-dir` flag. If one cannot
be redirected, install it another way rather than letting it write there.

`/usr/local/bin` is also where a canonical-name symlink goes when Debian
renames a binary (`fdfind` → `fd`, `batcat` → `bat`); see
`cli::link_canonical_name` in `modules/11-cli.sh`.

### Bash, not Python

`setup.sh` bootstraps a *fresh* machine, where `python3`, `pip` and any
third-party module may not exist. A provisioning script that needs
provisioning first is the wrong shape. Bash 4+ is assumed and checked.

### Toolchains are installed, never upgraded

If Go or Rust is already present, report the version and move on. Do not run
`rustup update` or `apt upgrade`. Provisioning and upgrading are separate
concerns: re-running `setup.sh` must never move a compiler under a project
that is mid-build. Upgrades stay explicit and manual.

### Rust comes from rustup, never from apt

`apt install cargo` installs a second Rust that dpkg owns, pinned to whatever
the distro release froze, unable to `rustup update` or switch toolchains per
project. On a machine that already has rustup the two coexist and PATH order
silently decides which compiler a build uses.

This is the canonical example of why there are **two kinds of installed
check** — see below.

---

## Architecture

```
setup.sh              entrypoint: arg parsing, module discovery, orchestration
lib/
  bootstrap.sh        single source point; resolves SETUP_ROOT
  log.sh              leveled, colored logging
  os.sh               distro detection -> OS_FAMILY / OS_ARCH
  pkg.sh              package-manager abstraction  (dispatches on OS_FAMILY)
  shell.sh            shell rc contract            (dispatches on SETUP_SHELL)
  util.sh             run/sudo/download/version helpers
modules/
  NN-<name>.sh        one installable concern each
.setup.local          machine-local choices, gitignored
```

Both `pkg.sh` and `shell.sh` follow the same pattern, and any future
abstraction should too: a generic API on top, family dispatch below, real
implementations for what is supported, and stubs that fail loudly for what
is not. No module ever names a package manager or an rc file.

### The two kinds of "already installed" check

Getting this wrong is the most likely way to break a working machine.

| Use | When | Asks |
| --- | --- | --- |
| `pkg::install foo` | The package manager owns it | `dpkg-query` |
| `util::ensure_command foo "Label" installer_fn` | It has its own installer | `command -v` |

`pkg::is_installed cargo` reports **missing** on a machine that has cargo via
rustup, because dpkg genuinely does not own it. Anything installed by
`curl | sh`, a release tarball, or a version manager must be checked at the
command level.

### Modules

A module is `modules/NN-<name>.sh`. The `NN` prefix orders execution;
`<name>` is what `--only` and `--skip` match.

Header contract:

```bash
#!/usr/bin/env bash
# module-description: One line, shown by --list
# module-required: true          # optional; runs even when filters exclude it
```

Rules every module follows:

- **Idempotent.** Safe to run on a fully-provisioned machine. A no-op run
  should print skips, make no network calls, and exit 0.
- **Standalone.** Sources `lib/bootstrap.sh` by relative path, so
  `./modules/30-langs.sh` works on its own. Do not rely on `setup.sh` having
  exported anything except the documented `SETUP_*` flags.
- **Own process.** `setup.sh` runs each with `bash "$path"`. Modules cannot
  share variables or functions; if two need the same helper, it goes in
  `lib/`.
- **Strict mode.** `set -o errexit -o nounset -o pipefail -o errtrace`.
- **All mutations through `util::run` / `util::sudo`**, so `--dry-run` is
  honored in one place rather than forty.

Group modules **by install mechanism, not by topic** — the mechanism is what
determines the code. Plain apt packages, third-party apt repositories
(`pkg::add_apt_repo`, see `40-gh.sh`), things with their own installers, and
build-only headers are all different kinds of work.

### Configuration modules never overwrite

`60-gitconfig.sh` is the pattern for anything that configures rather than
installs: read the current value, and if it is set, **report it and move
on**. Only fill in blanks. A module that stamps its own opinion over a
setting the user tuned by hand is a module they will stop running.

Where there is no safe default — a name, an email address — offer none and
say what to run later. Guessing an identity and putting it on every future
commit is worse than leaving it unset.

Configuration modules run last, so their prompts land after the long package
output rather than interleaved with it.

### Adding a distro

`lib/pkg.sh` dispatches on `OS_FAMILY`. Only `debian` is implemented; the
others are deliberate stubs that fail with a clear message.

To add one: fill in the four `_pkg::<family>::*` functions, and add entries
to `PKG_ALIASES` / `PKG_BINARIES` for names that differ. Nothing above those
functions changes, and no module changes.

Note that `modules/20-buildlibs.sh` calls `os::require_family debian` because
`-dev` package names diverge too far to alias casually (`libgtk-3-dev` is
`gtk3` on Arch, `gtk3-devel` on Fedora). That guard needs revisiting when a
second family is implemented.

---

## Working with the user

### Git

**The user creates repositories and links remotes himself.** Do not run
`git init`, `git remote add`, `gh repo create`, or `git push`. Create the
directory and files; stop there and report.

**Commit only when asked.** Use conventional commits (`feat:`, `fix:`,
`chore:`, `docs:`) with a scope. Split genuinely unrelated changes into
separate commits.

### Process

The user prefers to **discuss a design before it is written**, and to guide
multi-step work one step at a time. When a request has real forks in it,
raise them and ask rather than scaffolding everything and asking forgiveness.

Do not install packages or change system state that was not asked for.

---

## Testing

There is no test suite. Before committing:

```bash
bash -n setup.sh lib/*.sh modules/*.sh   # syntax
shellcheck -x setup.sh lib/*.sh modules/*.sh
./setup.sh --dry-run                     # full run, no changes
./setup.sh --dry-run --only <module>     # one module
./modules/NN-name.sh                     # standalone execution
```

`--dry-run` is the primary safety net. Every state-changing path must be
reachable under it without actually changing anything.

---

## Bash gotchas already hit in this repo

Do not reintroduce these. All three were live bugs here.

**`read` returns non-zero at EOF.** When its input has no trailing newline,
`read` assigns the variables correctly and *still* returns 1. Under
`errexit` that kills the script. Always emit a trailing newline into a
`read` (see `os::detect`).

**`curl | grep -m1` is a race.** `grep -m1` exits at the first match, curl
takes SIGPIPE, and `pipefail` reports the pipeline as failed — but only
sometimes, depending on which process finishes first. Fetch into a variable
first, then parse. The same applies to `| head -n1`, which is why
`util::first_line cmd args` exists — use it rather than piping into `head`.

**`return 1` fires the ERR trap.** With `errtrace` on, returning non-zero to
signal an expected outcome prints a spurious "Failed at line N". Record the
outcome in a variable and let the caller convert it to an exit status (see
`FAILED_COUNT`).

**Command substitution runs in a subshell.** A function called as
`x="$(f)"` cannot register anything in a shell variable for a later trap to
find. `util::tmpdir` works around this by naming directories after `$$`,
which is identical inside subshells.
