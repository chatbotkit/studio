import AppKit
import Network
import WebKit

// Standalone, test-only app: exercise ATS in a real bundle, not XCTest's plist.
final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var listener: NWListener!
    var webView: WKWebView!
    var window: NSWindow!
    var index = 0
    let hosts = ["cbk-apps.localhost", "cbk-labs.localhost", "unlisted.localhost"]
    let baseline = CommandLine.arguments.contains("--baseline")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do { listener = try NWListener(using: parameters) }
        catch { fail("Listener: \(error)") }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let body = "<html><head><title>Studio transport fixture</title></head><body>OK</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: self.loadNext()
            case .failed(let error): self.fail("Listener: \(error)")
            default: break
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.fail("Timed out") }
    }

    func loadNext() {
        if index == hosts.count {
            print("STUDIO_TRANSPORT_PASS: \(baseline ? "baseline rejects HTTP" : "Apps/Labs load; unlisted host rejected")")
            fflush(stdout)
            exit(0)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = webView
        webView.load(URLRequest(url: URL(string: "http://\(hosts[index]):\(listener.port!.rawValue)/")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !baseline, index < 2 else {
            fail("Unexpected successful load for \(hosts[index])")
        }
        webView.evaluateJavaScript("document.title") { title, error in
            guard error == nil, title as? String == "Studio transport fixture" else {
                self.fail("Unexpected fixture title: \(String(describing: title)); \(String(describing: error))")
            }
            print("PASS: \(self.hosts[self.index]) loaded fixture")
            self.advance()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        guard (baseline || index == 2), error.domain == NSURLErrorDomain, error.code == -1022 else {
            fail("\(hosts[index]): \(error)")
        }
        print("PASS: \(hosts[index]) rejected by ATS (-1022)")
        advance()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("Navigation failed: \(error)")
    }

    func advance() {
        index += 1
        DispatchQueue.main.async { self.loadNext() }
    }

    func fail(_ message: String) -> Never {
        print("STUDIO_TRANSPORT_FAIL: \(message)")
        fflush(stdout)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let probe = Probe()
app.delegate = probe
app.run()
