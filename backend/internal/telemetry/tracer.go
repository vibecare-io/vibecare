package telemetry

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

// InitTracer initializes the OpenTelemetry tracer with OTLP exporter
// Returns a shutdown function that should be called on application exit
func InitTracer(serviceName, otlpEndpoint string, logger *zap.Logger) (func(context.Context) error, error) {
	ctx := context.Background()

	// Create OTLP trace exporter
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(otlpEndpoint),
		otlptracegrpc.WithInsecure(), // Use insecure for local development
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create OTLP exporter: %w", err)
	}

	// Get hostname for resource attributes
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	// Create resource with service information
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion("1.0.0"),
			semconv.HostName(hostname),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// Create trace provider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		// Sample all traces for development
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)

	// Set global tracer provider
	otel.SetTracerProvider(tp)

	logger.Info("OpenTelemetry tracer initialized",
		zap.String("service", serviceName),
		zap.String("endpoint", otlpEndpoint),
	)

	// Return shutdown function
	return func(ctx context.Context) error {
		logger.Info("Shutting down tracer...")
		// Create a context with timeout for shutdown
		shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		return tp.Shutdown(shutdownCtx)
	}, nil
}

// GetTracer returns a tracer for the given instrumentation scope
func GetTracer(instrumentationName string) trace.Tracer {
	return otel.GetTracerProvider().Tracer(instrumentationName)
}
