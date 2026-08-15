# VibeCare Development Commands
# https://github.com/casey/just

# Default recipe to display help
default:
    @just --list

# Backend directory
backend_dir := "backend"
cli_dir := "clients/cli"
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

# Build the backend server (release mode with optimizations)
[group('📦 Build & Run')]
build-release:
    @echo "{{GREEN}}Building VibeCare server (release)...{{NC}}"
    cd {{backend_dir}} && go build -ldflags="-s -w" -o ../bin/vibecare-server cmd/server/main.go
    @echo "{{GREEN}}✓ Server built: bin/vibecare-server{{NC}}"

# Install built binaries to user-local paths (no sudo needed)
[group('🔧 Setup & Installation')]
install-binaries: build-release swift-build-release install-plugins
    @echo "{{GREEN}}Installing binaries...{{NC}}"
    mkdir -p ~/.local/bin
    sudo cp bin/vibecare-server /usr/local/bin/vibecare-server
    mkdir -p ~/Applications/VibeCare.app/Contents/MacOS
    cp clients/macos-swift/VibeCare/.build/release/VibeCare ~/Applications/VibeCare.app/Contents/MacOS/VibeCare
    @echo "{{GREEN}}✓ Binaries installed:{{NC}}"
    @echo "  /usr/local/bin/vibecare-server"
    @echo "  ~/Applications/VibeCare.app"
    @echo ""
    @echo "{{YELLOW}}Note: Add ~/.local/bin to your PATH if not already{{NC}}"

# Run the server in development mode
[group('📦 Build & Run')]
run: proto-gen build-plugins
    @echo "{{GREEN}}Starting VibeCare server...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing --log-level debug --plugins-dir ../plugins

# Like `just run`, but plugins serve ui/ from disk and push a reload to the
# browser on every edit — change plugins/todo/ui/index.html and the page
# refreshes itself, no rebuild and no restart. For backend iteration that
# also manages the background LaunchAgent, use `just dev` instead.
#
# Run the server with plugin UI live reload
[group('📦 Build & Run')]
dev-ui: proto-gen build-plugins-dev
    @echo "{{GREEN}}Starting VibeCare server (plugin live reload enabled)...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing --log-level debug --plugins-dir ../plugins

# Run the server with custom port
[group('📦 Build & Run')]
run-port port="50051":
    @echo "{{GREEN}}Starting VibeCare server on port {{port}}...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go -port={{port}}

# Reload the LaunchAgent safely (bootout, wait for it to clear, bootstrap, kickstart)
[private]
_reload-service label="io.vibecare.server":
    #!/usr/bin/env bash
    set -uo pipefail
    uid=$(id -u)
    label="{{label}}"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
    # bootout is async — wait until the service actually clears before bootstrapping
    for _ in $(seq 1 25); do
        launchctl list "$label" >/dev/null 2>&1 || break
        sleep 0.2
    done
    launchctl bootstrap "gui/${uid}" "$plist"
    # RunAtLoad is throttled (ThrottleInterval); kickstart forces an immediate start
    launchctl kickstart "gui/${uid}/${label}" 2>/dev/null || true

# Fast dev loop: free the ports, run go server, restore background service on exit
[group('📦 Build & Run')]
dev:
    #!/usr/bin/env bash
    set -uo pipefail
    uid=$(id -u)
    label="io.vibecare.server"
    was_loaded=0
    launchctl list "$label" >/dev/null 2>&1 && was_loaded=1
    restore() {
        if [ "$was_loaded" = 1 ]; then
            echo -e "\n${GREEN}Restoring background service...${NC}"
            just _reload-service
        fi
    }
    trap restore EXIT
    if [ "$was_loaded" = 1 ]; then
        echo -e "${YELLOW}Stopping background service to free ports...${NC}"
        launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
    fi
    echo -e "${GREEN}Starting dev server (go run)...${NC}"
    echo -e "${YELLOW}(run 'just proto-gen' first if you changed proto/vibecare.proto)${NC}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing --log-level debug

