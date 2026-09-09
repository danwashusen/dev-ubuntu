# Ubuntu ARM64 developer workstation

An Ansible project for turning a fresh **Ubuntu Server 26.04.1 LTS ARM64**
guest in Parallels Desktop into a lean, keyboard-first developer workstation.
It installs Hyprland without a conventional desktop environment, keeps Ubuntu's
netplan/systemd-networkd networking, and uses lightweight desktop components.

## What it installs

- Base OS tools and Parallels Tools build prerequisites
- zsh, Starship, Neovim, tmux, lazygit, GitHub CLI, and modern CLI utilities
- Firefox from Mozilla's DEB repository (not Snap)
- Google Chrome for Linux ARM64, Visual Studio Code ARM64, mise, and Claude Code
- Docker Engine, Buildx, and Compose from Docker's repository
- Hyprland, greetd/agreety, Ghostty, Waybar, fuzzel, mako, Nautilus, PipeWire,
  portals, clipboard history, locking, and screenshot tools

The project intentionally does **not** install GNOME/KDE, `ubuntu-desktop`,
GDM/SDDM, NetworkManager, a dock, or desktop icons.

## Prerequisites

1. Create an Ubuntu Server 26.04.1 LTS ARM64 VM in Parallels Desktop.
2. Create a normal user with sudo access and enable SSH during installation.
3. Make sure the Mac can reach the VM over SSH.
4. On the Mac, install Ansible (for example, `brew install ansible`).
5. Prefer an SSH key. Password authentication also works with the flags below.

Only modules included with `ansible-core` are used; no Galaxy collections are
required.

Ubuntu 26.04 uses `sudo-rs` by default. Older Ansible controllers do not
recognise its authentication prompt, so this project sets Ansible's privilege
escalation executable to Ubuntu's supported `/usr/bin/sudo.ws` compatibility
implementation. This affects Ansible only; interactive `sudo` remains
`sudo-rs`.

## Inventory and variables

Replace both placeholders in `inventory.ini`:

```ini
[workstation]
ubuntu-vm ansible_host=YOUR_HOST_OR_IP ansible_user=YOUR_USER
```

Set the same account in `group_vars/all.yml`:

```yaml
workstation_user: YOUR_USER
```

The main switches live in `group_vars/all.yml`. Firefox, Chrome, VS Code, mise,
Claude Code, Docker, and Snap removal are enabled by default. Set
`remove_snapd: false` if the VM needs any snaps. Useful display settings include
`hyprland_scale`, `hyprland_main_modifier`, `keyboard_layout`, and
`ghostty_font_size`. The main modifier defaults to `ALT SUPER`, requiring
Option+Command together for Hyprland shortcuts in Parallels. Ghostty defaults
to scoped Mesa software rendering through `ghostty_force_software_rendering`
because Parallels virgl does not expose Ghostty's required OpenGL version.

Before its first apt operation, the base role compares the VM's UTC clock with
the Ansible controller. If their difference exceeds
`maximum_clock_skew_seconds`, it corrects the guest and restarts chrony. This
prevents apt from rejecting signed repository metadata as not valid yet after
the VM has been suspended or restored.

Set `parallels_vm_name` to the VM's exact name in Parallels Desktop. With
`prepare_parallels_tools_media: true`, the playbook checks inside Ubuntu for
an installed `parallels-tools` package or Tools executable. Only when Tools is
absent does it ask the Mac's `prlctl` to attach the bundled ARM64 ISO. It reuses
an already attached or mounted Parallels Tools disc and never runs the vendor
installer automatically.

