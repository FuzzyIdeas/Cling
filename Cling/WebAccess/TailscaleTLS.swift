//
//  TailscaleTLS.swift
//  Cling
//
//  HTTPS for File server on a tailnet. A tailnet with HTTPS certificates turned on gives each Mac a Let's Encrypt
//  certificate for its MagicDNS name, which `tailscale cert` hands over (and renews when it runs close to expiry).
//  Served on the Tailscale addresses it makes the page a secure context, which a service worker, the share sheet and
//  installing the page as an app on Android or in Chrome all need. The LAN stays plain HTTP: no public certificate
//  can name a 192.168 address.
//

import Foundation
import Network
import Security

enum TailscaleTLS {
    struct Certificate: @unchecked Sendable {
        let domain: String
        let identity: sec_identity_t
        /// The leaf's bytes, to tell a renewed certificate from the one already served.
        let leaf: Data
    }

    /// The CLI is the app's own binary (what /usr/local/bin/tailscale runs), or Homebrew's for the open-source build.
    static func cli() -> String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's MagicDNS name, when the tailnet issues certificates for it.
    static func domain(cli: String) -> String? {
        guard let output = run(cli, ["status", "--json", "--peers=false"], timeout: 10),
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              var name = me["DNSName"] as? String
        else { return nil }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return (json["CertDomains"] as? [String] ?? []).contains(name) ? name : nil
    }

    /// The certificate and its key as an identity held in this process only, never added to a keychain (which would
    /// ask for access again after every update, since each build signs differently).
    @available(macOS 15, *)
    static func certificate(cli: String, domain: String) -> Certificate? {
        // A first certificate takes Let's Encrypt a minute at most; a cached one comes back at once.
        guard let output = run(cli, ["cert", "--cert-file", "-", "--key-file", "-", domain], timeout: 120),
              let pem = String(data: output, encoding: .utf8),
              // The chain comes first, then the key (EC, or PKCS#8 on other setups).
              let keyMarker = pem.range(of: "PRIVATE KEY-----"),
              let keyStart = pem.range(of: "-----BEGIN ", options: .backwards, range: pem.startIndex ..< keyMarker.lowerBound)?.lowerBound
        else {
            webLog.error("No certificate from Tailscale for \(domain, privacy: .public)")
            return nil
        }
        let chain = String(pem[..<keyStart])
        let key = String(pem[keyStart...])
        guard chain.contains("BEGIN CERTIFICATE"), let p12 = pkcs12(chain: chain, key: key) else { return nil }

        var items: CFArray?
        let options = [kSecImportExportPassphrase: p12.password, kSecImportToMemoryOnly: true] as CFDictionary
        guard SecPKCS12Import(p12.data as CFData, options, &items) == errSecSuccess,
              let item = (items as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String],
              let certificates = item[kSecImportItemCertChain as String] as? [SecCertificate],
              let leaf = certificates.first
        else {
            webLog.error("Couldn't load the Tailscale certificate for \(domain, privacy: .public)")
            return nil
        }
        let identity = identityValue as! SecIdentity
        // The leaf comes from the identity; the rest is the chain browsers need to reach a root they trust (an
        // iPhone fetches no missing intermediates).
        guard let secIdentity = sec_identity_create_with_certificates(identity, Array(certificates.dropFirst()) as CFArray) else { return nil }
        return Certificate(domain: domain, identity: secIdentity, leaf: SecCertificateCopyData(leaf) as Data)
    }

    /// openssl reads the key and the chain from separate files, so they sit for a moment in a folder only this user can
    /// read, and the archive's password goes through the environment rather than the arguments `ps` shows.
    private static func pkcs12(chain: String, key: String) -> (data: Data, password: String)? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cling-tls-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        let chainFile = folder.appendingPathComponent("chain.pem")
        let keyFile = folder.appendingPathComponent("key.pem")
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              fm.createFile(atPath: chainFile.path, contents: Data(chain.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        else { return nil }

        let password = WebAccessServer.randomToken()
        guard let data = run(
            "/usr/bin/openssl",
            ["pkcs12", "-export", "-in", chainFile.path, "-inkey", keyFile.path, "-passout", "env:CLING_P12"],
            environment: ["CLING_P12": password],
            timeout: 20
        ), !data.isEmpty else {
            webLog.error("openssl couldn't package the Tailscale certificate")
            return nil
        }
        return (data, password)
    }

    private static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            webLog.error("Couldn't run \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
