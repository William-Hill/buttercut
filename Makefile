# ButterCut — common dev tasks (desktop + sidecar).
# Run `make` or `make help` for targets.

.PHONY: help check setup dev sidecar-spec

help:
	@echo "ButterCut Makefile"
	@echo ""
	@echo "  make check         Verify desktop/Tauri + sidecar prerequisites"
	@echo "  make setup         bundle install (sidecar) + pnpm install (ui) + libraries/"
	@echo "  make dev           pnpm tauri dev (from ui/)"
	@echo "  make sidecar-spec  bundle exec rspec in ui/sidecar (needs Ruby 3.3 on PATH)"
	@echo ""
	@echo "Full Mac + Python + WhisperX audit: ruby .claude/skills/setup/verify_install.rb"
	@echo ""

check:
	@chmod +x scripts/check_desktop_prereqs.sh 2>/dev/null || true
	@./scripts/check_desktop_prereqs.sh

setup:
	@echo "Requires Ruby $$(sed 's/[[:space:]]*$$//' .ruby-version | cut -d. -f1,2).x on PATH (see: make check)."
	@echo "→ ui/sidecar: bundle install"
	cd ui/sidecar && bundle install
	@echo "→ ui: pnpm install"
	cd ui && pnpm install
	@mkdir -p libraries
	@echo ""
	@echo "Setup finished. Run: make check"

dev:
	cd ui && pnpm tauri dev

sidecar-spec:
	cd ui/sidecar && bundle exec rspec
