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
| `cli` | ripgrep, fd, bat, eza, jq, delta, direnv, tmux, zoxide, btop, just, atuin |
| `zshplugins` | zsh-autosuggestions, zsh-syntax-highlighting (zsh only) |
| `buildlibs` | sassc, libdrm-dev, libgtk-3-dev, libgdm-dev — headers for building Wayland/GTK tools from source |
| `langs` | Go (apt), Rust (rustup) |
| `node` | nvm, Node LTS, corepack (yarn + pnpm), bun |
| `python` | pyenv + build deps, latest CPython, uv |
| `java` | SDKMAN with Java LTS, Gradle, Kotlin |
| `dotnet` | .NET 10 SDK, `~/.dotnet/tools` on PATH |
| `gh` | GitHub CLI, from GitHub's own apt repository |
| `neovim` | Neovim AppImage → `/opt/nvim`, plus `$EDITOR` and the `editor` alternative |
| `tools` | lazygit, starship (+ Gruvbox Rainbow), Task — all to `/usr/local/bin` |
| `apps` | timeshift |
| `gitconfig` | git identity, default branch, pull strategy, commit editor, delta as pager |

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
effect at your next login**, not immediately. It also creates `~/.local/bin`
and puts it on `PATH` — **reserved for your own scripts**; nothing this repo
installs is placed there. Ubuntu's stock `~/.profile` adds that directory
only if it already exists at login, and nothing adds it for zsh at all.

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
  11-cli.sh           modern CLI tools from the archive
  12-zshplugins.sh    zsh autosuggestions + syntax highlighting
  20-buildlibs.sh     -dev headers
  30-langs.sh         Go, Rust
  32-node.sh          nvm, Node, corepack, bun
  33-python.sh        pyenv, CPython, uv
  34-java.sh          SDKMAN: Java, Gradle, Kotlin
  35-dotnet.sh        .NET 10 SDK
  40-gh.sh            GitHub CLI (third-party apt repo)
  41-neovim.sh        Neovim AppImage -> /opt/nvim
  42-tools.sh         lazygit, starship, Task -> /usr/local/bin
  50-apps.sh          desktop applications
  60-gitconfig.sh     git global settings (prompts, runs last)
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

Rules worth knowing:

- **Use generic package names.** `pkg::install fd` resolves to `fd-find` on
  Debian and `fd` on Arch via the lookup tables in `lib/pkg.sh`. Where a
  distro also renames the *binary* — Debian ships `fd` as `fdfind` and `bat`
  as `batcat` — `pkg::binary_for fd` returns the real name.
- **Package-installed and command-installed are different checks.** Use
  `pkg::install` for anything the package manager owns, and
  `util::ensure_command` for anything with its own installer (rustup, nvm, a
  release tarball). `pkg::is_installed cargo` reports missing on a machine
  that has cargo through rustup.
- **Third-party apt repositories go through `pkg::add_apt_repo`.** It writes
  a `signed-by` keyring and sources file, idempotently, and refreshes the
  index afterwards. See `modules/40-gh.sh`.
- **Skip expensive work, not just the write.** `shell::add_path` and friends
  already skip a line that is present. The `shell::has_*` predicates let you
  skip the work that *produces* it:

  ```bash
  if ! shell::has_source "$HOME/.nvm/nvm.sh"; then
      install_nvm                              # the expensive part
      shell::source_file "$HOME/.nvm/nvm.sh"
  fi
  ```

- **Never `| head -n1`.** Use `util::first_line cmd args`. Under `pipefail`,
  `head` exiting early kills the producer with SIGPIPE and fails the
  pipeline — intermittently, which is the worst kind of bug.

---

## Adding a distro

`lib/pkg.sh` dispatches on `OS_FAMILY`. Only Debian/Ubuntu is implemented;
Fedora and Arch are stubs that fail with a clear message rather than doing
something wrong.

To add one, fill in the four `_pkg::<family>::*` functions at the bottom of
`lib/pkg.sh` and add any differing names to `PKG_ALIASES` / `PKG_BINARIES`.
Nothing else changes — no module references a package manager directly.

---

## Where things get installed

**`~/.local/bin` is yours** — for your own scripts. Nothing this repo
installs goes there. Everything else lands where its own documentation says:

| Destination | For |
| --- | --- |
| The tool's own home | `~/.nvm`, `~/.pyenv`, `~/.sdkman`, `~/.bun`, `~/.cargo` |
| `/opt/<name>` | Self-contained upstream trees — neovim → `/opt/nvim` |
| `/usr/local/bin` | Single upstream binaries — lazygit, starship, task, uv |
| `/usr/bin` | Anything from the distro archive |

Installers that default to `~/.local/bin` are redirected: `uv` via
`UV_INSTALL_DIR`, others via a `-b` / `--bin-dir` flag.

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
