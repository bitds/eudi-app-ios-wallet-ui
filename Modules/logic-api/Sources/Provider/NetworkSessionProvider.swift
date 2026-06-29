/*
 * Copyright (c) 2026 European Commission
 *
 * Licensed under the EUPL, Version 1.2 or - as soon they will be approved by the European
 * Commission - subsequent versions of the EUPL (the "Licence"); You may not use this work
 * except in compliance with the Licence.
 *
 * You may obtain a copy of the Licence at:
 * https://joinup.ec.europa.eu/software/page/eupl
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF
 * ANY KIND, either express or implied. See the Licence for the specific language
 * governing permissions and limitations under the Licence.
 */
import Foundation

public protocol NetworkSessionProvider: Sendable {
  var urlSession: URLSession { get }
}

final class NetworkSessionProviderImpl: NetworkSessionProvider {

  let urlSession: URLSession

  init() {
    let configuration = URLSessionConfiguration.default
    configuration.protocolClasses = [NetworkLoggingURLProtocol.self] + (configuration.protocolClasses ?? [])
    self.urlSession = URLSession(configuration: configuration)
  }
}

private final class NetworkLoggingURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {

  private static let requestHandledKey = "NetworkLoggingURLProtocol.requestHandled"
  private var dataTask: URLSessionDataTask?
  private var responseData = Data()

  override class func canInit(with request: URLRequest) -> Bool {
    URLProtocol.property(forKey: requestHandledKey, in: request) == nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    URLProtocol.setProperty(true, forKey: Self.requestHandledKey, in: mutableRequest)
    logRequest(mutableRequest as URLRequest)

    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    dataTask = session.dataTask(with: mutableRequest as URLRequest)
    dataTask?.resume()
  }

  override func stopLoading() {
    dataTask?.cancel()
    dataTask = nil
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    responseData.removeAll()
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    responseData.append(data)
    client?.urlProtocol(self, didLoad: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      print("[HTTP] Error: \(error)")
      client?.urlProtocol(self, didFailWithError: error)
    } else {
      logResponse(task.response, data: responseData)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  private func logRequest(_ request: URLRequest) {
    print("[HTTP] Request: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
    logHeaders(request.allHTTPHeaderFields)

    if let body = request.httpBody, body.isEmpty == false {
      print("[HTTP] Request body: \(body.readableBody)")
    }
  }

  private func logResponse(_ response: URLResponse?, data: Data) {
    if let httpResponse = response as? HTTPURLResponse {
      print("[HTTP] Response: \(httpResponse.statusCode) \(httpResponse.url?.absoluteString ?? "")")
    }

    if data.isEmpty == false {
      print("[HTTP] Response body: \(data.readableBody)")
    }
  }

  private func logHeaders(_ headers: [String: String]?) {
    guard let headers, headers.isEmpty == false else { return }

    let redactedHeaders = headers.mapValues { value in
      value.isSensitiveHeaderValue ? "<redacted>" : value
    }
    print("[HTTP] Headers: \(redactedHeaders)")
  }
}

private extension Data {
  var readableBody: String {
    if let jsonObject = try? JSONSerialization.jsonObject(with: self),
       let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: jsonData, encoding: .utf8) {
      return json
    }

    return String(data: self, encoding: .utf8) ?? "<\(count) bytes>"
  }
}

private extension String {
  var isSensitiveHeaderValue: Bool {
    hasPrefix("Bearer ") || hasPrefix("DPoP ") || lowercased().contains("session")
  }
}
