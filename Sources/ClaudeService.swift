import Foundation
import WebKit
import AppKit

// Weak proxy to break WKWebView → ClaudeService retain cycle
private class LeakAvoider: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
class ClaudeService: NSObject, ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading: Bool = false
    @Published var needsLogin: Bool = false

    private var webView: WKWebView!
    private var loginController: LoginWindowController?
    private var refreshTimer: Timer?

    // Pretend to be Safari so sites don't block us
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"

    override init() {
        super.init()
        setupWebView()
        refresh()
        startAutoRefresh()
    }

    // MARK: - WebView Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let contentController = WKUserContentController()
        let fetchInterceptorScript = WKUserScript(
            source: fetchInterceptorJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(fetchInterceptorScript)

        let proxy = LeakAvoider(self)
        contentController.add(proxy, name: "usageData")
        contentController.add(proxy, name: "noData")
        contentController.add(proxy, name: "apiResponse")

        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = Self.safariUserAgent
    }

    // MARK: - Public API

    func refresh() {
        isLoading = true
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    func showLoginWindow() {
        if loginController != nil { return }

        loginController = LoginWindowController(dataStore: WKWebsiteDataStore.default())
        loginController?.onSuccess = { [weak self] in
            Task { @MainActor in
                self?.loginController = nil
                self?.refresh()
            }
        }
        loginController?.show()
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    // MARK: - JavaScript

    private var fetchInterceptorJS: String {
        """
        (function() {
            if (window._claudeFetchPatched) return;
            window._claudeFetchPatched = true;

            var originalFetch = window.fetch;
            window.fetch = function() {
                var args = Array.prototype.slice.call(arguments);
                var url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url ? args[0].url : '');
                var reqBody = (args[1] && args[1].body) ? String(args[1].body).substring(0, 500) : null;
                var promise = originalFetch.apply(this, args);
                promise.then(function(response) {
                    var ct = response.headers.get('content-type') || '';
                    var status = response.status;
                    if (ct.includes('json')) {
                        response.clone().text().then(function(text) {
                            try {
                                var json = JSON.parse(text);
                                var payload = { url: url + ' [' + status + ']', data: json };
                                if (reqBody) payload.reqBody = reqBody;
                                window.webkit.messageHandlers.apiResponse.postMessage(payload);
                            } catch(e) {}
                        }).catch(function(){});
                    }
                }).catch(function(){});
                return promise;
            };
        })();
        """
    }

    private var extractionJS: String {
        """
        (function() {
            // Prevent multiple pollers running simultaneously across didFinish calls
            if (window._claudeExtracting) return;
            window._claudeExtracting = true;

            var attempts = 0;
            var maxAttempts = 20; // 10 seconds at 500ms intervals

            function tryExtract() {
                // Use textContent (captures all text regardless of CSS visibility)
                var bodyText = (document.body ? document.body.textContent : '') || '';
                if (attempts === 0) {
                    // Search __next_f (Next.js RSC chunks) for "percent"
                    var nextF = window.__next_f || [];
                    var nextRaw = '';
                    for (var ni = 0; ni < nextF.length; ni++) {
                        var item = nextF[ni];
                        if (Array.isArray(item) && item.length > 1) nextRaw += String(item[1]);
                    }
                    var pctIdx = nextRaw.toLowerCase().indexOf('percent');
                    var pctSnippet = pctIdx >= 0
                        ? nextRaw.substring(Math.max(0, pctIdx - 80), pctIdx + 200)
                        : 'NOT_FOUND';

                    try { window.webkit.messageHandlers.apiResponse.postMessage({
                        url: window.location.href,
                        data: { _debug: 'attempt0',
                                bodyLen: bodyText.length,
                                title: document.title,
                                nextFLen: nextF.length,
                                pctSnippet: pctSnippet }
                    }); } catch(e) {}
                }

                // Poll for progress bar elements first (most accurate)
                var progressEls = document.querySelectorAll('[role="progressbar"], progress, [aria-valuenow]');
                var progressValues = [];
                progressEls.forEach(function(el) {
                    var val = el.getAttribute('aria-valuenow') || el.getAttribute('value');
                    if (val != null && val !== '') progressValues.push(parseFloat(val));
                });

                // Also check for "% used" text (textContent, not innerText)
                var percentRegex = /(\\d+(?:\\.\\d+)?)%\\s*used/gi;
                var percentMatches = [];
                var m;
                while ((m = percentRegex.exec(bodyText)) !== null) {
                    percentMatches.push(parseFloat(m[1]));
                }

                if (progressValues.length === 0 && percentMatches.length === 0) {
                    attempts++;
                    if (attempts < maxAttempts) {
                        setTimeout(tryExtract, 500);
                    } else {
                        // Timed out waiting for data — page loaded but no usage data found
                        window.webkit.messageHandlers.noData.postMessage({});
                    }
                    return;
                }

                // Found data — extract reset times.
                // Non-greedy (.+?) stops at the first "XX% used" text that follows.
                var resetRegex = /Resets?\\s+(?:in\\s+)?(.+?)(?=\\s*\\d+%)/g;
                var resetMatches = [];
                while ((m = resetRegex.exec(bodyText)) !== null) {
                    resetMatches.push(m[1].trim());
                }

                var dollarRegex = /\\$(-?[\\d,]+\\.?\\d*)/g;
                var dollarAmounts = [];
                while ((m = dollarRegex.exec(bodyText)) !== null) {
                    dollarAmounts.push(parseFloat(m[1].replace(',', '')));
                }

                var lastUpdated = null;
                var lm = bodyText.match(/less than a minute ago/i) ||
                         bodyText.match(/(\\d+\\s+(?:minute|hour|second)s?\\s+ago)/i) ||
                         bodyText.match(/Updated\\s+([^\\n]+)/i);
                if (lm) lastUpdated = lm[0];

                window.webkit.messageHandlers.usageData.postMessage({
                    progressValues: progressValues,
                    percentMatches: percentMatches,
                    resetMatches: resetMatches,
                    dollarAmounts: dollarAmounts,
                    lastUpdated: lastUpdated,
                    url: window.location.href
                });
            }

            tryExtract();
        })();
        """
    }
}

// MARK: - WKNavigationDelegate

extension ClaudeService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let urlString = webView.url?.absoluteString else { return }
            print("📄 Main didFinish: \(urlString)")

            if urlString.contains("/login") || urlString.contains("/auth") {
                print("🔒 Login page detected → needsLogin = true")
                self.needsLogin = true
                self.isLoading = false
                return
            }

            print("▶️ Running extraction JS on: \(urlString)")
            webView.evaluateJavaScript(self.extractionJS) { _, error in
                if let error = error { print("❌ JS error: \(error)") }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false }
    }

    nonisolated func webView(_ webView: WKWebView,
                              didFailProvisionalNavigation navigation: WKNavigation!,
                              withError error: Error) {
        Task { @MainActor in self.isLoading = false }
    }
}

