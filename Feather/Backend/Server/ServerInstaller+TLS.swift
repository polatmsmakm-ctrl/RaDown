//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	func setupApp(port: Int) throws -> Application {
		let app = Application(Self.env)
		app.threadPool = .init(numberOfThreads: 1)
		
		if getServerMethod() != 1 {
			if let tls = try tls() {
				app.http.server.configuration.tlsConfiguration = tls
			}
		}
		
		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		
		return app
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		} else {
			return readCommonName() ?? localhost
		}
	}
	
	func tls() throws -> TLSConfiguration? {
		guard
			let crt = Self.getUrl("server", ext: "crt"),
			let pem = Self.getUrl("server", ext: "pem")
		else {
			return nil
		}
		
		return try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(crt.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: pem.path, format: .pem)
			)
		)
	}
	
	/// RaDown: when the certificate expires iOS refuses the connection without
	/// a word, so the install screen used to sit on "Ready" forever. The copy
	/// shipped inside the app expires, so its date has to be checked, not just
	/// its presence.
	private static let _expiryLock = NSLock()
	private static var _expiryComputed = false
	private static var _expiry: Date?

	static func sslCertificateExpiry() -> Date? {
		_expiryLock.lock()
		defer { _expiryLock.unlock() }

		if _expiryComputed {
			return _expiry
		}

		_expiry = _readSSLCertificateExpiry()
		_expiryComputed = true
		return _expiry
	}

	/// Call after writing new certificate files.
	static func invalidateSSLCertificateCache() {
		_expiryLock.lock()
		_expiryComputed = false
		_expiry = nil
		_expiryLock.unlock()
	}

	private static func _readSSLCertificateExpiry() -> Date? {
		guard
			let crt = getUrl("server", ext: "crt"),
			let chain = try? NIOSSLCertificate.fromPEMFile(crt.path),
			let leaf = chain.first
		else {
			return nil
		}

		return Date(timeIntervalSince1970: TimeInterval(leaf.notValidAfter))
	}

	/// Whether the Fully Local server has a certificate iOS will accept today.
	static var hasSSLCertificates: Bool {
		guard
			getUrl("server", ext: "pem") != nil,
			getUrl("commonName", ext: "txt") != nil,
			let expiry = sslCertificateExpiry()
		else {
			return false
		}

		return expiry > Date()
	}

	/// True while the certificate is missing, expired, or about to expire.
	static var shouldRefreshSSLCertificates: Bool {
		guard
			getUrl("server", ext: "pem") != nil,
			getUrl("commonName", ext: "txt") != nil,
			let expiry = sslCertificateExpiry()
		else {
			return true
		}

		return expiry.timeIntervalSinceNow < (3 * 24 * 60 * 60)
	}

	/// Fully Local once the certificates are there, Semi Local until then.
	static var defaultServerMethod: Int {
		hasSSLCertificates ? 0 : 1
	}

	func readCommonName() -> String? {
		guard let url = Self.getUrl("commonName", ext: "txt") else {
			return nil
		}
		
		return try? String(contentsOf: url, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default
		
		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		let bundlesURL = Bundle.main.url(forResource: name, withExtension: ext)
		
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}
		
		if let bundlesURL, fileManager.fileExists(atPath: bundlesURL.path) {
			return bundlesURL
		}
		
		return nil
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
						               &hostname, socklen_t(hostname.count),
						               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
