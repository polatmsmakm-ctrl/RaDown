//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = ServerInstaller.defaultServerMethod
	private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]

	@State private var _isTrusted: Bool = ServerInstaller.localCertificateTrustIsEstablished()

	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			} footer: {
				Text(.localized("Fully Local installs straight from this device and needs its certificate trusted below. Semi Local needs no certificate."))
			}

			Section {
				Label(
					_isTrusted
						? .localized("Certificate trusted")
						: .localized("Certificate not trusted yet"),
					systemImage: _isTrusted ? "checkmark.seal" : "exclamationmark.triangle"
				)
				.foregroundStyle(_isTrusted ? Color.green : Color.orange)

				Button(.localized("Trust Local Certificate"), systemImage: "lock.shield") {
					_share()
				}

				Button(.localized("Regenerate Local Certificate"), systemImage: "arrow.clockwise") {
					_regenerate()
				}
			} header: {
				Text(.localized("Local Certificate"))
			} footer: {
				Text(.localized("Tap Trust Local Certificate, save the file, then open it from the Files app. Install it in Settings → General → VPN & Device Management, then switch it on in Settings → General → About → Certificate Trust Settings."))
			}
		}
		.onAppear {
			ServerInstaller.invalidateLocalCertificateTrust()
			_isTrusted = ServerInstaller.localCertificateTrustIsEstablished()
		}
	}

	private func _share() {
		if !FR.hasLocalCertificateAuthority {
			FR.generateLocalSSLCertificates()
		}

		UIActivityViewController.show(activityItems: [FR.localCertificateAuthorityUrl])
	}

	private func _regenerate() {
		let success = FR.generateLocalSSLCertificates()

		ServerInstaller.invalidateLocalCertificateTrust()
		_isTrusted = ServerInstaller.localCertificateTrustIsEstablished()

		UIAlertController.showAlertWithOk(
			title: .localized("Local Certificate"),
			message: success
				? .localized("A new certificate was made. Trust it again using the button above.")
				: .localized("The certificate could not be made.")
		)
	}
}
