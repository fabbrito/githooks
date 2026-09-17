# githooks - the engine lives in bin/, the vendored copy in .githooks/.
# `make check` runs the copy: this repo is its own first consumer.

.PHONY: help hooks vendor test check fmt release publish

define HELP_AWK
BEGIN {
	FS = ":.*##"
	printf "\nUsage: make \033[1m<target>\033[0m\n"
}
/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }
/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }
endef
export HELP_AWK

##@ Setup
help: ## show this help
	@awk "$$HELP_AWK" $(lastword $(MAKEFILE_LIST))

# Once per clone: hooks do not travel with the tree.
hooks: ## enable .githooks for this clone
	git config core.hooksPath .githooks
	@chmod +x .githooks/githooks .githooks/commit-msg .githooks/pre-commit
	@echo 'hooks enabled - skip one commit with --no-verify'

# Dogfood. The copy is what the hooks run, so it must not drift from bin/.
vendor: ## refresh .githooks/githooks from bin/githooks
	cp bin/githooks .githooks/githooks
	@chmod +x .githooks/githooks

##@ Quality
test: ## the fixture harness - commit-msg + dispatcher
	tests/run.sh

# No fmt.sh or lint.sh here: the lanes live in hooks.conf and the vendored
# engine dispatches them. That is the whole product.
check: vendor ## the staging gate - every lane, read only
	.githooks/githooks check

fmt: vendor ## the same lanes, writing - shfmt -w, prettier --write
	.githooks/githooks check --fix

##@ Release
# release.sh stamps VERSION into bin/githooks, vendors, commits, tags.
release: ## tag a release here, gated - VERSION=vX.Y.Z [DRY_RUN=1]
	scripts/release.sh $(if $(DRY_RUN),--dry-run) $(VERSION)

publish: ## push the tag and cut the GitHub release - [DRY_RUN=1]
	scripts/publish.sh $(if $(DRY_RUN),--dry-run)
