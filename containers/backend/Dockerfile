FROM		alpine:3.20

RUN		apk update && apk add --no-cache \
		    bash curl jq && rm -rf /var/cache/apk/* 

RUN		addgroup -S appgroup && adduser -S appuser -G appgroup
USER		appuser

WORKDIR		/app

EXPOSE		8080/tcp

# Default entrypoint (Replace it with your entrypoint a 7bibna)
ENTRYPOINT	["bash", "-c", "echo 'Please specify an entrypoint for your backend application' && sleep infinity"]
