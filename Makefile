# githooks - shared lefthook configs and the commit-message grader they call.
# `make check` runs them over this tree: this repo is its own first consumer.

.PHONY: help hooks test check fmt release publish

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

# Once per clone: hooks do not travel with the tree. core.hooksPath is
# unset first - a leftover from the vendored engine would hide lefthook's.
hooks: ## install lefthook's hooks for this clone
	@git config --unset core.hooksPath || true
	lefthook install
	@echo 'hooks enabled - skip one commit with LEFTHOOK=0'

##@ Quality
test: ## the fixture harness - grader + shared configs through lefthook
	tests/run.sh

# The lanes live in lefthook.yml, which extends shared/: this repo is its
# own first consumer.
check: ## the whole-tree gate - every lane, read only
	lefthook run check --all-files

fmt: ## the same lanes, writing - never stages
	lefthook run fix --all-files

##@ Release
# release.sh stamps VERSION into the grader, gates, commits, tags.
release: ## tag a release here, gated - VERSION=vX.Y.Z [DRY_RUN=1]
	scripts/release.sh $(if $(DRY_RUN),--dry-run) $(VERSION)

publish: ## push the tag and cut the GitHub release - [DRY_RUN=1]
	scripts/publish.sh $(if $(DRY_RUN),--dry-run)
