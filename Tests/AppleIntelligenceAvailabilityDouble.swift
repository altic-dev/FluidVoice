enum AppleIntelligenceAvailability {
    static let providerID = "apple-intelligence"
    static let modelID = "System Language Model"
    static var unavailableReason: String?
    static var isAvailable: Bool {
        self.unavailableReason == nil
    }
}
