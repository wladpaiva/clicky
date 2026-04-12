//
//  WorkerConfig.swift
//  leanring-buddy
//
//  Single source of truth for the Cloudflare Worker base URL and the
//  shared-secret Authorization header. Both values come from Info.plist
//  keys that are injected at build time from Secrets.xcconfig.
//
//  To set up locally: copy Secrets.xcconfig.template to Secrets.xcconfig
//  and fill in the real values.
//

import Foundation

enum WorkerConfig {
    /// Base URL for the Cloudflare Worker proxy, e.g.
    /// "https://clicky-proxy.farza-0cb.workers.dev".
    /// Injected at build time via WORKER_BASE_URL in Secrets.xcconfig.
    static let baseURL: String = {
        guard let url = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL"),
              !url.isEmpty else {
            fatalError(
                "[WorkerConfig] WorkerBaseURL está ausente no Info.plist. " +
                "Copie Secrets.xcconfig.template para Secrets.xcconfig e preencha com a URL do worker."
            )
        }
        return url
    }()

    /// Shared secret sent in the Authorization header on every worker request.
    /// The worker validates this token and returns 401 if it's missing or wrong.
    /// Injected at build time via WORKER_APP_SECRET in Secrets.xcconfig.
    static let appSecret: String = {
        guard let secret = AppBundleConfiguration.stringValue(forKey: "WorkerAppSecret"),
              !secret.isEmpty else {
            fatalError(
                "[WorkerConfig] WorkerAppSecret está ausente no Info.plist. " +
                "Copie Secrets.xcconfig.template para Secrets.xcconfig e preencha com o segredo."
            )
        }
        return secret
    }()

    /// Adds the Authorization: Bearer <secret> header to any URLRequest
    /// directed at the Cloudflare Worker proxy.
    static func authorizeRequest(_ request: inout URLRequest) {
        request.setValue("Bearer \(appSecret)", forHTTPHeaderField: "Authorization")
    }
}
