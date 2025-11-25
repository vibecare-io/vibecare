import Foundation
import Logging
import SwiftProtobuf
import GRPCCore
import GRPCProtobuf
import VCStubs

enum ProfileServiceError: Error {
    case timeout
}

public final class ProfileService: @unchecked Sendable {

    public init() {}
    private let logger = Logger(label: "com.vibecare.profile-service")

    // MARK: - Profile Operations

    public func listProfiles() async throws -> [Profile] {
        logger.info("Listing profiles from server")

        do {
            let profiles = try await GRPCClientManager.shared.withProfileServiceClient { client in
                // Create a request message using the generated struct
                let request = VCListProfilesRequest()
                logger.info("Making gRPC call to listProfiles...")

                // Call the unary RPC and handle the response
                let clientRequest = ClientRequest(message: request)
                let response = try await client.listProfiles(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCListProfilesRequest>(),
                    deserializer: ProtobufDeserializer<VCListProfilesResponse>()
                )

                logger.info("Received response from server")

                let profiles = response.profiles.map { vcProfile in
                    convertToProfile(vcProfile)
                }

                logger.info("Successfully fetched \(profiles.count) profiles from server")
                return profiles
            }

            return profiles

        } catch {
            logger.error("Failed to list profiles: \(error)")

            // Return empty list if server is unavailable
            logger.info("Server unavailable, returning empty profile list")
            return []
        }
    }

