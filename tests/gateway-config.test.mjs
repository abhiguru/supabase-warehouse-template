import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { composeAvailable, renderCompose, renderedCompose } from './compose-render.mjs';
import { parseGatewayLog } from '../scripts/watch.mjs';

// The gateway is plain nginx (docker/nginx). These tests read the files as text and render the templates the way the image's
// entrypoint does; tests/gateway-nginx.test.mjs runs the real image (nginx -t, and the routes against stand-in upstreams).
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const compose = read('docker/docker-compose.yml');
const deploy = name => new URL(`../deploy/${name}`, import.meta.url);

const FILES = {
  main: read('docker/nginx/nginx.conf'),
  http: read('docker/nginx/api-http.conf'),
  locations: read('docker/nginx/api-locations.conf'),
  cors: read('docker/nginx/cors-headers.conf'),
  httpTemplate: read('docker/nginx/templates/http.conf.template'),
  gatewayTemplate: read('docker/nginx/templates/gateway.conf.template'),
  // The LAN server of the gateway-lan service, mounted over the public template in that one container (docker-compose.yml).
  lanTemplate: read('docker/nginx/lan/gateway-lan.conf.template'),
};
const dockerfile = read('docker/nginx/Dockerfile');
// What nginx reads: the text without its comment lines (every comment in these files is a whole line).
const code = text => text.split('\n').filter(line => !line.trim().startsWith('#')).join('\n');
const CODE = Object.fromEntries(Object.entries(FILES).map(([name, text]) => [name, code(text)]));

