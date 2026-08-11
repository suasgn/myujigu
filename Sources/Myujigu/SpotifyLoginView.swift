import SwiftUI
import WebKit

struct SpotifyLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailed = false

    let saveCookie: (String) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign in with Spotify")
                        .font(.headline)
                    Text("This private login session is discarded when the window closes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(14)

            Divider()

            SpotifyLoginWebView { cookie in
                if saveCookie(cookie) {
                    dismiss()
                } else {
                    saveFailed = true
                }
            }

            if saveFailed {
                Divider()
                Text("Spotify signed in, but the login could not be saved to Keychain.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .frame(width: 520, height: 680)
    }
}

private struct SpotifyLoginWebView: NSViewRepresentable {
    let didCaptureCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(didCaptureCookie: didCaptureCookie)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(to: webView)

        var components = URLComponents(string: "https://accounts.spotify.com/login")!
        components.queryItems = [
            URLQueryItem(name: "continue", value: "https://open.spotify.com/"),
        ]
        webView.load(URLRequest(url: components.url!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
        WKHTTPCookieStoreObserver
    {
        private let didCaptureCookie: (String) -> Void
        private var didFinish = false

        init(didCaptureCookie: @escaping (String) -> Void) {
            self.didCaptureCookie = didCaptureCookie
        }

        func attach(to webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
            inspectCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        func detach(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            inspectCookies(in: cookieStore)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // OAuth providers commonly request a new browser window. Keep the
            // navigation in this isolated login view so its cookie store stays
            // observable and no session data leaks into the default browser.
            if navigationAction.targetFrame == nil,
               let requestURL = navigationAction.request.url
            {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }

        private func inspectCookies(in cookieStore: WKHTTPCookieStore) {
            guard !didFinish else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.didFinish else { return }
                guard let cookie = cookies.first(where: {
                    let domain = $0.domain.lowercased()
                    let isSpotifyDomain = domain == "spotify.com"
                        || domain.hasSuffix(".spotify.com")
                    return $0.name == "sp_dc"
                        && isSpotifyDomain
                        && !$0.value.isEmpty
                }) else {
                    return
                }

                self.didFinish = true
                DispatchQueue.main.async {
                    self.didCaptureCookie(cookie.value)
                }
            }
        }
    }
}
