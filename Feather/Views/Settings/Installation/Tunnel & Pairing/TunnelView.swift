//
//  SettingsTunnelView.swift
//  Feather (idevice)
//
//  Created by samara on 29.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift

// MARK: - View
struct TunnelView: View {
	@State private var _isImportingPairingPresenting = false
	
	@State var doesHavePairingFile = false
	@State private var isLocalDevVpnAvailable = false
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				if #available(iOS 17.4, *) {
				} else {
					_tunnelInfo()
					TunnelHeaderView()
				}
			} footer: {
				if doesHavePairingFile {
					Text(.localized("Seems like you've gotten your hands on your pairing file!"))
				} else {
					Text(.localized("No pairing file found, please import it."))
				}
			}
			
			Section {
				Button(.localized("Import Pairing File"), systemImage: "square.and.arrow.down") {
					_isImportingPairingPresenting = true
				}
				if #available(iOS 17.4, *) {
				} else {
					Button(.localized("Restart Heartbeat"), systemImage: "arrow.counterclockwise") {
						HeartbeatManager.shared.start(true)
						
						DispatchQueue.global(qos: .userInitiated).async {
							if !HeartbeatManager.shared.checkSocketConnection().isConnected {
								DispatchQueue.main.async {
									UIAlertController.showAlertWithOk(
										title: "Socket",
										message: "Unable to connect to TCP. Make sure you have loopback VPN enabled and you are on WiFi or Airplane mode."
									)
								}
							}
						}
					}
				}
			}
			
			NBSection(.localized("Help")) {
				// RaDown: the steps in full, rather than a link to a page
				// elsewhere, since this is the one thing that needs a computer.
				VStack(alignment: .leading, spacing: 8) {
					Text(.localized("How to get a pairing file"))
						.font(.headline)

					Text(.localized("1. On your computer, install iTunes (Windows) so it can see the iPhone.\n2. Download JitterbugPair and run it with the iPhone plugged in and unlocked, tapping Trust if asked.\n3. It makes a file ending in .mobiledevicepairing.\n4. Send that file to the iPhone and import it above.\n\nOnce it is imported, installing needs no server, no certificate and no internet."))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				.padding(.vertical, 4)

				if isLocalDevVpnAvailable {
					Button(.localized("Connect to LocalDevVPN"), systemImage: "link") {
						UIApplication.open("localdevvpn://enable?scheme=feather")
					}
				} else {
					Button(.localized("Download LocalDevVPN"), systemImage: "arrow.down.app") {
						UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
					}
				}
			}
		}
		.sheet(isPresented: $_isImportingPairingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes:  [.xmlPropertyList, .plist, .mobiledevicepairing],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					FR.movePairing(selectedFileURL)
					doesHavePairingFile = true
				}
			)
			.ignoresSafeArea()
		}
		.onAppear {
			doesHavePairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
				? true
				: false
			if let url = URL(string: "localdevvpn://") {
				isLocalDevVpnAvailable = UIApplication.shared.canOpenURL(url)
			} else {
				isLocalDevVpnAvailable = false
			}
		}
	}
	
	@ViewBuilder
	private func _tunnelInfo() -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Heartbeat"))
					.font(.headline)
				Text(.localized("The heartbeat is activated in the background, it will restart when the app is re-opened or prompted. If the status below is pulsing, that means its healthy."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		}
	}
}
