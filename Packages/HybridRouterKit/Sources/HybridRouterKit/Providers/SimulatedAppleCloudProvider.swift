import FoundationModels

/// Serves the Apple Cloud route with the on-device model, for developing without Apple's
/// Private Cloud Compute entitlement. Every step it produces is marked simulated, so its
/// speed and quality are never mistaken for Apple Cloud's. Private turns stay on the device.
public struct SimulatedAppleCloudProvider: ModelProvider {
    public let route = Route.appleCloud
    public let modelID = "apple-cloud-simulated"
    public let isSimulated = true
    private let onDevice: OnDeviceProvider

    public init(model: SystemLanguageModel = .default) {
        self.onDevice = OnDeviceProvider(model: model)
    }

    public var model: any LanguageModel { onDevice.model }

    public var availability: ProviderAvailability { onDevice.availability }

    /// The on-device window, not Apple Cloud's 32K: routing should see the real limit.
    public func contextSize() async -> Int? {
        await onDevice.contextSize()
    }
}
