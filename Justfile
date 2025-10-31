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
[group('🔧 Setup & Installation')]
install:
    @echo "{{GREEN}}Installing Go dependencies...{{NC}}"
    cd {{backend_dir}} && go mod download
    @echo "{{GREEN}}Installing protoc plugins...{{NC}}"
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
    @echo "{{GREEN}}Installing goose for migrations...{{NC}}"
    go install github.com/pressly/goose/v3/cmd/goose@latest
    @echo "{{GREEN}}✓ Dependencies installed{{NC}}"

# Generate protobuf code for all targets
[group('🧬 Protocol Buffers')]
proto-gen:
    @echo "{{GREEN}}Generating protobuf code for all targets...{{NC}}"
    @chmod +x scripts/generate_proto.sh
    @scripts/generate_proto.sh

# Generate protobuf code for backend only
[group('🧬 Protocol Buffers')]
proto-gen-backend:
    @echo "{{GREEN}}Generating protobuf code for backend...{{NC}}"
    @chmod +x scripts/generate_proto.sh
    @scripts/generate_proto.sh -t backend

# Generate protobuf code for macOS client only
[group('🧬 Protocol Buffers')]
proto-gen-macos:
    @echo "{{GREEN}}Generating protobuf code for macOS client...{{NC}}"
    @chmod +x scripts/generate_proto.sh
    @scripts/generate_proto.sh -t client-macos

# Alias for generating all protobuf code
[group('🧬 Protocol Buffers')]
proto-gen-all: proto-gen

# Backward compatibility alias
[group('🧬 Protocol Buffers')]
proto: proto-gen

# Run database migrations
[group('🗄️  Database')]
migrate:
    @echo "{{GREEN}}Running database migrations...{{NC}}"
    @mkdir -p {{data_dir}}
    cd {{backend_dir}} && goose -dir internal/storage/migrations sqlite3 {{data_dir}}/vibecare.db up
    @echo "{{GREEN}}✓ Migrations complete{{NC}}"

# Rollback last migration
[group('🗄️  Database')]
migrate-down:
    @echo "{{YELLOW}}Rolling back last migration...{{NC}}"
    cd {{backend_dir}} && goose -dir internal/storage/migrations sqlite3 {{data_dir}}/vibecare.db  down

# Create a new migration
[group('🗄️  Database')]
new-migration name:
    @echo "{{GREEN}}Creating new migration: {{name}}{{NC}}"
    cd {{backend_dir}} && goose -dir internal/storage/migrations create {{name}} sql

# Build the backend server
[group('📦 Build & Run')]
build:
    @echo "{{GREEN}}Building VibeCare server...{{NC}}"
    cd {{backend_dir}} && go build -o ../bin/vibecare-server cmd/server/main.go
    @echo "{{GREEN}}✓ Server built: bin/vibecare-server{{NC}}"

# Run the server in development mode
[group('📦 Build & Run')]
run: proto-gen
    @echo "{{GREEN}}Starting VibeCare server...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing

# Run the server with custom port
[group('📦 Build & Run')]
run-port port="50051":
    @echo "{{GREEN}}Starting VibeCare server on port {{port}}...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go -port={{port}}

# Run the server with MCP enabled
[group('🤖 MCP Server')]
run-with-mcp profile_id: proto-gen
    @echo "{{GREEN}}Starting VibeCare server with MCP enabled...{{NC}}"
    @echo "{{YELLOW}}Profile ID: {{profile_id}}{{NC}}"
    @echo "{{YELLOW}}Configure Claude Desktop with this server before connecting{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --with-mcp --mcp-profile-id={{profile_id}} --enable-tracing