# Deploy your local build into the always-on LaunchAgent (no sudo)
[group('📦 Build & Run')]
deploy-local:
    #!/usr/bin/env bash
    set -euo pipefail
    uid=$(id -u)
    label="io.vibecare.server"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    target="$HOME/.local/bin/vibecare-server"
    if [ ! -f "$plist" ]; then
        echo -e "${RED}LaunchAgent not found at $plist — is VibeCare installed?${NC}"
        exit 1
    fi
    echo -e "${GREEN}Building release binary...${NC}"
    (cd {{backend_dir}} && go build -ldflags="-s -w" -o ../bin/vibecare-server cmd/server/main.go)
    mkdir -p "$HOME/.local/bin"
    cp bin/vibecare-server "$target"
    echo -e "${GREEN}✓ Installed: ${target}${NC}"
    if grep -q "<string>${target}</string>" "$plist"; then
        echo -e "${GREEN}Restarting service with new binary...${NC}"
        launchctl kickstart -k "gui/${uid}/${label}"
    else
        echo -e "${YELLOW}Repointing LaunchAgent to local build...${NC}"
        sed -i '' "s|<string>/usr/local/bin/vibecare-server</string>|<string>${target}</string>|" "$plist"
        just _reload-service
    fi
    echo -e "${GREEN}✓ Service now running your local build${NC}"

# Show which backend is configured and running
[group('📦 Build & Run')]
service-status:
    #!/usr/bin/env bash
    set -uo pipefail
    label="io.vibecare.server"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    if launchctl list "$label" >/dev/null 2>&1; then
        echo -e "${GREEN}Service: loaded${NC}"
    else
        echo -e "${YELLOW}Service: not loaded${NC}"
    fi
    if [ -f "$plist" ]; then
        binpath=$(grep -o '<string>[^<]*vibecare-server</string>' "$plist" | head -1 | sed 's|<string>||; s|</string>||')
        echo -e "Binary in plist: ${binpath}"
        case "$binpath" in
            "$HOME/.local/bin/vibecare-server") echo -e "  ${GREEN}(local build)${NC}" ;;
            "/usr/local/bin/vibecare-server")   echo -e "  ${YELLOW}(production / PKG build)${NC}" ;;
        esac
    else
        echo -e "${YELLOW}No LaunchAgent plist found${NC}"
    fi
    pid=$(pgrep -f 'vibecare-server' | head -1 || true)
    [ -n "$pid" ] && echo -e "Running PID: ${pid}" || echo -e "No vibecare-server process running"
    echo -n "Port 50051: "; lsof -i :50051 -sTCP:LISTEN -t >/dev/null 2>&1 && echo "in use" || echo "free"
    echo -n "Port 8080:  "; lsof -i :8080 -sTCP:LISTEN -t >/dev/null 2>&1 && echo "in use" || echo "free"

# Stop the background LaunchAgent (frees ports)
[group('📦 Build & Run')]
service-stop:
    @launchctl bootout "gui/$(id -u)/io.vibecare.server" 2>/dev/null && echo "{{GREEN}}✓ Service stopped{{NC}}" || echo "{{YELLOW}}Service was not running{{NC}}"

# Start (or restart) the background LaunchAgent
[group('📦 Build & Run')]
service-start: _reload-service
    @echo "{{GREEN}}✓ Service started{{NC}}"

# Revert the LaunchAgent to the shipped /usr/local/bin production binary
[group('📦 Build & Run')]
service-restore-prod:
    #!/usr/bin/env bash
    set -euo pipefail
    label="io.vibecare.server"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    sed -i '' "s|<string>$HOME/.local/bin/vibecare-server</string>|<string>/usr/local/bin/vibecare-server</string>|" "$plist"
    just _reload-service
    echo -e "${GREEN}✓ Service restored to production build (/usr/local/bin/vibecare-server)${NC}"

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

