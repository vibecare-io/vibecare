module github.com/vibecare-io/vibecare/plugins/vibecheck

go 1.23.0

toolchain go1.24.4

require github.com/vibecare-io/vibecare/backend v0.0.0-00010101000000-000000000000

require (
	golang.org/x/net v0.43.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
	golang.org/x/text v0.28.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20250825161204-c5933d9347a5 // indirect
	google.golang.org/grpc v1.75.0 // indirect
	google.golang.org/protobuf v1.36.8 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

replace github.com/vibecare-io/vibecare/backend => ../../backend