# Build embedded MCP server (MCP + gRPC server together)
[group('🤖 MCP Server')]
build-mcp:
    @echo "{{GREEN}}Building VibeCare server with embedded MCP support...{{NC}}"
    cd {{backend_dir}} && go build -o ../bin/vibecare-server cmd/server/main.go
    @echo "{{GREEN}}✓ Server built: bin/vibecare-server{{NC}}"
    @echo "{{YELLOW}}Run with: ./bin/vibecare-server --with-mcp --mcp-profile-id=YOUR_PROFILE_ID{{NC}}"

# Build standalone MCP server (connects to gRPC server)
[group('🤖 MCP Server')]
build-mcp-standalone:
    @echo "{{GREEN}}Building standalone VibeCare MCP server...{{NC}}"
    cd {{backend_dir}} && go build -o ../bin/vibecare-mcp-server cmd/mcp-server/main.go
    @echo "{{GREEN}}✓ Standalone MCP server built: bin/vibecare-mcp-server{{NC}}"
    @echo "{{YELLOW}}Usage: ./bin/vibecare-mcp-server --grpc-addr=localhost:50051 --profile-id=YOUR_PROFILE_ID{{NC}}"

# Run standalone MCP server (requires running gRPC server)
[group('🤖 MCP Server')]
run-mcp-standalone profile_id="" grpc_addr="":
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{GREEN}}Starting standalone VibeCare MCP server...{{NC}}"

    # Build command with optional flags
    cmd="cd {{backend_dir}} && go run cmd/mcp-server/main.go"

    if [ -n "{{profile_id}}" ]; then
        cmd="$cmd --profile-id={{profile_id}}"
        echo -e "{{YELLOW}}Profile ID: {{profile_id}}{{NC}}"
    else
        echo -e "{{YELLOW}}Profile ID: (from config file){{NC}}"
    fi

    if [ -n "{{grpc_addr}}" ]; then
        cmd="$cmd --grpc-addr={{grpc_addr}}"
        echo -e "{{YELLOW}}gRPC Address: {{grpc_addr}}{{NC}}"
    else
        echo -e "{{YELLOW}}gRPC Address: (from config file or default){{NC}}"
    fi

    echo -e "{{YELLOW}}Make sure the backend gRPC server is running first!{{NC}}"
    echo ""
    eval "$cmd"

# Run standalone MCP server using script (auto-builds if needed)
[group('🤖 MCP Server')]
mcp-standalone profile_id="" grpc_addr="":
    #!/usr/bin/env bash
    if [ -z "{{profile_id}}" ]; then
        echo -e "{{YELLOW}}Note: Using profile from config file{{NC}}"
    fi
    scripts/start-mcp-standalone.sh {{profile_id}} {{grpc_addr}}

# Run MCP server in HTTP mode (recommended for development)
# If profile_id is not provided, it will be read from ~/.vibecare/config.yaml
[group('🤖 MCP Server')]
mcp-start-http-server profile_id="" grpc_addr="" port="":
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "{{GREEN}}Starting VibeCare MCP HTTP server...{{NC}}"

    # Build command with optional flags
    cmd="cd {{backend_dir}} && go run cmd/mcp-server/main.go --http"

    if [ -n "{{profile_id}}" ]; then
        cmd="$cmd --profile-id={{profile_id}}"
        echo -e "{{YELLOW}}Profile ID: {{profile_id}}{{NC}}"
    else
        echo -e "{{YELLOW}}Profile ID: (from config file){{NC}}"
    fi

    if [ -n "{{grpc_addr}}" ]; then
        cmd="$cmd --grpc-addr={{grpc_addr}}"
        echo -e "{{YELLOW}}gRPC Address: {{grpc_addr}}{{NC}}"
    else
        echo -e "{{YELLOW}}gRPC Address: (from config file or default){{NC}}"
    fi

    if [ -n "{{port}}" ]; then
        cmd="$cmd --port={{port}}"
        echo -e "{{YELLOW}}HTTP Port: {{port}}{{NC}}"
    else
        echo -e "{{YELLOW}}HTTP Port: (from config file or default){{NC}}"
    fi

    echo -e "{{YELLOW}}Make sure the backend gRPC server is running first!{{NC}}"
    echo ""
    eval "$cmd"