    func createProfile(name: String, email: String?, timezone: String? = nil, preferences: [String: String]) async throws -> Profile {
        logger.info("Creating profile: \(name)")

        do {
            let profile = try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCCreateProfileRequest()
                request.name = name
                request.email = email ?? ""  // Send empty string if email is nil
                request.timezone = timezone ?? TimeZone.current.identifier  // Auto-detect if not provided
                request.preferences = preferences

                let clientRequest = ClientRequest(message: request)
                let response = try await client.createProfile(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCCreateProfileRequest>(),
                    deserializer: ProtobufDeserializer<VCCreateProfileResponse>()
                )

                let profile = convertToProfile(response.profile)
                logger.info("Profile created successfully: \(profile.id)")
                return profile
            }

            return profile

        } catch {
            logger.error("Failed to create profile: \(error)")
            throw error
        }
    }

    func getProfile(id: String) async throws -> Profile? {
        logger.info("Getting profile: \(id)")

        do {
            let profile = try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCGetProfileRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                let vcProfile = try await client.getProfile(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCGetProfileRequest>(),
                    deserializer: ProtobufDeserializer<VCProfile>()
                )

                let profile = convertToProfile(vcProfile)
                logger.info("Successfully retrieved profile: \(profile.id)")
                return profile
            }

            return profile

        } catch {
            logger.error("Failed to get profile: \(error)")
            return nil
        }
    }

    func updateProfile(_ profile: Profile) async throws -> Profile {
        logger.info("Updating profile: \(profile.id)")

        do {
            let updatedProfile = try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCUpdateProfileRequest()
                request.id = profile.id
                request.name = profile.name
                request.email = profile.email ?? ""  // Convert nil to empty string for protobuf
                request.timezone = profile.timezone

                let clientRequest = ClientRequest(message: request)
                let updatedVCProfile = try await client.updateProfile(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCUpdateProfileRequest>(),
                    deserializer: ProtobufDeserializer<VCProfile>()
                )

                let updatedProfile = convertToProfile(updatedVCProfile)
                logger.info("Profile updated successfully")
                return updatedProfile
            }

            return updatedProfile

        } catch {
            logger.error("Failed to update profile: \(error)")
            throw error
        }
    }

    func deleteProfile(id: String) async throws {
        logger.info("Deleting profile: \(id)")

        do {
            try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCDeleteProfileRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                _ = try await client.deleteProfile(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCDeleteProfileRequest>(),
                    deserializer: ProtobufDeserializer<SwiftProtobuf.Google_Protobuf_Empty>()
                )

                logger.info("Profile deleted successfully")
            }

        } catch {
            logger.error("Failed to delete profile: \(error)")
            throw error
        }
    }

    // MARK: - Device Operations

    func registerDevice(
        profileId: String,
        deviceName: String,
        deviceType: DeviceType,
        pushToken: String? = nil
    ) async throws -> Device {
        logger.info("Registering device: \(deviceName) for profile: \(profileId)")

        do {
            let device = try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCRegisterDeviceRequest()
                request.profileID = profileId
                request.deviceName = deviceName
                request.deviceType = convertToVCDeviceType(deviceType)
                if let pushToken = pushToken {
                    request.pushToken = pushToken
                }

                let clientRequest = ClientRequest(message: request)
                let vcDevice = try await client.registerDevice(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCRegisterDeviceRequest>(),
                    deserializer: ProtobufDeserializer<VCDevice>()
                )

                let device = convertToDevice(vcDevice)
                logger.info("Device registered successfully: \(device.id)")
                return device
            }

            return device

        } catch {
            logger.error("Failed to register device: \(error)")
            throw error
        }
    }

    func unregisterDevice(profileId: String, deviceId: String) async throws {
        logger.info("Unregistering device: \(deviceId) for profile: \(profileId)")

        do {
            try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCUnregisterDeviceRequest()
                request.profileID = profileId
                request.deviceID = deviceId

                let clientRequest = ClientRequest(message: request)
                _ = try await client.unregisterDevice(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCUnregisterDeviceRequest>(),
                    deserializer: ProtobufDeserializer<SwiftProtobuf.Google_Protobuf_Empty>()
                )

                logger.info("Device unregistered successfully")
            }

        } catch {
            logger.error("Failed to unregister device: \(error)")
            throw error
        }
    }

    func listDevices(profileId: String) async throws -> [Device] {
        logger.info("Listing devices for profile: \(profileId)")

        do {
            let devices = try await GRPCClientManager.shared.withProfileServiceClient { client in
                var request = VCListDevicesRequest()
                request.profileID = profileId

                let clientRequest = ClientRequest(message: request)
                let response = try await client.listDevices(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCListDevicesRequest>(),
                    deserializer: ProtobufDeserializer<VCListDevicesResponse>()
                )

                let devices = response.devices.map { vcDevice in
                    convertToDevice(vcDevice)
                }

                logger.info("Successfully listed \(devices.count) devices")
                return devices
            }

            return devices

        } catch {
            logger.error("Failed to list devices: \(error)")
            return []
        }
    }

    // MARK: - Private Helpers

    private func convertToProfile(_ vcProfile: VCProfile) -> Profile {
        let devices = vcProfile.devices.map { vcDevice in
            convertToDevice(vcDevice)
        }

        return Profile(
            id: vcProfile.id,
            name: vcProfile.name,
            email: vcProfile.email.isEmpty ? nil : vcProfile.email,  // Convert empty string to nil
            timezone: vcProfile.timezone.isEmpty ? TimeZone.current.identifier : vcProfile.timezone,  // Default to system timezone if empty
            preferences: vcProfile.preferences,
            devices: devices,
            createdAt: vcProfile.hasCreatedAt ? vcProfile.createdAt.date : Date(),
            updatedAt: vcProfile.hasUpdatedAt ? vcProfile.updatedAt.date : Date()
        )
    }

    private func convertToVCProfile(_ profile: Profile) -> VCProfile {
        var vcProfile = VCProfile()
        vcProfile.id = profile.id
        vcProfile.name = profile.name
        vcProfile.email = profile.email ?? ""  // Convert nil to empty string for protobuf
        vcProfile.timezone = profile.timezone
        vcProfile.preferences = profile.preferences
        vcProfile.devices = profile.devices.map { device in
            convertToVCDevice(device)
        }
        vcProfile.createdAt = Google_Protobuf_Timestamp(date: profile.createdAt)
        vcProfile.updatedAt = Google_Protobuf_Timestamp(date: profile.updatedAt)
        return vcProfile
    }

    private func convertToDevice(_ vcDevice: VCDevice) -> Device {
        return Device(
            id: vcDevice.id,
            name: vcDevice.name,
            type: convertDeviceType(vcDevice.type),
            pushToken: vcDevice.pushToken.isEmpty ? nil : vcDevice.pushToken,
            lastSeen: vcDevice.hasLastSeen ? vcDevice.lastSeen.date : Date(),
            active: vcDevice.active
        )
    }

    private func convertToVCDevice(_ device: Device) -> VCDevice {
        var vcDevice = VCDevice()
        vcDevice.id = device.id
        vcDevice.name = device.name
        vcDevice.type = convertToVCDeviceType(device.type)
        if let pushToken = device.pushToken {
            vcDevice.pushToken = pushToken
        }
        vcDevice.lastSeen = Google_Protobuf_Timestamp(date: device.lastSeen)
        vcDevice.active = device.active
        return vcDevice
    }

    private func convertDeviceType(_ vcDeviceType: VCDeviceType) -> DeviceType {
        switch vcDeviceType {
        case .macos:
            return .macOS
        case .ios:
            return .iOS
        case .linux:
            return .linux
        case .android:
            return .android
        case .windows:
            return .windows
        default:
            return .macOS // Default fallback
        }
    }

    private func convertToVCDeviceType(_ deviceType: DeviceType) -> VCDeviceType {
        switch deviceType {
        case .macOS:
            return .macos
        case .iOS:
            return .ios
        case .linux:
            return .linux
        case .android:
            return .android
        case .windows:
            return .windows
        }
    }
}