// The block that starts with `header {`; braces inside a quoted string (the JSON bodies) do not count.
function block(text, header) {
  const start = text.indexOf(`${header} {`);
  assert.ok(start >= 0, `no block "${header}"`);
  let depth = 0;
  let quote = null;
  for (let i = start + header.length; i < text.length; i += 1) {
    const c = text[i];
    if (quote) { if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"') { quote = c; continue; }
    if (c === '{') depth += 1;
    if (c === '}') { depth -= 1; if (depth === 0) return text.slice(start, i + 1); }
  }
  return assert.fail(`block "${header}" is not closed`);
}
const route = name => block(CODE.locations, `location ${name}`);

// The variables the image's entrypoint puts into the templates (NGINX_ENVSUBST_FILTER in docker/nginx/Dockerfile) and the
// way it does it: GNU envsubst replaces both forms, $NAME and the braced form, for a name the filter matches in full (checked on the
// real image in tests/gateway-nginx.test.mjs); every other dollar sign is left alone.
const filter = /^ENV NGINX_ENVSUBST_FILTER="\^\(([A-Z_|]+)\)\$"$/m.exec(dockerfile)?.[1].split('|');
const VALUES = { CORS_ALLOWED_ORIGIN: 'https://app.example.test', ANON_KEY: 'unit.anon.key', SERVICE_ROLE_KEY: 'unit.service.key', WAREHOUSE_MAINTENANCE: 'off', LAN_CIDR: '192.168.7.0/24', LAN_BIND_IP: '192.168.7.20', LAN_HTTP_PORT: '8181' };
const render = text => text.replace(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g, (all, braced, bare) => (filter.includes(braced ?? bare) ? VALUES[braced ?? bare] : all));
const RENDERED = { http: render(FILES.httpTemplate), gateway: render(FILES.gatewayTemplate), lan: render(FILES.lanTemplate) };

test('the gateway is nginx from docker/nginx: no Kong file, entrypoint override or Kong variable is left', () => {
  assert.ok(!existsSync(new URL('../docker/kong.yml', import.meta.url)), 'docker/kong.yml is gone');
  for (const file of ['Dockerfile', 'nginx.conf', 'api-http.conf', 'api-locations.conf', 'cors-headers.conf', 'templates/http.conf.template', 'templates/gateway.conf.template', 'lan/gateway-lan.conf.template', 'docker-entrypoint.d/18-require-env.sh']) {
    assert.ok(existsSync(new URL(`../docker/nginx/${file}`, import.meta.url)), `docker/nginx/${file}`);
  }
  const service = compose.slice(compose.indexOf('\n  gateway:\n'), compose.indexOf('\n  gateway-lan:\n'));
  assert.ok(service.length > 100, 'the gateway service was read');
  assert.match(service, /\n    build:\n      context: \.\/nginx\n/);
  // The templates are rendered by the image's own entrypoint: no `eval`, no replacement entrypoint or command.
  assert.doesNotMatch(service, /^\s+(?:entrypoint|command):/m);
  assert.doesNotMatch(service, /\beval\b/);
  // The only Kong name left in the Compose file is the old port variable, read as a fallback.
  assert.deepEqual(compose.match(/.*KONG.*/g).filter(line => !line.trim().startsWith('#')), ['      - "127.0.0.1:${GATEWAY_HTTP_PORT:-${KONG_HTTP_PORT:-18000}}:8000/tcp"']);
  assert.match(read('.env.example'), /^GATEWAY_HTTP_PORT=18000$/m);
  assert.doesNotMatch(read('.env.example'), /^KONG_/m);
});

test('the public templates hold exactly four variables, the LAN server three more, the image puts in only those, and no key or origin can add to the configuration', () => {
  assert.deepEqual([...filter].sort(), ['ANON_KEY', 'CORS_ALLOWED_ORIGIN', 'LAN_BIND_IP', 'LAN_CIDR', 'LAN_HTTP_PORT', 'SERVICE_ROLE_KEY', 'WAREHOUSE_MAINTENANCE']);
  const used = new Set();
  for (const [name, text] of Object.entries({ http: FILES.httpTemplate, gateway: FILES.gatewayTemplate })) {
    for (const match of text.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)) used.add(match[1]);
    // The entrypoint replaces $NAME as well as the braced form. A comment that wrote either would have the real key put into it,
    // and so would a bare $NAME in the configuration itself (the templates write the braced form only).
    const comments = text.split('\n').filter(line => line.trim().startsWith('#')).join('\n');
    assert.doesNotMatch(comments, /\$\{?(?:ANON_KEY|SERVICE_ROLE_KEY|CORS_ALLOWED_ORIGIN|WAREHOUSE_MAINTENANCE)\b/, `${name}: a comment writes a variable`);
    assert.doesNotMatch(comments, /\$\{/, `${name}: a comment writes a brace after a dollar sign`);
    assert.doesNotMatch(code(text), /\$(?:ANON_KEY|SERVICE_ROLE_KEY|CORS_ALLOWED_ORIGIN|WAREHOUSE_MAINTENANCE)\b/, `${name}: a variable without braces`);
  }
  assert.deepEqual([...used].sort(), ['ANON_KEY', 'CORS_ALLOWED_ORIGIN', 'SERVICE_ROLE_KEY', 'WAREHOUSE_MAINTENANCE'], 'the public templates have no LAN variable');
  // The LAN server holds LAN_CIDR (the allow list) once and LAN_BIND_IP and LAN_HTTP_PORT (the Host pin), and writes none of them in a comment (the
  // entrypoint would put the value into the comment too).
  assert.deepEqual([...FILES.lanTemplate.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map(match => match[1]), ['LAN_BIND_IP', 'LAN_BIND_IP', 'LAN_HTTP_PORT', 'LAN_CIDR']);
  assert.doesNotMatch(FILES.lanTemplate.split('\n').filter(line => line.trim().startsWith('#')).join('\n'), /\$\{?LAN_|\$\{/);
  assert.doesNotMatch(code(FILES.lanTemplate), /\$LAN_[A-Z_]+\b/, 'the braced form only');
  // The values are put in as they are: the rendered templates have none left, and keep every nginx variable.
  for (const [name, text] of Object.entries(RENDERED)) assert.doesNotMatch(text, /\$\{/, `${name}: an unreplaced variable`);
  assert.doesNotMatch(RENDERED.lan, /\$\{/, 'lan: an unreplaced variable');
  assert.match(RENDERED.lan, /^\s*allow 192\.168\.7\.0\/24;$/m);
  assert.match(RENDERED.lan, /^\s*"192\.168\.7\.20"\s+1;$/m);
  assert.match(RENDERED.lan, /^\s*"192\.168\.7\.20:8181"\s+1;$/m);
  assert.match(RENDERED.http, /default "https:\/\/app\.example\.test";/);
  assert.match(RENDERED.http, /"unit\.anon\.key"\s+"";/);
  assert.match(RENDERED.http, /"unit\.service\.key"\s+"";/);
  assert.match(code(RENDERED.http), /map \$http_apikey \$apikey_error/);
  // The container refuses to start on a value the configuration could not hold safely (checked for real in tests/gateway-nginx.test.mjs).
  const entry = read('docker/nginx/docker-entrypoint.d/18-require-env.sh');
  assert.match(entry, /\*\[!A-Za-z0-9\._~:\/-\]\*\)/);
  // The LAN container also refuses a missing or non-private LAN_CIDR, LAN_BIND_IP and a bad LAN_HTTP_PORT; the public one is not asked for them (checked
  // for real in the lab). Which container is the LAN one is decided by the template directory it reads (or the role), and by a template line that is
  // not a comment, never by a comment.
  assert.match(entry, /if \[ "\$\{GATEWAY_ROLE:-\}" = lan \] \|\| \[ "\$template_dir" = \/etc\/nginx\/templates-lan \]; then\n  lan_server=yes\nelif cat "\$template_dir"\/\*\.template 2>\/dev\/null \| grep -v '\^\[\[:space:\]\]\*#' \| grep -Eq /);
  assert.match(entry, /if \[ "\$lan_server" = yes \]; then\n  check LAN_CIDR "\$\{LAN_CIDR:-\}"/);
  assert.match(entry, /check LAN_BIND_IP "\$\{LAN_BIND_IP:-\}"/);
  assert.match(entry, /check LAN_HTTP_PORT "\$\{LAN_HTTP_PORT:-\}"/);
  assert.doesNotMatch(entry, /\beval\b/);
  assert.match(dockerfile, /^COPY --chmod=0755 docker-entrypoint\.d\/ \/docker-entrypoint\.d\/$/m);
  // The LAN server and the http-level template are in the image under templates-lan; nothing is mounted from the checkout.
  assert.match(dockerfile, /^COPY lan\/ \/etc\/nginx\/templates-lan\/$/m);
  assert.match(dockerfile, /^COPY templates\/http\.conf\.template \/etc\/nginx\/templates-lan\/http\.conf\.template$/m);
  // The compose environment names exactly those four and requires each of the three that are not a switch; the switch has the default `off` in both gateway services.
  for (const name of filter.filter(name => !name.startsWith('LAN_') && name !== 'WAREHOUSE_MAINTENANCE')) assert.match(compose, new RegExp(`\\n      ${name}: \\$\\{${name}:\\?[^}]+\\}\\n`), `${name} is required by Compose`);
  assert.equal((compose.match(/\n      WAREHOUSE_MAINTENANCE: \$\{WAREHOUSE_MAINTENANCE:-off\}\n/g) || []).length, 2, 'both gateway services take the switch, off by default');
  // The LAN names are for gateway-lan only and may be empty in Compose (the entrypoint refuses an empty one); the public gateway is not given them.
  for (const name of ['LAN_CIDR', 'LAN_BIND_IP', 'LAN_HTTP_PORT']) assert.equal((compose.match(new RegExp(`\\n      ${name}: \\$\\{${name}:-\\}\\n`, 'g')) || []).length, name === 'LAN_CIDR' ? 1 : 2, name);
});

test('gateway takes the client address from the tunnel hop only, in the public server only, and limits per client IP', () => {
  const server = CODE.gatewayTemplate;
  // One server, one listener, HTTP/2 on.
  assert.equal((server.match(/^\s*server\s*\{/gm) || []).length, 1);
  assert.deepEqual(server.match(/^\s*listen\s.*$/gm).map(line => line.trim()), ['listen 8000;']);
  assert.match(server, /^\s*http2 on;$/m);
  assert.match(server, /^\s*real_ip_header CF-Connecting-IP;$/m);
  assert.match(server, /^\s*real_ip_recursive off;$/m);
  assert.deepEqual([...server.matchAll(/^\s*set_real_ip_from (\S+);$/gm)].map(match => match[1]), ['127.0.0.1/32', '::1/128', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']);
  assert.equal((server.match(/^\s*include \/etc\/nginx\/api-locations\.conf;$/gm) || []).length, 1, 'the routes are one shared file');
  // The trust must not be in anything a second server (LAN mode) shares: that server would let a phone choose its own address.
  for (const name of ['main', 'http', 'locations', 'cors', 'httpTemplate']) {
    assert.doesNotMatch(CODE[name], /set_real_ip_from|real_ip_header|real_ip_recursive/, `${name} must not trust a client address`);
    assert.doesNotMatch(CODE[name], /^\s*(?:server\s*\{|listen\b)/m, `${name} defines no server`);
  }
  // Requests are limited per client address (the one realip settled on), nothing else.
  assert.match(CODE.http, /^limit_req_zone \$binary_remote_addr zone=rest:10m rate=30r\/s;$/m);
  assert.match(CODE.http, /^limit_req_zone \$binary_remote_addr zone=functions:10m rate=100r\/m;$/m);
  assert.deepEqual(CODE.http.match(/^limit_req_zone .*$/gm).length, 2, 'storage has no zone');
  assert.match(CODE.http, /^limit_req_status 429;$/m);
  assert.match(route('/rest/v1/'), /^\s*limit_req zone=rest burst=1800 nodelay;$/m);
  assert.match(route('/functions/v1/'), /^\s*limit_req zone=functions burst=100 nodelay;$/m);
  assert.doesNotMatch(route('/storage/v1/'), /limit_req/, 'storage has no rate limit (docs/CONTAINER_SECURITY.md)');
  assert.deepEqual(CODE.locations.match(/^\s*limit_req .*$/gm).length, 2);
});

test('request bodies are limited to 10 MB for REST and functions and 50 MB for storage, and are never written to a file', () => {
  for (const [name, size] of Object.entries({ '/rest/v1/': '10m', '/storage/v1/': '50m', '/functions/v1/': '10m' })) {
    assert.match(route(name), new RegExp(`^\\s*client_max_body_size ${size};$`, 'm'), `${name} body limit`);
  }
  assert.deepEqual(CODE.locations.match(/^\s*client_max_body_size .*$/gm).length, 3);
  // The temporary directories are on a tmpfs, so a spooled body would be memory (the anon key is public).
  assert.match(CODE.main, /^\s*proxy_request_buffering off;$/m);
  assert.match(route('/rest/v1/'), /^\s*proxy_max_temp_file_size 0;$/m);
  assert.match(route('/functions/v1/'), /^\s*proxy_max_temp_file_size 0;$/m);
  assert.match(route('/storage/v1/'), /^\s*proxy_buffering off;$/m);
  for (const name of ['client_body_temp_path', 'proxy_temp_path', 'fastcgi_temp_path', 'uwsgi_temp_path', 'scgi_temp_path']) {
    assert.match(CODE.main, new RegExp(`^\\s*${name}\\s+/tmp/\\w+;$`, 'm'), `${name} is under /tmp`);
  }
  assert.match(CODE.main, /^pid \/tmp\/nginx\.pid;$/m);
});

test('only the REST route checks the apikey, with the anon or the service key and the messages the app reads', () => {
  const http = code(RENDERED.http);
  const map = block(http, 'map $http_apikey $apikey_error');
  assert.deepEqual(
    [...map.matchAll(/^\s+("[^"]*"|default)\s+("[^"]*");$/gm)].map(match => [match[1], match[2]]),
    [['default', '"Unauthorized"'], ['""', '"No API key found in request"'], ['"unit.anon.key"', '""'], ['"unit.service.key"', '""']],
  );
  assert.match(route('/rest/v1/'), /^\s*if \(\$apikey_error != ""\) \{ return 401; \}$/m);
  for (const name of ['/storage/v1/', '/functions/v1/']) assert.doesNotMatch(route(name), /apikey_error|return 401/, `${name} has no key check`);
  // The 401 body: the mobile app ends the session on exactly these two messages (src/config/supabaseConfig.ts, GATEWAY_KEY_REJECTIONS).
  assert.match(block(CODE.locations, 'location @json_401'), /return 401 '\{"message":"\$apikey_error"\}';/);
  assert.match(block(CODE.locations, 'location @json_401'), /add_header WWW-Authenticate Key always;/);
  // The key is checked here and not passed on (Kong's hide_credentials); a client address header is never passed on as the client sent it.
  assert.match(route('/rest/v1/'), /^\s*proxy_set_header apikey "";$/m);
  // The check runs before the rate limit, and the preflight before the check, so a refused request does not use up the budget.
  const rest = route('/rest/v1/');
  assert.ok(rest.indexOf('$cors_preflight') < rest.indexOf('$apikey_error') && rest.indexOf('$apikey_error') < rest.indexOf('limit_req'));
});

test('CORS: the one configured origin, with credentials, answered at the gateway with the lists Kong sent', () => {
  // The origin comes from the variable, as one exact value; never a wildcard.
  assert.match(code(RENDERED.http), /^\s*default "https:\/\/app\.example\.test";$/m);
  assert.doesNotMatch(code(FILES.httpTemplate), /default "\*"|default \*/);
  assert.doesNotMatch(Object.values(CODE).join('\n'), /Access-Control-Allow-Origin\s+\*|Access-Control-Allow-Origin\s+"\*"/);
  assert.match(CODE.cors, /^add_header Access-Control-Allow-Origin \$cors_allowed_origin always;$/m);
  assert.match(CODE.cors, /^add_header Access-Control-Allow-Credentials true always;$/m);
  assert.match(CODE.cors, /^add_header Vary Origin always;$/m);
  assert.match(CODE.cors, /^add_header Access-Control-Expose-Headers \$cors_expose always;$/m);
  const routes = {
    '/rest/v1/': ['GET,POST,PUT,PATCH,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey,Prefer,Range', 'Content-Range,X-Request-Id'],
    '/storage/v1/': ['GET,POST,PUT,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey,Cache-Control,X-Upsert', 'Content-Range,X-Request-Id'],
    '/functions/v1/': ['GET,POST,PUT,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey', 'X-Request-Id'],
  };
  for (const [name, [methods, headers, exposed]] of Object.entries(routes)) {
    const text = route(name);
    const preflight = block(text, 'if ($cors_preflight)');
    assert.match(preflight, new RegExp(`add_header Access-Control-Allow-Methods "${methods}" always;`), `${name} methods`);
    assert.match(preflight, new RegExp(`add_header Access-Control-Allow-Headers "${headers}" always;`), `${name} headers`);
    assert.match(preflight, /add_header Access-Control-Max-Age 86400 always;/, `${name} max age`);
    assert.match(preflight, /include \/etc\/nginx\/cors-headers\.conf;/, `${name} preflight carries the origin and credentials`);
    assert.match(preflight, /return 204;/);
    assert.match(text, new RegExp(`^\\s*set \\$cors_expose "${exposed}";$`, 'm'), `${name} exposed headers`);
    // An upstream's own CORS headers would double the header the browser reads.
    for (const header of ['Allow-Origin', 'Allow-Credentials', 'Expose-Headers']) assert.match(text, new RegExp(`^\\s*proxy_hide_header Access-Control-${header};$`, 'm'), `${name} hides the upstream's ${header}`);
  }
  // A preflight is an OPTIONS request with an Origin and a requested method; any other OPTIONS request goes upstream.
  assert.match(CODE.http, /map "\$request_method\|\$http_origin\|\$http_access_control_request_method" \$cors_preflight \{\n\s+default 0;\n\s+"~\^OPTIONS\\\|\[\^\|\]\+\\\|\[\^\|\]\+\$" 1;/);
  // The errors the gateway makes carry the CORS headers too, so a browser can read them.
  for (const status of [401, 404, 413, 429, 502, 503, 504]) {
    assert.match(block(CODE.locations, `location @json_${status}`), /include \/etc\/nginx\/cors-headers\.conf;/, `the ${status} answer`);
    assert.match(CODE.locations, new RegExp(`^error_page ${status} @json_${status};$`, 'm'));
  }
});

// Maintenance mode (WAREHOUSE_MAINTENANCE, docs/OPERATOR_INSTALL.md "While it upgrades"): tests/gateway-nginx.test.mjs runs it for real.
test('maintenance mode: after the preflight every API route answers the 503 that says upgrading, with Retry-After 120; /health is not touched; only off and upgrading are accepted', () => {
  // The word reaches the configuration as one map value (the public template, copied into the LAN directory of the image); everything else is derived from it.
  assert.match(code(FILES.httpTemplate), /map \$server_name \$maintenance_mode \{\n\s+default "\$\{WAREHOUSE_MAINTENANCE\}";\n\}/);
  assert.match(CODE.http, /map \$maintenance_mode \$maintenance_on \{\n\s+default\s+0;\n\s+upgrading 1;\n\}/);
  assert.match(CODE.http, /map \$maintenance_mode \$unavailable_retry_after \{\n\s+default\s+"";\n\s+upgrading 120;\n\}/);
  const bodies = /map \$maintenance_mode \$unavailable_body \{\n\s+default\s+('[^\n]+');\n\s+upgrading\s+('[^\n]+');\n\}/.exec(CODE.http);
  assert.ok(bodies, 'the bodies of the 503');
  const body = text => JSON.parse(text.slice(1, -1).replace("\\'", "'"));
  assert.deepEqual(body(bodies[1]), { message: 'The upstream server is unavailable' }, 'an upstream that does not answer: the body Kong sent');
  assert.deepEqual(body(bodies[2]), { code: 'upgrading', message: "The facility's server is being updated. Try again in a few minutes." });
  const answer = block(CODE.locations, 'location @json_503');
  assert.match(answer, /add_header Retry-After \$unavailable_retry_after always;/);
  assert.match(answer, /include \/etc\/nginx\/cors-headers\.conf;/, 'the app reads it, and the path header is on it');
  assert.match(answer, /return 503 \$unavailable_body;/);
  // On each route: the preflight first (so the app can read the answer), then the refusal, and before everything that could answer something else.
  for (const name of ['/rest/v1/', '/storage/v1/', '/functions/v1/']) {
    const text = route(name);
    const refusal = '    if ($maintenance_on) { return 503; }';
    assert.equal(text.split(refusal).length - 1, 1, `${name}: one refusal`);
    const at = needle => text.indexOf(needle);
    assert.ok(at('if ($cors_preflight)') >= 0 && at('if ($cors_preflight)') < at(refusal), `${name}: the preflight is answered first`);
    assert.ok(at(refusal) < at('return 404;'), `${name}: before the path check`);
    for (const later of ['return 401;', 'limit_req ', 'proxy_pass ']) if (at(later) >= 0) assert.ok(at(refusal) < at(later), `${name}: before ${later.trim()}`);
    // `return` is the only thing done inside an `if` (nginx's rule for a safe `if`), here as in the rest of the file.
    assert.deepEqual([...text.matchAll(/^\s*if \(\$maintenance_on\) \{ ([^}]*) \}$/gm)].map(match => match[1]), ['return 503;']);
  }
  // Not a route of the API: nothing outside the three is touched, and the container's own health check answers as always.
  assert.doesNotMatch(CODE.gatewayTemplate + CODE.lanTemplate, /maintenance/);
  assert.doesNotMatch(CODE.locations.replace(/if \(\$maintenance_on\) \{ return 503; \}/g, ''), /maintenance/);
  // The container: nothing set means off, only the two words start it, and both gateway services pass the same switch (gateway-lan: the other way in).
  const entry = read('docker/nginx/docker-entrypoint.d/18-require-env.sh');
  assert.match(entry, /case "\$\{WAREHOUSE_MAINTENANCE:-\}" in\n\s+off\|upgrading\) ;;\n\s+\*\) fail "WAREHOUSE_MAINTENANCE must be off or upgrading" ;;\nesac/);
  const defaults = new URL('../docker/nginx/docker-entrypoint.d/17-maintenance-default.envsh', import.meta.url);
  assert.match(readFileSync(defaults, 'utf8').split('\n').filter(line => !line.startsWith('#')).join('\n'), /^: "\$\{WAREHOUSE_MAINTENANCE:=off\}"\nexport WAREHOUSE_MAINTENANCE$/m);
  assert.ok((statSync(defaults).mode & 0o111) !== 0, 'the image\'s entrypoint sources an executable .envsh only');
});

// The first line of each path map (docker/nginx/api-http.conf): a dot segment in the raw path, `.` or `..` written plainly or as
// %2e, between slashes (or %2F), at the end of the path or in front of the query string. The query string itself is not looked at.
const DOT_SEGMENT = String.raw`"~^[^?]*(?:/|%2[fF])(?:\.|%2[eE]){1,2}(?:/|%2[fF]|\?|$)" "";`;
const escapeRegExp = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
test('each route strips its prefix as Kong did, to the same upstream, and keeps the path as the client wrote it', () => {
  const upstreams = Object.fromEntries([...CODE.http.matchAll(/upstream (\w+) \{[^}]*?server (\S+) resolve;[^}]*?keepalive (\d+);[^}]*\}/g)].map(match => [match[1], [match[2], Number(match[3])]]));
  assert.deepEqual(upstreams, { rest_up: ['rest:3000', 64], storage_up: ['storage:5000', 64], functions_up: ['functions:9000', 64] });
  for (const [name, upstream, path, host] of [['/rest/v1/', 'rest_up', 'rest_path', 'rest:3000'], ['/storage/v1/', 'storage_up', 'storage_path', 'storage:5000'], ['/functions/v1/', 'functions_up', 'functions_path', 'functions:9000']]) {
    const text = route(name);
    assert.match(text, new RegExp(`^\\s*proxy_pass http://${upstream}\\$${path};$`, 'm'), `${name} upstream`);
    assert.match(text, new RegExp(`^\\s*proxy_set_header Host ${host};$`, 'm'), `${name} host header`);
    assert.match(text, new RegExp(`^\\s*if \\(\\$${path} = ""\\) \\{ return 404; \\}$`, 'm'), `${name} refuses a path whose raw form is not under the prefix`);
    assert.match(text, /^\s*proxy_http_version 1\.1;$/m);
    assert.match(text, /^\s*proxy_set_header Connection "";$/m, 'keepalive to the upstream');
    // The prefix comes off the raw request URI (path and query string), with several slashes in front accepted.
    const prefix = name.replace(/\/$/, '').replace(/\//g, '\\/');
    // A raw dot segment comes first and gives no path (404); the prefix map follows.
    assert.match(CODE.http, new RegExp(`map \\$request_uri \\$${path} \\{\\n\\s+default "";\\n\\s+${escapeRegExp(DOT_SEGMENT)}\\n\\s+"~\\^/\\+${name.slice(1, -1).replace('/', '/')}\\(\\?<\\w+>/\\.\\*\\)\\$" \\$\\w+;`), `${name} prefix map ${prefix}`);
  }
  // The route set is pinned: the locations of the routes file are exactly these, and three of them proxy (a fourth `proxy_pass`, or a
  // proxying location of another name, would be a route nobody reviewed, with no key check, limit or CORS handling).
  assert.deepEqual([...CODE.locations.matchAll(/^location (\S+ )?(\S+) \{/gm)].map(match => `${match[1] ?? ''}${match[2]}`),
    ['@json_401', '@json_404', '@json_413', '@json_429', '@json_502', '@json_503', '@json_504', '/', '= /rest/v1', '= /storage/v1', '= /functions/v1', '/rest/v1/', '/storage/v1/', '/functions/v1/']);
  assert.deepEqual([...CODE.locations.matchAll(/^\s*proxy_pass (\S+);$/gm)].map(match => match[1]), ['http://rest_up$rest_path', 'http://storage_up$storage_path', 'http://functions_up$functions_path']);
  assert.doesNotMatch(CODE.locations, /\b(?:fastcgi_pass|uwsgi_pass|scgi_pass|grpc_pass|proxy_cache|mirror|auth_request)\b/);
  assert.doesNotMatch(CODE.gatewayTemplate, /proxy_pass/, 'the public server proxies nothing of its own');
  // The exact prefix without its slash and every other path have no route (nginx would redirect the first).
  for (const name of ['/rest/v1', '/storage/v1', '/functions/v1']) assert.match(CODE.locations, new RegExp(`^location = ${name} \\{ return 404; \\}$`, 'm'));
  assert.match(CODE.locations, /^location \/ \{ return 404; \}$/m);
  assert.match(block(CODE.locations, 'location @json_404'), /return 404 '\{"message":"no Route matched with those values"\}';/);
});

test('the client address header: set from the connection on REST and functions, cleared on storage, never taken from the request', () => {
  for (const name of ['/rest/v1/', '/functions/v1/']) {
    const text = route(name);
    assert.match(text, /^\s*proxy_set_header CF-Connecting-IP \$remote_addr;$/m, `${name} sets the address`);
    assert.match(text, /^\s*proxy_set_header X-Real-IP \$remote_addr;$/m);
    assert.match(text, /^\s*proxy_set_header X-Forwarded-For \$remote_addr;$/m);
  }
  // Storage does not use the client address (its image-render limit is off) but writes these headers into its own log.
  const storage = route('/storage/v1/');
  for (const header of ['CF-Connecting-IP', 'X-Real-IP', 'X-Forwarded-For']) assert.match(storage, new RegExp(`^\\s*proxy_set_header ${header} "";$`, 'm'), `storage: ${header} is cleared`);
  assert.doesNotMatch(Object.values(CODE).join('\n'), /\$http_cf_connecting_ip|\$http_x_forwarded_for|\$http_x_real_ip|\$proxy_add_x_forwarded_for/, 'a client-supplied address is never put into a header');
});

// The environment variables and the header names are fixed text, so the log line the checker parses is the format below.
const FORBIDDEN_IN_ACCESS_LOG = [
  // The request line and anything that carries the query string.
  /\$request(?![_a-z])/, /\$request_uri/, /\$args/, /\$is_args/, /\$query_string/, /\$arg_/, /\$upstream_uri/, /\$upstream_x_forwarded_path/,
  // Fields that can carry a credential or a person.
  /\$http_/, /\$remote_user/, /\$cookie_/, /\$sent_http_/,
];

test('the gateway access log has no query string, so a signed link or an apikey in a URL is not kept', () => {
  // Kong's default format (and nginx's) logs `$request`, the whole request line with ?token= and ?apikey=.
  const formats = [...CODE.main.matchAll(/^\s*log_format (\w+) '([^']*)';$/gm)];
  assert.deepEqual(formats.map(match => match[1]), ['warehouse_redacted'], 'one format, with the one name');
  const format = formats[0][2];
  assert.ok(format.includes('$uri'), 'the path is logged as $uri (no query string)');
  assert.ok(format.includes('$remote_addr'), 'the client address stays in the log (owner decision of 2026-10-17)');
  for (const pattern of FORBIDDEN_IN_ACCESS_LOG) assert.doesNotMatch(format, pattern, `the format must not contain ${pattern}`);
  assert.equal(format, '$remote_addr [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent $request_time');
  // The access log is the redacted format on stdout, in one place; the health check is not logged at all; no server or route sets another.
  assert.deepEqual(CODE.main.match(/^\s*access_log .*$/gm).map(line => line.trim()), ['access_log /dev/stdout warehouse_redacted;']);
  assert.deepEqual(CODE.gatewayTemplate.match(/^\s*access_log .*$/gm).map(line => line.trim()), ['access_log off;']);
  assert.doesNotMatch(CODE.locations + CODE.http + CODE.httpTemplate, /access_log|log_format/);
  // The checker (scripts/watch.mjs, checkApiLogs) reads the line this format writes.
  const line = format.replace('$remote_addr', '172.18.0.1').replace('$time_local', '26/Oct/2026:10:00:00 +0000').replace('$request_method', 'GET').replace('$uri', '/storage/v1/object/sign/docs/a.pdf')
    .replace('$server_protocol', 'HTTP/1.1').replace('$status', '429').replace('$body_bytes_sent', '37').replace('$request_time', '0.001');
  assert.equal(line, '172.18.0.1 [26/Oct/2026:10:00:00 +0000] "GET /storage/v1/object/sign/docs/a.pdf HTTP/1.1" 429 37 0.001');
  assert.deepEqual(parseGatewayLog(line), [{ status: 429, seconds: 0.001 }]);
});

test('storage is not sent the client address, and the log contract says what the gateway keeps and what it cannot', () => {
  const docs = read('docs/CONTAINER_SECURITY.md');
  const start = docs.indexOf('\n## Logs\n');
  assert.ok(start > 0, 'docs/CONTAINER_SECURITY.md has the Logs section');
  const section = docs.slice(start + 1, docs.indexOf('\n## ', start + 1)).replace(/\s+/g, ' ');
  for (const needed of ['warehouse_redacted', 'no log line holds a token, a key, an OTP', 'X-Real-IP', 'X-Forwarded-For', 'error log', '3 x 10 MB']) {
    assert.ok(section.toLowerCase().includes(needed.toLowerCase()), `the Logs section does not mention ${needed}`);
  }
  assert.doesNotMatch(section, /Kong sets them itself/, 'the old limit of the Kong plugin is gone');
});

test('the gateway runs one worker, hides its version, looks its upstreams up at run time, keeps its answer buffers small and compresses as Kong did', () => {
  assert.match(CODE.main, /^worker_processes 1;$/m);
  assert.match(CODE.main, /^\s*server_tokens off;$/m);
  assert.match(CODE.main, /^\s*resolver 127\.0\.0\.11 valid=5s ipv6=off;$/m);
  assert.doesNotMatch(CODE.main + CODE.http + CODE.locations, /^\s*(?:user|daemon)\b/m);
  // Answer buffers inside a 128 MB container: REST and functions hold at most 32k + 16 x 32k = about 0.5 MB of one answer (Kong's
  // 64 x 160k, up to 10 MB a request, cost 7 MiB for each reader that stops reading a 10 MB answer, with the socket buffers; this costs
  // about 4 MiB), and never write a file. Storage is not buffered at all and relays through one buffer of 64k (the default would be 4k).
  const buffers = Object.fromEntries(['/rest/v1/', '/functions/v1/'].map(name => [name, [Number(/^\s*proxy_buffer_size (\d+)k;$/m.exec(route(name))?.[1]), /^\s*proxy_buffers (\d+) (\d+)k;$/m.exec(route(name))?.slice(1).map(Number)]]));
  assert.deepEqual(buffers, { '/rest/v1/': [32, [16, 32]], '/functions/v1/': [32, [16, 32]] });
  for (const [size, [count, each]] of Object.values(buffers)) assert.ok(size + count * each <= 600, 'at most about 0.5 MB of buffers for one answer');
  assert.match(route('/storage/v1/'), /^\s*proxy_buffering off;$/m);
  assert.match(route('/storage/v1/'), /^\s*proxy_buffer_size 64k;$/m);
  assert.match(route('/storage/v1/'), /^\s*proxy_buffers 4 64k;$/m, 'only so that nginx accepts the larger buffer; unused with buffering off');
  // A request body that arrives slowly is cut off after 20 s between two reads (it is streamed to the upstream, not collected first).
  for (const name of ['/rest/v1/', '/functions/v1/']) assert.match(route(name), /^\s*client_body_timeout 20s;$/m, `${name} body timeout`);
  // Compress JSON and text answers only, as the invoice-form preview of 3,055 lines (2.2 MB of JSON) needs.
  const main = CODE.main;
  assert.match(main, /^\s*gzip on;$/m);
  assert.match(main, /^\s*gzip_proxied any;$/m, 'answers that came through the tunnel proxy are compressed too');
  assert.match(main, /^\s*gzip_min_length 1024;$/m);
  assert.match(main, /^\s*gzip_vary on;$/m);
  const types = main.match(/^\s*gzip_types (.*);$/m)[1].split(/\s+/);
  for (const type of ['application/json', 'application/vnd.pgrst.object+json', 'application/vnd.pgrst.array+json', 'text/plain', 'text/csv']) assert.ok(types.includes(type), `${type} is compressed`);
  // Images, PDFs and other downloads stay as stored; the websocket upgrade is not an answer type.
  assert.ok(!types.some(type => /^(image|video|audio)\//.test(type) || /pdf|octet-stream|zip/.test(type)), 'no binary type is listed');
  // Idle clients: 75 s, at most 10000 requests, as before.
  assert.match(main, /^\s*keepalive_timeout 75s;$/m);
  assert.match(main, /^\s*keepalive_requests 10000;$/m);
});

test('the gateway service publishes one loopback port, is read-only with no capability, and is limited to 128 MB and half a CPU', () => {
  const service = compose.slice(compose.indexOf('\n  gateway:\n'), compose.indexOf('\n  gateway-lan:\n'));
  assert.equal((compose.match(/^\s+ports:/gm) || []).length, 2, 'the operator stack publishes the gateway port and, in profile lan, the LAN port (and nothing else)');
  assert.match(service, /\n    ports:\n/);
  assert.match(service, /"127\.0\.0\.1:\$\{GATEWAY_HTTP_PORT:-\$\{KONG_HTTP_PORT:-18000\}\}:8000\/tcp"/);
  assert.match(service, /\n    read_only: true\n/);
  assert.match(service, /\n    cap_drop: \[ALL\]\n/);
  assert.doesNotMatch(service, /cap_add/);
  assert.match(service, /\n    security_opt: \["no-new-privileges:true"\]\n/);
  assert.match(service, /\n          cpus: '0\.5'\n          memory: 128M\n/);
  assert.match(service, /test: \["CMD", "wget", "-q", "-T", "5", "-O", "\/dev\/null", "http:\/\/127\.0\.0\.1:8000\/health"\]/);
  // /health answers the container's own check (from 127.0.0.1) and nobody else, a tunnel client included.
  assert.match(code(FILES.gatewayTemplate), /location = \/health \{\n\s+if \(\$remote_addr != "127\.0\.0\.1"\) \{ return 404; \}\n\s+access_log off;\n\s+default_type text\/plain;\n\s+return 200 "ok\\n";\n\s+\}/);
  assert.match(service, /\n    depends_on:\n      db:\n        condition: service_healthy\n/);
  assert.doesNotMatch(service, /\n    networks:/, 'the default network only');
  assert.match(service, /- \/tmp:size=4m\n/);
  assert.match(service, /- \/etc\/nginx\/conf\.d:uid=101,gid=101,mode=0755,size=1m\n/);
});

test('the rendered Compose gateway has the hardening, the limits, the port and the four variables', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const { services } = renderedCompose();
  const gateway = services.gateway;
  assert.equal(services.kong, undefined, 'there is no Kong service');
  assert.ok(gateway.build, 'built from docker/nginx');
  assert.equal(gateway.read_only, true);
  assert.deepEqual(gateway.cap_drop, ['ALL']);
  assert.equal(gateway.cap_add, undefined);
  assert.deepEqual(gateway.security_opt, ['no-new-privileges:true']);
  assert.ok(!gateway.entrypoint && !gateway.command, 'the image\'s own entrypoint renders the templates');
  assert.equal(gateway.dns_search, undefined);
  assert.deepEqual(gateway.networks, { default: null });
  assert.equal(Number(gateway.deploy.resources.limits.memory), 128 * 1024 ** 2);
  assert.equal(Number(gateway.deploy.resources.limits.cpus), 0.5);
  assert.deepEqual(gateway.ports.map(({ host_ip, target, protocol }) => [host_ip, target, protocol]), [['127.0.0.1', 8000, 'tcp']]);
  assert.match(String(gateway.ports[0].published), /^\d{4,5}$/);
  assert.deepEqual(Object.keys(gateway.environment).sort(), ['ANON_KEY', 'CORS_ALLOWED_ORIGIN', 'SERVICE_ROLE_KEY', 'WAREHOUSE_MAINTENANCE']);
  assert.equal(gateway.environment.WAREHOUSE_MAINTENANCE, 'off', 'a state without the marker is not in maintenance mode');
  assert.ok(gateway.environment.ANON_KEY.length > 20 && gateway.environment.SERVICE_ROLE_KEY.length > 20);
  for (const key of Object.keys(gateway.environment)) assert.doesNotMatch(gateway.environment[key], /[\s"'$;{}]/, `${key} holds nothing the configuration could not hold`);
  // The LAN service is the only other one that publishes a port (tests below).
  assert.deepEqual(Object.keys(services).filter(name => services[name].ports?.length).sort(), ['gateway', 'gateway-lan']);
});

test('the published port is GATEWAY_HTTP_PORT, or KONG_HTTP_PORT in a compose.env that has the old name, or 18000', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const published = edit => {
    const result = renderCompose(edit);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout).services.gateway.ports.map(port => String(port.published));
  };
  assert.deepEqual(published(text => text.replace(/^GATEWAY_HTTP_PORT=.*$/m, 'GATEWAY_HTTP_PORT=18123')), ['18123']);
  assert.deepEqual(published(text => text.replace(/^GATEWAY_HTTP_PORT=.*$/m, 'KONG_HTTP_PORT=18124')), ['18124'], 'the old name still decides the port');
  assert.deepEqual(published(text => text.replace(/^GATEWAY_HTTP_PORT=.*$/m, 'KONG_HTTP_PORT=18124\nGATEWAY_HTTP_PORT=18125')), ['18125'], 'the new name wins');
  assert.deepEqual(published(text => text.replace(/^GATEWAY_HTTP_PORT=.*\n/m, '')), ['18000'], 'neither name: the default of the tunnel example');
});

test('the REST limit leaves a whole facility room to work and cannot lock it out for an hour', () => {
  // Every phone on the facility network reaches the gateway from one public address, so the facility shares one bucket
  // (docs/CONTAINER_SECURITY.md, REST request limit; owner decision of 2026-10-11). The old limit of 300 a minute and 6000 an hour
  // gave 100 phones 3 requests a minute each and 60 an hour each, and once the hour was used up every phone was refused until it ended.
  const devices = 100;
  const rate = Number(/zone=rest:10m rate=(\d+)r\/s;/.exec(CODE.http)[1]);
  const burst = Number(/limit_req zone=rest burst=(\d+) nodelay;/.exec(route('/rest/v1/'))[1]);
  assert.equal(rate, 30);
  assert.equal(burst, 1800);
  assert.equal(rate * 60, 1800, 'a minute at the refill rate is the 1800 of the owner decision');
  assert.equal(rate * 60 / devices, 18, 'requests a minute for each of 100 phones working at once');
  // Nothing longer than the bucket: no hourly or daily rule in the REST route or anywhere in the gateway.
  assert.doesNotMatch(CODE.http + CODE.locations, /r\/h|r\/d|\bhour\b/);
  // The 6000-an-hour rule of the functions route is not a second zone either: 100 a minute adds up to 6000 an hour.
  assert.equal(CODE.http.match(/limit_req_zone/g).length, 2);
});

test('the limits are described as a leaky bucket (a burst, then a steady rate), not as a counter per fixed minute', () => {
  // Kong's rate-limiting plugin counted in fixed windows. nginx's limit_req is a leaky bucket: 1800 requests may come at once,
  // and then 30 a second. Wording that still promised a fixed minute, or no per-second brake, would be wrong now.
  const docs = read('docs/CONTAINER_SECURITY.md');
  const section = (from, to) => { const start = docs.indexOf(from); assert.ok(start > 0, from); return docs.slice(start, docs.indexOf(to, start + from.length)); };
  const texts = {
    'docker/nginx/api-http.conf': FILES.http.slice(0, FILES.http.indexOf('limit_req_zone $binary_remote_addr zone=rest')),
    'docs/CONTAINER_SECURITY.md, REST request limit': section('### REST request limit', '\n## '),
  };
  for (const [where, text] of Object.entries(texts)) {
    const plain = text.replace(/^\s*#\s?/gm, '').replace(/\s+/g, ' ');
    assert.match(plain, /leaky bucket/, `${where} does not say it is a leaky bucket`);
    assert.match(plain, /burst of 1800/, `${where} does not name the burst`);
    assert.match(plain, /30 a second/, `${where} does not name the refill rate`);
    assert.match(plain, /no hourly window/, `${where} does not say there is no hourly window`);
    assert.doesNotMatch(plain, /per fixed minute|no per-second brake|(sent|starts) again within the minute/, `${where} still describes Kong's fixed window`);
  }
  assert.doesNotMatch(Object.values(CODE).join('\n'), /^\s*(second|minute|hour): \d+$/m);
});

test('every REST request passes the session check before its function runs', () => {
  // public.check_session refuses an ended session and a profile that is disabled or
  // not approved. Functions that resolve the caller themselves (own_profile_id in
  // migration 38 checks active only) rely on it for the enrollment state; see
  // tests/preferred_language.sql.
  assert.match(compose, /\n\s+PGRST_DB_PRE_REQUEST: public\.check_session\n/);
});

const withoutComments = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8').split('\n').filter(line => !line.trim().startsWith('--')).join('\n');

test('the JWT signing secret is not published as a database or PostgREST setting', () => {
  // TW-BE-003: "app.settings.jwt_secret" is readable by every database role through current_setting().
  // The database code reads warehouse_security.auth_config; PostgREST takes the secret from PGRST_JWT_SECRET.
  assert.doesNotMatch(compose, /APP_SETTINGS_JWT_SECRET/, 'PostgREST must not set the secret as an app setting');
  assert.match(compose, /\n\s+PGRST_JWT_SECRET: \$\{JWT_SECRET\}\n/, 'PostgREST still verifies tokens');
  // Nothing reads app.settings.jwt_exp (the database code takes the lifetime from warehouse_security.auth_config), so no
  // database setting and no PostgREST app setting carries it either.
  assert.doesNotMatch(compose, /APP_SETTINGS_JWT_EXP/, 'PostgREST must not set the expiry as an app setting');
  assert.ok(!existsSync(new URL('../docker/volumes/db/jwt.sql', import.meta.url)), 'jwt.sql is gone: nothing sets app.settings.jwt_exp');
  assert.doesNotMatch(withoutComments('scripts/rotate-auth.sql'), /app\.settings\.jwt_secret/, 'rotation must not set the secret as a database setting');
  // Every run of the auth configuration removes it again, at database level and for roles.
  const configure = withoutComments('scripts/configure-auth.sql');
  assert.match(configure, /ALTER DATABASE %I RESET "app\.settings\.jwt_secret"/);
  assert.match(configure, /ALTER ROLE %I IN DATABASE %I RESET "app\.settings\.jwt_secret"/);
  assert.match(configure, /ALTER ROLE %I RESET "app\.settings\.jwt_secret"/);
  assert.doesNotMatch(configure, /(?<![A-Z])SET "app\.settings\.jwt_secret"/, 'configure-auth.sql must only reset the setting');
});

test('the rendered Compose project has no app setting that carries the JWT signing secret', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const { services } = renderedCompose();
  assert.ok(services.rest.environment.PGRST_JWT_SECRET, 'PostgREST has no secret to verify tokens with');
  for (const [name, definition] of Object.entries(services)) {
    const settings = Object.keys(definition.environment ?? {}).filter(key => /APP_SETTINGS_JWT_SECRET/.test(key));
    assert.deepEqual(settings, [], `${name} publishes the signing secret as an app setting`);
  }
  assert.equal(services.rest.environment.PGRST_APP_SETTINGS_JWT_EXP, undefined, 'the expiry app setting is not set');
});

test('ingress is Cloudflare Tunnel only', () => {
  assert.ok(!existsSync(deploy('Caddyfile.example')), 'Caddy example must not ship');
  assert.ok(existsSync(deploy('cloudflared-config.example.yml')));
  const tunnel = readFileSync(deploy('cloudflared-config.example.yml'), 'utf8');
  assert.ok(tunnel.includes('service: http://127.0.0.1:18000'));
  assert.ok(tunnel.includes('noTLSVerify: false'));
  assert.ok(tunnel.includes('service: http_status:404'));
});

// The gateway's nginx is the stable branch, alpine-slim variant: even minors from 1.30 on (1.30, 1.32, 1.34; the odd ones
// are the mainline). The yearly move to the next stable branch is made by hand (docs/CONTAINER_SECURITY.md, "Image pins")
// and needs no edit here; scripts/check-base-images.mjs tells weekly when the pinned branch is no longer published.
const stableNginxSlimTag = tag => {
  const match = /^1\.(\d+)\.\d+-alpine-slim$/.exec(tag ?? '');
  return match !== null && Number(match[1]) >= 30 && Number(match[1]) % 2 === 0;
};

test('the gateway nginx rule takes any stable (even) minor from 1.30 in the alpine-slim variant, and nothing else', () => {
  for (const tag of ['1.30.6-alpine-slim', '1.30.0-alpine-slim', '1.32.0-alpine-slim', '1.34.12-alpine-slim', '1.100.1-alpine-slim']) assert.ok(stableNginxSlimTag(tag), tag);
  for (const tag of ['1.29.3-alpine-slim', '1.28.3-alpine-slim', '1.31.8-alpine-slim', '1.33.0-alpine-slim', '1.30.6', '1.30.6-alpine', '1.32.0-trixie',
    '1.32-alpine-slim', '1.32.0-alpine3.24-slim', '2.0.0-alpine-slim', 'mainline-alpine-slim', undefined]) assert.ok(!stableNginxSlimTag(tag), String(tag));
});

test('publisher images are pinned by digest, the gateway base too, and the notices name the versions in use', () => {
  const images = [...compose.matchAll(/^\s+image: (\S+)$/gm)].map(match => match[1]).filter(image => !image.endsWith(':local'));
  assert.ok(images.some(image => /^postgrest\/postgrest:v[0-9.]+@sha256:[0-9a-f]{64}$/.test(image)), 'PostgREST is not pinned by digest');
  assert.deepEqual(images.filter(image => !/@sha256:[0-9a-f]{64}$/.test(image)), [], 'every pulled image is pinned by digest');
  assert.doesNotMatch(compose, /image: kong:/);

  const notices = read('THIRD_PARTY_NOTICES.md');
  const base = (recipe, image) => new RegExp(`^FROM ${image}:([^@\\s]+)@sha256:[0-9a-f]{64}(?: AS \\w+)?$`, 'm').exec(read(`docker/${recipe}/Dockerfile`))?.[1];
  const nginxTag = base('nginx', 'nginx');
  assert.ok(stableNginxSlimTag(nginxTag), `the gateway is on an nginx stable branch (even minor, 1.30 or later), alpine-slim variant, by tag and index digest: ${nginxTag}`);
  const versions = {
    nginx: nginxTag?.split('-')[0],
    PostgREST: /image: postgrest\/postgrest:(v[0-9.]+)/.exec(compose)[1],
    Supavisor: base('supavisor', 'supabase/supavisor'),
    'edge-runtime': base('edge-runtime', 'supabase/edge-runtime'),
    // The PDF renderer's pins: the chrome-headless-shell build and puppeteer-core (docker/pdf-renderer).
    'Chrome for Testing': /^ARG CHS_VERSION=(\S+)$/m.exec(read('docker/pdf-renderer/Dockerfile'))?.[1],
    'puppeteer-core': JSON.parse(read('docker/pdf-renderer/package.json')).dependencies?.['puppeteer-core'],
    // The sensor bridge (GPL-3.0-or-later): its base image and the GPL library it installs.
    Python: base('sensor-bridge', 'python'),
    'python-kasa': /^python-kasa==([0-9][0-9.]*)\b/m.exec(read('docker/sensor-bridge/requirements.txt'))?.[1],
  };
  for (const [name, version] of Object.entries(versions)) {
    assert.ok(version, `${name} version was not read`);
    const row = notices.split('\n').find(line => line.startsWith('|') && line.includes(name) && line.includes(version));
    assert.ok(row, `THIRD_PARTY_NOTICES.md does not name ${name} ${version}`);
  }
  assert.doesNotMatch(notices, /Kong/);
  assert.doesNotMatch(notices, /v1\.76\.2|postgrest:v14\.17|PostgREST v14\.17/);
});

// ---- the LAN fallback: a second server in a second container (docs/OPERATOR_INSTALL.md, "LAN fallback") ---------------------------
test('the LAN server: plain http on 8080 only, the same routes, no trust in a client address, an allow list, and it names its path', () => {
  const server = CODE.lanTemplate;
  assert.equal((server.match(/^\s*server\s*\{/gm) || []).length, 1);
  assert.deepEqual(server.match(/^\s*listen\s.*$/gm).map(line => line.trim()), ['listen 8080;'], 'one plain listener: no ssl, no http2, no other port');
  assert.doesNotMatch(server, /\bssl\b|http2|ssl_certificate/);
  // Owner decision of 2026-10-26: plain http. No real-IP setting of any kind: the address of the connection is the client's.
  assert.doesNotMatch(server, /set_real_ip_from|real_ip_header|real_ip_recursive/);
  assert.doesNotMatch(server, /\$http_cf_connecting_ip|\$http_x_forwarded_for|\$http_x_real_ip/);
  assert.equal((server.match(/^\s*include \/etc\/nginx\/api-locations\.conf;$/gm) || []).length, 1, 'the same routes file as the public server');
  assert.match(server, /^\s*allow \$\{LAN_CIDR\};$\n^\s*deny all;$/m);
  assert.deepEqual([...server.matchAll(/^\s*(allow|deny) (\S+);$/gm)].map(match => match[1] + ' ' + match[2]), ['allow ${LAN_CIDR}', 'deny all'], 'one allowed range, then everyone else is denied');
  assert.match(server, /^\s*set \$warehouse_path lan;$/m);
  assert.match(CODE.gatewayTemplate, /^\s*set \$warehouse_path public;$/m);
  // Every API answer carries the header: cors-headers.conf is included by every route, the preflight and every error answer.
  assert.match(CODE.cors, /^add_header X-Warehouse-Path \$warehouse_path always;$/m);
  // The Host pin: the header must be LAN_BIND_IP (with or without LAN_HTTP_PORT), or the container's own health check; anything else is a 404 answered in
  // the rewrite phase of the server, after the routes file (which sets what the 404 uses) and before the location, the allow list and any limit.
  assert.match(server, /^map \$http_host \$lan_host_ok \{\n\s+default\s+0;\n\s+"\$\{LAN_BIND_IP\}"\s+1;\n\s+"\$\{LAN_BIND_IP\}:\$\{LAN_HTTP_PORT\}"\s+1;\n\s+"127\.0\.0\.1:8080"\s+1;\n\s+"localhost:8080"\s+1;\n\}$/m);
  assert.match(server, /^\s*if \(\$lan_host_ok = 0\) \{ return 404; \}$/m);
  assert.ok(server.indexOf('include /etc/nginx/api-locations.conf;') < server.indexOf('if ($lan_host_ok = 0)'), 'the pin follows the include (the 404 uses what the routes file sets)');
  assert.doesNotMatch(CODE.gatewayTemplate, /lan_host_ok|\$http_host/, 'the public server has no Host pin');
  // /health for the container only, as in the public server.
  assert.match(server, /location = \/health \{\n\s+if \(\$remote_addr != "127\.0\.0\.1"\) \{ return 404; \}\n\s+access_log off;\n\s+default_type text\/plain;\n\s+return 200 "ok\\n";\n\s+\}/);
  // The per-client keys the sign-in functions and the limits use are the connection's address on the routes that pass one on.
  for (const name of ['/rest/v1/', '/functions/v1/']) assert.match(route(name), /^\s*proxy_set_header CF-Connecting-IP \$remote_addr;$/m, `${name} sets the address from the connection`);
  assert.match(route('/storage/v1/'), /^\s*proxy_set_header CF-Connecting-IP "";$/m, 'storage is still not sent one');
  // The public template does not get the LAN server's lines.
  assert.doesNotMatch(CODE.gatewayTemplate, /\ballow\b|\bdeny\b|LAN_CIDR/);
});

test('the gateway-lan service: profile lan, the gateway\'s own image (no build of its own), published on LAN_BIND_IP only (loopback by default), on the default network', () => {
  const service = compose.slice(compose.indexOf('\n  gateway-lan:\n'), compose.indexOf('\n  rest:\n'));
  assert.ok(service.length > 300, 'the gateway-lan service was read');
  assert.match(service, /\n    profiles: \["lan"\]\n/);
  // One image: the tag Compose gives the gateway's build, never a second build of the same recipe (a second build could be another version).
  assert.match(service, /\n    image: \$\{WAREHOUSE_PROJECT_NAME:\?[^}]+\}-gateway\n    pull_policy: never\n/);
  assert.doesNotMatch(code(service), /^\s+build:/m, 'no build of its own');
  assert.doesNotMatch(code(service), /\n    volumes:/, 'nothing is mounted from the checkout: the LAN server is in the image');
  assert.doesNotMatch(service, /^\s+(?:entrypoint|command):/m);
  assert.deepEqual(service.match(/^\s+- "[^"]*:8080\/tcp"$/gm), ['      - "${LAN_BIND_IP:-127.0.0.1}:${LAN_HTTP_PORT:-8080}:8080/tcp"']);
  assert.match(service, /\n    read_only: true\n/);
  assert.match(service, /\n    cap_drop: \[ALL\]\n/);
  assert.doesNotMatch(service, /cap_add/);
  assert.match(service, /\n    security_opt: \["no-new-privileges:true"\]\n/);
  assert.match(service, /\n          cpus: '0\.5'\n          memory: 128M\n/);
  assert.match(service, /test: \["CMD", "wget", "-q", "-T", "5", "-O", "\/dev\/null", "http:\/\/127\.0\.0\.1:8080\/health"\]/);
  assert.match(service, /\n    logging: \*default-logging\n/);
  assert.match(service, /\n    depends_on:\n      db:\n        condition: service_healthy\n/);
  assert.doesNotMatch(service, /\n    networks:/, 'the default network only');
  assert.match(service, /- \/tmp:size=4m\n/);
  assert.match(service, /- \/etc\/nginx\/conf\.d:uid=101,gid=101,mode=0755,size=1m\n/);
  // Its server replaces the public one in this container only: the image's entrypoint reads the LAN template directory.
  assert.match(service, /\n      NGINX_ENVSUBST_TEMPLATE_DIR: \/etc\/nginx\/templates-lan\n      GATEWAY_ROLE: lan\n      LAN_CIDR: \$\{LAN_CIDR:-\}\n      LAN_BIND_IP: \$\{LAN_BIND_IP:-\}\n      LAN_HTTP_PORT: \$\{LAN_HTTP_PORT:-\}\n/);
  for (const name of ['ANON_KEY', 'SERVICE_ROLE_KEY', 'CORS_ALLOWED_ORIGIN']) assert.match(service, new RegExp(`\\n      ${name}: \\$\\{${name}:\\?[^}]+\\}\\n`));
  // The public gateway has neither the role, the range nor the template directory, and mounts nothing.
  const gateway = code(compose.slice(compose.indexOf('\n  gateway:\n'), compose.indexOf('\n  gateway-lan:\n')));
  assert.doesNotMatch(gateway, /GATEWAY_ROLE|LAN_|NGINX_ENVSUBST_TEMPLATE_DIR|\n    volumes:|profiles:/);
  // get-config reads the address from the function runtime's environment; get-public-config has no such name.
  assert.match(compose, /\n      LAN_ENABLED: \$\{LAN_ENABLED:-\}\n      LAN_BIND_IP: \$\{LAN_BIND_IP:-\}\n      LAN_HTTP_PORT: \$\{LAN_HTTP_PORT:-\}\n/);
});

test('the rendered Compose project: the LAN port is loopback until lan.sh gives it an address, and nothing else is published', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const publishers = edit => {
    const result = renderCompose(edit);
    assert.equal(result.status, 0, result.stderr);
    const { services, name } = JSON.parse(result.stdout);
    return { services, name, ports: Object.fromEntries(Object.entries(services).filter(([, service]) => service.ports?.length).map(([name, service]) => [name, service.ports.map(({ host_ip, published, target }) => `${host_ip}:${published}->${target}`)])) };
  };
  // A new state: .env.example has LAN off with loopback and 8080.
  const fresh = publishers();
  assert.deepEqual(fresh.ports['gateway-lan'], ['127.0.0.1:8080->8080']);
  assert.match(fresh.ports.gateway[0], /^127\.0\.0\.1:\d{4,5}->8000$/);
  assert.deepEqual(Object.keys(fresh.ports).sort(), ['gateway', 'gateway-lan']);
  assert.deepEqual(fresh.services['gateway-lan'].profiles, ['lan']);
  assert.deepEqual(fresh.services['gateway-lan'].networks, { default: null });
  // One image: gateway-lan runs the tag Compose gives the gateway's build (<project>-gateway), and has no build of its own.
  assert.equal(fresh.services['gateway-lan'].image, `${fresh.name}-gateway`);
  assert.equal(fresh.services['gateway-lan'].pull_policy, 'never');
  assert.equal(fresh.services['gateway-lan'].build, undefined);
  assert.ok(fresh.services.gateway.build?.context.endsWith('/docker/nginx'));
  assert.equal(fresh.services['gateway-lan'].environment.NGINX_ENVSUBST_TEMPLATE_DIR, '/etc/nginx/templates-lan');
  assert.equal(fresh.services['gateway-lan'].environment.GATEWAY_ROLE, 'lan');
  assert.equal(fresh.services['gateway-lan'].environment.LAN_CIDR, '');
  // Written by lan.sh on.
  const on = publishers(text => text.replace(/^LAN_ENABLED=.*$/m, 'LAN_ENABLED=true').replace(/^LAN_BIND_IP=.*$/m, 'LAN_BIND_IP=192.168.1.20').replace(/^LAN_HTTP_PORT=.*$/m, 'LAN_HTTP_PORT=8181').replace(/^LAN_CIDR=.*$/m, 'LAN_CIDR=192.168.1.0/24'));
  assert.deepEqual(on.ports['gateway-lan'], ['192.168.1.20:8181->8080']);
  assert.equal(on.services['gateway-lan'].environment.LAN_CIDR, '192.168.1.0/24');
  assert.deepEqual(Object.fromEntries(['LAN_ENABLED', 'LAN_BIND_IP', 'LAN_HTTP_PORT'].map(name => [name, on.services.functions.environment[name]])), { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.20', LAN_HTTP_PORT: '8181' });
  // A compose.env from before these lines still renders, with the loopback default.
  const old = publishers(text => text.replace(/^LAN_[A-Z_]+=.*\n/gm, ''));
  assert.deepEqual(old.ports['gateway-lan'], ['127.0.0.1:8080->8080']);
  // The function runtime offers the address to signed-in phones only: get-public-config never reads these names.
  assert.doesNotMatch(read('functions/get-public-config/index.ts'), /LAN_|lan-url|lanOrigin/);
});