// MARK: - WKScriptMessageHandler

extension ClaudeService: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        Task { @MainActor in
            switch message.name {
            case "noData":
                print("⚠️ noData: no usage data found after polling — assuming login required")
                self.needsLogin = true
                self.isLoading = false

            case "usageData":
                print("✅ usageData received")
                guard let body = message.body as? [String: Any] else { return }
                self.parseUsageData(body)

            case "apiResponse":
                if let body = message.body as? [String: Any] {
                    let url = body["url"] as? String ?? "?"
                    if let data = body["data"] as? [String: Any], data["_debug"] != nil {
                        print("🔍 JS debug @ \(url)")
                        print("   title:\(data["title"] ?? "") bodyLen:\(data["bodyLen"] ?? 0) nextFLen:\(data["nextFLen"] ?? 0)")
                        print("   pctSnippet: \(data["pctSnippet"] ?? "none")")
                    } else if let data = body["data"] as? [String: Any] {
                        print("🌐 API: \(url)")
                        if let reqBody = body["reqBody"] as? String {
                            print("   req: \(reqBody.prefix(200))")
                            // Fast login detection via analytics events
                            if (reqBody.contains("login.page_viewed") ||
                                reqBody.contains("\"name\":\"/login\"")) && !self.needsLogin {
                                print("🔒 Login page analytics event → needsLogin")
                                self.needsLogin = true
                                self.isLoading = false
                            }
                        }
                        self.tryParseAPIUsage(url: url, json: data)
                    }
                }

            default: break
            }
        }
    }

    /// Attempt to parse usage info directly from an intercepted API JSON response.
    private func tryParseAPIUsage(url: String, json: [String: Any]) {
        // 403 on any claude.ai endpoint = not authenticated
        if url.contains("claude.ai") && url.contains("[403]") && !self.needsLogin {
            print("🔒 403 on claude.ai → needsLogin")
            self.needsLogin = true
            self.isLoading = false
            return
        }

        let keys = json.keys.sorted().joined(separator: ", ")
        print("   keys: \(keys)")

        // ── /api/organizations/{uuid}/usage ──────────────────────────────────
        // Keys: five_hour (session), seven_day (weekly), extra_usage, etc.
        if url.contains("/usage [") && (json["five_hour"] != nil || json["seven_day"] != nil) {
            print("   📊 Usage endpoint — logging sub-objects:")
            for key in ["five_hour", "seven_day", "extra_usage"] {
                if let sub = json[key] { print("      \(key): \(sub)") }
            }

            var data = self.usageData ?? UsageData()
            var found = false

            func pct(_ obj: [String: Any]?) -> Double? {
                guard let o = obj else { return nil }
                for k in ["percent_usage", "pct", "percent", "usage_pct", "percentUsage"] {
                    if let v = o[k] as? Double { return v }
                    if let v = o[k] as? Int    { return Double(v) }
                }
                return nil
            }
            func resetText(_ obj: [String: Any]?) -> String? {
                guard let o = obj else { return nil }
                for k in ["reset_at", "resetAt", "resets_at", "next_reset"] {
                    if let s = o[k] as? String { return s }
                }
                return nil
            }

            if let p = pct(json["five_hour"] as? [String: Any]) {
                data.sessionPercent = p; found = true
                data.sessionResetText = resetText(json["five_hour"] as? [String: Any])
            }
            if let p = pct(json["seven_day"] as? [String: Any]) {
                data.weeklyPercent = p; found = true
                data.weeklyResetText = resetText(json["seven_day"] as? [String: Any])
            }
            if let ex = json["extra_usage"] as? [String: Any] {
                if let p = pct(ex) { data.extraPercent = p; found = true }
            }

            if found {
                print("   ✅ Parsed usage from /usage API")
                self.usageData = data
                self.needsLogin = false
                self.isLoading = false
            }
            return
        }

        // ── /api/organizations/{uuid}/overage_spend_limit ────────────────────
        if url.contains("/overage_spend_limit") {
            var data = self.usageData ?? UsageData()
            var found = false
            if let limit = json["monthly_credit_limit"] as? Double { data.monthlyLimit = limit / 100; found = true }
            if let limit = json["monthly_credit_limit"] as? Int    { data.monthlyLimit = Double(limit) / 100; found = true }
            if let used  = json["used_credits"] as? Double { data.extraAmountSpent = used / 100; found = true }
            if let used  = json["used_credits"] as? Int    { data.extraAmountSpent = Double(used) / 100; found = true }
            if found {
                print("   ✅ Parsed spend limit")
                self.usageData = data
            }
            return
        }

        // ── Legacy patterns ───────────────────────────────────────────────────
        var data = UsageData()
        var found = false
        if let limits = json["message_usage_limits"] as? [String: Any] {
            if let p = limits["percent_message_usage"] as? Double { data.weeklyPercent = p; found = true }
            if let p = limits["percent_message_usage"] as? Int    { data.weeklyPercent = Double(p); found = true }
        }
        if found {
            self.usageData = data; self.needsLogin = false; self.isLoading = false
        }
    }

    private func parseUsageData(_ body: [String: Any]) {
        var data = UsageData()

        let progressValues = body["progressValues"] as? [Double] ?? []
        let percentMatches = body["percentMatches"] as? [Double] ?? []
        let resetMatches   = body["resetMatches"]   as? [String] ?? []
        let dollarAmounts  = body["dollarAmounts"]  as? [Double] ?? []
        let lastUpdated    = body["lastUpdated"]    as? String

        let percents = progressValues.isEmpty ? percentMatches : progressValues

        if percents.count >= 1 { data.sessionPercent = percents[0] }
        if percents.count >= 2 { data.weeklyPercent  = percents[1] }
        if percents.count >= 3 { data.extraPercent   = percents[2] }

        if resetMatches.count >= 1 { data.sessionResetText = resetMatches[0] }
        if resetMatches.count >= 2 { data.weeklyResetText  = resetMatches[1] }
        if resetMatches.count >= 3 { data.extraResetText   = resetMatches[2] }

        if dollarAmounts.count >= 1 { data.extraAmountSpent = dollarAmounts[0] }
        if dollarAmounts.count >= 2 { data.monthlyLimit     = dollarAmounts[1] }
        if dollarAmounts.count >= 3 { data.currentBalance   = dollarAmounts[2] }

        data.lastUpdatedText = lastUpdated

        self.usageData  = data
        self.needsLogin = false
        self.isLoading  = false
    }
}

