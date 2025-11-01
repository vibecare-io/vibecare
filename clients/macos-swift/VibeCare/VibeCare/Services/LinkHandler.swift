import Foundation
import AppKit
import Logging

@MainActor
class LinkHandler: ObservableObject {
    static let shared = LinkHandler()

    private let logger = Logger(label: "com.vibecare.link-handler")

    private init() {
        logger.info("LinkHandler initialized")
    }

    /// Execute an open_link action
    func executeAction(_ action: Action) {
        guard action.type == .openLink else {
            logger.error("Invalid action type for LinkHandler: \(action.type)")
            return
        }

        guard let urlString = action.parameters["url"], !urlString.isEmpty else {
            logger.error("Missing or empty URL parameter in action: \(action.id)")
            return
        }

        openURL(urlString)
    }

    /// Open a URL in the default browser
    func openURL(_ urlString: String) {
        // Clean and validate URL
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL) else {
            logger.error("Invalid URL format: \(trimmedURL)")
            return
        }

        // Ensure URL has a scheme
        let finalURL: URL
        if url.scheme == nil {
            // Add https:// if no scheme provided
            guard let urlWithScheme = URL(string: "https://\(trimmedURL)") else {
                logger.error("Could not add scheme to URL: \(trimmedURL)")
                return
            }
            finalURL = urlWithScheme
            logger.info("Added https:// scheme to URL: \(trimmedURL)")
        } else {
            finalURL = url
        }

        logger.info("Opening URL: \(finalURL.absoluteString)")

        // Open URL in default browser
        NSWorkspace.shared.open(finalURL)
    }

    /// Open multiple URLs (for future use with multiple link actions)
    func openURLs(_ urlStrings: [String]) {
        for urlString in urlStrings {
            openURL(urlString)
        }
    }

    /// Validate if a URL string is well-formed
    func isValidURL(_ urlString: String) -> Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to create URL
        guard let url = URL(string: trimmedURL) else {
            return false
        }

        // Check if it has a scheme, or can have one added
        if url.scheme == nil {
            // Try with https://
            return URL(string: "https://\(trimmedURL)") != nil
        }

        return true
    }
}
