#!/usr/bin/env python3
"""Fail-closed, local-only v4 replacement restore. Never starts a tunnel or sends OTPs.

Run prepare, then restore, then verify. Keep STATE and BACKUP outside Git.
All subprocess output, including PostgreSQL diagnostics, stays in STATE/evidence.
"""

import argparse
import base64
from collections import Counter
from datetime import date, datetime, timedelta, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
prep = SourceFileLoader("prepare_recovery_bundle", str(ROOT / "scripts/prepare-recovery-bundle.py")).load_module()
CORE = {"db", "rest", "storage", "imgproxy", "realtime", "functions", "kong", "studio", "meta", "gotenberg"}
REMAP = {"WAREHOUSE_DB_PATH": "data/db", "WAREHOUSE_STORAGE_PATH": "data/storage", "WAREHOUSE_MANIFEST_PATH": "public/instance.json"}
URL_PATHS = {"MAILER_URLPATHS_CONFIRMATION", "MAILER_URLPATHS_INVITE", "MAILER_URLPATHS_RECOVERY", "MAILER_URLPATHS_EMAIL_CHANGE"}
EXPECTED_HEAD = "e15cd6bb39bd762cfc3f99b750fcef8b6c3cd872"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def run(args, log=None, input_path=None, output_path=None, env=None):
    with (open(log, "ab") if log else open(os.devnull, "wb")) as errors:
        with (open(input_path, "rb") if input_path else open(os.devnull, "rb")) as source:
            if output_path:
                with open(output_path, "wb") as output:
                    result = subprocess.run(args, stdin=source, stdout=output, stderr=errors, env=env, check=False)
            else:
                result = subprocess.run(args, stdin=source, stdout=errors, stderr=errors, env=env, check=False)
    require(result.returncode == 0, f"Private command failed ({Path(args[0]).name}); see {log}")


def capture(args, log=None, env=None):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False)
    if result.returncode:
        if log:
            with open(log, "ab") as private:
                private.write(result.stdout)
                private.write(result.stderr)
        raise ValueError(f"Private command failed ({Path(args[0]).name}); see {log}")
    return result.stdout


def private_file(path):
    prep.private_path(path, False)


def private_dir(path):
    prep.private_path(path, True)


def git_head():
    head = capture(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).decode().strip()
    base = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", EXPECTED_HEAD, "HEAD"])
    require(base.returncode == 0, "Checkout is not based on reviewed recovery commit")
    return head


