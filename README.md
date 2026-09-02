# setup

Provisioning script for a development machine. One command takes a fresh
Ubuntu install to a working environment: shell, CLI tools, compilers,
language toolchains, applications.

Configuration files are **not** here — those live in a separate dotfiles
repository, deployed with GNU Stow. This repo installs software; that one
deploys config.

---

## Quick start

```bash
git clone <this-repo> ~/setup
cd ~/setup

./setup.sh --list        # see what would run
./setup.sh --dry-run     # see exactly what it would do, change nothing
./setup.sh               # do it
```

Running it on an already-provisioned machine is safe. Every module is
idempotent: it checks what is present, skips it, and moves on.

---

## Options

| Flag | Effect |
| --- | --- |
| `-l`, `--list` | List available modules and exit |
| `-o`, `--only <a,b>` | Run only these modules |
| `-s`, `--skip <a,b>` | Run everything except these |
| `-n`, `--dry-run` | Print every command, execute nothing |
| `-y`, `--yes` | Answer yes to all prompts (unattended runs) |
| `-v`, `--verbose` | Show debug output, including each command |
| `-q`, `--quiet` | Warnings and errors only |
| `-h`, `--help` | Show help |

`GITHUB_TOKEN` raises the GitHub API rate limit used when resolving the
latest release of a tool. `NO_COLOR` disables colored output.

---

## Modules

| Module | Installs |
| --- | --- |
| `shell` **(required)** | The shell you chose, and makes it your login shell |
| `core` | git, curl, wget, build-essential, clang, cmake, pkg-config, perl, unzip, fzf, stow, shellcheck |
| `buildlibs` | sassc, libdrm-dev, libgtk-3-dev, libgdm-dev — headers for building Wayland/GTK tools from source |
| `langs` | Go (apt), Rust (rustup) |
| `apps` | timeshift |

`shell` is marked required: it runs on every invocation and `--skip shell`
will not exclude it. Every other module writes its `PATH` and environment
lines into your shell's rc file, and `shell` is what guarantees that file
exists first.

Run a subset:

```bash
./setup.sh --only core,langs     # shell still runs — it is required
./setup.sh --skip buildlibs      # on a machine that never compiles
./setup.sh --skip apps           # on a headless machine
```

Each module also runs standalone, which is the fastest way to iterate on one:

```bash
./modules/30-langs.sh
```

---

## Choosing your shell

The first run asks:

```
  Which shell should this machine use?
    zsh   with oh-my-zsh (default)
    bash  bare, using the existing ~/.bashrc

  ? shell [zsh/bash]
```

The answer is saved to `.setup.local`, which is gitignored — it records what
*this* machine chose, so a fresh clone asks again. Delete the file to be
asked once more.

You can skip the prompt entirely:

```bash
SETUP_SHELL=bash ./setup.sh                       # for one run
SETUP_ZSH_FRAMEWORK=none SETUP_SHELL=zsh ./setup.sh   # bare zsh, no oh-my-zsh
```

The environment wins over `.setup.local`, which wins over the prompt. With
no terminal and nothing configured — a CI run, or `--yes` — it defaults to
zsh and says so.

**fish** has a complete backend in `lib/shell.sh` but is gated off until it
has been tested. Choosing it fails with a message pointing at the guard.

### What it does

`shell` sets your chosen shell as the login shell via `chsh`. **This takes
effect at your next login**, not immediately.

Modules that need to extend `PATH` or source an env file go through
`lib/shell.sh`, which writes to whichever rc file your shell uses —
`~/.zshrc` or `~/.bashrc`. Writes are idempotent, so re-running never
duplicates a line.

Modules describe *intent* rather than shell syntax:

```bash
shell::add_path   "$HOME/.local/bin"
shell::set_env    EDITOR nvim
shell::source_file "$HOME/.cargo/env"
```

The backend renders each one for the configured shell. That matters because
fish is not POSIX — `export PATH="x:$PATH"` is a syntax error there, and the
equivalent is `fish_add_path x` — so a module that wrote raw shell text
could never work under it.

Third-party installers are told not to edit rc files themselves
(`rustup --no-modify-path`, `oh-my-zsh --unattended`), because they append
unconditionally and would duplicate their lines on a second run.

---

## Layout

```
setup.sh              entrypoint: arg parsing, discovery, orchestration
lib/
  bootstrap.sh        single source point for the library
  log.sh              leveled, colored logging
  os.sh               distro detection -> OS_FAMILY / OS_ARCH
  pkg.sh              package-manager abstraction
  shell.sh            shell rc contract (dispatches on SETUP_SHELL)
  util.sh             run/sudo/download/version helpers
modules/
  00-shell.sh         chosen shell + framework [required]
  10-core.sh          base tools and compilers
  20-buildlibs.sh     -dev headers
  30-langs.sh         Go, Rust
  50-apps.sh          desktop applications
```

Modules run in their own process, so a failure is contained and no module
can leak variables or functions into another. The numeric prefix sets order.

---

## Adding a module

Create `modules/NN-<name>.sh`, make it executable, and give it the header:

```bash
#!/usr/bin/env bash
# module-description: One line, shown by --list

set -o errexit -o nounset -o pipefail -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

pkg::install ripgrep bat jq
```

`--list` picks it up automatically. Add `# module-required: true` to make it
run even when `--only` or `--skip` would exclude it.

Two rules worth knowing:

- **Use generic package names.** `pkg::install fd` resolves to `fd-find` on
  Debian and `fd` on Arch via the lookup tables in `lib/pkg.sh`. Where a
  distro also renames the *binary* — Debian ships `fd` as `fdfind` and `bat`
  as `batcat` — `pkg::binary_for fd` returns the real name.
- **Package-installed and command-installed are different checks.** Use
  `pkg::install` for anything the package manager owns, and
  `util::ensure_command` for anything with its own installer (rustup, nvm, a
  release tarball). `pkg::is_installed cargo` reports missing on a machine
  that has cargo through rustup.

---

## Adding a distro

`lib/pkg.sh` dispatches on `OS_FAMILY`. Only Debian/Ubuntu is implemented;
Fedora and Arch are stubs that fail with a clear message rather than doing
something wrong.

To add one, fill in the four `_pkg::<family>::*` functions at the bottom of
`lib/pkg.sh` and add any differing names to `PKG_ALIASES` / `PKG_BINARIES`.
Nothing else changes — no module references a package manager directly.

---

## Adding a shell

`lib/shell.sh` works the same way, dispatching on `SETUP_SHELL`. zsh and bash
are implemented. fish has a complete backend that is gated off by
`_shell::fish::assert_supported` because it is untested — enabling it means
verifying it and removing that guard, not writing new code.

A backend implements six functions:

| Function | Returns |
| --- | --- |
| `rc_path` | The rc file to write to |
| `is_posix` | Whether `shell::add_line` / `add_block` are usable |
| `render_path <dir>` | A line that prepends `<dir>` to `PATH` |
| `render_env <name> <value>` | A line that exports a variable |
| `render_source <path>` | A line that sources a file |
| `assert_supported` | Nothing, or dies if the backend is not ready |

No module changes when you add one — that is the point of the semantic API.

---

## Development

```bash
bash -n setup.sh lib/*.sh modules/*.sh     # syntax
shellcheck -x setup.sh lib/*.sh modules/*.sh
./setup.sh --dry-run                       # full run, no changes
```

`--dry-run` is the safety net: every state-changing path routes through
`util::run` or `util::sudo`, so it prints rather than executes.

See [AGENTS.md](AGENTS.md) for the conventions and design decisions behind
all of this.
