#!/bin/bash

# Consolidated protobuf generation script for VibeCare
# Supports multiple targets: backend (Go), client-macos (Swift), all

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$PROJECT_ROOT/proto"

# Default values
TARGET="all"
TARGET_DIR=""
BACKEND_DEFAULT_DIR="$PROJECT_ROOT/backend/pkg/proto"
MACOS_DEFAULT_DIR="$PROJECT_ROOT/clients/macos-swift/VibeCare/VCStubs"
# Swift plugins share ONE copy of the stubs, in the shared Swift SDK. There
# was a per-plugin copy under plugins/vibecheck/Sources/VCKStubs; a second
# copy is how the two disagreeing Package.resolved files in this tree came to
# exist, so there is deliberately only one output directory here.
PLUGIN_SWIFT_DEFAULT_DIR="$PROJECT_ROOT/sdk/swift/VCPluginSDK/Sources/VCKStubs"

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate protobuf code for VibeCare project"
    echo ""
    echo "Options:"
    echo "  -t, --target TARGET         Target to generate for: backend, client-macos, plugin-swift, all (default: all)"
    echo "  -td, --target-directory DIR Custom output directory (overrides default per target)"
    echo "  -h, --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                          # Generate all targets"
    echo "  $0 -t backend               # Generate only backend (Go) code"
    echo "  $0 -t client-macos          # Generate only macOS client (Swift) code"
    echo "  $0 -t backend -td /custom   # Generate backend to custom directory"
    exit 0
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--target)
                TARGET="$2"
                shift 2
                ;;
            -td|--target-directory)
                TARGET_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done

    # Validate target
    if [[ ! "$TARGET" =~ ^(backend|client-macos|plugin-swift|all)$ ]]; then
        echo -e "${RED}Invalid target: $TARGET${NC}"
        echo "Valid targets are: backend, client-macos, plugin-swift, all"
        exit 1
    fi
}

# Check if protoc is installed
check_protoc() {
    if ! command -v protoc &> /dev/null; then
        echo -e "${RED}protoc is not installed. Please install Protocol Buffers compiler.${NC}"
        echo "On macOS: brew install protobuf"
        echo "On Linux: apt-get install protobuf-compiler"
        exit 1
    fi
}

# Generate Go backend code
generate_backend() {
    local output_dir="${TARGET_DIR:-$BACKEND_DEFAULT_DIR}"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Generating Go backend protobuf code...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if Go protoc plugins are installed
    if ! command -v protoc-gen-go &> /dev/null; then
        echo -e "${YELLOW}Installing protoc-gen-go...${NC}"
        go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    fi

    if ! command -v protoc-gen-go-grpc &> /dev/null; then
        echo -e "${YELLOW}Installing protoc-gen-go-grpc...${NC}"
        go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
    fi

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    # Generate Go code
    echo -e "${GREEN}Output directory: $output_dir${NC}"

    # Protos now live both at the root and under versioned subdirectories
    # (plugin/v1, client/v1, topics/v1). paths=source_relative mirrors that
    # tree into the output dir, so proto/plugin/v1/plugin.proto lands at
    # backend/pkg/proto/plugin/v1/plugin.pb.go and proto/topics/v1/vision.proto
    # at backend/pkg/proto/topics/v1/vision.pb.go.
    local proto_files
    proto_files=$(cd "$PROTO_DIR" && find . -name '*.proto' | sed 's|^\./||' | sort)

    protoc \
        --proto_path="$PROTO_DIR" \
        --go_out="$output_dir" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$output_dir" \
        --go-grpc_opt=paths=source_relative \
        $proto_files

    echo -e "${GREEN}✓ Go backend protobuf code generated successfully${NC}"
}

# Ensure protoc-gen-swift is available. Shared by every Swift-generating
# target (client-macos, plugin-swift) so the check lives in one place.
# Exits if $TARGET strictly requires Swift output; otherwise returns 1 so
# the caller can skip gracefully (e.g. `all` on a machine without Swift
# tooling).
ensure_swift_protoc_plugin() {
    if command -v protoc-gen-swift &> /dev/null; then
        return 0
    fi

    echo -e "${YELLOW}Swift protobuf plugin not found.${NC}"

    # Auto-install if in CI or AUTO_INSTALL_PLUGINS is set
    if [[ "${CI:-false}" == "true" ]] || [[ "${AUTO_INSTALL_PLUGINS:-false}" == "true" ]]; then
        echo -e "${GREEN}Installing swift-protobuf...${NC}"
        brew install swift-protobuf
        return 0
    fi

    echo "To install: brew install swift-protobuf"
    if [[ "$TARGET" == "client-macos" || "$TARGET" == "plugin-swift" ]]; then
        exit 1
    fi
    echo -e "${YELLOW}Skipping Swift code generation.${NC}"
    return 1
}

