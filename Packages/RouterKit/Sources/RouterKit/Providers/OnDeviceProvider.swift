import FoundationModels

/// Apple's on-device model. Free, private, and works offline.
public struct OnDeviceProvider: ModelProvider {
    public let route = Route.onDevice
    public let modelID = "apple-on-device"
    private let systemModel: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) {
        self.systemModel = model
    }

    public var model: any LanguageModel { systemModel }

    public var availability: ProviderAvailability {
        Self.map(systemModel.availability)
    }

    static func map(_ availability: SystemLanguageModel.Availability) -> ProviderAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence is turned off in Settings")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The on-device model is still downloading")
        case .unavailable:
            return .unavailable(reason: "The on-device model is unavailable")
        }
    }
}
