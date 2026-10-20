#!/usr/bin/env bash
# Live guard for the OpenCode 2 entrypoint of the primary watch-arm plugin on a
# private server with its own database. OpenCode 2 must report the plugin
# active, a turn end in a foreign project must not arm, a primary turn end must
# arm one cycle whose ordinary wake starts one verified successor before the
# wake prompt reaches the session, and a later turn end must not start another
# cycle. Sessions pin a model no provider serves, so no model call is made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OPENCODE_V2_WATCH_LIVE opencode node git

OPENCODE_VERSION=$(opencode --version 2>/dev/null)
case $OPENCODE_VERSION in
  2.* | v2.* | *" 2."* | *" v2."*) ;;
  *)
    printf 'skip: live: %s is not OpenCode 2\n' "${OPENCODE_VERSION:-unknown opencode}"
    exit 0
    ;;
esac

LAB=$(fm_test_tmproot fm-opencode-v2-watch-arm-live)
LAB=$(cd "$LAB" && pwd -P)
PRIMARY="$LAB/primary"
OTHER="$LAB/other"
HOME_DIR="$LAB/home"
LOG="$LAB/arm.log"
STOP="$LAB/stop"
SERVER_PID=""

stop_server() {
  : > "$STOP"
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  SERVER_PID=""
}
trap 'stop_server; fm_test_cleanup' EXIT

failed() {
  fail "$OPENCODE_VERSION: $1$([ -f "$LOG" ] && printf ' (arm log: %s)' "$(tr '\n' ';' < "$LOG")")"
}

mkdir -p "$PRIMARY/bin" "$PRIMARY/.opencode/plugins/lib" "$OTHER" "$HOME_DIR/state" "$HOME_DIR/config"
git init -q "$PRIMARY"
git init -q "$OTHER"
: > "$PRIMARY/AGENTS.md"
cp "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$PRIMARY/bin/"
cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$ROOT/.opencode/plugins/package.json" "$PRIMARY/.opencode/plugins/"
cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$PRIMARY/.opencode/plugins/lib/"
: > "$HOME_DIR/state/task.meta"
cat > "$PRIMARY/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(grep -c '^arm=' "$FM_ARM_LOG")" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 0.3
  printf 'signal: live ordinary wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.05; done
SH
chmod +x "$PRIMARY/bin/fm-watch-arm.sh"

# No HERDR_* environment, so a global herdr integration never reports these
# private sessions to a live pane.
(
  cd "$PRIMARY" &&
    exec env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SESSION \
      FM_HOME="$HOME_DIR" FM_ARM_LOG="$LOG" FM_STOP_FILE="$STOP" OPENCODE_DB="$LAB/opencode.db" \
      OPENCODE_DISABLE_AUTOUPDATE=1 opencode serve --port 0 --hostname 127.0.0.1 > "$LAB/serve.log" 2>&1
) &
SERVER_PID=$!
for _ in $(seq 1 150); do grep -q '^server password ' "$LAB/serve.log" 2>/dev/null && break; sleep 0.1; done
URL=$(sed -n 's/^server listening on //p' "$LAB/serve.log")
OPENCODE_PASSWORD=$(sed -n 's/^server password //p' "$LAB/serve.log")
export OPENCODE_PASSWORD
[ -n "$URL" ] && [ -n "$OPENCODE_PASSWORD" ] || failed "the private server did not start: $(cat "$LAB/serve.log")"
# The plugin runs inside the server, which is the lock holder's process.
printf '%s\n' "$SERVER_PID" > "$HOME_DIR/state/.lock"

api() { opencode api --server "$URL" "$@"; }
plugin_state() {  # <directory>
  api plugin.list --param "location.directory=$1" | node -e '
    let s = "";
    process.stdin.on("data", (c) => (s += c)).on("end", () => {
      const rows = JSON.parse(s).data.filter((p) => String(p.source?.path || "").endsWith("fm-primary-watch-arm.js"));
      console.log(rows.map((p) => `${p.id ?? "-"} ${p.state.status}${p.state.error ? ` ${p.state.error}` : ""}`).join("; ") || "absent");
    });'
}
wait_plugin_state() {  # <directory>
  local state="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    state=$(plugin_state "$1")
    case $state in *active* | *failed*) break ;; esac
    sleep 1
  done
  printf '%s\n' "$state"
}
new_session() {  # <directory>
  api session.create -d "{\"location\":{\"directory\":\"$1\"},\"title\":\"fm-live\",\"model\":{\"id\":\"fm-live-none\",\"providerID\":\"fm-live-none\"}}" |
    node -e 'let s = ""; process.stdin.on("data", (c) => (s += c)).on("end", () => console.log(JSON.parse(s).data.id))'
}
end_turn() { api session.prompt --param "sessionID=$1" -d '{"text":"fm live turn"}' >/dev/null; }
arm_count() { grep -c '^arm=' "$LOG" 2>/dev/null || printf '0\n'; }

for dir in "$PRIMARY" "$ROOT"; do
  state=$(wait_plugin_state "$dir")
  [ "$state" = "firstmate.primary-watch-arm active" ] || failed "the watch-arm plugin is not active in $dir: $state"
done
pass "$OPENCODE_VERSION reports the watch-arm plugin active"

foreign=$(new_session "$OTHER")
[ -n "$foreign" ] || failed "could not create the foreign session"
end_turn "$foreign"
sleep 3
[ "$(arm_count)" = 0 ] || failed "a foreign project's turn end armed a cycle"
pass "$OPENCODE_VERSION: a foreign project's turn end does not arm"

primary=$(new_session "$PRIMARY")
[ -n "$primary" ] || failed "could not create the primary session"
end_turn "$primary"
for _ in $(seq 1 200); do grep -q '^confirmed ' "$LOG" 2>/dev/null && break; sleep 0.1; done
[ "$(arm_count)" = 2 ] || failed "expected one cycle and one successor after the ordinary wake"
first=$(grep '^arm=' "$LOG" | sed -n '1s/^arm=\([0-9]*\).*/\1/p')
successor=$(grep '^arm=' "$LOG" | sed -n '2s/^arm=\([0-9]*\).*/\1/p')
[ "$(grep '^arm=' "$LOG" | sed -n '2s/.*predecessor=//p')" = "$first" ] || failed "the successor did not name the closed cycle"
grep -qx "confirmed generation=live-generation watcher=$successor" "$LOG" || failed "the handoff was not confirmed against the successor"
kill -0 "$successor" 2>/dev/null || failed "the successor cycle is not alive"
delivered=0
for _ in $(seq 1 50); do
  delivered=$(api session.context --param "sessionID=$primary" 2>/dev/null | grep -c 'live ordinary wake' || true)
  [ "${delivered:-0}" -ge 1 ] && break
  sleep 0.2
done
[ "${delivered:-0}" -ge 1 ] || failed "the wake prompt did not reach the primary session"
pass "$OPENCODE_VERSION: an ordinary wake starts one verified successor before the prompt is delivered"

end_turn "$primary"
sleep 3
[ "$(arm_count)" = 2 ] || failed "a later turn end started another cycle"
kill -0 "$successor" 2>/dev/null || failed "a later turn end disturbed the live successor"
pass "$OPENCODE_VERSION: a later turn end keeps exactly one live cycle"
