# SmartPot-Broker-EMQX (MQTT)

## Estado del Proyecto

[![Broker Image CI](https://github.com/SmartPotTech/SmartPot-Broker-EMQX/actions/workflows/ci.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker-EMQX/actions/workflows/ci.yml)
[![Publish Docker Images](https://github.com/SmartPotTech/SmartPot-Broker-EMQX/actions/workflows/packaging.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker-EMQX/actions/workflows/packaging.yml)

## Descripción

SmartPot-Broker-EMQX es el **receptor MQTT** de SmartPot: la pieza por la que viajan la telemetría de los cultivos y
los comandos hacia sus actuadores. Es una imagen de **EMQX 5.8** (open source) con **TLS 1.2 o superior** sobre una CA
propia, sin acceso anónimo y con aislamiento por cultivo: cada dispositivo solo puede publicar su propia telemetría y
solo recibe sus propios comandos.

Reemplaza al broker anterior de Eclipse Mosquitto manteniendo **idéntico el contrato de los dispositivos** (mismos
tópicos, mismo usuario y clave, mismo TLS con la CA incrustada en el firmware). Lo que cambia es la operación interna:
en vez de aprovisionar cuentas en el broker por tópicos de control, **el broker delega la autenticación en la API**.

[SmartPot-API](https://github.com/SmartPotTech/SmartPot-API-Go) es el centro: EMQX solo habla con ella. Al conectarse un
dispositivo, EMQX pregunta a la API por HTTP; la API verifica la clave del cultivo contra su base y responde con el
permiso y un ACL acotado a ese cultivo. Un cultivo real usa la clave en su ESP32 (físico o en Wokwi); uno virtual, a
través del simulador. La API no registra ni borra nada en el broker: la clave vive en la base, así que crear, rotar o
borrar un cultivo tiene efecto inmediato sin tocar al broker (al rotar o borrar, la API corta las sesiones vivas por la
API REST de EMQX).

## Estructura del Proyecto

```text
SmartPot-Broker-EMQX/
├── .github/
│   ├── dependabot.yml          # Actualización de la imagen base y de las Actions
│   └── workflows/
│       ├── ci.yml              # Construye la imagen y corre la prueba de seguridad
│       ├── packaging.yml       # Publica la imagen en GHCR con SBOM y procedencia (y en Docker Hub con credenciales)
│       └── deploy.yml          # Pide el despliegue al workflow central de SmartPotTech/.github
├── config/
│   └── emqx.conf.template      # Listeners, cadena de autenticación, autorización y API REST (el entrypoint la renderiza)
├── scripts/
│   └── generate-certs.sh       # CA privada y certificado TLS del broker (la CA no se regenera)
├── tests/
│   └── smoke.sh                # Autenticación, aislamiento por dispositivo, TLS y listeners (con un stub de la API)
├── compose.yaml                # Broker local endurecido
├── docker-entrypoint.sh        # Renderiza la config, siembra la cuenta de servicio y la clave de API, y añade el TLS
├── Dockerfile
└── .env.example
```

## Modelo de Seguridad

| Cuenta                                | Quién la usa                                                 | Permisos                                                                                                               |
|---------------------------------------|--------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| Servicio (`MQTT_ADMIN_USERNAME`)      | SmartPot-API                                                 | Superusuario: lectura/escritura en `smartpot/#`. Se siembra en la base interna de EMQX al primer arranque              |
| Dispositivo                           | Una conexión por cultivo: usuario = id del cultivo, clave = clave del dispositivo | Publicar en `smartpot/v1/{su id}/telemetry`, `/commands/ack` y `/status`; suscribirse a `smartpot/v1/{su id}/commands` |

La autenticación de los dispositivos la resuelve la API por HTTP y devuelve un **ACL por cultivo** (campo `acl` de la
respuesta de autenticación, EMQX 5.8+): se permite solo `smartpot/v1/{id}/...` del propio cultivo y se niega el resto.
Así un dispositivo no puede escribir ni leer a nombre de otro cultivo aunque conozca su id, sin que el broker guarde
ningún estado por dispositivo. Lo que no coincide con el ACL se rechaza y se corta la conexión (`no_match = deny`,
`deny_action = disconnect`). La cuenta de servicio es superusuario y no pasa por autorización.

## TLS y Conexión

| Listener                               | Uso                                                       | Publicación en producción                        |
|----------------------------------------|-----------------------------------------------------------|--------------------------------------------------|
| `8883` MQTT sobre TLS (1.2 o superior) | Dispositivos de los cultivos reales                       | Directo en `mqtt.smartpot.app:8883`              |
| `9001` WebSocket (ruta `/mqtt`)        | Clientes web                                              | `wss://mqtt.smartpot.app/mqtt` a través de Nginx |
| `1883` MQTT                            | La API y el simulador, dentro de la red interna de Docker | Nunca se publica                                 |
| `18083` API REST                       | La API, para desconectar sesiones al rotar o borrar       | Nunca se publica                                 |

El listener TLS se habilita solo si existen `ca.crt`, `server.crt` y `server.key` en `/opt/emqx/etc/certs` (se monta de
solo lectura). El dispositivo verifica el servidor con `ca.crt`, que es público y se distribuye con el firmware; el
broker no exige certificado de cliente (`verify = verify_none`), así que el dispositivo se autentica con usuario y
clave, no con certificado.

Para generar la CA y el certificado del servidor:

```bash
sh scripts/generate-certs.sh certs mqtt.smartpot.app
```

> [!IMPORTANT]
> La CA **no se regenera** si ya existe: el firmware la lleva incrustada y dejaría de confiar en el broker. El
> certificado del servidor sí puede renovarse (lo firma la misma CA). `ca.key` firma los certificados y **no** debe
> quedar en el servidor.

## Tópicos (contrato v1)

| Tópico                              | Sentido                                 | Carga                                                                                                          |
|-------------------------------------|-----------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `smartpot/v1/{cropId}/telemetry`    | Dispositivo → API                       | `{"temperature":24.5,"humidity":61,"brightness":710,"ph":6.1,"tds":820,"atmosphere":1012.8,"soilMoisture":55}` |
| `smartpot/v1/{cropId}/commands`     | API → dispositivo (QoS 1)               | `{"id":"…","actuator":"WATER_PUMP","action":"ACTIVATE","durationSeconds":30}`                                  |
| `smartpot/v1/{cropId}/commands/ack` | Dispositivo → API (QoS 1)               | `{"id":"…","status":"EXECUTED","message":"Bomba encendida"}`                                                   |
| `smartpot/v1/{cropId}/status`       | Dispositivo (retenido, última voluntad) | `online` / `offline`                                                                                           |

## Guía de Instalación

### Requisitos Previos

- Docker (Docker Desktop o Docker Engine con Compose v2)

### Ejecución con Docker Compose

```bash
git clone https://github.com/SmartPotTech/SmartPot-Broker-EMQX.git
cd SmartPot-Broker-EMQX
cp .env.example .env    # define MQTT_ADMIN_PASSWORD, MQTT_AUTHN_TOKEN y la clave de la API REST
docker compose up -d
```

| Puerto | Protocolo            | Publicación                                                  |
|--------|----------------------|--------------------------------------------------------------|
| 1883   | MQTT                 | Solo `127.0.0.1`                                             |
| 8883   | MQTT sobre TLS       | Solo `127.0.0.1` en local; con los certificados de `./certs` |
| 9001   | MQTT sobre WebSocket | Solo `127.0.0.1`                                             |

> [!IMPORTANT]
> `MQTT_ADMIN_PASSWORD` solo se aplica cuando el volumen está vacío (es la cuenta de servicio sembrada en la base
> interna de EMQX). Las claves de los dispositivos no viven en el broker: las gestiona la API en su base.

Los hilos del broker se limitan con `MQTT_SCHEDULERS` (1 o 2 bastan para la carga de SmartPot); se traduce a la bandera
`+S` del BEAM.

### Prueba de humo

```bash
docker build -t smartpot-broker-emqx:ci .
sh tests/smoke.sh smartpot-broker-emqx:ci
```

Levanta un stub que imita el endpoint de autenticación de la API (devuelve `result` y el `acl` por cultivo) y verifica
que la telemetría propia llega a la API, que el broker descarta publicaciones y suscripciones a nombre de otro cultivo,
que rechaza claves incorrectas y conexiones anónimas, y que el listener TLS acepta solo credenciales válidas. El
aislamiento con la API real se vuelve a comprobar en el E2E central.

## Imagen publicada

```bash
docker pull ghcr.io/smartpottech/smartpot-broker-emqx:latest
```

La imagen corre como el usuario `emqx` sin privilegios ni capacidades, con un volumen en `/opt/emqx/data` y un
`HEALTHCHECK` con `emqx ctl status`. EMQX gestiona un directorio de datos mutable, por eso el contenedor no es de solo
lectura; el resto del endurecimiento (sin capacidades, sin escalada, usuario sin privilegios) se mantiene.

Cada cambio en `main` pasa por el CI, publica la imagen en GHCR (y en Docker Hub como réplica cuando el repositorio
tiene credenciales) y pide el despliegue al workflow central
de [SmartPotTech/.github](https://github.com/SmartPotTech/.github), que actualiza producción de a uno y verifica
`/health`.

## Documentación

El broker es el único punto de contacto de los dispositivos con la plataforma. Su documentación propia está en
[`docs/`](docs/SmartPot_Broker_EMQX_Documentation.md). La
[documentación técnica](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Technical_Documentation.md)
detalla el contrato MQTT, los permisos por cultivo y la red de producción.

## Hoja de Ruta Industrial: MQTT v5, mTLS X.509 y Stream gRPC ExHook

Como parte del **Plan Maestro de Maximización del Stack B (demo-beta)**, `SmartPot-Broker-EMQX` evoluciona hacia una arquitectura ciberfísica de ultra-bajo consumo y seguridad de hardware:

1. **Protocolo MQTT v5.0 y Topic Aliases**:
   - `topic_alias_maximum = 64` obligatorio, reduciendo los tópicos extensos de telemetría a un identificador entero de 2 bytes tras el paquete inicial.
2. **Seguridad Criptográfica mTLS X.509**:
   - Autenticación mutua en el handshake TLS basada en certificados cliente Ed25519 / ECDSA P-256 con TLS Session Resumption (Session Tickets < 15 ms).
   - Regla ACL criptográfica estricta que exige `peer_cert_cn == clientid`, impidiendo la suplantación de identidad entre macetas.
3. **Integración gRPC ExHook Persistente**:
   - Sustitución de los webhooks HTTP por un canal gRPC persistente multiplexado sobre HTTP/2 directo hacia `SmartPot-API-Go:9090` para telemetría binaria y control de sesiones.

## Licencia

Este proyecto está bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
