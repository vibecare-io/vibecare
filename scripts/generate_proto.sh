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

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate protobuf code for VibeCare project"
    echo ""
    echo "Options:"
    echo "  -t, --target TARGET         Target to generate for: backend, client-macos, all (default: all)"
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
    if [[ ! "$TARGET" =~ ^(backend|client-macos|all)$ ]]; then
        echo -e "${RED}Invalid target: $TARGET${NC}"
        echo "Valid targets are: backend, client-macos, all"
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
    protoc \
        --proto_path="$PROTO_DIR" \
        --go_out="$output_dir" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$output_dir" \
        --go-grpc_opt=paths=source_relative \
        "$PROTO_DIR/vibecare.proto"

    echo -e "${GREEN}✓ Go backend protobuf code generated successfully${NC}"
}

# Generate Swift macOS client code
generate_macos() {
    local output_dir="${TARGET_DIR:-$MACOS_DEFAULT_DIR}"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Generating Swift macOS client protobuf code...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if Swift protoc plugins are installed
    if ! command -v protoc-gen-swift &> /dev/null; then
        echo -e "${YELLOW}Swift protobuf plugin not found.${NC}"
        echo "To install: brew install swift-protobuf"
        if [[ "$TARGET" == "client-macos" ]]; then
            exit 1
        else
            echo -e "${YELLOW}Skipping Swift code generation.${NC}"
            return
        fi
    fi

    # Check for gRPC Swift 2 plugin
    local grpc_plugin=""
    if [[ -f "/opt/homebrew/bin/protoc-gen-grpc-swift-2" ]]; then
        grpc_plugin="/opt/homebrew/bin/protoc-gen-grpc-swift-2"
    elif command -v protoc-gen-grpc-swift &> /dev/null; then
        grpc_plugin="$(which protoc-gen-grpc-swift)"
    else
        echo -e "${YELLOW}Swift gRPC plugin not found.${NC}"
        echo "To install: brew install grpc-swift"
        if [[ "$TARGET" == "client-macos" ]]; then
            exit 1
        else
            echo -e "${YELLOW}Skipping Swift gRPC code generation.${NC}"
            return
        fi
    fi

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    echo -e "${GREEN}Output directory: $output_dir${NC}"

    # Generate protobuf messages
    echo -e "${GREEN}Generating Swift protobuf messages...${NC}"
    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_opt=Visibility=Public \
        --swift_out="$output_dir" \
        "$PROTO_DIR/vibecare.proto"

    # Generate gRPC service stubs
    echo -e "${GREEN}Generating Swift gRPC service stubs...${NC}"
    protoc \
        --proto_path="$PROTO_DIR" \
        --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
        --grpc-swift_opt=Visibility=Public \
        --grpc-swift_out="$output_dir" \
        "$PROTO_DIR/vibecare.proto"

    # List generated files
    echo -e "${GREEN}Generated files:${NC}"
    ls -la "$output_dir"

    echo -e "${GREEN}✓ Swift macOS client protobuf code generated successfully${NC}"
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