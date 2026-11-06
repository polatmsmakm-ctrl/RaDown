//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	/// RaDown: set when the local server could not be started, so the install
	/// screen can say so instead of waiting for a link that never arrives.
	var startupError: String?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) throws {
		self.app = app
		self.viewModel = viewModel
		try _setup()
		try _configureRoutes()
		try _server?.server.start()
		_needsShutdown = true
	}
	
	deinit {
		_shutdownServer()
	}
	
	private func _setup() throws {
		self._server = try? setupApp(port: port)

		if _server == nil {
			startupError = String.localized("The local server could not start. Open Settings → Installation → Server & SSL and regenerate the local certificate.")
		}
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		// RaDown: Fully Local (0) serves the manifest and the app itself over
		// HTTPS from the device, which is what iOS needs and does not depend on
		// any outside service. It only works with a certificate iOS accepts, so
		// a missing or expired one falls back to Semi Local (1) even when Fully
		// Local was picked by hand — otherwise iOS is handed a link it refuses
		// without reporting anything.
		guard Self.hasSSLCertificates, Self.localCertificateTrustIsEstablished() else {
			return 1
		}

		if let chosen = UserDefaults.standard.object(forKey: "Feather.serverMethod") as? Int {
			return chosen
		}
		return Self.defaultServerMethod
	}
	
	func getIPFix() -> Bool {
		// RaDown: serve from the loopback address by default. The Wi-Fi address
		// is reachable in principle but depends on the network behaving, and on
		// iOS it runs into local-network restrictions; the loopback address is
		// the device talking to itself and always works. GBox, which installs
		// the same way, uses localhost for exactly this reason.
		if let chosen = UserDefaults.standard.object(forKey: "Feather.ipFix") as? Bool {
			return chosen
		}
		return true
	}

	/// The service that turns the local package URL into the manifest iOS asks
	/// for. It has to be reachable over HTTPS, which is why it cannot be this
	/// device. Configurable so a service going down is not a dead end.
	static var manifestServiceUrl: String {
		let stored = UserDefaults.standard.string(forKey: "RaDown.manifestService")

		guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else {
			return defaultManifestServiceUrl
		}

		return stored
	}

	static let defaultManifestServiceUrl = "https://api.palera.in/genPlist"
}
