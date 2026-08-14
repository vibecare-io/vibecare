import Foundation

public enum VCEnvironmentError: Error, Equatable {
    case missing(String)
}

/// The entire spawn contract: three variables, all required.
/// `supervisor.go:229-233` sets exactly these and nothing else.
public struct VCEnvironment: Sendable {
    public let socketPath: String
    public let pluginID: String
    public let dataDir: URL

    /// Returns a thunk rather than throwing directly so callers can build
    /// the value in one expression and decide where to surface the failure.
    public static func from(_ env: [String: String]) -> Result<VCEnvironment, VCEnvironmentError> {
        func require(_ key: String) -> Result<String, VCEnvironmentError> {
            guard let v = env[key], !v.isEmpty else { return .failure(.missing(key)) }
            return .success(v)
        }
        return require("VIBECARE_SOCKET").flatMap { socket in
            require("VIBECARE_PLUGIN_ID").flatMap { id in
                require("VIBECARE_DATA_DIR").map { dir in
                    VCEnvironment(socketPath: socket,
                                  pluginID: id,
                                  dataDir: URL(fileURLWithPath: dir))
                }
            }
        }
    }

    public static func fromProcess() -> Result<VCEnvironment, VCEnvironmentError> {
        from(ProcessInfo.processInfo.environment)
    }
}