def read_env(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=([^\r\n]*)", line)
        require(match is not None and match[1] not in result, "Saved environment has unsupported syntax or duplicate key")
        value = re.sub(r"\s+#.*$", "", match[2].strip()).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        require(not any(ch in value for ch in "`$\\\"'"), "Saved environment has unsupported interpolation or quoting")
        result[match[1]] = value
    return result


def docker_inventory(project, state):
    raw = capture(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"], state / "evidence/docker.private.log")
    require(not raw.strip(), "Compose project already has containers; use a new destination or stop for review")
    networks = capture(["docker", "network", "ls", "--format", "{{.Name}}"], state / "evidence/docker.private.log").decode().splitlines()
    require(not any(n == f"{project}_default" for n in networks), "Compose project network already exists")
    volumes = capture(["docker", "volume", "ls", "--format", "{{.Name}}"], state / "evidence/docker.private.log").decode().splitlines()
    require(not any(n.startswith(project + "_") for n in volumes), "Compose project volume already exists")


def env_for_compose(state):
    values = read_env(state / "config/compose.env")
    env = {key: value for key, value in os.environ.items() if key not in values and key not in {"COMPOSE_PROFILES", "COMPOSE_FILE", "COMPOSE_PROJECT_NAME"}}
    env["WAREHOUSE_STATE_DIR"] = str(state)
    return env, values


def compose_args(state, *args):
    _, values = env_for_compose(state)
    return ["docker", "compose", "--project-directory", str(ROOT / "docker"), "--project-name", values["WAREHOUSE_PROJECT_NAME"],
            "--env-file", str(state / "config/compose.env"), "-f", str(ROOT / "docker/docker-compose.yml"),
            "-f", str(ROOT / "docker/docker-compose.override.yml"), "-f", str(state / "config/isolation.json"), *args]


def validate_rendered(state):
    env, values = env_for_compose(state)
    # The repository wrapper checks owner, modes, manifest and bind paths.
    run(["bash", str(ROOT / "scripts/compose.sh"), "config", "--quiet"], state / "evidence/preflight.private.log", env=env)
    rendered = json.loads(capture(compose_args(state, "config", "--format", "json"), state / "evidence/preflight.private.log", env=env))
    require(set(rendered["services"]) == CORE, "Unexpected active service/profile")
    require(rendered["networks"]["default"]["internal"] is True, "Compose network is not internal")
    require(rendered["name"] == values["WAREHOUSE_PROJECT_NAME"], "Rendered project identity mismatch")
    for name, service in rendered["services"].items():
        require(service.get("network_mode") not in ("host", "bridge"), "Unsafe network mode")
        require(not service.get("privileged") and not service.get("extra_hosts"), "Unsafe container privilege or host route")
        require(not service.get("secrets") and not service.get("build", {}).get("args"), "Unreviewed build args or Compose secrets")
        require(service.get("restart") == "no", "Automatic restart enabled before restoration")
        for port in service.get("ports", []):
            require(name == "kong" and port.get("host_ip") == "127.0.0.1", "Public port is configured")
        for mount in service.get("volumes", []):
            if mount.get("type") == "bind":
                source = mount.get("source", "")
                allowed = {str(state / "data/db"), str(state / "data/storage"), str(state / "public/instance.json")}
                if name == "functions":
                    allowed.update({str(state / "cache/edge"), str(ROOT / "functions")})
                require(source in allowed or source.startswith(str(ROOT / "docker") + "/"), "Unreviewed bind source")
                if source.startswith(str(ROOT) + "/"):
                    path = Path(source)
                    require(path.exists() and not path.is_symlink() and
                            ((path.stat().st_mode & 0o005) == 0o005 if path.is_dir() else bool(path.stat().st_mode & 0o004)),
                            "Tracked source bind is unreadable by container UID")
    (state / "evidence/rendered-compose.private.json").write_text(json.dumps(rendered, indent=2))
    return rendered


def prepare(backup, state):
    git_head()
    require(ROOT not in backup.parents and ROOT not in state.parents, "Backup and state must be outside Git")
    private_dir(backup)
    require(not state.exists() and state.is_absolute() and not state.is_symlink(), "Destination must be new and absolute")
    private_dir(state.parent)
    prep.verify_backup(backup)
    require({child.name for child in backup.iterdir()} == prep.BACKUP_FILES, "Unexpected or missing backup file")
    metadata = dict(line.split("=", 1) for line in (backup / "metadata.txt").read_text().splitlines() if "=" in line)
    require(metadata.get("format") == "warehouse-backup-v4" and metadata.get("database_image") == "supabase/postgres:15.8.1.060", "Backup format or database image is unsupported")
    for child in backup.iterdir():
        private_file(child)
    env = read_env(backup / "compose.env")
    manifest = json.loads((backup / "instance.json").read_text())
    require(re.fullmatch(r"warehouse-[0-9a-f-]{12}", env["WAREHOUSE_PROJECT_NAME"]) is not None, "Invalid project name")
    require(env["WAREHOUSE_PROJECT_NAME"] == "warehouse-" + manifest["instanceId"][:12], "Project and instance ID disagree")
    require(env["SUPABASE_PUBLIC_URL"] == manifest["canonicalOrigin"], "Canonical origin differs")
    require(env["BIND_ADDRESS"] == "127.0.0.1" and env["POSTGRES_HOST"] == "db" and env["POSTGRES_DB"] == "postgres", "Unsafe saved host binding")
    require(env["KONG_HTTP_PORT"].isdigit(), "Invalid saved gateway port")
    # Reject every unaccounted absolute value. URL route values begin with / but are not filesystem paths.
    absolute = {k for k, v in env.items() if v.startswith("/")}
    require(absolute == set(REMAP) | URL_PATHS | {"DOCKER_SOCKET_LOCATION"}, "Unreviewed saved absolute path")
    require(all(re.fullmatch(r"/auth/[A-Za-z0-9/_-]+", env[key]) and ".." not in env[key] for key in URL_PATHS),
            "Saved mailer route is not a reviewed URL path")
    require(env["DOCKER_SOCKET_LOCATION"] == "/var/run/docker.sock" and Path("/var/run/docker.sock").is_socket(), "Docker socket path mismatch")
    for key in REMAP:
        saved = Path(env[key])
        require(saved.is_absolute() and ".." not in saved.parts and "." not in saved.parts, "Saved state path is not canonical")
        require(not (state == saved or state in saved.parents or saved in state.parents), "Saved path collides with replacement state")
    # An internal Docker network prevents publishing, but reject a host port collision too.
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", int(env["KONG_HTTP_PORT"])))
        except OSError as error:
            raise ValueError("Saved gateway port is occupied") from error
    # Compose project is a host-local resource namespace, not the application instance ID.
    # A second drill may coexist with stopped evidence from the first one.
    drill_project = "warehouse-restore-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
    state.mkdir(mode=0o700)
    for name in ("config", "data", "data/db", "data/storage", "public", "evidence"):
        (state / name).mkdir(mode=0o700)
    try:
        docker_inventory(drill_project, state)
        original = (backup / "compose.env").read_text()
        for key, suffix in REMAP.items():
            original, count = re.subn(rf"(?m)^{key}=.*$", f"{key}={state / suffix}", original)
            require(count == 1, "Missing state path to remap")
        original, count = re.subn(r"(?m)^WAREHOUSE_PROJECT_NAME=.*$", "WAREHOUSE_PROJECT_NAME=" + drill_project, original)
        require(count == 1, "Missing saved project name")
        (state / "config/compose.env").write_text(original)
        shutil.copyfile(backup / "instance.json", state / "public/instance.json")
        # Tunnel config is never installed. Validate its one saved path and quarantine it.
        secrets = backup.parent / "recovery-secrets"
        private_dir(secrets)
        credential = list(secrets.glob("*.json"))
        require(len(credential) == 1, "Expected one dedicated tunnel credential")
        require({child.name for child in secrets.iterdir()} == {"cloudflared-config.yml", "msg91.env", credential[0].name},
                "Unexpected or missing recovery credential file")
        for child in secrets.iterdir():
            private_file(child)
        private_file(credential[0])
        tunnel = (secrets / "cloudflared-config.yml").read_text()
        absolute_keys = {key.strip() for line in tunnel.splitlines() if ":" in line
                         for key, value in [line.split(":", 1)] if value.strip().startswith("/")}
        require(absolute_keys == {"credentials-file"}, "Unreviewed absolute path in tunnel config")
        matches = re.findall(r"(?m)^credentials-file:\s*(\S+)\s*$", tunnel)
        require(len(matches) == 1 and matches[0].startswith("/"), "Unreviewed tunnel credential path")
        require(Path(matches[0]).name == credential[0].name, "Tunnel credential filename differs")
        tunnel = tunnel.replace(matches[0], str(credential[0]))
        (state / "config/cloudflared.INACTIVE.yml").write_text(tunnel)
        isolation = {"services": {name: {"restart": "no"} for name in CORE}, "networks": {"default": {"internal": True}}}
        isolation["services"]["db"]["command"] = ["postgres", "-c", "listen_addresses=*", "-c", "shared_preload_libraries=pg_stat_statements,pg_cron,pg_net", "-c", "cron.database_name=postgres", "-c", "cron.launch_active_jobs=off", "-c", "wal_level=logical", "-c", "log_statement=none"]
        (state / "config/isolation.json").write_text(json.dumps(isolation, indent=2))
        (state / "config/backup.path").write_text(str(backup) + "\n")
        for file in (state / "config").iterdir():
            file.chmod(0o600)
        (state / "public/instance.json").chmod(0o600)
        validate_rendered(state)
        (state / "evidence/prepared.json").write_text(json.dumps({"source_head": git_head(), "backup_checksum_manifest_sha256": prep.sha256(backup / "SHA256SUMS"), "saved_project": env["WAREHOUSE_PROJECT_NAME"], "drill_project": drill_project, "path_keys_remapped": sorted(REMAP), "saved_tunnel_path_quarantined": True, "network_internal": True}, indent=2))
        print("PASS: private state prepared; paths, project, port and network gates passed. No service started.")
    except BaseException:
        # Keep failed state and evidence for diagnosis; never reuse it.
        raise


def db_id(state):
    env, _ = env_for_compose(state)
    return capture(compose_args(state, "ps", "-q", "db"), state / "evidence/restore.private.log", env=env).decode().strip()


def db_exec(state, *args, input_path=None, output_path=None):
    identifier = db_id(state)
    require(identifier, "Database container does not exist")
    command = ["docker", "exec", "-i" if input_path else "-t", identifier, *args]
    # -t is unsuitable for machine-readable output; docker exec without tty is the default.
    command.remove("-t") if "-t" in command else None
    run(command, state / "evidence/restore.private.log", input_path=input_path, output_path=output_path)


def db_capture(state, *args):
    identifier = db_id(state)
    require(identifier, "Database container does not exist")
    return capture(["docker", "exec", identifier, *args], state / "evidence/restore.private.log")


def network_gate(state, project):
    network = project + "_default"
    run(["docker", "network", "create", "--internal", "--label", f"com.docker.compose.project={project}",
         "--label", "com.docker.compose.network=default", network], state / "evidence/restore.private.log")
    details = json.loads(capture(["docker", "network", "inspect", network], state / "evidence/restore.private.log"))[0]
    require(details["Internal"] is True and details["Name"] == network, "Network is not internal")
    # This credential-free probe must fail to open an external TCP connection.
    probe = subprocess.run(["docker", "run", "--rm", "--network", network, "--pull", "never", "--entrypoint", "bash",
                            "supabase/postgres:15.8.1.060", "-c", "echo PROBE_STARTED; timeout 3 bash -c 'echo > /dev/tcp/1.1.1.1/443'"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with open(state / "evidence/restore.private.log", "ab") as log:
        log.write(probe.stderr)
    require(probe.stdout.strip() == b"PROBE_STARTED" and probe.returncode not in (0, 125, 126, 127), "Outbound TCP probe succeeded or could not run")
    return network


def inspect_db(state, project, network):
    item = json.loads(capture(["docker", "inspect", db_id(state)], state / "evidence/restore.private.log"))[0]
    (state / "evidence/db-inspect.private.json").write_text(json.dumps(item))
    require(item["Config"]["Labels"]["com.docker.compose.project"] == project, "Database container belongs to another project")
    require(item["Config"]["Labels"]["com.docker.compose.project.working_dir"] == str(ROOT / "docker"), "Database container uses another checkout")
    require(item["HostConfig"]["RestartPolicy"]["Name"] == "no", "Database auto-restart enabled")
    require(not item["HostConfig"]["PortBindings"], "Database publishes a port")
    require(set(item["NetworkSettings"]["Networks"]) == {network}, "Database has an extra network")


def replay_globals(state, backup):
    source = (backup / "globals.sql").read_text()
    statements = [line for line in source.splitlines() if line and not line.startswith("--")]
    require(all(re.match(r"^(SET |CREATE ROLE |ALTER ROLE |GRANT )", line) and line.endswith(";") for line in statements), "Unreviewed cluster-global statement")
    creates = [re.fullmatch(r"CREATE ROLE ([A-Za-z_][A-Za-z0-9_]*);", line) for line in statements if line.startswith("CREATE ROLE ")]
    require(all(creates), "Unsupported role name in globals")
    names = {match[1] for match in creates}
    archived = set((backup / "roles.txt").read_text().splitlines())
    require(names == archived, "Role inventory differs from globals")
    current = set(db_capture(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "template1", "-c",
                             "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname").decode().splitlines())
    require(current <= names, "Runtime contains unreviewed non-system roles")
    script = "\n".join(line for line in statements if not line.startswith("CREATE ROLE ") or line[12:-1] not in current) + "\n"
    path = state / "evidence/replay-globals.private.sql"
    path.write_text(script)
    db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "template1", input_path=path)
    actual = state / "evidence/globals-after.private.sql"
    db_exec(state, "pg_dumpall", "-U", "supabase_admin", "--globals-only", output_path=actual)
    def content(text):
        return [line for line in text.splitlines() if line and not line.startswith("--")]
    require(content(actual.read_text()) == content(source), "Cluster globals differ after replay; private dumps retained")
    roles = set(db_capture(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "template1", "-c",
                           "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname").decode().splitlines())
    require(roles == names, "Role names differ after replay")


def compare_data(original, restored):
    def parse(path):
        blocks, sequences, active = {}, [], None
        for line in path.read_text().splitlines():
            if active is not None:
                if line == "\\.":
                    active = None
                else:
                    blocks[active].append(line)
            elif line.startswith("COPY ") and line.endswith(" FROM stdin;"):
                require(line not in blocks, "Duplicate table in data export")
                blocks[line], active = [], line
            elif line.startswith("SELECT pg_catalog.setval("):
                sequences.append(line)
        require(active is None, "Incomplete COPY block")
        return {key: sorted(value) for key, value in blocks.items()}, sorted(sequences)
    a, sa = parse(original)
    b, sb = parse(restored)
    require(a == b and sa == sb, "Rows or sequence values differ from archived database")
    return {"tables": len(a), "rows": sum(map(len, a.values())), "sequences": len(sa)}


def restore_storage(state, backup):
    target = state / "data/storage"
    require(not any(target.iterdir()), "Storage destination is not empty")
    count = 0
    with tarfile.open(backup / "storage.tar.gz", "r:gz") as archive:
        members = archive.getmembers()
        require(len(members) <= 100000 and sum(member.size for member in members) + 256 * 1024 * 1024 < shutil.disk_usage(target).free,
                "Storage archive exceeds safe extraction space or entry count")
        for member in members:
            name = member.name.removeprefix("./").rstrip("/")
            if name in ("", ".") and member.isdir():
                continue
            parts = name.split("/")
            require(all(part not in ("", ".", "..") for part in parts) and not name.startswith("/"), "Unsafe storage path")
            output = target.joinpath(*parts)
            if member.isdir():
                output.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                require(member.isfile() and not output.exists(), "Unsafe or duplicate storage entry")
                output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with archive.extractfile(member) as source, output.open("xb") as destination:
                    shutil.copyfileobj(source, destination)
                output.chmod(0o600)
                count += 1
                with archive.extractfile(member) as source, output.open("rb") as destination:
                    require(hashlib.sha256(source.read()).digest() == hashlib.sha256(destination.read()).digest(), "Stored object bytes differ")
    return count


def restore(state):
    git_head()
    private_dir(state)
    backup = Path((state / "config/backup.path").read_text().strip())
    private_dir(backup)
    prep.verify_backup(backup)
    prepared = json.loads((state / "evidence/prepared.json").read_text())
    require(prepared["backup_checksum_manifest_sha256"] == prep.sha256(backup / "SHA256SUMS"), "Prepared backup manifest changed")
    rendered = validate_rendered(state)
    project = rendered["name"]
    docker_inventory(project, state)
    require(not (state / "data/db/PG_VERSION").exists(), "Database destination already initialized")
    require(not any((state / "data/db").iterdir()) and not any((state / "data/storage").iterdir()), "Data destination is not empty")
    start = time.monotonic()
    env, _ = env_for_compose(state)
    # A build has no access to recovered credentials inside a running container.
    run(compose_args(state, "build", "db"), state / "evidence/build-db.private.log", env=env)
    network = network_gate(state, project)
    run(compose_args(state, "up", "-d", "--no-build", "--wait", "--wait-timeout", "180", "db"), state / "evidence/restore.private.log", env=env)
    inspect_db(state, project, network)
    bootstrap = db_capture(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "postgres", "-c",
                           "SELECT to_regnamespace('warehouse_migrations') IS NULL AND NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='warehouse_restored_stage')").decode().strip()
    require(bootstrap == "t", "Database is not bootstrap-only")
    replay_globals(state, backup)
    identifier = db_id(state)
    run(["docker", "cp", str(backup / "database.dump"), identifier + ":/tmp/database.dump"], state / "evidence/restore.private.log")
    db_exec(state, "createdb", "-U", "supabase_admin", "-T", "template1", "warehouse_restored_stage")
    before = state / "evidence/roles-before.private.jsonl"
    db_exec(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "template1", "-c",
            "SELECT row_to_json(r) FROM pg_authid r ORDER BY rolname", output_path=before)
    temporary_superuser = False
    try:
        db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "template1", "-c", "ALTER ROLE postgres SUPERUSER")
        temporary_superuser = True
        for section in ("pre-data", "data", "post-data"):
            extra = ["--clean", "--if-exists"] if section == "pre-data" else []
            db_exec(state, "pg_restore", "-U", "supabase_admin", "-d", "warehouse_restored_stage", "--no-acl", *extra,
                    "--section=" + section, "--exit-on-error", "/tmp/database.dump")
        wrapper = state / "evidence/graphql-wrapper.private.sql"
        wrapper.write_text('CREATE OR REPLACE FUNCTION graphql_public.graphql("operationName" text DEFAULT NULL, query text DEFAULT NULL, variables jsonb DEFAULT NULL, extensions jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$ SELECT graphql.resolve(query := query, variables := coalesce(variables, \'{}\'::jsonb), "operationName" := "operationName", extensions := extensions); $$;\n')
        db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "warehouse_restored_stage", input_path=wrapper)
        toc = db_capture(state, "pg_restore", "-l", "/tmp/database.dump").decode()
        acl = state / "evidence/acl-list.private.txt"
        acl.write_text("\n".join(line for line in toc.splitlines() if re.match(r"^[0-9]+; .* ACL ", line)) + "\n")
        run(["docker", "cp", str(acl), identifier + ":/tmp/acl.list"], state / "evidence/restore.private.log")
        db_exec(state, "pg_restore", "-U", "supabase_admin", "-d", "warehouse_restored_stage", "-L", "/tmp/acl.list", "--exit-on-error", "/tmp/database.dump")
    finally:
        if temporary_superuser:
            db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "template1", "-c", "ALTER ROLE postgres NOSUPERUSER")
    after = state / "evidence/roles-after.private.jsonl"
    db_exec(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "template1", "-c",
            "SELECT row_to_json(r) FROM pg_authid r ORDER BY rolname", output_path=after)
    require(before.read_bytes() == after.read_bytes(), "Role attributes or password hashes changed during staging")
    integrity = state / "evidence/restored-integrity.private.txt"
    db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "warehouse_restored_stage",
            input_path=ROOT / "scripts/backup-integrity.sql", output_path=integrity)
    require(integrity.read_bytes() == (backup / "integrity.txt").read_bytes(), "Restored integrity differs")
    original = state / "evidence/original-data.private.sql"
    restored = state / "evidence/restored-data.private.sql"
    db_exec(state, "pg_restore", "--data-only", "--no-owner", "--no-acl", "-f", "-", "/tmp/database.dump", output_path=original)
    db_exec(state, "pg_dump", "-U", "supabase_admin", "-d", "warehouse_restored_stage", "--data-only", "--no-owner", "--no-acl", output_path=restored)
    counts = compare_data(original, restored)
    objects = restore_storage(state, backup)
    # Promotion replaces only the freshly initialized local bootstrap database.
    promote = state / "evidence/promote.private.sql"
    promote.write_text("DROP DATABASE postgres WITH (FORCE);\nALTER DATABASE warehouse_restored_stage RENAME TO postgres;\n")
    db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "template1", input_path=promote)
    db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "postgres", input_path=ROOT / "docker/volumes/db/jwt.sql")
    checks = db_capture(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "postgres", "-c",
                        "SELECT current_setting('cron.launch_active_jobs')='off', NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subenabled), (SELECT count(*) FROM storage.objects)").decode().strip()
    fields = checks.split("|")
    require(len(fields) == 3 and fields[:2] == ["t", "t"] and int(fields[2]) == objects, "Post-promotion isolation or object catalog mismatch")
    result = {"source_head": git_head(), "elapsed_seconds": round(time.monotonic() - start, 2), "rows": counts, "storage_files": objects,
              "globals_exact_match": True, "role_attributes_and_passwords_preserved": True, "network_internal": True, "outbound_tcp_blocked": True, "staged_before_promotion": True}
    (state / "evidence/restore-result.json").write_text(json.dumps(result, indent=2))
    print("PASS: staged database, globals, rows, sequences, ACL replay and storage promoted locally; private evidence retained.")


