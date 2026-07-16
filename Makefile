SHELL := /bin/bash

.PHONY: up setup test demo backup restore clean

up:
	docker compose up -d

setup:
	./scripts/setup.sh

test:
	./scripts/test.sh

demo:
	./scripts/demo.sh

backup:
	./scripts/backup.sh

restore:
	@test -n "$(BACKUP)" || (echo "Usage: make restore BACKUP=backups/file.dump [TARGET_DB=name]" && exit 2)
	./scripts/restore.sh "$(BACKUP)" "$(or $(TARGET_DB),freight_ops_restore_test)"

clean:
	docker compose down