# Resolve the protoc-gen-grpc-swift(-2) plugin path into the global
# $grpc_plugin so every Swift-generating target can see it. Exits if
# $TARGET strictly requires Swift output; otherwise returns 1 so the
# caller can skip.
resolve_grpc_swift_plugin() {
    grpc_plugin=""
    if [[ -f "/opt/homebrew/bin/protoc-gen-grpc-swift-2" ]]; then
        grpc_plugin="/opt/homebrew/bin/protoc-gen-grpc-swift-2"
    elif command -v protoc-gen-grpc-swift &> /dev/null; then
        grpc_plugin="$(which protoc-gen-grpc-swift)"
    else
        echo -e "${YELLOW}Swift gRPC plugin not found.${NC}"

        # Auto-install if in CI or AUTO_INSTALL_PLUGINS is set
        if [[ "${CI:-false}" == "true" ]] || [[ "${AUTO_INSTALL_PLUGINS:-false}" == "true" ]]; then
            echo -e "${GREEN}Installing grpc-swift...${NC}"
            brew install grpc-swift
            # Re-check for the plugin after installation
            if [[ -f "/opt/homebrew/bin/protoc-gen-grpc-swift-2" ]]; then
                grpc_plugin="/opt/homebrew/bin/protoc-gen-grpc-swift-2"
            elif command -v protoc-gen-grpc-swift &> /dev/null; then
                grpc_plugin="$(which protoc-gen-grpc-swift)"
            else
                echo -e "${RED}Failed to install grpc-swift plugin${NC}"
                exit 1
            fi
        else
            echo "To install: brew install grpc-swift"
            if [[ "$TARGET" == "client-macos" || "$TARGET" == "plugin-swift" ]]; then
                exit 1
            else
                echo -e "${YELLOW}Skipping Swift gRPC code generation.${NC}"
                return 1
            fi
        fi
    fi
    return 0
}

# Generate Swift macOS client code
generate_macos() {
    local output_dir="${TARGET_DIR:-$MACOS_DEFAULT_DIR}"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Generating Swift macOS client protobuf code...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    ensure_swift_protoc_plugin || return
    local grpc_plugin
    resolve_grpc_swift_plugin || return

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    echo -e "${GREEN}Output directory: $output_dir${NC}"

    # topics/ holds BUS payloads exchanged between plugins. The client has no
    # per-plugin code and never touches the bus — it knows "a URL", never a
    # topic schema — so those protos are excluded here rather than shipped as
    # dead Swift in the app target. Swift plugins get them via plugin-swift.
    local proto_files
    proto_files=$(cd "$PROTO_DIR" && find . -name '*.proto' | sed 's|^\./||' | grep -v '^topics/' | sort)

    # Generate protobuf messages
    echo -e "${GREEN}Generating Swift protobuf messages...${NC}"
    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_opt=Visibility=Public \
        --swift_opt=FileNaming=DropPath \
        --swift_out="$output_dir" \
        $proto_files

    # Generate gRPC service stubs
    echo -e "${GREEN}Generating Swift gRPC service stubs...${NC}"
    protoc \
        --proto_path="$PROTO_DIR" \
        --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
        --grpc-swift_opt=Visibility=Public \
        --grpc-swift_opt=FileNaming=DropPath \
        --grpc-swift_out="$output_dir" \
        $proto_files

    # List generated files
    echo -e "${GREEN}Generated files:${NC}"
    ls -la "$output_dir"

    echo -e "${GREEN}✓ Swift macOS client protobuf code generated successfully${NC}"
}

# Generate the Swift stubs every Swift plugin needs: the plugin<->core
# contract (plugin/v1) plus the bus payload contracts (topics/v1). Unlike
# generate_macos this does not walk the whole proto/ tree — no plugin has any
# business with vibecare.proto or client/v1 — and it is deliberately excluded
# from the `all` target: `all` is the release path, this is plugin codegen run
# from within a plugin's own build.
#
# Output is the SHARED Swift SDK's stub target, not a per-plugin directory:
# vision, vibecheck and blink-jump all link the same copy.
generate_plugin_swift() {
    local output_dir="${TARGET_DIR:-$PLUGIN_SWIFT_DEFAULT_DIR}"

    ensure_swift_protoc_plugin || return
    local grpc_plugin
    resolve_grpc_swift_plugin || return

    mkdir -p "$output_dir"
    echo -e "${BLUE}Generating Swift plugin stubs -> $output_dir${NC}"

    # Messages: plugin/v1 and every topics/v1 payload.
    local topic_protos
    topic_protos=$(find "$PROTO_DIR/topics" -name '*.proto' | sort)

    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_opt=Visibility=Public \
        --swift_opt=FileNaming=DropPath \
        --swift_out="$output_dir" \
        "$PROTO_DIR/plugin/v1/plugin.proto" \
        $topic_protos

    # Service stubs: plugin/v1 only. The topic protos declare no service —
    # they are bus payloads, and a plugin is always the gRPC client (D2), so
    # there is nothing for grpc-swift to emit.
    protoc \
        --proto_path="$PROTO_DIR" \
        --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
        --grpc-swift_opt=Visibility=Public \
        --grpc-swift_opt=FileNaming=DropPath \
        --grpc-swift_out="$output_dir" \
        "$PROTO_DIR/plugin/v1/plugin.proto"

    echo -e "${GREEN}✓ Swift plugin stubs generated${NC}"
}

# Main function
main() {
    echo -e "${GREEN}VibeCare Protobuf Code Generator${NC}"
    echo -e "${GREEN}==================================${NC}"

    # Check protoc is installed
    check_protoc

    # Execute based on target
    case "$TARGET" in
        backend)
            generate_backend
            ;;
        client-macos)
            generate_macos
            ;;
        plugin-swift)
            generate_plugin_swift
            ;;
        all)
            generate_backend
            echo ""  # Add spacing between outputs
            generate_macos
            ;;
    esac

    echo ""
    echo -e "${GREEN}✓ All requested protobuf code generation complete!${NC}"
}

# Parse arguments and run
parse_arguments "$@"
main