#!/usr/bin/env bash
#
# Build this checkout, install it to ~/.local/bin/sketchybar, keep a
# LaunchAgent pointing at it, and restart the bar.
#
# The previous binary is kept at ~/.local/bin/sketchybar.previous for rollback.
#
# macOS keys Screen Recording and Accessibility grants (needed by alias items)
# to the code signature. An ad-hoc signature changes on every build, which
# drops both grants, so builds are signed with one stable self-signed identity:
# $SKETCHYBAR_SIGNING_IDENTITY, by default the one Paneru's install-local.sh
# creates. Without it the build is signed ad hoc and the grants reset.
#
# Usage: ./install-local.sh [--no-restart]

set -euo pipefail

readonly SERVICE="com.github.felixkratz.sketchybar"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TARGET="${HOME}/.local/bin/sketchybar"
readonly PLIST="${HOME}/Library/LaunchAgents/${SERVICE}.plist"
readonly DOMAIN="gui/$(id -u)"
readonly IDENTITY="${SKETCHYBAR_SIGNING_IDENTITY:-Paneru Local Builds}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  arm64) readonly ARCH_TARGET="arm64" ;;
  x86_64) readonly ARCH_TARGET="x86" ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

write_plist() {
  local path="${HOME}/.local/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local log_base="/tmp/${SERVICE}_$(id -u)"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${TARGET}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${path}</string>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>Nice</key>
  <integer>-20</integer>
  <key>StandardOutPath</key>
  <string>${log_base}.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_base}.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "${tmp}" >/dev/null || die "generated an invalid LaunchAgent"
  if [[ -f "${PLIST}" ]] && cmp -s "${tmp}" "${PLIST}"; then
    rm -f "${tmp}"
    return 1
  fi
  mkdir -p "$(dirname "${PLIST}")"
  mv "${tmp}" "${PLIST}"
  return 0
}

main() {
  local restart=1
  [[ "${1:-}" == "--no-restart" ]] && restart=0

  log "building ${ARCH_TARGET} binary"
  (cd "${REPO_ROOT}" && make clean >/dev/null && make "${ARCH_TARGET}")
  local built="${REPO_ROOT}/bin/sketchybar"
  [[ -x "${built}" ]] || die "build produced no binary at ${built}"

  mkdir -p "$(dirname "${TARGET}")"
  if [[ -f "${TARGET}" ]]; then
    cp -p "${TARGET}" "${TARGET}.previous"
  fi
  log "installing to ${TARGET}"
  # Replace rather than overwrite, so a running bar keeps its own inode.
  cp "${built}" "${TARGET}.new"
  if security find-identity -v -p codesigning | grep -qF "\"${IDENTITY}\""; then
    log "signing as '${IDENTITY}'"
    codesign --force --identifier com.felixkratz.sketchybar --sign "${IDENTITY}" "${TARGET}.new"
  else
    log "no '${IDENTITY}' identity: signing ad hoc; Screen Recording and Accessibility grants will reset"
    codesign --force --identifier com.felixkratz.sketchybar --sign - "${TARGET}.new" >/dev/null 2>&1
  fi
  mv -f "${TARGET}.new" "${TARGET}"

  local plist_changed=0
  if write_plist; then
    plist_changed=1
    log "wrote ${PLIST}"
  fi

  (( restart )) || { log "done (not restarted)"; return; }

  if ! launchctl print "${DOMAIN}/${SERVICE}" >/dev/null 2>&1; then
    log "loading ${SERVICE}"
    launchctl bootstrap "${DOMAIN}" "${PLIST}"
  elif (( plist_changed )); then
    log "reloading ${SERVICE}"
    launchctl bootout "${DOMAIN}/${SERVICE}" || true
    launchctl bootstrap "${DOMAIN}" "${PLIST}"
  else
    log "restarting ${SERVICE}"
    launchctl kickstart -k "${DOMAIN}/${SERVICE}"
  fi
  log "done"
}

main "$@"
