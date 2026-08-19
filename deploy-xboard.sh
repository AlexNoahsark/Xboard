#!/usr/bin/env bash
set -Eeuo pipefail

# XBoard + Xboard-Node + VLESS Reality one-click installer.
# Target: a fresh Ubuntu 22.04 server, run as root.
#
# Usage:
#   sudo bash deploy-xboard.sh [PUBLIC_IP]
# Optional environment variables:
#   PUBLIC_IP=149.28.219.50 ADMIN_EMAIL=admin@example.com bash deploy-xboard.sh

readonly XBOARD_REPO="https://github.com/AlexNoahsark/Xboard.git"
readonly NODE_REPO="https://github.com/cedar2025/Xboard-Node.git"
readonly XBOARD_DIR="/opt/xboard"
readonly NODE_DIR="/opt/xboard-node"
readonly REALITY_SERVER_NAME="www.amazon.com"
readonly REALITY_PORT="443"
readonly ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

PUBLIC_IP="${1:-${PUBLIC_IP:-}}"
TEMP_DIR=""

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f xboard-reality-test >/dev/null 2>&1 || true
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "Please run this script as root."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] || \
  die "This installer supports Ubuntu 22.04 only. Detected: ${PRETTY_NAME:-unknown}."

if [[ -f "$XBOARD_DIR/.env" ]] && grep -qE '^INSTALLED=(1|true)$' "$XBOARD_DIR/.env"; then
  die "An installed XBoard instance already exists at $XBOARD_DIR; refusing to overwrite it."
