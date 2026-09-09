# Project guidance

This repository provisions a lean Ubuntu Server 26.04 LTS ARM64 developer workstation running in Parallels Desktop.

- Keep roles small, modular, and independently taggable.
- Prefer idempotent `ansible.builtin` modules and avoid external Ansible collections.
- Target Ubuntu 26.04 (Resolute) on `aarch64`; do not silently broaden platform support.
- Keep netplan/systemd-networkd. Do not add NetworkManager or a full desktop environment.
- Let apt and vendor-supported repositories own durable workstation applications. Let mise own language runtimes and fast-moving development toolchains.
- Never commit real hostnames, IP addresses, usernames, passwords, tokens, or private keys.
- Run the syntax checks documented in `README.md` after changing YAML or Jinja templates.

