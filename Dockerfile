# Última versión 5.8 de EMQX (open source, Apache-2.0); 5.9+ cambió a BSL. 5.8 ya trae el campo `acl`
# en la respuesta de autenticación HTTP, que es lo que usa SmartPot para acotar cada dispositivo a su cultivo.
FROM emqx/emqx:6.3.2

LABEL org.opencontainers.image.title="SmartPot Broker EMQX" \
      org.opencontainers.image.description="Broker MQTT de SmartPot sobre EMQX: la API autentica cada dispositivo y lo acota a su cultivo" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-Broker-EMQX" \
      org.opencontainers.image.licenses="MIT"

COPY --chown=emqx:emqx config/emqx.conf.template /opt/emqx/etc/emqx.conf.template
COPY --chown=emqx:emqx --chmod=755 docker-entrypoint.sh /usr/local/bin/smartpot-entrypoint.sh

EXPOSE 1883 8883 9001 18083

# Comprobación ligera del puerto MQTT: `emqx ctl status` arranca un nodo nuevo por RPC y es demasiado pesado
# con pocos schedulers. Si el listener 1883 acepta conexiones, la aplicación ya está lista.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/1883' || exit 1

ENTRYPOINT ["/usr/local/bin/smartpot-entrypoint.sh"]
CMD ["/opt/emqx/bin/emqx", "foreground"]
