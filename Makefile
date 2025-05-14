.PHONY: all build push deploy clean

all: build push deploy

build:
	docker-compose build

push:
	docker-compose push

deploy:
	docker-compose up -d

clean:
	docker-compose down -v
	docker system prune -f

ansible:
	ansible-playbook infrastructure/ansible/playbook.yml

terraform:
	terraform -chdir=infrastructure/terraForm apply -auto-approve

k8s:
	kubectl apply -f k8s/

monitoring:
	kubectl apply -f monitoring/

secrets:
	@for file in secrets/*.env; do \
		kubectl create secret generic $${file##*/} --from-env-file=$$file; \
	done

services:
	bash services/database/setup.sh
	bash services/vault/bootstrap.sh
	bash services/vault/launch.sh
	bash services/webserver/launcher.sh

stop:
	docker-compose down

logs:
	docker-compose logs -f