fi
[[ ! -e "$XBOARD_DIR" || -z "$(find "$XBOARD_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || \
  die "$XBOARD_DIR already exists and is not empty."
[[ ! -e "$NODE_DIR" || -z "$(find "$NODE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || \
  die "$NODE_DIR already exists and is not empty."

for port in 80 443; do
  if ss -H -lnt "sport = :$port" 2>/dev/null | grep -q .; then
    die "TCP port $port is already in use. Stop or reconfigure that service before deploying."
  fi
done

TEMP_DIR="$(mktemp -d /tmp/xboard-install.XXXXXX)"
chmod 700 "$TEMP_DIR"

log "Installing prerequisites and Docker Engine"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git jq openssl

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "${VERSION_CODENAME}" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

docker compose version >/dev/null
systemctl enable --now docker
printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/99-xboard.conf
sysctl -w vm.overcommit_memory=1 >/dev/null

if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
fi
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
  die "Could not determine a valid public IPv4 address. Pass it as the first argument."

ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
TEST_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
SHORT_ID="$(openssl rand -hex 8)"

log "Generating Reality keys"
REALITY_KEY_OUTPUT="$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)"
REALITY_PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$REALITY_KEY_OUTPUT")"
REALITY_PUBLIC_KEY="$(awk -F': ' '/^Password \(PublicKey\):/ {print $2}' <<<"$REALITY_KEY_OUTPUT")"
if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
  REALITY_PUBLIC_KEY="$(awk -F': ' '/^PublicKey:/ {print $2}' <<<"$REALITY_KEY_OUTPUT")"
fi
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Failed to generate Reality keys."

log "Validating Reality target TLS 1.3 support"
if ! timeout 15 openssl s_client \
  -connect "${REALITY_SERVER_NAME}:443" \
  -servername "$REALITY_SERVER_NAME" \
  -tls1_3 </dev/null 2>/dev/null | grep -q 'TLSv1.3'; then
  die "Reality target ${REALITY_SERVER_NAME} did not pass the TLS 1.3 check."
fi

log "Deploying XBoard from the documented AlexNoahsark/Xboard compose branch"
git clone -b compose --depth 1 "$XBOARD_REPO" "$XBOARD_DIR"
cd "$XBOARD_DIR"
sed -i 's/"7001:7001"/"80:7001"/' compose.yaml
install -d -m 775 .docker/.data storage/logs storage/theme plugins
touch .env
chmod 600 .env

docker compose pull
docker compose run --rm \
  -e ENABLE_SQLITE=true \
  -e ENABLE_REDIS=true \
  -e ADMIN_ACCOUNT="$ADMIN_EMAIL" \
  xboard php artisan xboard:install

grep -qE '^INSTALLED=(1|true)$' .env || die "XBoard initialization did not complete."
sed -i "s#^APP_URL=.*#APP_URL=http://${PUBLIC_IP}#" .env
docker compose up -d

for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null || die "XBoard did not become ready."

cat > "$TEMP_DIR/provision_xboard.php" <<'PHP'
<?php

use App\Models\Plan;
use App\Models\Server;
use App\Models\ServerGroup;
use App\Models\Setting;
use App\Models\User;
use App\Support\Setting as SettingStore;
use App\Utils\Helper;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\DB;

require '/www/vendor/autoload.php';
$app = require '/www/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$required = [
    'PUBLIC_IP', 'ADMIN_EMAIL', 'ADMIN_PASSWORD', 'TEST_PASSWORD',
    'REALITY_PRIVATE_KEY', 'REALITY_PUBLIC_KEY', 'REALITY_SHORT_ID',
    'REALITY_SERVER_NAME',
];
$env = [];
foreach ($required as $key) {
    $env[$key] = getenv($key);
    if (!$env[$key]) {
        throw new RuntimeException("Missing required value: {$key}");
    }
}

$result = DB::transaction(function () use ($env) {
    $admin = User::where('email', strtolower($env['ADMIN_EMAIL']))->firstOrFail();
    $admin->password = password_hash($env['ADMIN_PASSWORD'], PASSWORD_DEFAULT);
    $admin->save();

    $existingToken = Setting::where('name', 'server_token')->first();
    $serverToken = $existingToken?->getRawOriginal('value') ?: bin2hex(random_bytes(32));
    app(SettingStore::class)->save([
        'server_token' => $serverToken,
        'app_url' => "http://{$env['PUBLIC_IP']}",
        'subscribe_url' => "http://{$env['PUBLIC_IP']}",
        'server_ws_enable' => '1',
    ]);

    $group = ServerGroup::where('name', '默认节点组')->first() ?: new ServerGroup();
    $group->name = '默认节点组';
    $group->save();

    $server = Server::updateOrCreate(
        ['name' => '默认节点-01'],
        [
            'type' => 'vless',
            'code' => 'default-node-01',
            'parent_id' => null,
            'group_ids' => [(string) $group->id],
            'route_ids' => [],
            'name' => '默认节点-01',
            'rate' => 1,
            'tags' => ['Reality'],
            'host' => $env['PUBLIC_IP'],
            'port' => '443',
            'server_port' => 443,
            'protocol_settings' => [
                'tls' => 2,
                'tls_settings' => ['server_name' => null, 'allow_insecure' => false],
                'flow' => 'xtls-rprx-vision',
                'encryption' => ['enabled' => false, 'encryption' => null, 'decryption' => null],
                'network' => 'tcp',
                'network_settings' => [],
                'reality_settings' => [
                    'server_name' => $env['REALITY_SERVER_NAME'],
                    'server_port' => 443,
                    'public_key' => $env['REALITY_PUBLIC_KEY'],
                    'private_key' => $env['REALITY_PRIVATE_KEY'],
                    'short_id' => $env['REALITY_SHORT_ID'],
                    'allow_insecure' => false,
                ],
                'multiplex' => [
                    'enabled' => false,
                    'protocol' => 'yamux',
                    'max_connections' => null,
                    'padding' => false,
                    'brutal' => ['enabled' => false, 'up_mbps' => null, 'down_mbps' => null],
                ],
                'utls' => ['enabled' => true, 'fingerprint' => 'chrome'],
            ],
            'show' => true,
            'sort' => 1,
            'rate_time_enable' => false,
            'rate_time_ranges' => [],
            'custom_outbounds' => [],
            'custom_routes' => [],
            'cert_config' => ['cert_mode' => 'none'],
            'transfer_enable' => 0,
            'enabled' => true,
        ]
    );

    $planSpecs = [
        ['name' => '50GB套餐',  'gb' => 50,  'price' => 5,  'sort' => 1],
        ['name' => '100GB套餐', 'gb' => 100, 'price' => 10, 'sort' => 2],
        ['name' => '250GB套餐', 'gb' => 250, 'price' => 20, 'sort' => 3],
    ];
    $plans = [];
    foreach ($planSpecs as $spec) {
        $plans[$spec['name']] = Plan::updateOrCreate(
            ['name' => $spec['name']],
            [
                'group_id' => $group->id,
                'transfer_enable' => $spec['gb'],
                'speed_limit' => null,
                'show' => true,
                'sort' => $spec['sort'],
                'renew' => true,
                'content' => "每30天 {$spec['gb']}GB 流量，可使用默认节点组全部节点。",
                'reset_traffic_method' => Plan::RESET_TRAFFIC_MONTHLY,
                'capacity_limit' => 9999,
                'prices' => ['monthly' => $spec['price']],
                'sell' => true,
                'device_limit' => null,
                'tags' => ['30天'],
            ]
        );
    }

    $testPlan = $plans['50GB套餐'];
    $testUser = User::firstOrNew(['email' => 'test@example.com']);
    $testUser->password = password_hash($env['TEST_PASSWORD'], PASSWORD_DEFAULT);
    $testUser->password_algo = null;
    $testUser->password_salt = null;
    $testUser->uuid = $testUser->uuid ?: Helper::guid(true);
    $testUser->token = $testUser->token ?: Helper::guid();
    $testUser->group_id = $group->id;
    $testUser->plan_id = $testPlan->id;
    $testUser->transfer_enable = 50 * 1073741824;
    $testUser->u = 0;
    $testUser->d = 0;
    $testUser->banned = false;
    $testUser->is_admin = false;
    $testUser->expired_at = time() + 30 * 86400;
    $testUser->next_reset_at = time() + 30 * 86400;
    $testUser->device_limit = null;
    $testUser->save();

    return [
        'node_id' => $server->id,
        'server_token' => $serverToken,
        'test_uuid' => $testUser->uuid,
        'subscribe_url' => "http://{$env['PUBLIC_IP']}/s/{$testUser->token}",
    ];
});

echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
PHP

docker cp "$TEMP_DIR/provision_xboard.php" xboard-xboard-1:/tmp/provision_xboard.php
docker exec \
  -e PUBLIC_IP="$PUBLIC_IP" \
  -e ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e TEST_PASSWORD="$TEST_PASSWORD" \
  -e REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY" \
  -e REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY" \
  -e REALITY_SHORT_ID="$SHORT_ID" \
  -e REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
  xboard-xboard-1 php /tmp/provision_xboard.php \
  > /root/xboard-provision-result.json
chmod 600 /root/xboard-provision-result.json

NODE_ID="$(jq -r .node_id /root/xboard-provision-result.json)"
SERVER_TOKEN="$(jq -r .server_token /root/xboard-provision-result.json)"
TEST_UUID="$(jq -r .test_uuid /root/xboard-provision-result.json)"
SUBSCRIBE_URL="$(jq -r .subscribe_url /root/xboard-provision-result.json)"

# Reload long-lived Octane workers after changing settings and nodes.
docker compose restart
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

ADMIN_PATH="$(docker exec xboard-xboard-1 php -r '
require "/www/vendor/autoload.php";
$app = require "/www/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
echo admin_setting("secure_path", admin_setting("frontend_admin_path", hash("crc32b", config("app.key"))));
')"
[[ -n "$ADMIN_PATH" ]] || die "Could not determine the admin path."

log "Deploying Xboard-Node"
git clone -b compose --depth 1 "$NODE_REPO" "$NODE_DIR"
cd "$NODE_DIR"
sed -i 's#url: ".*"#url: "http://127.0.0.1"#' config/config.yml
sed -i "s#token: \".*\"#token: \"${SERVER_TOKEN}\"#" config/config.yml
sed -i "s#node_id: .*#node_id: ${NODE_ID}#" config/config.yml
sed -i 's#type: "singbox"#type: "singbox"#' config/config.yml
chmod 600 config/config.yml
docker compose pull
docker compose up -d

for _ in $(seq 1 30); do
  if ss -H -lnt "sport = :443" 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done
ss -H -lnt "sport = :443" | grep -q . || die "Reality port 443 did not start listening."

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log "Allowing only required application ports in the active UFW firewall"
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

log "Validating subscription and performing an end-to-end Reality request"
curl -fsS -A 'v2rayN/7.15.4' "$SUBSCRIBE_URL" -o "$TEMP_DIR/subscription.txt"
base64 -d "$TEMP_DIR/subscription.txt" > "$TEMP_DIR/subscription.decoded"
grep -q 'security=reality' "$TEMP_DIR/subscription.decoded" || die "Subscription does not contain a Reality node."

cat > "$TEMP_DIR/reality-client.json" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10808,
    "protocol": "socks",
    "settings": {"udp": true}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{
      "address": "127.0.0.1",
      "port": 443,
      "users": [{
        "id": "$TEST_UUID",
        "encryption": "none",
        "flow": "xtls-rprx-vision"
      }]
    }]},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "fingerprint": "chrome",
        "serverName": "$REALITY_SERVER_NAME",
        "password": "$REALITY_PUBLIC_KEY",
        "shortId": "$SHORT_ID",
        "spiderX": "/"
      }
    }
  }]
}
JSON

