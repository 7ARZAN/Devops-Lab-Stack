FROM		vault:1.17.6

USER		root

RUN		apk update && apk add --no-cache \
		bash curl && rm -rf /var/cache/apk/* 

USER		vault

COPY		../../services/vault/launch.sh /launch.sh
RUN		chmod 550 /launch.sh

EXPOSE		8200/tcp

ENTRYPOINT	["exec", "sh", "/launch.sh"]
