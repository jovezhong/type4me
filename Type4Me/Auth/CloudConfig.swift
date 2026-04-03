// Type4Me/Auth/CloudConfig.swift

import Foundation

enum CloudRegion: String, Codable {
    case cn = "cn"
    case overseas = "overseas"
}

enum CloudConfig {
    // API endpoints
    static let cnAPIEndpoint = "https://cn.api.type4me.com"
    static let usAPIEndpoint = "https://us.api.type4me.com"

    // Pricing display
    static let weeklyPriceCN = "¥7"
    static let weeklyPriceUS = "$1.50"

    // Current region (persisted)
    static var currentRegion: CloudRegion {
        get {
            CloudRegion(rawValue: UserDefaults.standard.string(forKey: "tf_cloud_region") ?? "") ?? .overseas
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "tf_cloud_region")
        }
    }

    static var apiEndpoint: String {
        currentRegion == .cn ? cnAPIEndpoint : usAPIEndpoint
    }
}
