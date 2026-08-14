// Command shutdownplugin is a test-only fixture for
// TestShutdownMessageIsDeliveredBeforeSIGTERM in ../../kernel_test.go. It
// is not a real plugin and ships nowhere.
//
// It deliberately talks raw pluginv1 gRPC instead of using
// backend/pkg/vc, and installs NO signal handling of its own. That means
// the ONLY way its marker file gets written is by actually receiving
// CoreMsg_Shutdown over the Register stream before the (default, untrapped)
// SIGTERM ends the process. That isolates the core-side half of Finding 1
// — Host.BroadcastShutdown's drain wait in backend/kernel/rpc.go — from the
// SDK-side half (vc.Connect's own SIGTERM fallback), which has its own
// separate test in backend/pkg/vc/vc_test.go. If this fixture used the SDK
// instead, its SIGTERM fallback would paper over a broken drain wait and
// the regression this test exists to catch would go undetected.
//
// Go's tool chain never treats a "testdata" directory as part of `./...`,
// so this never gets swept into `go build ./...` or `go vet ./...` at the
// module root; the test that uses it builds it explicitly by path.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"

	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	socket := os.Getenv("VIBECARE_SOCKET")
	id := os.Getenv("VIBECARE_PLUGIN_ID")
	dataDir := os.Getenv("VIBECARE_DATA_DIR")
	if socket == "" || id == "" || dataDir == "" {
		log.Fatal("shutdownplugin: VIBECARE_SOCKET, VIBECARE_PLUGIN_ID and VIBECARE_DATA_DIR must all be set")
	}

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("shutdownplugin: listen: %v", err)
	}
	_, portStr, err := net.SplitHostPort(lis.Addr().String())
	if err != nil {
		log.Fatalf("shutdownplugin: split addr: %v", err)
	}
	var port int
	if _, err := fmt.Sscanf(portStr, "%d", &port); err != nil {
		log.Fatalf("shutdownplugin: parse port: %v", err)
	}

	conn, err := grpc.NewClient("unix://"+socket, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("shutdownplugin: dial: %v", err)
	}
	client := pluginv1.NewPluginHostClient(conn)

	stream, err := client.Register(context.Background(), &pluginv1.RegisterReq{Id: id, HttpPort: uint32(port)})
	if err != nil {
		log.Fatalf("shutdownplugin: register: %v", err)
	}

	for {
		msg, err := stream.Recv()
		if err != nil {
			log.Fatalf("shutdownplugin: stream ended: %v", err)
		}
		if msg.GetShutdown() != nil {
			_ = os.WriteFile(filepath.Join(dataDir, "shutdown-received"), []byte("ok"), 0o600)
		}
		// Ready and Event messages need no handling for this fixture.
	}
}