docker run -d --rm --network host --name xboard-reality-test \
  -v "$TEMP_DIR/reality-client.json:/etc/xray/config.json:ro" \
  ghcr.io/xtls/xray-core:latest run -config /etc/xray/config.json >/dev/null
sleep 3
TRACE_RESULT="$(curl -fsS --max-time 30 \
  --proxy socks5h://127.0.0.1:10808 \
  https://www.cloudflare.com/cdn-cgi/trace)" || die "End-to-end Reality proxy request failed."
grep -q "ip=${PUBLIC_IP}" <<<"$TRACE_RESULT" || die "Reality test did not use the expected server exit IP."
docker rm -f xboard-reality-test >/dev/null

sleep 5
if docker logs --since=30s xboard-node 2>&1 | \
  grep -Eqi 'authentication failed|node not found|unauthorized|connection refused|invalid token|panel unavailable|reality configuration invalid|\bERROR\b'; then
  docker logs --since=30s xboard-node >&2
  die "Xboard-Node reported an error during final validation."
fi

docker ps --format '{{.Names}}' | grep -qx 'xboard-xboard-1' || die "XBoard container is not running."
docker ps --format '{{.Names}}' | grep -qx 'xboard-node' || die "Xboard-Node container is not running."

cat > /root/xboard-deployment-summary.txt <<SUMMARY
XBoard访问地址：http://${PUBLIC_IP}
管理后台：http://${PUBLIC_IP}/${ADMIN_PATH}
管理员账号：${ADMIN_EMAIL}
管理员密码：${ADMIN_PASSWORD}

节点名称：默认节点-01
节点协议：VLESS + Reality
节点服务器：${PUBLIC_IP}:443
节点状态：在线 / 已通过实连测试

测试账号：test@example.com
测试密码：${TEST_PASSWORD}
测试套餐：50GB套餐
订阅地址：${SUBSCRIBE_URL}

套餐：
50GB套餐  - 5元 / 30天 / 50GB
100GB套餐 - 10元 / 30天 / 100GB
250GB套餐 - 20元 / 30天 / 250GB

XBoard配置：/opt/xboard/compose.yaml
Node配置：/opt/xboard-node/compose.yml
SUMMARY
chmod 600 /root/xboard-deployment-summary.txt

printf '\n============================================================\n'
printf '部署完成\n'
printf '============================================================\n'
cat /root/xboard-deployment-summary.txt
printf '============================================================\n'
printf '以上信息同时保存在 /root/xboard-deployment-summary.txt\n'