// MARK: - Login Window Controller

/// Manages the login NSWindow + WKWebView, including OAuth popup handling.
///
/// Success detection uses auth polling rather than URL-based detection because
/// Google's OAuth uses a `storagerelay://` redirect URI that WKWebView cannot
/// load, so the popup never navigates back to claude.ai. Instead we poll
/// `/api/referral` from the main login webview every 2 s; when it returns
/// something other than 403 the session cookie is confirmed to be set.
@MainActor
final class LoginWindowController: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onSuccess: (() -> Void)?

    private var mainWebView: WKWebView?
    private var window: NSWindow?
    private var popupWebViews: [WKWebView] = []
    private var popupWindows:  [NSWindow]  = []
    private var hasCompleted = false
    private var authPollTimer: Timer?

    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"

    init(dataStore: WKWebsiteDataStore) {
        super.init()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 700),
                           configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = Self.safariUA
        mainWebView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in to Claude"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        window = win
    }

    func show() {
        guard let wv = mainWebView, let win = window else { return }
        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        authPollTimer?.invalidate()
        authPollTimer = nil

        popupWindows.forEach { $0.orderOut(nil) }
        popupWindows.removeAll()
        let dyingPopups = popupWebViews
        popupWebViews.removeAll()
        DispatchQueue.main.async { _ = dyingPopups }

        window?.orderOut(nil)
        window = nil
        let dyingMain = mainWebView
        mainWebView = nil
        DispatchQueue.main.async { _ = dyingMain }
    }

    // MARK: Auth polling

    /// Start polling /api/referral from the main login webview.
    /// Called as soon as the login page loads — polls every 2 s.
    private func startAuthPolling() {
        guard authPollTimer == nil else { return }
        print("🔄 LoginWindow: starting auth polling")
        authPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAuthStatus() }
        }
    }

    private func pollAuthStatus() {
        guard !hasCompleted, let webView = mainWebView else { return }
        // Use the main login webview's cookie store to fetch.
        // Any status other than 0 (network error) or 403 means we're authenticated.
        webView.callAsyncJavaScript(
            "return fetch('/api/referral', {credentials:'include'}).then(r=>r.status).catch(()=>0)",
            arguments: [:],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, !self.hasCompleted else { return }
            if case .success(let value) = result, let status = value as? Int {
                print("🔐 Auth poll → \(status)")
                if status > 0 && status != 403 {
                    self.triggerSuccess()
                }
            }
        }
    }

    private func triggerSuccess() {
        guard !hasCompleted else { return }
        hasCompleted = true
        print("✅ LoginWindow: auth confirmed, closing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.dismiss()
            self?.onSuccess?()
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasCompleted else { return }
        guard let urlObj = webView.url else { return }
        print("🔐 LoginWindow didFinish (\(webView === mainWebView ? "main" : "popup")): \(urlObj.absoluteString)")

        // Only act on the main login webview
        guard webView === mainWebView else { return }

        let host = urlObj.host ?? ""
        let isClaudeHost = host == "claude.ai" || host.hasSuffix(".claude.ai")
        guard isClaudeHost else { return }

        // Start polling once we're on any claude.ai page (beginning at /login)
        startAuthPolling()

        // If the main webview navigated away from /login or /auth, do an immediate check
        let isAuthPath = urlObj.path.hasPrefix("/login") || urlObj.path.hasPrefix("/auth")
        if !isAuthPath {
            print("🔐 Main webview reached \(urlObj.path) — checking auth immediately")
            pollAuthStatus()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("🔐 LoginWindow didFail (\(webView === mainWebView ? "main" : "popup")): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        print("🔐 LoginWindow didFailProvisional (\(webView === mainWebView ? "main" : "popup")): \(error.localizedDescription)")
    }

    // MARK: WKUIDelegate — handle window.open() for Google OAuth popup

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Use WebKit's provided configuration as-is so the popup is in the same
        // WebKit process group and window.opener.postMessage() can reach the
        // main login webview.  Modifying configuration.websiteDataStore here
        // breaks that relationship.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                              configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.customUserAgent = Self.safariUA

        let popupWin = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWin.isReleasedWhenClosed = false
        popupWin.title = "Sign in"
        popupWin.contentView = popup
        popupWin.center()
        popupWin.makeKeyAndOrderFront(nil)

        popupWebViews.append(popup)
        popupWindows.append(popupWin)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let idx = popupWebViews.firstIndex(of: webView) else { return }
        popupWindows[idx].orderOut(nil)
        popupWindows.remove(at: idx)
        let dying = popupWebViews.remove(at: idx)
        DispatchQueue.main.async { _ = dying }
        // Popup closed (window.close() called by OAuth relay) — check auth immediately
        print("🔐 Popup closed by JS — polling auth now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollAuthStatus()
        }
    }
}
