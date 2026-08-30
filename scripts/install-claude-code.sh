#!/usr/bin/env bash
# Installs the Claude Code CLI for on-demand debugging directly on the Pi.
# Sets up NO background service - the CLI is only invoked manually when needed
# with 'claude' (see README "Claude Code direkt auf dem Pi").
set -euo pipefail

NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ "${NODE_MAJOR}" -ge 18 ]]; then
    NEED_NODE=0
  fi
fi

if [[ "${NEED_NODE}" -eq 1 ]]; then
  echo "==> Installing Node.js (LTS) (required for the Claude Code CLI)"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
  sudo apt install -y nodejs
else
  echo "==> Node.js $(node --version) already sufficient, skipping install"
fi

echo "==> Installing Claude Code CLI (via npm)"
# Deliberately npm instead of the native installer (curl -fsSL https://claude.ai/install.sh | bash):
# the native installer has known issues on ARM64/Raspberry Pi (reports success but
# does not actually install the binary) - see README for details/source.
sudo npm install -g @anthropic-ai/claude-code

echo
echo "=================================================================="
echo "Installation complete. No background service is running -"
echo "the CLI is only started manually with 'claude' in the project"
echo "folder when needed, and exits again once you are done."
echo
echo "If a warning 'npm warn allow-scripts ... not yet covered'"
echo "appeared above: check with 'claude --version' whether it still works"
echo "(it should print a version number). If not:"
echo "  npm approve-scripts --allow-scripts-pending"
echo
echo "Next step: log in once - set this up beforehand so the interactive"
echo "login menu is skipped on the first 'claude' call:"
echo "  1) API key:"
echo "       echo 'export ANTHROPIC_API_KEY=<your-api-key>' >> ~/.bashrc"
echo "       source ~/.bashrc"
echo "  2) Claude Pro/Max (generate the token on a device WITH a browser):"
echo "       claude setup-token"
echo "     Then on the Pi:"
echo "       echo 'export CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.bashrc"
echo "       source ~/.bashrc"
echo "Details: README section 'Claude Code direkt auf dem Pi'."
echo "=================================================================="
