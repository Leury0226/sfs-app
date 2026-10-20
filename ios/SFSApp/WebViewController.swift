import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  static let scheme = "sfsapp"
  private static let bridgeName = "sfsNative"

  private var webView: WKWebView!

  override func loadView() {
    let contentController = WKUserContentController()
    contentController.add(WeakScriptMessageHandler(self), name: Self.bridgeName)

    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: Self.scheme)
    configuration.userContentController = contentController
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []

    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.bounces = false
    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
    if #available(iOS 16.4, *) {
      webView.isInspectable = true
    }
    view = webView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    if let url = URL(string: "\(Self.scheme)://localhost/index.html") {
      webView.load(URLRequest(url: url))
    }
  }

  // Mensajes de la interfaz: { keepAwake: Bool }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any] else { return }
    if let keepAwake = body["keepAwake"] as? Bool {
      UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
  }

  // Los links externos se abren en Safari; la app solo navega dentro de su propia interfaz
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }

    let internalSchemes: Set<String> = [Self.scheme, "about", "blob", "data"]
    let isInternal = internalSchemes.contains(url.scheme?.lowercased() ?? "")
    let isSubframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
    if isInternal || isSubframe {
      decisionHandler(.allow)
      return
    }

    UIApplication.shared.open(url)
    decisionHandler(.cancel)
  }

  // `window.open` y links con target="_blank"
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, url.scheme?.lowercased() != Self.scheme {
      UIApplication.shared.open(url)
    }
    return nil
  }

  // Si iOS mata el proceso de la interfaz (por memoria), se vuelve a cargar
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.reload()
  }

  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.grant)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
    present(alert, animated: true)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
    present(alert, animated: true)
  }
}

// Evita que el WebView retenga al controlador para siempre
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}
