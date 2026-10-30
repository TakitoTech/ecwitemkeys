#!/usr/bin/env bash
#
# devcontainer `initializeCommand` — runs on the HOST before the container builds.
#
# Ensures a persistent user ssh-agent, an SSH_AUTH_SOCK export in ~/.bashrc, and a
# loaded key exist on the host, so VS Code can forward the agent into this dev
# container and `git push` works from inside it.
#
# Idempotent and safe to re-run. No-ops on hosts without a systemd user session
# (e.g. macOS / Windows), so cloning this repo elsewhere won't touch their shell.
# Written to work across systemd distros (Fedora/CoreOS, Debian/Ubuntu, ...).

set -u

SOCK_EXPORT='export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"'

# Only meaningful on a Linux host with a systemd user session.
command -v systemctl >/dev/null 2>&1 || exit 0
systemctl --user show-environment >/dev/null 2>&1 || exit 0

# 1. Persistent agent on a stable socket via a systemd user service.
#    Derive the ssh-agent path (Debian & Fedora both use /usr/bin, but don't assume).
agent_bin="$(command -v ssh-agent || echo /usr/bin/ssh-agent)"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
if [ ! -f "$unit_dir/ssh-agent.service" ]; then
	cat >"$unit_dir/ssh-agent.service" <<EOF
[Unit]
Description=SSH authentication agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=${agent_bin} -D -a \$SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF
fi
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service

# Keep the agent alive when no session is active (Fedora/CoreOS often pre-enable
# this; Debian/Ubuntu don't). Best-effort — may need polkit auth on some hosts.
loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true

# 2. Export SSH_AUTH_SOCK from ~/.bashrc (once) so login shells that spawn the
#    VS Code Server inherit the agent socket. Prepend ABOVE any early "return for
#    non-interactive shells" guard (Debian/Ubuntu ship one; Fedora does not) so
#    the export is actually reached.
if ! grep -qF 'ssh-agent.socket' "$HOME/.bashrc" 2>/dev/null; then
	tmp="$(mktemp)"
	{
		printf '# Persistent user ssh-agent (VS Code dev container agent forwarding)\n'
		printf '%s\n\n' "$SOCK_EXPORT"
		[ -f "$HOME/.bashrc" ] && cat "$HOME/.bashrc"
	} >"$tmp"
	cat "$tmp" >"$HOME/.bashrc" # overwrite contents, preserve file perms/inode
	rm -f "$tmp"
fi

# 3. Load the default key if present and not already in the agent.
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
if [ -f "$HOME/.ssh/id_ed25519" ] && ! ssh-add -l >/dev/null 2>&1; then
	ssh-add "$HOME/.ssh/id_ed25519" >/dev/null 2>&1 || true
fi

exit 0
