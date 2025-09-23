# VibeCare Development Commands
# https://github.com/casey/just

# Default recipe to display help
default:
    @just --list

# Backend directory
backend_dir := "backend"
proto_dir := "proto"
data_dir := "~/.vibecare"

# Colors
export GREEN := '\033[0;32m'
export YELLOW := '\033[0;33m'
export RED := '\033[0;31m'
export NC := '\033[0m'

# Install all dependencies
install:
    @echo "{{GREEN}}Installing Go dependencies...{{NC}}"
    cd {{backend_dir}} && go mod download
    @echo "{{GREEN}}Installing protoc plugins...{{NC}}"
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
    @echo "{{GREEN}}Installing goose for migrations...{{NC}}"
    go install github.com/pressly/goose/v3/cmd/goose@latest
    @echo "{{GREEN}}✓ Dependencies installed{{NC}}"

# Generate protobuf code
proto:
    @echo "{{GREEN}}Generating protobuf code...{{NC}}"
    @chmod +x scripts/generate_proto.sh
    @scripts/generate_proto.sh

# Run database migrations
migrate:
    @echo "{{GREEN}}Running database migrations...{{NC}}"
    @mkdir -p {{data_dir}}
    cd {{backend_dir}} && goose -dir internal/storage/migrations sqlite3 {{data_dir}}/vibecare.db up
    @echo "{{GREEN}}✓ Migrations complete{{NC}}"

# Rollback last migration
migrate-down:
    @echo "{{YELLOW}}Rolling back last migration...{{NC}}"
    cd {{backend_dir}} && goose -dir internal/storage/migrations sqlite3 ~/.vibecare/vibecare.db down

# Create a new migration
new-migration name:
    @echo "{{GREEN}}Creating new migration: {{name}}{{NC}}"
    cd {{backend_dir}} && goose -dir internal/storage/migrations create {{name}} sql

# Build the backend server
build:
    @echo "{{GREEN}}Building VibeCare server...{{NC}}"
    cd {{backend_dir}} && go build -o ../bin/vibecare-server cmd/server/main.go
    @echo "{{GREEN}}✓ Server built: bin/vibecare-server{{NC}}"

# Run the server in development mode
run: proto
    @echo "{{GREEN}}Starting VibeCare server...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go

# Run the server with custom port
run-port port="50051":
    @echo "{{GREEN}}Starting VibeCare server on port {{port}}...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go -port={{port}}

# Run tests
test:
    @echo "{{GREEN}}Running tests...{{NC}}"
    cd {{backend_dir}} && go test -v ./...

# Run tests with coverage
test-coverage:
    @echo "{{GREEN}}Running tests with coverage...{{NC}}"
    cd {{backend_dir}} && go test -v -coverprofile=coverage.out ./...
    cd {{backend_dir}} && go tool cover -html=coverage.out -o coverage.html
    @echo "{{GREEN}}✓ Coverage report: backend/coverage.html{{NC}}"

# Format Go code
fmt:
    @echo "{{GREEN}}Formatting Go code...{{NC}}"
    cd {{backend_dir}} && go fmt ./...
    @echo "{{GREEN}}✓ Code formatted{{NC}}"

# Lint Go code
lint:
    @echo "{{GREEN}}Linting Go code...{{NC}}"
    @if ! command -v golangci-lint &> /dev/null; then \
        echo "{{YELLOW}}Installing golangci-lint...{{NC}}"; \
        go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest; \
    fi
    cd {{backend_dir}} && golangci-lint run ./...

# Clean build artifacts
clean:
    @echo "{{YELLOW}}Cleaning build artifacts...{{NC}}"
    rm -rf bin/
    rm -f {{backend_dir}}/coverage.out {{backend_dir}}/coverage.html
    @echo "{{GREEN}}✓ Clean complete{{NC}}"