# Kill any orphaned MCP server processes
[group('🤖 MCP Server')]
mcp-cleanup:
    @echo "{{YELLOW}}Checking for orphaned MCP server processes...{{NC}}"
    @pgrep -f "vibecare-mcp-server" && pkill -TERM -f "vibecare-mcp-server" && echo "{{GREEN}}✓ Cleaned up orphaned processes{{NC}}" || echo "{{YELLOW}}No orphaned processes found{{NC}}"

# Interactive MCP configuration - select profile and save to config file
[group('🤖 MCP Server')]
mcp-configure:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "\033[0;32mVibeCare MCP Configuration\033[0m\n"
    echo ""

    # Check if mcp-remote is installed
    if ! command -v mcp-remote &> /dev/null; then
        printf "\033[0;33mInstalling mcp-remote (required for Claude Desktop)...\033[0m\n"
        npm install -g mcp-remote
        if [ $? -eq 0 ]; then
            printf "\033[0;32m✓ mcp-remote installed successfully\033[0m\n"
        else
            printf "\033[0;31m✗ Failed to install mcp-remote. Please run: npm install -g mcp-remote\033[0m\n"
            exit 1
        fi
        echo ""
    fi

    # Check database exists
    if [ ! -f {{data_dir}}/vibecare.db ]; then
        printf "\033[0;31mDatabase not found. Run 'just migrate' first.\033[0m\n"
        exit 1
    fi

    # Get profiles
    profiles=$(sqlite3 {{data_dir}}/vibecare.db "SELECT id || '|' || name || '|' || email FROM profiles;")
    if [ -z "$profiles" ]; then
        printf "\033[0;31mNo profiles found.\033[0m\n"
        printf "\033[0;33mCreate a profile first: just grpc-create-profile 'Your Name' 'your@email.com'\033[0m\n"
        exit 1
    fi

    # Show profiles
    printf "\033[0;33mAvailable profiles:\033[0m\n"
    IFS=$'\n'
    count=0
    declare -a profile_ids
    for profile in $profiles; do
        count=$((count + 1))
        id=$(echo "$profile" | cut -d'|' -f1)
        name=$(echo "$profile" | cut -d'|' -f2)
        email=$(echo "$profile" | cut -d'|' -f3)
        profile_ids[$count]="$id"
        echo "  $count) $name ($email)"
    done

    # Get user selection
    echo ""
    echo -n "Select profile (1-$count): "
    read selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
        printf "\033[0;31mInvalid selection\033[0m\n"
        exit 1
    fi

    selected_id="${profile_ids[$selection]}"

    # Get optional settings
    echo ""
    echo -n "gRPC address [localhost:50051]: "
    read grpc_addr
    grpc_addr="${grpc_addr:-localhost:50051}"

    echo -n "HTTP port [8081]: "
    read http_port
    http_port="${http_port:-8081}"

    # Create config
    config_path="$HOME/.vibecare/config.yaml"
    mkdir -p "$(dirname "$config_path")"

    # Write config file
    printf "mcp:\n" > "$config_path"
    printf "  profile_id: %s\n" "$selected_id" >> "$config_path"
    printf "  grpc_addr: %s\n" "$grpc_addr" >> "$config_path"
    printf "  port: %s\n" "$http_port" >> "$config_path"

    echo ""
    printf "\033[0;32m✓ Configuration saved to: $config_path\033[0m\n"
    echo ""
    printf "\033[0;33mConfiguration:\033[0m\n"
    echo "  Profile ID: $selected_id"
    echo "  gRPC Address: $grpc_addr"
    echo "  HTTP Port: $http_port"
    echo ""
    printf "\033[0;32mYou can now start the MCP server with: just mcp-start-http-server\033[0m\n"
    echo ""

    # Detect npx and print Claude Desktop config
    npx_path=$(which npx 2>/dev/null || echo "")
    if [ -n "$npx_path" ]; then
        echo ""
        printf "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\033[0;32mClaude Desktop Configuration\033[0m\n"
        printf "\033[0;33mCopy this to: ~/Library/Application Support/Claude/claude_desktop_config.json\033[0m\n"
        echo ""
        echo "{"
        echo "  \"mcpServers\": {"
        echo "    \"vibecare\": {"
        echo "      \"command\": \"$npx_path\","
        echo "      \"args\": [\"-y\", \"mcp-remote\", \"http://localhost:$http_port/mcp\"]"
        echo "    }"
        echo "  }"
        echo "}"
        printf "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
    fi

