#!/bin/bash
# install.sh — One-command setup for ai-conductor on a new Mac
set -euo pipefail

echo "Setting up ai-conductor..."

# Homebrew
if ! command -v brew >/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# CLI tools
echo "Installing CLI tools..."
brew install gum llm glow jq

# llm plugins for Claude and Gemini
echo "Installing llm model plugins..."
llm install llm-claude-3 llm-gemini

# gcloud (for GCP secret injection)
if ! command -v gcloud >/dev/null; then
  echo "Installing Google Cloud SDK..."
  brew install --cask google-cloud-sdk
  echo ""
  echo "Run 'gcloud auth login' and 'gcloud config set project pwa-id-app' after install."
fi

# Make script executable
chmod +x "$(dirname "$0")/ai-conductor.sh"

# Desktop launcher
LAUNCHER="$HOME/Desktop/AI Conductor.command"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
cd "$(dirname "$0")"
./ai-conductor.sh
LAUNCHER_EOF

# Fix the path inside the launcher to point to the actual install location
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
cd "$INSTALL_DIR"
./ai-conductor.sh
LAUNCHER_EOF
chmod +x "$LAUNCHER"

echo ""
echo "Done. To run:"
echo "  Double-click 'AI Conductor' on your Desktop"
echo "  or: cd ~/Documents/ai-conductor && ./ai-conductor.sh"
echo ""
echo "Make sure gcloud is authenticated before first use:"
echo "  gcloud auth login"
echo "  gcloud config set project pwa-id-app"