# Check if all tools are installed
check:
    @echo "{{GREEN}}Checking development environment...{{NC}}"
    @echo -n "Go: "
    @go version || echo "{{RED}}NOT INSTALLED{{NC}}"
    @echo -n "protoc: "
    @protoc --version || echo "{{RED}}NOT INSTALLED{{NC}}"
    @echo -n "goose: "
    @goose -version 2>/dev/null || echo "{{RED}}NOT INSTALLED{{NC}}"
    @echo -n "SQLite: "
    @sqlite3 --version || echo "{{RED}}NOT INSTALLED{{NC}}"
    @echo "{{GREEN}}✓ Environment check complete{{NC}}"

# Development setup - install everything and run initial setup
setup: install proto migrate
    @echo "{{GREEN}}✓ Development environment ready!{{NC}}"
    @echo "Run 'just run' to start the server"

# Watch for changes and restart server (requires entr)
watch:
    @if ! command -v entr &> /dev/null; then \
        echo "{{RED}}entr is not installed. Install with: brew install entr{{NC}}"; \
        exit 1; \
    fi
    @echo "{{GREEN}}Watching for changes...{{NC}}"
    find {{backend_dir}} -name '*.go' | entr -r just run

# Connect to SQLite database
db:
    sqlite3 ~/.vibecare/vibecare.db

# Show database schema
db-schema:
    sqlite3 ~/.vibecare/vibecare.db ".schema"

# Test gRPC connection with grpcurl
grpc-test:
    @if ! command -v grpcurl &> /dev/null; then \
        echo "{{YELLOW}}Installing grpcurl...{{NC}}"; \
        brew install grpcurl; \
    fi
    @echo "{{GREEN}}Testing gRPC connection...{{NC}}"
    grpcurl -plaintext localhost:50051 list

# Create a sample profile via gRPC
grpc-create-profile name="Test User" email="test@example.com":
    @echo "{{GREEN}}Creating profile: {{name}} ({{email}}){{NC}}"
    grpcurl -plaintext -d '{"name":"{{name}}","email":"{{email}}","preferences":{}}' \
        localhost:50051 vibecare.v1.ProfileService/CreateProfile

# Docker build
docker-build:
    @echo "{{GREEN}}Building Docker image...{{NC}}"
    docker build -t vibecare-server:latest .

# Docker run
docker-run:
    @echo "{{GREEN}}Running Docker container...{{NC}}"
    docker run -p 50051:50051 -v ~/.vibecare:/data vibecare-server:latest

# macOS Swift client commands
swift-build:
    @echo "{{GREEN}}Building Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift build

swift-run:
    @echo "{{GREEN}}Running Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift run VibeCare

swift-test:
    @echo "{{GREEN}}Testing Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift test

# Test the complete stack
test-stack: proto migrate
    @echo "{{GREEN}}Testing complete VibeCare stack...{{NC}}"
    @echo "{{YELLOW}}Starting backend server in background...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go &
    @sleep 2
    @echo "{{GREEN}}Testing gRPC connection...{{NC}}"
    just grpc-test
    @echo "{{GREEN}}Creating test profile...{{NC}}"
    just grpc-create-profile "Test User" "test@vibecare.io"
    @echo "{{GREEN}}✓ Stack test complete{{NC}}"
    @echo "{{YELLOW}}Note: Backend server is still running. Press Ctrl+C to stop.{{NC}}"

# Open test setup guide
test-guide:
    @echo "{{GREEN}}Opening test setup guide...{{NC}}"
    @if command -v open &> /dev/null; then \
        open test_setup.md; \
    else \
        cat test_setup.md; \
    fi

# Generate macOS app (Swift client)
macos-build:
    @echo "{{GREEN}}Building macOS app...{{NC}}"
    cd clients/macos-swift && xcodebuild -scheme VibeCare -configuration Release

# Open Xcode project
xcode:
    open clients/macos-swift/VibeCare.xcodeproj

# Full build: backend and macOS client
build-all: build swift-build
    @echo "{{GREEN}}✓ All components built{{NC}}"