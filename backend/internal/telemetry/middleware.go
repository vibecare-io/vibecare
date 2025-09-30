package telemetry

import (
	"context"
	"encoding/json"
	"fmt"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

const (
	// MaxPayloadSize limits the size of logged payloads to prevent memory issues
	MaxPayloadSize = 10000 // 10KB
)

// serializeProtoMessage safely serializes a proto message to JSON string
// Truncates if the payload is too large
func serializeProtoMessage(msg interface{}) string {
	if msg == nil {
		return ""
	}

	protoMsg, ok := msg.(proto.Message)
	if !ok {
		return fmt.Sprintf("(non-proto message: %T)", msg)
	}

	// Use protojson for better field names (uses json_name option)
	marshaler := protojson.MarshalOptions{
		Multiline:       false,
		Indent:          "",
		UseProtoNames:   false,
		EmitUnpopulated: false,
	}

	jsonBytes, err := marshaler.Marshal(protoMsg)
	if err != nil {
		return fmt.Sprintf("(marshal error: %v)", err)
	}

	// Truncate if too large
	if len(jsonBytes) > MaxPayloadSize {
		return string(jsonBytes[:MaxPayloadSize]) + "... (truncated)"
	}

	return string(jsonBytes)
}

// extractKeyFields extracts important fields from the JSON payload for span attributes
func extractKeyFields(jsonStr string) map[string]string {
	result := make(map[string]string)

	var data map[string]interface{}
	if err := json.Unmarshal([]byte(jsonStr), &data); err != nil {
		return result
	}

	// Extract common ID fields
	for _, key := range []string{"id", "profileId", "routineId", "scheduleId", "name", "email"} {
		if val, ok := data[key]; ok {
			result[key] = fmt.Sprintf("%v", val)
		}
	}

	return result
}

// UnaryServerInterceptor returns a new unary server interceptor that adds custom tracing
func UnaryServerInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {
		// Get the current span from context
		span := trace.SpanFromContext(ctx)

		// Serialize request payload
		requestJSON := serializeProtoMessage(req)

		// Add custom attributes
		span.SetAttributes(
			attribute.String("grpc.method", info.FullMethod),
		)

		// Extract metadata if present
		if md, ok := metadata.FromIncomingContext(ctx); ok {
			if userAgent := md.Get("user-agent"); len(userAgent) > 0 {
				span.SetAttributes(attribute.String("http.user_agent", userAgent[0]))
			}
		}

		// Add request payload as span event (better for large data)
		span.AddEvent("grpc.request", trace.WithAttributes(
			attribute.String("request.payload", requestJSON),
		))

		// Extract and add key fields as span attributes (for easier filtering)
		keyFields := extractKeyFields(requestJSON)
		for k, v := range keyFields {
			span.SetAttributes(attribute.String("request."+k, v))
		}

		// Log the request with payload
		logger.Debug("gRPC request received",
			zap.String("method", info.FullMethod),
			zap.String("trace_id", span.SpanContext().TraceID().String()),
			zap.String("span_id", span.SpanContext().SpanID().String()),
			zap.String("request_payload", requestJSON),
		)

		// Call the handler
		resp, err := handler(ctx, req)

		// Serialize response payload
		responseJSON := serializeProtoMessage(resp)

		// Record error if present
		if err != nil {
			// Use enhanced error recording with full context
			RecordErrorWithDetails(span, err, requestJSON)

			// Log with full error context
			LogErrorWithContext(ctx, logger, err, "gRPC request failed",
				zap.String("method", info.FullMethod),
				zap.String("request_payload", requestJSON),
			)
		} else {
			span.SetAttributes(attribute.String("grpc.status_code", "OK"))

			// Add response payload as span event
			span.AddEvent("grpc.response", trace.WithAttributes(
				attribute.String("response.payload", responseJSON),
			))

			logger.Debug("gRPC request completed",
				zap.String("method", info.FullMethod),
				zap.String("trace_id", span.SpanContext().TraceID().String()),
				zap.String("response_payload", responseJSON),
			)
		}

		return resp, err
	}
}

// PanicRecoveryInterceptor returns a new unary server interceptor that recovers from panics
func PanicRecoveryInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (resp interface{}, err error) {
		// Get the current span
		span := trace.SpanFromContext(ctx)

		// Serialize request for panic logging
		requestJSON := serializeProtoMessage(req)

		// Setup panic recovery
		defer func() {
			if r := recover(); r != nil {
				// Recover the panic and record it
				RecoverPanic(span, requestJSON)

				// Log the panic
				logger.Error("Panic recovered in gRPC handler",
					zap.String("method", info.FullMethod),
					zap.Any("panic_value", r),
					zap.String("trace_id", span.SpanContext().TraceID().String()),
					zap.String("request_payload", requestJSON),
				)

				// Return internal error to client
				err = status.Error(13, "internal server error: panic recovered") // code 13 = INTERNAL
			}
		}()

		// Call the handler
		return handler(ctx, req)
	}
}
