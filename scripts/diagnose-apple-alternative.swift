import AppleAuth
import Foundation

@main
enum Probe {
    static func field(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func verify(_ headers: [String: String]) {
        let required = [
            "X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO",
            "X-Mme-Device-Id", "X-Mme-Client-Info", "User-Agent", "X-Apple-I-Client-Time",
            "X-Apple-Locale", "X-Apple-I-TimeZone"
        ]
        let missing = required.filter { field($0, in: headers)?.isEmpty != false }
        guard missing.isEmpty else {
            print("Missing required headers: \(missing.joined(separator: ", "))")
            exit(1)
        }
    }

    static func main() async {
        do {
            let device = try Device(
                platform: .mac, macOSVersion: "26.6", macOSBuild: "25F84",
                clientInfo: "<MacBookPro18,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            )
            let headers = try await device.headers()
            verify(headers)
            let state = try await device.serializeState()
            let restored = try Device(
                initialState: state, platform: .mac,
                macOSVersion: "26.6", macOSBuild: "25F84",
                transport: { _ in throw URLError(.networkConnectionLost) },
                clientInfo: "<MacBookPro18,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            )
            let resumedHeaders = try await restored.headers()
            verify(resumedHeaders)
            guard field("X-Mme-Device-Id", in: headers) == field("X-Mme-Device-Id", in: resumedHeaders),
                  field("X-Apple-I-MD-M", in: headers) == field("X-Apple-I-MD-M", in: resumedHeaders) else {
                print("Restored state returned a different provider identity")
                exit(1)
            }
            print("Alternate local registration returned required metadata and restored the same identity without a provisioning request.")
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
