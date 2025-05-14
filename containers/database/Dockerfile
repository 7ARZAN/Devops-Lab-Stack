FROM		alpine:3.19

COPY		setup.sh /setup.sh
COPY		table-schema.sql /etc/postgres/table-schema.sql

RUN		apk add --no-cache postgresql curl jq su-exec && \
		install -do postgres -g postgres /var/lib/postgresql/data && \
		install -do postgres -g postgres /run/postgresql && chmod +x /setup.sh

USER		postgres

EXPOSE		5432/tcp

ENTRYPOINT	[ "sh", "/setup.sh" ]