# Print Claude Desktop configuration for copy/paste
[group('🤖 MCP Server')]
mcp-print-config:
    #!/usr/bin/env bash
    set -euo pipefail

    # Detect npx location
    npx_path=$(which npx 2>/dev/null || echo "")

    printf "\033[0;32mClaude Desktop Configuration\033[0m\n"
    printf "\033[0;33mCopy this to: ~/Library/Application Support/Claude/claude_desktop_config.json\033[0m\n"
    echo ""

    if [ -z "$npx_path" ]; then
        printf "\033[0;31m✗ npx not found in PATH\033[0m\n"
        printf "\033[0;33mInstall Node.js first, then run this command again\033[0m\n"
        exit 1
    fi

    echo "{"
    echo "  \"mcpServers\": {"
    echo "    \"vibecare\": {"
    echo "      \"command\": \"$npx_path\","
    echo "      \"args\": [\"-y\", \"mcp-remote\", \"http://localhost:8081/mcp\"]"
    echo "    }"
    echo "  }"
    echo "}"
    echo ""
    printf "\033[0;32m✓ Using npx at: $npx_path\033[0m\n"
    echo ""
    printf "\033[0;33mPrerequisites:\033[0m\n"
    echo "1. Run: npm install -g mcp-remote"
    echo "2. Configure MCP: just mcp-configure"
    echo "3. Start HTTP server: just mcp-start-http-server"
    echo "4. Restart Claude Desktop"

# Get profile IDs from database (for MCP setup)
[group('🤖 MCP Server')]
mcp-list-profiles:
    @echo "{{GREEN}}Fetching profile IDs from database...{{NC}}"
    @if [ ! -f {{data_dir}}/vibecare.db ]; then \
        echo "{{RED}}Database not found. Run 'just migrate' first.{{NC}}"; \
        exit 1; \
    fi
    @echo "{{YELLOW}}Available profiles:{{NC}}"
    @sqlite3 {{data_dir}}/vibecare.db "SELECT id, name, email FROM profiles;" || echo "{{RED}}No profiles found. Create one with 'just grpc-create-profile'{{NC}}"

# Show MCP setup instructions
[group('🤖 MCP Server')]
mcp-setup-guide:
    @echo "{{GREEN}}VibeCare MCP Setup Guide{{NC}}"
    @echo ""
    @echo "{{YELLOW}}=== Embedded Mode (recommended for local development) ==={{NC}}"
    @echo "1. Get or create a profile ID:"
    @echo "   just mcp-list-profiles"
    @echo "   # Or create new: just grpc-create-profile 'Your Name' 'your@email.com'"
    @echo ""
    @echo "2. Start backend with embedded MCP:"
    @echo "   just run-with-mcp YOUR_PROFILE_ID"
    @echo ""
    @echo "3. Configure Claude Desktop:"
    @echo "   Edit ~/.claude/config.json with embedded server config"
    @echo "   See .claude/mcp-config-example.json for template"
    @echo ""
    @echo "{{YELLOW}}=== Standalone Mode (for production/remote deployments) ==={{NC}}"
    @echo "1. Start the backend gRPC server:"
    @echo "   just run"
    @echo ""
    @echo "2. In another terminal, start standalone MCP server:"
    @echo "   just run-mcp-standalone YOUR_PROFILE_ID"
    @echo "   # Or specify remote gRPC address:"
    @echo "   just run-mcp-standalone YOUR_PROFILE_ID remote-host:50051"
    @echo ""
    @echo "3. Configure Claude Desktop with standalone server"
    @echo ""
    @echo "{{YELLOW}}4. Restart Claude Desktop{{NC}}"
    @echo ""
    @echo "{{GREEN}}Full documentation: docs/MCP_SETUP.md{{NC}}"

