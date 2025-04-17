FROM		vault:1.17.6

USER		root

RUN		apk update && apk add --no-cache \
		bash curl && rm -rf /var/cache/apk/*

USER		vault

COPY		../../services/vault/launch.sh /launch.sh

RUN		chmod 550 /launch.sh

EXPOSE		8200/tcp

HEALTHCHECK	--interval=10s --timeout=5s --retries=3 --start-period=30s \
		CMD curl -f http://localhost:8200/v1/sys/health || exit 1

ENTRYPOINT	["sh", "/launch.sh"]
CMD		["server", "-dev"]