def core_inspect(state, require_healthy=True):
    rendered = validate_rendered(state)
    project = rendered["name"]
    ids = capture(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"], state / "evidence/verify.private.log").decode().split()
    require(len(ids) == len(CORE), "Unexpected core container count")
    items = json.loads(capture(["docker", "inspect", *ids], state / "evidence/verify.private.log"))
    services = {}
    for item in items:
        name = item["Config"]["Labels"].get("com.docker.compose.service")
        require(name in CORE and name not in services, "Unexpected or duplicate core service")
        require(item["Config"]["Labels"].get("com.docker.compose.project.working_dir") == str(ROOT / "docker"), "Foreign container checkout")
        require(set(item["NetworkSettings"]["Networks"]) == {project + "_default"}, "Container has an extra network")
        require(not item["HostConfig"]["Privileged"], "Privileged container")
        bindings = item["HostConfig"]["PortBindings"] or {}
        for ports in bindings.values():
            for port in ports:
                require(name == "kong" and port["HostIp"] == "127.0.0.1", "Container publishes a public host port")
        if require_healthy:
            require(item["State"]["Running"] and item["State"].get("Health", {}).get("Status", "healthy") == "healthy", "Core service unhealthy")
        services[name] = item
    network = json.loads(capture(["docker", "network", "inspect", project + "_default"], state / "evidence/verify.private.log"))[0]
    require(network["Internal"] is True, "Core network has external routing")
    (state / "evidence/core-inspect.private.json").write_text(json.dumps(items))
    return services


def wait_healthy(state, deadline=240):
    end = time.monotonic() + deadline
    last = None
    while time.monotonic() < end:
        try:
            return core_inspect(state)
        except ValueError as error:
            last = error
            time.sleep(5)
    raise ValueError(f"Core health deadline exceeded: {last}")


def local_http(origin, path, key=None, bearer=None):
    headers = {}
    if key:
        headers = {"apikey": key, "Authorization": "Bearer " + (bearer or key)}
    request = urllib.request.Request(origin + path, headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=25) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def match_storage_catalog(storage_root, rows):
    """Match every catalog version to one restored file, with no stray files."""
    files = []
    for path in storage_root.rglob("*"):
        require(not path.is_symlink() and (path.is_dir() or path.is_file()), "Unsafe restored storage entry")
        if path.is_file():
            files.append(path)
    by_version = {}
    for path in files:
        by_version.setdefault(path.name, []).append(path)
    matches = []
    used = set()
    for row in rows:
        bucket, name, version = (row.get(key) for key in ("bucket_id", "name", "version"))
        require(isinstance(bucket, str) and re.fullmatch(r"[A-Za-z0-9._-]+", bucket) and bucket not in (".", ".."),
                "Unsafe storage bucket in catalog")
        require(isinstance(name, str) and name and not name.startswith("/") and "\\" not in name and
                all(part not in ("", ".", "..") for part in name.split("/")), "Unsafe storage object name in catalog")
        require(isinstance(version, str) and re.fullmatch(r"[A-Za-z0-9._-]+", version) and version not in (".", ".."),
                "Unsafe storage version in catalog")
        suffix = (bucket, *name.split("/"), version)
        candidates = [path for path in by_version.get(version, ()) if path.relative_to(storage_root).parts[-len(suffix):] == suffix]
        require(len(candidates) == 1 and candidates[0] not in used, "Storage catalog version has no unique file")
        used.add(candidates[0])
        matches.append((bucket, name, candidates[0]))
    require(len(used) == len(files), "Restored storage has unaccounted files")
    return matches


def local_checks(state, services):
    env = read_env(state / "config/compose.env")
    backup = Path((state / "config/backup.path").read_text().strip())
    manifest = json.loads((state / "public/instance.json").read_text())
    require((state / "public/instance.json").read_bytes() == (backup / "instance.json").read_bytes(), "Instance manifest changed")
    network = next(iter(services["kong"]["NetworkSettings"]["Networks"].values()))
    ip = network["IPAddress"]
    require(ip and ip.startswith(("172.", "10.", "192.168.")), "No private gateway address")
    origin = "http://" + ip + ":8000"
    status, body = local_http(origin, "/functions/v1/get-public-config")
    require(status == 200, "Local discovery failed")
    data = json.loads(body)["data"]
    require(data["instanceId"] == manifest["instanceId"] and data["canonicalOrigin"] == manifest["canonicalOrigin"], "Instance identity changed")
    require(data["anonKey"] == env["ANON_KEY"], "Anonymous credential changed")
    status, _ = local_http(origin, "/rest/v1/feature_flags?select=name,enabled", env["ANON_KEY"])
    require(status == 200, "Public feature flags unavailable")
    for path in ("/rest/v1/orders?select=id&limit=1", "/rest/v1/sms_config?select=*&limit=1"):
        status, _ = local_http(origin, path, env["ANON_KEY"])
        require(status in (401, 403), "Anonymous business or secret read allowed")
    status, _ = local_http(origin, "/rest/v1/user_profiles?select=id&limit=1", env["SERVICE_ROLE_KEY"])
    require(status == 200, "Original service credential rejected")
    def signed_session(expiry):
        payload = {"iss": "supabase", "role": "authenticated", "aud": "authenticated", "sub": str(uuid.uuid4()),
                   "session_id": str(uuid.uuid4()), "iat": int(time.time()) - 60, "exp": expiry}
        encode = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        message = encode({"alg": "HS256", "typ": "JWT"}) + "." + encode(payload)
        signature = base64.urlsafe_b64encode(hmac.new(env["JWT_SECRET"].encode(), message.encode(), hashlib.sha256).digest()).decode().rstrip("=")
        return message + "." + signature
    for expiry in (int(time.time()) + 120, int(time.time()) - 120):
        status, _ = local_http(origin, "/rest/v1/orders?select=id&limit=1", env["ANON_KEY"], signed_session(expiry))
        require(status in (401, 403), "Nonexistent or expired authenticated session was accepted")
    status, body = local_http(origin, "/storage/v1/bucket", env["SERVICE_ROLE_KEY"])
    require(status == 200 and all(not row["public"] for row in json.loads(body)), "Restored buckets are not private")
    # Match the complete catalog to restored files; sample API access without
    # logging names, bytes, URLs or responses. restore_storage already checked
    # every file against the checksummed archive before service startup.
    catalog = [json.loads(line) for line in db_capture(state, "psql", "-X", "-qAt", "-U", "supabase_admin", "-d", "postgres", "-c",
                                                  "SELECT row_to_json(o) FROM (SELECT bucket_id,name,version FROM storage.objects ORDER BY bucket_id,name) o").decode().splitlines()]
    objects = match_storage_catalog(state / "data/storage", catalog)
    sampled = sorted({0, len(objects) // 2, len(objects) - 1}) if objects else []
    for index in sampled:
        bucket, name, path = objects[index]
        route = "/storage/v1/object/authenticated/" + urllib.parse.quote(bucket, safe="") + "/" + urllib.parse.quote(name, safe="/")
        status, body = local_http(origin, route, env["SERVICE_ROLE_KEY"])
        require(status == 200 and hashlib.sha256(body).digest() == hashlib.sha256(path.read_bytes()).digest(), "Restored private object bytes differ")
        status, _ = local_http(origin, route, env["ANON_KEY"])
        require(status in (400, 401, 403, 404), "Anonymous private object read allowed")
    return {"identity": True, "saved_credentials": True, "anonymous_boundary": True, "invalid_and_expired_sessions_denied": True,
            "private_bucket": True, "object_catalog_files_matched": len(objects), "private_object_access_samples": len(sampled)}


def cache_edge(state):
    """Prime source dependencies using a dummy instance, then prove offline startup."""
    private_dir(state)
    require((state / "evidence/restore-result.json").is_file(), "Restore has not passed")
    require((state / "evidence/build-result.json").is_file(), "Core image build has not passed")
    env, values = env_for_compose(state)
    project = values["WAREHOUSE_PROJECT_NAME"]
    image = project + "-functions"
    cache = state / "cache"
    edge = cache / "edge"
    require(not edge.exists(), "Edge cache already exists; preserve it or use fresh state")
    cache.mkdir(mode=0o700, exist_ok=True)
    edge.mkdir(mode=0o700)
    (edge / "dummy-instance.json").write_text("{}\n")
    names = ["main", "get-public-config", "hello", "get-config", "generate-sample-pdf", "generate-grn-pdf",
             "generate-dispatch-pdf", "generate-invoice-pdf", "generate-customer-stock-pdf", "operator-otp"]
    mounts = ["--mount", f"type=bind,src={edge},dst=/cache", "--mount", f"type=bind,src={ROOT / 'functions'},dst=/home/deno/functions,readonly"]
    for name in names:
        run(["docker", "run", "--rm", "--pull", "never", "--user", f"{os.getuid()}:{os.getgid()}", "--env", "DENO_DIR=/cache", *mounts,
             image, "bundle", "--entrypoint", f"/home/deno/functions/{name}/index.ts", "--output", f"/cache/{name}.eszip", "--timeout", "120"],
            state / "evidence/edge-cache.private.log")
    def probe(network):
        name = "warehouse-offline-probe-" + hashlib.sha256((str(state) + network).encode()).hexdigest()[:12]
        run(["docker", "run", "-d", "--pull", "never", "--name", name, "--network", network, "--user", f"{os.getuid()}:{os.getgid()}",
             "--env", "DENO_DIR=/cache", "--env", "INSTANCE_MANIFEST_PATH=/cache/dummy-instance.json", *mounts,
             image, "start", "--main-service", "/home/deno/functions/main"], state / "evidence/edge-cache.private.log")
        try:
            ready = False
            for _ in range(30):
                result = subprocess.run(["docker", "exec", name, "bash", "-c", "echo > /dev/tcp/127.0.0.1/9000"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode == 0:
                    ready = True
                    break
                time.sleep(1)
            if ready:
                response = state / f"evidence/edge-response-{network}.private.txt"
                run(["docker", "exec", name, "bash", "-c",
                     "exec 3<>/dev/tcp/127.0.0.1/9000; printf 'GET /get-public-config HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3; cat <&3"],
                    state / "evidence/edge-cache.private.log", output_path=response)
            logs = capture(["docker", "logs", name], state / "evidence/edge-cache.private.log")
            (state / f"evidence/edge-probe-{network}.private.log").write_bytes(logs)
            require(ready, f"Credential-free Edge runtime did not start on {network}")
        finally:
            run(["docker", "rm", "-f", name], state / "evidence/edge-cache.private.log")
    probe("bridge")
    probe("none")
    path = state / "config/isolation.json"
    override = json.loads(path.read_text())
    override["services"]["functions"]["environment"] = {"DENO_DIR": "/cache"}
    override["services"]["functions"]["volumes"] = [{"type": "bind", "source": str(edge), "target": "/cache"}]
    path.write_text(json.dumps(override, indent=2))
    validate_rendered(state)
    (state / "evidence/edge-cache-result.json").write_text(json.dumps({"bundles": len(names), "dummy_runtime_online_warmup": True,
                                                               "dummy_runtime_offline_start": True, "live_credentials_used": False}, indent=2))
    print("PASS: credential-free Edge dependencies cached and runtime started with network none.")


def build_core(state):
    """Build the pinned core images after staged restore, before service startup."""
    git_head()
    private_dir(state)
    require((state / "evidence/restore-result.json").is_file(), "Staged restore did not pass")
    validate_rendered(state)
    env, _ = env_for_compose(state)
    run(compose_args(state, "build", "functions", "realtime", "storage", "imgproxy", "meta", "studio", "gotenberg"),
        state / "evidence/build-core.private.log", env=env)
    (state / "evidence/build-result.json").write_text(json.dumps({"source_head": git_head(), "core_images_built": 7}, indent=2))
    print("PASS: seven isolated core images built; raw build output remains private.")


def realtime_partition_catalog(state):
    """Read actual partition links and security flags, not dump text."""
    query = """
SELECT row_to_json(partition)
FROM (
    SELECT c.relname AS name, c.relkind AS kind, c.relispartition AS is_partition,
           pg_get_userbyid(c.relowner) AS owner,
           parent_ns.nspname AS parent_schema, parent.relname AS parent_name,
           pg_get_expr(c.relpartbound, c.oid) AS bound,
           c.relrowsecurity AS row_security, c.relforcerowsecurity AS force_row_security,
           c.relpersistence AS persistence, c.relreplident AS replica_identity,
           c.reloptions AS options
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_inherits inheritance ON inheritance.inhrelid = c.oid
    LEFT JOIN pg_class parent ON parent.oid = inheritance.inhparent
    LEFT JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
    WHERE ns.nspname = 'realtime' AND c.relname ~ '^messages_[0-9]{4}_[0-9]{2}_[0-9]{2}$'
) partition ORDER BY partition.name;
"""
    raw = db_capture(state, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
                     "-U", "supabase_admin", "-d", "postgres", "-c", query)
    (state / "evidence/realtime-partitions.private.jsonl").write_bytes(raw)
    rows = [json.loads(line) for line in raw.splitlines()]
    require(len({row["name"] for row in rows}) == len(rows), "Duplicate Realtime partition catalog row")
    return {row["name"]: row for row in rows}


def archived_realtime_partitions(toc):
    """Get the peer partition owners from the verified archive TOC."""
    peers = {}
    for line in toc.splitlines():
        candidate = re.match(r"^\d+; \d+ \d+ TABLE realtime (messages_\d{4}_\d{2}_\d{2})(?=\s|$)", line)
        if candidate:
            match = re.fullmatch(r"\d+; \d+ \d+ TABLE realtime (messages_\d{4}_\d{2}_\d{2}) ([A-Za-z_][A-Za-z0-9_]*)", line)
            require(match is not None, "Archived Realtime partition owner has unsupported syntax")
            require(match[1] not in peers, "Duplicate archived Realtime partition")
            peers[match[1]] = match[2]
    require(len(peers) >= 2 and len(set(peers.values())) == 1,
            "Archived Realtime partition owners are missing or inconsistent")
    return peers


def reviewed_realtime_partition_grants(archived, actual, archived_peers, live_partitions):
    """Accept only the archived grant pattern on a new daily Realtime partition.

    Realtime can create the next messages partition while the ten services start.
    Every archived privilege remains mandatory; a new privilege on any other
    object, or a different privilege on the partition, still fails closed.
    """
    extra = actual - archived
    pattern = re.compile(
        r"^GRANT (ALL) ON TABLE realtime\.messages_(\d{4})_(\d{2})_(\d{2}) TO ([A-Za-z_][A-Za-z0-9_]*);$")
    templates = {name: Counter() for name in archived_peers}
    for statement, count in archived.items():
        # Any mention of a peer in an ACL statement must use the one reviewed
        # form. This also catches quoted identifiers and multi-table grants.
        mentioned = set(re.findall(r"(messages_\d{4}_\d{2}_\d{2})(?![A-Za-z0-9_])", statement))
        if mentioned.intersection(templates):
            match = pattern.fullmatch(statement)
            require(match is not None and mentioned == {"messages_" + "_".join(match.group(2, 3, 4))},
                    "Archived Realtime partition has unsupported privileges")
            templates[next(iter(mentioned))][(match[1], match[5])] += count
    reference = next(iter(templates.values()))
    require(len(reference) == 2 and all(grants == reference for grants in templates.values()),
            "Archived Realtime partition ACLs are missing or inconsistent")
    owner = next(iter(archived_peers.values()))
    security_fields = ("kind", "is_partition", "parent_schema", "parent_name",
                       "row_security", "force_row_security", "persistence", "replica_identity", "options")
    expected_security = ("r", True, "realtime", "messages", False, False, "p", "d", None)
    for name in archived_peers:
        row = live_partitions.get(name)
        require(row is not None and row["owner"] == owner,
                "Archived Realtime partition owner differs from verified archive")
        require(tuple(row[field] for field in security_fields) == expected_security,
                "Archived Realtime partition security properties differ")
        peer_day = date.fromisoformat(name.removeprefix("messages_").replace("_", "-"))
        peer_bound = ("FOR VALUES FROM ('" + peer_day.isoformat() + " 00:00:00')" +
                      " TO ('" + (peer_day + timedelta(days=1)).isoformat() + " 00:00:00')")
        require(row["bound"] == peer_bound, "Archived Realtime partition bounds differ")
    new = {}
    today = datetime.now(timezone.utc).date()
    new_partitions = set(live_partitions) - set(archived_peers)
    for name in new_partitions:
        match = re.fullmatch(r"messages_(\d{4})_(\d{2})_(\d{2})", name)
        require(match is not None, "Unexpected new Realtime partition name")
        partition_day = date(*(int(part) for part in match.groups()))
        require(0 <= (partition_day - today).days <= 7,
                "New Realtime partition date is outside the reviewed window")
        row = live_partitions[name]
        require(row["owner"] == owner and tuple(row[field] for field in security_fields) == expected_security,
                "New Realtime partition owner or security properties differ")
        expected_bound = ("FOR VALUES FROM ('" + partition_day.isoformat() + " 00:00:00')" +
                          " TO ('" + (partition_day + timedelta(days=1)).isoformat() + " 00:00:00')")
        require(row["bound"] == expected_bound, "New Realtime partition bounds differ")
    for statement, count in extra.items():
        match = pattern.fullmatch(statement)
        require(match is not None, "Restored catalog has extra privilege statements")
        partition_day = date(*(int(part) for part in match.group(2, 3, 4)))
        require(0 <= (partition_day - today).days <= 7,
                "New Realtime partition date is outside the reviewed window")
        table = "realtime.messages_" + "_".join(match.group(2, 3, 4))
        require(table.removeprefix("realtime.") not in archived_peers,
                "New Realtime partition was present in the archive")
        require(table.removeprefix("realtime.") in new_partitions,
                "New Realtime partition grant has no matching catalog partition")
        new.setdefault(table, Counter())[(match[1], match[5])] += count
    require({table.removeprefix("realtime.") for table in new} == new_partitions,
            "New Realtime partition is missing reviewed grants")
    require(all(grants == reference for grants in new.values()),
            "New Realtime partition grants differ from archived partitions")
    return sum(extra.values())


def catalog_checks(state):
    """Compare archived object owners and normalized ACL statements privately."""
    source_toc = state / "evidence/source-toc.private.txt"
    restored_toc = state / "evidence/restored-toc.private.txt"
    db_exec(state, "pg_dump", "-U", "supabase_admin", "-d", "postgres", "--schema-only", "-Fc", "-f", "/tmp/restored-schema.dump")
    source_toc.write_bytes(db_capture(state, "pg_restore", "-l", "/tmp/database.dump"))
    restored_toc.write_bytes(db_capture(state, "pg_restore", "-l", "/tmp/restored-schema.dump"))
    def entries(path):
        result = []
        for line in path.read_text().splitlines():
            if "; " not in line or not line[:1].isdigit():
                continue
            item = line.split("; ", 1)[1].split(" ", 2)[2]
            if item.startswith(("TABLE DATA ", "SEQUENCE SET ", "MATERIALIZED VIEW DATA ", "ACL ")):
                continue
            result.append(item)
        return Counter(result)
    missing = entries(source_toc) - entries(restored_toc)
    require(not missing, "Archived schema object or owner missing in restored catalog")
    source_sql = state / "evidence/source-schema.private.sql"
    restored_sql = state / "evidence/restored-schema.private.sql"
    db_exec(state, "pg_restore", "--schema-only", "-f", "-", "/tmp/database.dump", output_path=source_sql)
    db_exec(state, "pg_dump", "-U", "supabase_admin", "-d", "postgres", "--schema-only", output_path=restored_sql)
    def privileges(path):
        return Counter(line.strip() for line in path.read_text().splitlines()
                       if line.startswith(("GRANT ", "REVOKE ", "ALTER DEFAULT PRIVILEGES ")))
    archived, actual = privileges(source_sql), privileges(restored_sql)
    runtime_grants = reviewed_realtime_partition_grants(
        archived, actual, archived_realtime_partitions(source_toc.read_text()),
        realtime_partition_catalog(state))
    omitted = archived - actual
    require(all(line.startswith("REVOKE ") and " ON FUNCTION " in line and " FROM postgres;" in line for line in omitted.elements()),
            "Archived privilege grant or deny missing")
    return {"object_owners_and_definitions": True, "archived_grants_match": True,
            "redundant_postgres_function_revokes_normalized": sum(omitted.values()),
            "reviewed_realtime_partition_grants": runtime_grants}


def verify(state):
    git_head()
    private_dir(state)
    require((state / "evidence/restore-result.json").is_file(), "Staged restore did not pass")
    require((state / "evidence/build-result.json").is_file(), "Core image build did not pass")
    require((state / "evidence/edge-cache-result.json").is_file(), "Credential-free Edge cache check did not pass")
    rendered = validate_rendered(state)
    require(rendered["networks"]["default"]["internal"] is True, "Network isolation lost")
    env, _ = env_for_compose(state)
    # The root bind is private to this installation, but imgproxy runs as UID 999.
    # A named ACL grants only that service UID read/traverse on restored objects.
    run(["setfacl", "-R", "-m", "u:999:rX", str(state / "data/storage")], state / "evidence/verify.private.log")
    run(compose_args(state, "up", "-d", "--no-build", "--wait", "--wait-timeout", "300"), state / "evidence/start-core.private.log", env=env)
    services = wait_healthy(state)
    db_exec(state, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "supabase_admin", "-d", "postgres",
            input_path=ROOT / "scripts/replacement-access.sql")
    checks = local_checks(state, services)
    checks.update(catalog_checks(state))
    outbound = subprocess.run(["docker", "exec", services["functions"]["Id"], "bash", "-c",
                               "echo PROBE_STARTED; timeout 3 bash -c 'echo > /dev/tcp/1.1.1.1/443'"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with open(state / "evidence/verify.private.log", "ab") as log:
        log.write(outbound.stderr)
    require(outbound.stdout.strip() == b"PROBE_STARTED" and outbound.returncode not in (0, 125, 126, 127), "Runtime outbound TCP was allowed or probe failed")
    # Restore owned restart policy only after initial health and isolation checks.
    for item in services.values():
        run(["docker", "update", "--restart", "unless-stopped", item["Id"]], state / "evidence/verify.private.log")
    run(["docker", "restart", services["db"]["Id"]], state / "evidence/verify.private.log")
    services = wait_healthy(state)
    time.sleep(30)
    services = core_inspect(state)
    checks.update(local_checks(state, services))
    require(all(item["HostConfig"]["RestartPolicy"]["Name"] == "unless-stopped" for item in services.values()), "Owned restart policy missing")
    post = state / "evidence/post-service-data.private.sql"
    db_exec(state, "pg_dump", "-U", "supabase_admin", "-d", "postgres", "--data-only", "--no-owner", "--no-acl", output_path=post)
    original = state / "evidence/original-data.private.sql"
    def app_rows(path):
        blocks = {}
        current = None
        for line in path.read_text().splitlines():
            if line.startswith("COPY ") and line.endswith(" FROM stdin;"):
                current = line if re.match(r"^COPY (public|auth|storage|warehouse_security|warehouse_maintenance|warehouse_migrations)\.", line) else None
                if current:
                    blocks[current] = []
            elif line == "\\.":
                current = None
            elif current:
                blocks[current].append(line)
        return {key: sorted(value) for key, value in blocks.items()}
    require(app_rows(original) == app_rows(post), "Application, auth or storage rows changed during local checks")
    result = {"core_services": len(services), "internal_network": True, "runtime_outbound_tcp_blocked": True, "public_host_ports": 0, "owned_database_restart": True,
              "stable_health_after_restart": True, "application_rows_unchanged": True, **checks}
    (state / "evidence/verify-result.json").write_text(json.dumps(result, indent=2))
    print("PASS: isolated core health, saved identity/credentials, access controls, original PDF and owned restart recovery.")


def stop(state):
    """Stop only containers owned by this state; preserve private volumes and logs."""
    private_dir(state)
    rendered = validate_rendered(state)
    project = rendered["name"]
    ids = capture(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"], state / "evidence/stop.private.log").decode().split()
    if ids:
        items = json.loads(capture(["docker", "inspect", *ids], state / "evidence/stop.private.log"))
        for item in items:
            require(item["Config"]["Labels"].get("com.docker.compose.project.working_dir") == str(ROOT / "docker"), "Refusing to stop a foreign checkout")
            require(item["Config"]["Labels"].get("com.docker.compose.service") in CORE, "Refusing to stop an unreviewed service")
        env, _ = env_for_compose(state)
        run(compose_args(state, "stop"), state / "evidence/stop.private.log", env=env)
    running = capture(["docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={project}"], state / "evidence/stop.private.log")
    require(not running.strip(), "Owned service still running")
    print("PASS: owned isolated services stopped; data and evidence preserved.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "restore", "build", "cache", "verify", "stop"])
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        require(len(args.paths) == 2, "Usage: prepare BACKUP_DIR NEW_STATE_DIR")
        prepare(*args.paths)
    elif args.action == "restore":
        require(len(args.paths) == 1, "Usage: restore PREPARED_STATE_DIR")
        restore(args.paths[0])
    elif args.action == "cache":
        require(len(args.paths) == 1, "Usage: cache RESTORED_STATE_DIR")
        cache_edge(args.paths[0])
    elif args.action == "build":
        require(len(args.paths) == 1, "Usage: build RESTORED_STATE_DIR")
        build_core(args.paths[0])
    elif args.action == "stop":
        require(len(args.paths) == 1, "Usage: stop STATE_DIR")
        stop(args.paths[0])
    else:
        require(len(args.paths) == 1, "Usage: verify RESTORED_STATE_DIR")
        verify(args.paths[0])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, tarfile.TarError) as error:
        print(f"Replacement restore refused: {error}", file=sys.stderr)
        sys.exit(1)
