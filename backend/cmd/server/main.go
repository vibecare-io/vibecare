package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/vibecare-io/vibecare/backend/internal/api"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	var (
		port   = flag.Int("port", 50051, "The server port")
		dbPath = flag.String("db", "", "Path to SQLite database")
	)
	flag.Parse()

	// Setup logger
	logger, err := zap.NewDevelopment()
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Sync()

	// Determine database path
	if *dbPath == "" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			logger.Fatal("Failed to get home directory", zap.Error(err))
		}
		*dbPath = filepath.Join(homeDir, ".vibecare", "vibecare.db")

		// Create directory if it doesn't exist
		dir := filepath.Dir(*dbPath)
		if err := os.MkdirAll(dir, 0755); err != nil {
			logger.Fatal("Failed to create database directory", zap.Error(err))
		}
	}

	// Initialize database
	logger.Info("Opening database", zap.String("path", *dbPath))
	db, err := storage.New(*dbPath)
	if err != nil {
		logger.Fatal("Failed to open database", zap.Error(err))
	}
	defer db.Close()

	// Create gRPC server
	grpcServer := grpc.NewServer()

	// Register services
	api.RegisterServices(grpcServer, db, logger)

	// Register reflection service for debugging
	reflection.Register(grpcServer)

	// Start listening
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", *port))
	if err != nil {
		logger.Fatal("Failed to listen", zap.Error(err))
	}

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-sigChan
		logger.Info("Shutting down server...")
		grpcServer.GracefulStop()
	}()

	logger.Info("VibeCare server starting", zap.Int("port", *port))
	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("Failed to serve", zap.Error(err))
	}
}