# Build the kernel's todo reference plugin into its own directory — core
# discovers plugins by scanning plugins/<id>/manifest.yaml, so the binary
# lives alongside the manifest rather than under ~/.vibecare.
[group('🧩 Plugins')]
build-todo-plugin:
    @echo "{{GREEN}}Building todo plugin...{{NC}}"
    cd plugins/todo && go build -o todo .
    @echo "{{GREEN}}✓ todo plugin built: plugins/todo/todo{{NC}}"

# Build the vibecheck plugin. Swift, not Go. The -sectcreate flags embed
# Info.plist into the Mach-O so macOS has an NSCameraUsageDescription to
# show when the camera is first opened — a bare binary has no bundle and
# would otherwise get no prompt. The codesign step is REQUIRED, not
# optional cleanup: the -sectcreate section is inert until a signature
# seals it, and the binary has no CFBundleIdentifier until then either —
# TCC reads the *sealed* plist, so skipping this step means the camera
# prompt silently never carries NSCameraUsageDescription. Do not remove
# it. It's still ad-hoc (`-s -`, no certificate, nothing for a contributor
# to install): the TCC grant is keyed to the spawning process
# (vibecare-server), not to this binary, so an ad-hoc signature is fine
# and the grant survives rebuilds.
[group('🧩 Plugins')]
build-vibecheck-plugin:
    @echo "{{GREEN}}Building vibecheck plugin...{{NC}}"
    cd plugins/vibecheck && swift build -c release \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
    # Sign BEFORE copying, and specifically in .build/release/. plugins/vibecheck/
    # contains an Info.plist, so codesigning the copy there makes codesign treat
    # the whole directory as a bundle: it hashes everything under it — all of
    # .build/ included — and drops a ~9 MB plugins/vibecheck/_CodeSignature/
    # CodeResources next to the binary. Signing where no Info.plist sits beside
    # the Mach-O produces the same signature (the __info_plist section is linked
    # in above, so Identifier and Info.plist entries are identical) with no
    # bundle. The signature lives inside the Mach-O, so the copy preserves it.
    codesign -f -s - plugins/vibecheck/.build/release/vibecheck
    cp plugins/vibecheck/.build/release/vibecheck plugins/vibecheck/vibecheck
    # The UI is a SwiftPM resource (Sources/vibecheck/ui, declared as
    # `resources: [.copy("ui")]`), so it ships as a .bundle directory that
    # must sit NEXT TO the binary — that is the only place the generated
    # Bundle.module accessor looks in a real install. Copy the binary alone
    # and GET /p/vibecheck/ serves a 500 with no UI.
    rm -rf plugins/vibecheck/vibecheck_vibecheck.bundle
    cp -R plugins/vibecheck/.build/release/vibecheck_vibecheck.bundle plugins/vibecheck/
    @echo "{{GREEN}}✓ vibecheck plugin built: plugins/vibecheck/vibecheck{{NC}}"

