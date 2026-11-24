import SwiftUI
import Security

enum Keychain {
    private static func query(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "locus.license",
         kSecAttrAccount as String: k]
    }
    static func set(_ v: String, for k: String) {
        SecItemDelete(query(k) as CFDictionary)
        var q = query(k)
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        var q = query(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ k: String) { SecItemDelete(query(k) as CFDictionary) }
}

@MainActor
final class LicenseManager: ObservableObject {
    @Published var isAuthorized = false
    @Published var expiresAt: Date?
    @Published var message = ""
    @Published var busy = false

    private let base = "https://overstock-riptide-starfish.ngrok-free.dev"
    private let offlineGrace: TimeInterval = 24 * 3600

    var deviceID: String {
        if let id = Keychain.get("device_id") { return id }
        let id = UUID().uuidString
        Keychain.set(id, for: "device_id")
        return id
    }

    init() {
        loadCache()
        Task { await verify() }
    }

    private func loadCache() {
        guard Keychain.get("token") != nil,
              let exp = Double(Keychain.get("expires") ?? ""),
              let last = Double(Keychain.get("last_ok") ?? "") else { return }
        let now = Date().timeIntervalSince1970
        if exp > now && now - last < offlineGrace {
            expiresAt = Date(timeIntervalSince1970: exp)
            isAuthorized = true
        }
    }

    private func save(token: String?, expires: Double) {
        if let token { Keychain.set(token, for: "token") }
        Keychain.set(String(expires), for: "expires")
        Keychain.set(String(Date().timeIntervalSince1970), for: "last_ok")
        expiresAt = Date(timeIntervalSince1970: expires)
        isAuthorized = true
    }

    private func clear() {
        ["token", "expires", "last_ok"].forEach(Keychain.delete)
        isAuthorized = false
        expiresAt = nil
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    func activate(_ code: String) async {
        busy = true; defer { busy = false }
        do {
            let (_, j) = try await post("/activate", ["code": code, "device_id": deviceID])
            if j["ok"] as? Bool == true,
               let token = j["token"] as? String,
               let exp = j["expires_at"] as? Double {
                save(token: token, expires: exp)
                message = ""
            } else {
                message = j["msg"] as? String ?? "激活失败"
            }
        } catch { message = "网络错误，请检查网络后重试" }
    }

    func verify() async {
        guard let token = Keychain.get("token") else { return }
        do {
            let (status, j) = try await post("/verify", ["token": token, "device_id": deviceID])
            if j["ok"] as? Bool == true, let exp = j["expires_at"] as? Double {
                save(token: nil, expires: exp)
            } else if status == 401 {
                clear()
                message = j["msg"] as? String ?? "授权已失效"
            }
        } catch {
            // 断网：保持缓存状态，超过 24 小时会在下次启动时被拦截
        }
    }
}

struct ActivationView: View {
    @EnvironmentObject var license: LicenseManager
    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("激活").font(.largeTitle.bold())
            Text("请输入卡密").foregroundStyle(.secondary)
            TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            if !license.message.isEmpty {
                Text(license.message).foregroundStyle(.red).font(.footnote)
            }
            Button {
                Task { await license.activate(code.trimmingCharacters(in: .whitespaces)) }
            } label: {
                Group { license.busy ? AnyView(ProgressView()) : AnyView(Text("激活")) }
                    .frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || license.busy)
        }
        .padding(24)
    }
}
