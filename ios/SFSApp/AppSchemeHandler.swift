import Foundation
import WebKit

// Sirve la interfaz (carpeta `web` dentro de la app) en sfsapp://localhost/
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
  private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }

    var path = url.path
    if path.isEmpty || path == "/" {
      path = "/index.html"
    }

    let fileURL = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
    let isInsideRoot = fileURL.path.hasPrefix(root.standardizedFileURL.path)
    guard isInsideRoot, let data = try? Data(contentsOf: fileURL) else {
      respond(urlSchemeTask, url: url, status: 404, mimeType: "text/plain", data: Data())
      return
    }

    respond(urlSchemeTask, url: url, status: 200, mimeType: Self.mimeType(for: fileURL.pathExtension), data: data)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mimeType: String, data: Data) {
    let headers = [
      "Content-Type": mimeType,
      "Content-Length": String(data.count),
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-cache",
    ]
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
      task.didFailWithError(URLError(.cannotParseResponse))
      return
    }
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private static func mimeType(for fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json", "webmanifest", "map": return "application/json"
    case "wasm": return "application/wasm"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "ico": return "image/x-icon"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "mp3": return "audio/mpeg"
    case "ogg": return "audio/ogg"
    case "mp4": return "video/mp4"
    case "txt", "strings": return "text/plain; charset=utf-8"
    default: return "application/octet-stream"
    }
  }
}