The shell role clones [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh) and
[Powerlevel10k](https://github.com/romkatv/powerlevel10k) into the workstation
user's standard directories. It keeps `.zshrc` Linux-specific and managed by
Ansible; it does not copy the controller's complete `.zshrc`. When available,
the role copies the controller's `.p10k.zsh` and MesloLGS NF fonts, controlled
by `sync_controller_powerlevel10k_config` and
`sync_controller_powerlevel10k_fonts`. Override the controller paths in
`group_vars/all.yml` when running the playbook from a different machine.

The shell role also conditionally copies the controller's `.gitconfig` and
`.gitconfig-higeia` without storing either file in the project. Missing files
are skipped. Control this with `sync_controller_git_config`,
`controller_git_config_dir`, and `controller_git_config_files`.

The developer-apps role also conditionally copies these items from the
controller's `~/.claude`: `hooks/block-commands.sh`,
`statusline-command.sh`, `output-styles`, and `settings.json`.
Missing items are skipped. Files are copied with restrictive permissions and
`output-styles` is merged with its target rather than deleting VM-only content.
The controller home path in the hook is rewritten for the workstation account.
The `~/.claude/plugins` tree is deliberately not synchronized. Control this with
`sync_controller_claude_config` and the `controller_claude_*` variables in
`group_vars/all.yml`. The controller's personal files are never stored in this
project.

The playbook deliberately refuses to run unless the target reports Ubuntu 26.04
(Resolute) on `aarch64` and all placeholders have been replaced.

## Validate and run

From this directory, check connectivity and syntax:

```bash
ansible -i inventory.ini workstation -m ping
ansible-playbook -i inventory.ini site.yml --syntax-check
```

Provision with SSH keys:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

With SSH password authentication:

```bash
ansible-playbook -i inventory.ini site.yml --ask-pass --ask-become-pass
```

Roles are independently taggable. For example:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags shell,developer_apps
```

To prepare only the Parallels Tools installation media when Tools is absent:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags parallels_tools
```

To synchronize only the selected Claude Code configuration:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags claude_config
```

To synchronize only the selected Git configuration:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags git_config
```

The default does not reboot. Reboot manually when convenient, or set
`reboot_after_provision: true`. Log out and back in after provisioning so Docker
group membership and the zsh login shell take effect.

## Parallels Tools

The base role installs `dkms`, `libelf-dev`, `build-essential`, `pkg-config`, and
headers for the running kernel. The `parallels_tools` role conditionally makes
the matching installer media accessible inside the VM, but Parallels Tools
remains an interactive vendor installer.

After the role reports the installer path, run its `install` program with sudo.
For example, if the role mounted the image at its default location:

```bash
cd /media/cdrom0
sudo ./install
```

A VM snapshot immediately before this step is sensible.
If the kernel was upgraded by the playbook, reboot before installing the tools
so the running kernel and installed headers agree.

Wayland integration in Parallels can vary by Parallels Tools release. Test
dynamic resolution, shared clipboard, pointer behaviour, audio, and shared
folders before treating the VM as finished.

## Software ownership boundary

Ubuntu's package manager owns durable workstation software: Hyprland and its
desktop services, browsers, VS Code, Docker, shells, editors, CLI utilities, and
mise itself. Claude Code is the deliberate exception: its vendor-recommended
native installer owns that application and its updates.

Oh My Zsh and Powerlevel10k are treated as user-shell configuration rather
than workstation software. The shell role manages their Git checkouts and
disables Oh My Zsh's independent updater.

mise owns rapidly changing developer runtimes and toolchains such as Node.js,
Ruby, Python, Go, Terraform/OpenTofu, and project-specific utilities. Do not add
those runtimes to the base or shell roles. Declare them per project in
`mise.toml`, for example:

```toml
[tools]
node = "24"
ruby = "4"
python = "3.14"
```

This keeps the operating system boring and stable while projects select the
toolchain versions they need.

## Default Hyprland keys

| Keys | Action |
| --- | --- |
| `ALT+SUPER+Enter` | Ghostty |
| `ALT+SUPER+Space` | fuzzel launcher |
| `ALT+SUPER+B` | Google Chrome |
| `ALT+SUPER+Shift+B` | Firefox |
| `ALT+SUPER+C` | Visual Studio Code |
| `ALT+SUPER+E` | Nautilus |
| `ALT+SUPER+P` | Clipboard history |
| `ALT+SUPER+Shift+S` | Select area and copy screenshot |
| `ALT+SUPER+L` | Lock session |
| `ALT+SUPER+1..9` | Select workspace |
| `ALT+SUPER+Shift+1..9` | Move window to workspace |
