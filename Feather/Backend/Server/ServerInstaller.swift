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
			startupError = String.localized("The local server could not start. Open Settings → Installation → Server & SSL, tap Update SSL Certificates, then try again.")
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
		// any outside service. It only works once the SSL files are there, so
		// until then this falls back to Semi Local (1).
		if let chosen = UserDefaults.standard.object(forKey: "Feather.serverMethod") as? Int {
			return chosen
		}
		return Self.defaultServerMethod
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
}
