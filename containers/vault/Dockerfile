FROM		hashicorp/vault:1.17.6

USER		root

RUN		apk update && apk add --no-cache jq \
		bash curl && rm -rf /var/cache/apk/* && \
		install -o vault -g vault -m 770 -d /vault/tokens 

COPY		launch.sh /launch.sh
COPY		bootstrap.sh /vault/bootstrap.sh

RUN		install -o vault -g vault -m 550 /launch.sh /vault/bootstrap.sh

USER		vault

EXPOSE		8200/tcp

ENTRYPOINT	["sh", "/launch.sh"]
