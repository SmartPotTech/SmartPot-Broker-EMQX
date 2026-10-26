#!/bin/sh
# Prueba de humo: arranca la imagen endurecida con un stub de autenticación que imita a la API
# (devuelve result + acl por cultivo) y valida autenticación, aislamiento por dispositivo y TLS.
# El aislamiento con la API real se vuelve a comprobar en el E2E central.
set -eu

IMAGE="${1:-smartpot-broker-emqx:ci}"
NET="smartpot-emqx-smoke-net"
BROKER="smartpot-broker-emqx-smoke"
AUTHN="smartpot-authn-smoke"
CLIENT_IMAGE="eclipse-mosquitto:2.0"
ADMIN="smartpot-api"
ADMIN_PASS="smoke-admin-password-1234"
TOKEN="smoke-authn-token-1234567890"
DEVICE="6718f0a1b2c3d4e5f6a7b8c9"
OTHER="6718f0a1b2c3d4e5f6a7b8d0"
DEVICE_PASS="smoke-device-key-123"

WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$BROKER" "$AUTHN" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm smartpot-emqx-smoke-data >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cleanup

# CA y certificado de servidor desechables para probar el listener TLS.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=SmartPot Smoke CA" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$WORK/server.key" -out "$WORK/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost,DNS:%s,IP:127.0.0.1\n' "$BROKER" > "$WORK/san.ext"
openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
  -days 1 -extfile "$WORK/san.ext" -out "$WORK/server.crt" 2>/dev/null
chmod 755 "$WORK"
chmod 644 "$WORK"/*.crt "$WORK"/*.key

# Stub de autenticación: imita el endpoint interno de la API (verifica el token y la clave, devuelve el acl).
cat > "$WORK/authn.py" <<PY
import json
# Servidor concurrente: EMQX abre un pool de conexiones keep-alive, así que un servidor monohilo
# se bloquearía y la autenticación agotaría el tiempo. La API real (gin) ya es concurrente.
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEVICE = "$DEVICE"
DEVICE_PASS = "$DEVICE_PASS"
TOKEN = "$TOKEN"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.headers.get("x-smartpot-broker-token") != TOKEN:
            return self.reply({"result": "deny"})
        if body.get("username") == DEVICE and body.get("password") == DEVICE_PASS:
            base = "smartpot/v1/%s" % DEVICE
            return self.reply({"result": "allow", "acl": [
                {"permission": "allow", "action": "publish", "topic": base + "/telemetry"},
                {"permission": "allow", "action": "publish", "topic": base + "/status"},
                {"permission": "allow", "action": "publish", "topic": base + "/commands/ack"},
                {"permission": "allow", "action": "subscribe", "topic": base + "/commands"},
                {"permission": "deny", "action": "all", "topic": "#"},
            ]})
        return self.reply({"result": "deny"})

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

docker network create "$NET" >/dev/null

docker run -d --name "$AUTHN" --network "$NET" \
  -v "$WORK/authn.py:/authn.py:ro" \
  python:3-alpine python /authn.py >/dev/null

docker run -d --name "$BROKER" --network "$NET" \
  --cap-drop ALL --security-opt no-new-privileges \
  -e MQTT_ADMIN_USERNAME="$ADMIN" -e MQTT_ADMIN_PASSWORD="$ADMIN_PASS" \
  -e MQTT_AUTHN_TOKEN="$TOKEN" -e MQTT_AUTHN_URL="http://$AUTHN:8080/authn" \
  -e MQTT_BROKER_API_KEY=smoke-key -e MQTT_BROKER_API_SECRET=smoke-secret-1234567890 \
  -e MQTT_SCHEDULERS=1 \
  -v smartpot-emqx-smoke-data:/opt/emqx/data \
  -v "$WORK:/opt/emqx/etc/certs:ro" \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$BROKER")" = "healthy" ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$BROKER")" = "healthy" ] || { docker logs "$BROKER"; exit 1; }

# Cliente MQTT de un solo uso en la misma red; pub/sub contra el broker por su nombre.
mqtt() { docker run --rm --network "$NET" -v "$WORK:/certs:ro" "$CLIENT_IMAGE" "$@"; }

# La API (superusuario) escucha todo; un dispositivo publica lo suyo y lo ajeno (esto se corta).
mqtt mosquitto_sub -i smoke-admin -h "$BROKER" -u "$ADMIN" -P "$ADMIN_PASS" -t 'smartpot/#' -v -W 6 > "$WORK/admin.log" 2>&1 &
sleep 2
mqtt mosquitto_pub -i smoke-dev-1 -h "$BROKER" -u "$DEVICE" -P "$DEVICE_PASS" -t "smartpot/v1/$DEVICE/telemetry" -m own || true
mqtt mosquitto_pub -i smoke-dev-2 -h "$BROKER" -u "$DEVICE" -P "$DEVICE_PASS" -t "smartpot/v1/$OTHER/telemetry" -m foreign 2>/dev/null || true

# La API manda un comando al dispositivo, que está suscrito a su propio tópico de comandos.
mqtt mosquitto_sub -i smoke-dev-3 -h "$BROKER" -u "$DEVICE" -P "$DEVICE_PASS" -t "smartpot/v1/$DEVICE/commands" -v -W 6 > "$WORK/device.log" 2>&1 &
sleep 2
mqtt mosquitto_pub -i smoke-cmd -h "$BROKER" -u "$ADMIN" -P "$ADMIN_PASS" -t "smartpot/v1/$DEVICE/commands" -m command || true
sleep 4

admin_log="$(cat "$WORK/admin.log" 2>/dev/null || true)"
device_log="$(cat "$WORK/device.log" 2>/dev/null || true)"
fail=0
check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }

check "la API recibe la telemetría propia del dispositivo" 'echo "$admin_log" | grep -q "telemetry own"'
check "el broker descarta telemetría a nombre de otro cultivo" '! echo "$admin_log" | grep -q foreign'
check "el dispositivo recibe sus comandos" 'echo "$device_log" | grep -q "commands command"'
check "se rechaza una clave de dispositivo incorrecta" "! mqtt mosquitto_pub -i smoke-bad -h $BROKER -u $DEVICE -P wrong -t x -m y 2>/dev/null"
check "se rechaza la conexión anónima" "! mqtt mosquitto_pub -i smoke-anon -h $BROKER -t x -m y 2>/dev/null"
check "el dispositivo publica por TLS verificando la CA" "mqtt mosquitto_pub -i smoke-tls -h $BROKER -p 8883 --cafile /certs/ca.crt -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$DEVICE/telemetry' -m tls"
check "TLS rechaza una clave incorrecta" "! mqtt mosquitto_pub -i smoke-tls-bad -h $BROKER -p 8883 --cafile /certs/ca.crt -u $DEVICE -P wrong -t x -m y 2>/dev/null"
check "el dispositivo no puede suscribirse a comandos ajenos" "! mqtt mosquitto_sub -i smoke-sub-foreign -h $BROKER -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$OTHER/commands' -C 1 -W 3 2>/dev/null | grep -q ."
check "el listener WebSocket (9001) responde" "docker exec $BROKER /opt/emqx/bin/emqx ctl listeners 2>/dev/null | grep -q 9001"

exit "$fail"
