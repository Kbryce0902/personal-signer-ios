import AppleAuth
import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@main
enum Probe {
    static func main() async {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        do {
            let device = try Device(
                platform: .mac, macOSVersion: "26.6", macOSBuild: "25F84",
                transport: { request in
                    guard let endpoint = request.url, endpoint.scheme == "https", endpoint.host == "gsa.apple.com" else {
                        throw URLError(.unsupportedURL)
                    }
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    print("\(endpoint.lastPathComponent): HTTP \(http.statusCode)")
                    let headers = http.allHeaderFields.compactMap { name, value -> HTTPHeader? in
                        guard let name = name as? String else { return nil }
                        return HTTPHeader(name, String(describing: value))
                    }
                    return HTTPResponse(status: http.statusCode, body: data, headers: headers)
                },
                clientInfo: "<MacBookPro18,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            )
            let headers = try await device.headers()
            let needed = ["X-Apple-I-MD", "X-Apple-I-MD-M"]
            guard needed.allSatisfy({ field in headers.contains { $0.key.caseInsensitiveCompare(field) == .orderedSame && !$0.value.isEmpty } }) else {
                print("No usable local authentication metadata was returned")
                exit(1)
            }
            print("Alternate local registration returned both authentication fields.")
        } catch let error as AppleAuthError {
            print("Alternate provider failed with native error code \(error.code).")
            exit(1)
        } catch let error as URLError {
            print("Alternate provider failed with URL error \(error.errorCode).")
            exit(1)
        } catch {
            print("Alternate provider failed with system error \((error as NSError).code).")
            exit(1)
        }
    }
}
