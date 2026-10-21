# Sourced by setup.sh and restore-host.sh before their first `node` call: scripts/doctor.mjs (which checks the other
# host prerequisites) is itself a Node script, so a host without Node would otherwise stop with "node: command not found".
command -v node >/dev/null || { echo 'Missing prerequisite: node' >&2; exit 1; }