# List all available MCP tools (from running server)
[group('🤖 MCP Server')]
mcp-list-tools:
    @echo "{{GREEN}}Fetching MCP tools from server...{{NC}}"
    @if ! command -v jq &> /dev/null; then \
        echo "{{RED}}jq is not installed. Install with: brew install jq{{NC}}"; \
        echo "{{YELLOW}}Fetching without formatting:{{NC}}"; \
        curl -s http://localhost:8080/api/mcp/tools; \
        exit 0; \
    fi
    @curl -s http://localhost:8080/api/mcp/tools | jq -r 'if .enabled then "{{GREEN}}MCP Server: Enabled{{NC}}\n", "\n{{YELLOW}}Tools (\(.tools | length) total):{{NC}}", (.tools[] | "  • \(.name) - \(.description)"), "\n{{GREEN}}Resources (\(.resources | length) total):{{NC}}", (.resources[] | "  • \(.uri) - \(.description)") else "{{YELLOW}}MCP Server: Not enabled{{NC}}\nStart server with: just run-with-mcp PROFILE_ID" end' || echo "{{RED}}Error: Could not connect to server. Is it running?{{NC}}"

# Run tests
[group('🧪 Testing')]
test:
    @echo "{{GREEN}}Running tests...{{NC}}"
    cd {{backend_dir}} && go test -v ./...

# Run tests with coverage
[group('🧪 Testing')]
test-coverage:
    @echo "{{GREEN}}Running tests with coverage...{{NC}}"
    cd {{backend_dir}} && go test -v -coverprofile=coverage.out ./...
    cd {{backend_dir}} && go tool cover -html=coverage.out -o coverage.html
    @echo "{{GREEN}}✓ Coverage report: backend/coverage.html{{NC}}"

# Format Go code
[group('🛠️  Utilities')]
fmt:
    @echo "{{GREEN}}Formatting Go code...{{NC}}"
    cd {{backend_dir}} && go fmt ./...
    @echo "{{GREEN}}✓ Code formatted{{NC}}"

# Lint Go code
[group('🛠️  Utilities')]
lint:
    @echo "{{GREEN}}Linting Go code...{{NC}}"
    @if ! command -v golangci-lint &> /dev/null; then \
        echo "{{YELLOW}}Installing golangci-lint...{{NC}}"; \
        go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest; \
    fi
    cd {{backend_dir}} && golangci-lint run ./...

# Clean build artifacts
[group('🛠️  Utilities')]
clean:
    @echo "{{YELLOW}}Cleaning build artifacts...{{NC}}"
    rm -rf bin/
    rm -f {{backend_dir}}/coverage.out {{backend_dir}}/coverage.html
    @echo "{{GREEN}}✓ Clean complete{{NC}}"

# Check if all tools are installed
[group('🔧 Setup & Installation')]
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
[group('🔧 Setup & Installation')]
setup: install proto-gen migrate
    @echo "{{GREEN}}✓ Development environment ready!{{NC}}"
    @echo "Run 'just run' to start the server"

# Watch for changes and restart server (requires entr)
[group('📦 Build & Run')]
watch:
    @if ! command -v entr &> /dev/null; then \
        echo "{{RED}}entr is not installed. Install with: brew install entr{{NC}}"; \
        exit 1; \
    fi
    @echo "{{GREEN}}Watching for changes...{{NC}}"
    find {{backend_dir}} -name '*.go' | entr -r just run