# Copies each built plugin into the directory core scans by default
# (~/.vibecare/plugins-v2/<id>/), so an installed VibeCare finds them with
# no --plugins-dir flag. `just run` uses the repo's plugins/ instead and
# does not need this.
#
# Install built plugins where core looks for them by default
[group('🧩 Plugins')]
install-plugins: build-plugins
    #!/usr/bin/env bash
    set -euo pipefail
    dest="$HOME/.vibecare/plugins-v2"
    mkdir -p "$dest"
    for dir in plugins/*/; do
        id=$(basename "$dir")
        [ -f "$dir/manifest.yaml" ] || continue
        [ -x "$dir/$id" ] || { echo -e "${YELLOW}skipping $id: no binary${NC}"; continue; }
        mkdir -p "$dest/$id"
        cp "$dir/$id" "$dir/manifest.yaml" "$dest/$id/"
        # SwiftPM plugins ship their resources as a .bundle beside the
        # binary, and the generated Bundle.module accessor resolves it
        # relative to the executable — so it has to travel with it.
        for bundle in "$dir"*.bundle; do
            [ -d "$bundle" ] || continue
            rm -rf "$dest/$id/$(basename "$bundle")"
            cp -R "$bundle" "$dest/$id/"
        done
        echo -e "${GREEN}✓ installed $id -> $dest/$id{{NC}}"
    done

# Builds with `-tags dev`, so each plugin serves its ui/ from disk and
# exposes a reload stream instead of embedding the UI. Never release this.
#
# Build plugins with live reload (dev only, never for release)
[group('🧩 Plugins')]
build-plugins-dev:
    @echo "{{GREEN}}Building plugins (dev: live reload)...{{NC}}"
    cd plugins/todo && go build -tags dev -o todo .
    @echo "{{GREEN}}✓ Plugins built with live reload{{NC}}"

# Build every plugin binary into its own directory.
[group('🧩 Plugins')]
build-plugins: build-todo-plugin build-vibecheck-plugin
    @echo "{{GREEN}}✓ All plugins built{{NC}}"

# Picks a profile, builds vibecare-mcp-server, bakes it into the io.vibecare.mcp service
# Deploy your local MCP build into an always-on LaunchAgent (HTTP mode, no sudo)
[group('🤖 MCP Server')]
deploy-local-with-mcp profile_id="" port="8081":
    #!/usr/bin/env bash
    set -euo pipefail
    label="io.vibecare.mcp"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    target="$HOME/.local/bin/vibecare-mcp-server"
    db="$HOME/.vibecare/vibecare.db"
    port="{{port}}"

    # 1. Guard: database must exist (profiles live here)
    if [ ! -f "$db" ]; then
        echo -e "${RED}Database not found at $db — run 'just migrate' first.${NC}"
        exit 1
    fi

    # 2. Resolve profile ID (arg overrides the interactive picker)
    profile_id="{{profile_id}}"
    if [ -z "$profile_id" ]; then
        profiles=$(sqlite3 "$db" "SELECT id || '|' || COALESCE(name,'') || '|' || COALESCE(email,'') FROM profiles;")
        if [ -z "$profiles" ]; then
            echo -e "${RED}No profiles found.${NC}"
            echo -e "${YELLOW}Create one first: just grpc-create-profile 'Your Name' 'your@email.com'${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Available profiles:${NC}"
        IFS=$'\n'
        count=0
        declare -a profile_ids
        for p in $profiles; do
            count=$((count + 1))
            pid=$(echo "$p" | cut -d'|' -f1)
            name=$(echo "$p" | cut -d'|' -f2)
            email=$(echo "$p" | cut -d'|' -f3)
            profile_ids[$count]="$pid"
            echo "  $count) $name ($email)"
        done
        unset IFS
        echo ""
        echo -n "Select profile (1-$count): "
        read selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            echo -e "${RED}Invalid selection${NC}"
            exit 1
        fi
        profile_id="${profile_ids[$selection]}"
    fi
    echo -e "${GREEN}Profile ID: ${profile_id}${NC}"

    # 3. Warn if the gRPC backend isn't listening (the MCP server connects to it)
    if ! lsof -i :50051 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ gRPC backend not listening on :50051.${NC}"
        echo -e "${YELLOW}  Start it with 'just deploy-local' or 'just service-start' — the MCP service keeps retrying until it's up.${NC}"
    fi

    # 4. Build the standalone MCP binary and install to ~/.local/bin
    echo -e "${GREEN}Building standalone MCP server...${NC}"
    (cd {{backend_dir}} && go build -ldflags="-s -w" -o ../bin/vibecare-mcp-server cmd/mcp-server/main.go)
    mkdir -p "$HOME/.local/bin"
    cp bin/vibecare-mcp-server "$target"
    echo -e "${GREEN}✓ Installed: ${target}${NC}"

    # 5. Generate the LaunchAgent plist (regenerated each run — profile/port may change)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.vibecare/logs"
    cat > "$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>${label}</string>
        <key>ProgramArguments</key>
        <array>
            <string>${target}</string>
            <string>--http</string>
            <string>--profile-id=${profile_id}</string>
            <string>--grpc-addr</string>
            <string>localhost:50051</string>
            <string>--port</string>
            <string>${port}</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>StandardOutPath</key>
        <string>${HOME}/.vibecare/logs/mcp.log</string>
        <key>StandardErrorPath</key>
        <string>${HOME}/.vibecare/logs/mcp-error.log</string>
        <key>EnvironmentVariables</key>
        <dict>
            <key>PATH</key>
            <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        </dict>
        <key>ProcessType</key>
        <string>Background</string>
        <key>ThrottleInterval</key>
        <integer>30</integer>
    </dict>
    </plist>
    PLIST
    echo -e "${GREEN}✓ Wrote LaunchAgent: ${plist}${NC}"

    # 6. (Re)load the always-on service with the new binary + profile
    echo -e "${GREEN}Starting always-on MCP service...${NC}"
    just _reload-service "$label"
    echo -e "${GREEN}✓ MCP service running: http://localhost:${port}/mcp${NC}"

    # 7. Print the Claude Desktop config for copy/paste
    npx_path=$(command -v npx 2>/dev/null || echo "npx")
    echo ""
    echo -e "${YELLOW}Claude Desktop config (~/Library/Application Support/Claude/claude_desktop_config.json):${NC}"
    echo "{"
    echo "  \"mcpServers\": {"
    echo "    \"vibecare\": {"
    echo "      \"command\": \"${npx_path}\","
    echo "      \"args\": [\"-y\", \"mcp-remote\", \"http://localhost:${port}/mcp\"]"
    echo "    }"
    echo "  }"
    echo "}"
    echo -e "${YELLOW}(requires 'npm install -g mcp-remote'; restart Claude Desktop after saving)${NC}"

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
    profiles=$(sqlite3 {{data_dir}}/vibecare.db "SELECT id || '|' || COALESCE(name,'') || '|' || COALESCE(email,'') FROM profiles;")
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
    cd {{cli_dir}} && go test ./...
    cd {{cli_dir}} && go test -tags dev ./...
    cd plugins/todo && go test -v ./...
    # vibecheck is Swift: `swift test` covers VCPluginSDK, and `go test`
    # drives the built binary against a real kernel and a scripted core.
    # The Go side builds the Swift binary itself, so it is slow on a cold
    # cache — that is the price of testing the actual two-process loop.
    cd plugins/vibecheck && swift test
    cd plugins/vibecheck && go test ./...

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
swift-build-release:
    @echo "{{GREEN}}Building Swift client (release)...{{NC}}"
    cd clients/macos-swift/VibeCare && swift build -c release
    @echo "{{GREEN}}✓ Swift client built: clients/macos-swift/VibeCare/.build/release/VibeCare{{NC}}"

[group('🍎 macOS / Swift')]
swift-run:
    @echo "{{GREEN}}Running Swift client...{{NC}}"
    cd clients/macos-swift/VibeCare && swift run VibeCare

# Build + run the real .app bundle via Xcode. USE THIS FOR THE CAMERA:
# `swift run` produces a bare CLI binary with no Info.plist, so macOS can't
# prompt for camera access (VibeCheck never appears in Privacy > Camera). The
# Xcode build embeds Info.plist (NSCameraUsageDescription + bundle id), so the
# system prompts correctly and lists the app.
[group('🍎 macOS / Swift')]
swift-run-app:
    @echo "{{GREEN}}Building VibeCare.app via Xcode (camera-capable Info.plist)...{{NC}}"
    cd clients/macos-swift/VibeCare && xcodebuild -project vibecare.xcodeproj -scheme vibecare -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' build
    @echo "{{GREEN}}Launching app...{{NC}}"
    open clients/macos-swift/VibeCare/.build/xcode/Build/Products/Debug/vibecare.app

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

# The terminal client: `vibecare status`, `vibecare logs -f`, and the
# full-screen TUI. It is its own Go module, so every recipe here runs from
# clients/cli — `go build ./...` at the repo root does not reach it.

# Build the CLI client
[group('🖥️  CLI')]
cli-build:
    @echo "{{GREEN}}Building CLI client...{{NC}}"
    cd {{cli_dir}} && go build -o ../../bin/vibecare .
    @echo "{{GREEN}}✓ CLI built: bin/vibecare{{NC}}"

# Arguments pass straight through, so `just cli-run status --json` is
# `vibecare status --json`. With no arguments it opens the TUI.

# Run the CLI client without installing it
[group('🖥️  CLI')]
cli-run *args:
    cd {{cli_dir}} && go run . {{args}}

# `-tags dev` compiles in `plugins rebuild`, which runs the build: command
# from a plugin's manifest.yaml. That is deliberately absent from the normal
# build — a shipped client should not execute a program named by a file on
# disk — so this is the binary to use while working on a plugin.

# Build the CLI client with dev-only commands (plugins rebuild)
[group('🖥️  CLI')]
cli-build-dev:
    @echo "{{GREEN}}Building CLI client (dev)...{{NC}}"
    cd {{cli_dir}} && go build -tags dev -o ../../bin/vibecare .
    @echo "{{GREEN}}✓ CLI built with dev commands: bin/vibecare{{NC}}"

# Open the TUI from a dev build, so `b` rebuilds the selected plugin
[group('🖥️  CLI')]
tui-dev *args: cli-build-dev
    ./bin/vibecare {{args}}

# Core does not have to be running first: the TUI comes up either way, says
# what it cannot reach, and reconnects on its own with backoff — so `just tui`
# in one pane and `just run` in another is a working order.
#
# It builds and execs the binary rather than using `go run`, which for a
# full-screen program adds a compile pause before the first frame and sits
# between the program and its signals, leaving the alt-screen behind on ^C.

# Build and open the full-screen TUI
[group('🖥️  CLI')]
tui *args: cli-build
    ./bin/vibecare {{args}}

# Test the CLI client
[group('🖥️  CLI')]
cli-test:
    @echo "{{GREEN}}Testing CLI client...{{NC}}"
    cd {{cli_dir}} && go test ./...
    cd {{cli_dir}} && go test -tags dev ./...

# Install the CLI client into $GOBIN (or $GOPATH/bin)
[group('🖥️  CLI')]
cli-install:
    @echo "{{GREEN}}Installing CLI client...{{NC}}"
    cd {{cli_dir}} && go install
    @echo "{{GREEN}}✓ vibecare installed to $(go env GOBIN || echo $(go env GOPATH)/bin){{NC}}"

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

# Trigger GitHub release workflow
[group('🚀 Release')]
release version ref="release":
    @echo "{{GREEN}}Triggering release workflow...{{NC}}"
    @echo "{{YELLOW}}Version: {{version}}{{NC}}"
    @echo "{{YELLOW}}Ref: {{ref}}{{NC}}"
    gh workflow run "Release 🎉" --ref {{ref}} --field version={{version}}
    @echo "{{GREEN}}✓ Workflow triggered. Check status at: https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions{{NC}}"

# Install docs-site deps and ensure pandoc is available
[group('📚 Documentation')]
docs-setup:
    @echo "{{GREEN}}Installing docs-site dependencies...{{NC}}"
    cd docs-site && bun install
    @command -v pandoc >/dev/null 2>&1 || (echo "{{YELLOW}}Installing pandoc via brew...{{NC}}" && brew install pandoc)
    @echo "{{GREEN}}✓ Docs tooling ready{{NC}}"

# Ensure docs-site deps are installed (internal guard; runs bun install once)
[group('📚 Documentation')]
_docs-deps:
    @[ -d docs-site/node_modules ] || (echo "{{YELLOW}}Installing docs-site dependencies...{{NC}}" && cd docs-site && bun install)

# Regenerate site content from docs/ (internal helper)
[group('📚 Documentation')]
docs-sync:
    cd docs-site && bun run sync

# Serve the docs site with live reload (http://localhost:4321)
[group('📚 Documentation')]
docs: _docs-deps docs-sync
    @echo "{{GREEN}}Starting docs dev server...{{NC}}"
    cd docs-site && bun run dev

# Build the static docs site into docs-site/dist
[group('📚 Documentation')]
docs-build: _docs-deps docs-sync
    @echo "{{GREEN}}Building static docs site...{{NC}}"
    cd docs-site && bun run build
