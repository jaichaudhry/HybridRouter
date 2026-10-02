import FoundationModels

/// Apple's Private Cloud Compute model.
///
/// It needs the managed `com.apple.developer.private-cloud-compute` entitlement, which the
/// default build doesn't include, so the app tells the provider whether it's enabled.
public struct AppleCloudProvider: ModelProvider {
    public let route = Route.appleCloud
    public let modelID = "apple-private-cloud-compute"
    private let isEnabled: Bool
    private let cloudModel: PrivateCloudComputeLanguageModel

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.cloudModel = PrivateCloudComputeLanguageModel()
    }

    public var model: any LanguageModel { cloudModel }

    public var availability: ProviderAvailability {
        guard isEnabled else {
            return .unavailable(reason: "Apple Cloud isn't enabled in this build")
        }
        return Self.map(cloudModel.availability, isLimitReached: cloudModel.quotaUsage.isLimitReached)
    }

    public func contextSize() async -> Int? {
        guard isEnabled else { return nil }
        return try? await cloudModel.contextSize
    }

    /// Quota is checked separately: the model can be available after the daily limit is reached.
    static func map(
        _ availability: PrivateCloudComputeLanguageModel.Availability,
        isLimitReached: Bool
    ) -> ProviderAvailability {
        switch availability {
        case .available:
            return isLimitReached
                ? .unavailable(reason: "Daily Apple Cloud limit reached")
                : .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device doesn't support Apple Cloud")
        case .unavailable(.systemNotReady):
            return .unavailable(reason: "Apple Cloud isn't ready yet")
        case .unavailable:
            return .unavailable(reason: "Apple Cloud is unavailable")
        }
    }
}