# Connect to SQLite database
[group('🗄️  Database')]
inspect-db:
    @echo "{{GREEN}}Inspect backend database...{{NC}}"
    litecli {{data_dir}}/vibecare.db

# Show database schema
[group('🗄️  Database')]
db-schema:
    sqlite3 ~/.vibecare/vibecare.db ".schema"

# Test gRPC connection with grpcurl
[group('🔌 gRPC Tools')]
grpc-test:
    @if ! command -v grpcurl &> /dev/null; then \
        echo "{{YELLOW}}Installing grpcurl...{{NC}}"; \
        brew install grpcurl; \
    fi
    @echo "{{GREEN}}Testing gRPC connection...{{NC}}"
    grpcurl -plaintext localhost:50051 list

# Create a sample profile via gRPC
[group('🔌 gRPC Tools')]
grpc-create-profile name="Test User" email="test@example.com":
    @echo "{{GREEN}}Creating profile: {{name}} ({{email}}){{NC}}"
    grpcurl -plaintext -d '{"name":"{{name}}","email":"{{email}}","preferences":{}}' \
        localhost:50051 vibecare.v1.ProfileService/CreateProfile

# List all profiles via gRPC
[group('🔌 gRPC Tools')]
grpc-list-profiles:
    @if ! command -v grpcurl &> /dev/null; then \
        echo "{{YELLOW}}Installing grpcurl...{{NC}}"; \
        brew install grpcurl; \
    fi
    @echo "{{GREEN}}Listing all profiles...{{NC}}"
    grpcurl -plaintext -d '{}' localhost:50051 vibecare.v1.ProfileService/ListProfiles

# Docker build
[group('🐳 Docker')]
docker-build:
    @echo "{{GREEN}}Building Docker image...{{NC}}"
    docker build -t vibecare-server:latest .

# Docker run
[group('🐳 Docker')]
docker-run:
    @echo "{{GREEN}}Running Docker container...{{NC}}"
    docker run -p 50051:50051 -v ~/.vibecare:/data vibecare-server:latest

# macOS Swift client commands
[group('🍎 macOS / Swift')]
swift-build:
    @echo "{{GREEN}}Building Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift build

[group('🍎 macOS / Swift')]
swift-run:
    @echo "{{GREEN}}Running Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift run VibeCare

[group('🍎 macOS / Swift')]
swift-inspect-app-db:
    @echo "{{GREEN}}Inspect Swift client database...{{NC}}"
    cd ~/Library/Group\ Containers/com.vibecare.VibeCare/Library/Application\ Support/VibeCare/ && litecli VibeCare.sqlite

[group('🍎 macOS / Swift')]
swift-reset-app-db:
    @echo "{{GREEN}}Cleaning up the client database...{{NC}}"
    rm -rf ~/Library/Group\ Containers/com.vibecare.VibeCare/Library/Application\ Support/VibeCare/VibeCare.sqlite

[group('🍎 macOS / Swift')]
swift-test:
    @echo "{{GREEN}}Testing Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift test

# Test the complete stack
[group('🧪 Testing')]
test-stack: proto-gen migrate
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
[group('🧪 Testing')]
test-guide:
    @echo "{{GREEN}}Opening test setup guide...{{NC}}"
    @if command -v open &> /dev/null; then \
        open test_setup.md; \
    else \
        cat test_setup.md; \
    fi

# Generate macOS app (Swift client)
[group('🍎 macOS / Swift')]
macos-build:
    @echo "{{GREEN}}Building macOS app...{{NC}}"
    cd clients/macos-swift && xcodebuild -scheme VibeCare -configuration Release

# Open Xcode project
[group('🍎 macOS / Swift')]
xcode:
    open clients/macos-swift/VibeCare.xcodeproj

# Full build: backend and macOS client
[group('📦 Build & Run')]
build-all: build swift-build
    @echo "{{GREEN}}✓ All components built{{NC}}"
