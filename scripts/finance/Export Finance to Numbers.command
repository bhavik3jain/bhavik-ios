#!/bin/zsh
# Double-click in Finder to turn every month the app saved to iCloud Drive › Multitrack › Finance
# into a Numbers file beside it (export_folder.py; README.md has the setup). Extra arguments, such
# as --force, are passed through when it's run from a terminal.

cd "${0:A:h}" || exit 1
# Finder starts this with a bare PATH, without the places uv installs itself.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

finish() {
  # Terminal can close the window the moment this exits; keep it open when something went wrong.
  if [[ $1 -ne 0 ]]; then
    echo
    read -sk1 "?Something went wrong (see above). Press any key to close."
    echo
  fi
  exit $1
}

if ! command -v uv >/dev/null 2>&1; then
  echo "uv isn't installed. Install it (https://docs.astral.sh/uv/), then double-click this again."
  finish 1
fi

uv run --quiet export_folder.py "$@"
finish $?
