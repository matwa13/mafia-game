.PHONY: frontend frontend-install frontend-dev frontend-lint help

help:
	@echo "Targets:"
	@echo "  make frontend          Build the React SPA (frontend/dist/)"
	@echo "  make frontend-install  Install frontend dependencies"
	@echo "  make frontend-dev      Run the Vite dev server"
	@echo "  make frontend-lint     Lint the frontend (eslint)"

frontend:
	cd frontend && npm run build

frontend-install:
	cd frontend && npm install

frontend-dev:
	cd frontend && npm run dev

frontend-lint:
	cd frontend && npm run lint
