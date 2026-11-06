//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var _canInstall = false
	@State private var progressTask: Task<Void, Never>?
	@State private var _watchdogTask: Task<Void, Never>?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: try! ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus {
					_canInstall = true
					_openInstallLink()
				}

				if case .sendingManifest = newStatus {
					_watchdogTask?.cancel()
					_watchdogTask = nil
				}

				if case .sendingPayload = newStatus {
					_canInstall = false
					_watchdogTask?.cancel()
					_watchdogTask = nil

					if installer.getServerMethod() == 1 {
						_isWebviewPresenting = false
					}
				}

				if case .installing = newStatus {
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: app.identifier!,
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					_watchdogTask?.cancel()
					_watchdogTask = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_watchdogTask?.cancel()
			_watchdogTask = nil

			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			} else if _canInstall {
				// RaDown: the install link is opened on its own as soon as the
				// package is ready, but iOS quietly ignores that often enough
				// that there has to be something left to tap.
				Button {
					_openInstallLink()
				} label: {
					NBButton(.localized("Install"), systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
		.animation(.easeInOut(duration: 0.3), value: _canInstall)
	}

	/// Hands the package to iOS: Fully Local opens the itms-services link at
	/// the device's own HTTPS server, Semi Local opens the page that redirects
	/// to it.
	private func _openInstallLink() {
		if installer.getServerMethod() == 1 {
			_isWebviewPresenting = true
			_startWatchdog()
			return
		}

		guard let url = URL(string: installer.iTunesLink) else {
			_reportInstallDidNotStart()
			return
		}

		UIApplication.shared.open(url) { opened in
			if !opened {
				_reportInstallDidNotStart()
			}
		}

		_startWatchdog()
	}

	/// iOS answers an install link it does not like by doing nothing at all, so
	/// if it never comes back for the manifest, say so rather than leaving the
	/// screen on "Ready".
	private func _startWatchdog() {
		_watchdogTask?.cancel()
		_watchdogTask = Task {
			try? await Task.sleep(nanoseconds: 12_000_000_000)
			guard !Task.isCancelled else { return }

			await MainActor.run {
				if case .ready = viewModel.status {
					_reportInstallDidNotStart()
				}
			}
		}
	}

	private func _reportInstallDidNotStart() {
		FR.ensureSSLCertificates()

		UIAlertController.showAlertWithOk(
			title: .localized("Install"),
			message: .localized("iOS did not start the installation. Open Settings → Installation → Server & SSL, tap Update SSL Certificates, then try again.")
		)
	}
	
	private func _install() {
		// RaDown: the server starting is what produces the install link, so if
		// it did not start, say so now rather than leaving the screen waiting.
		if !isSharing, _installationMethod == 0, let startupError = installer.startupError {
			FR.ensureSSLCertificates()

			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: startupError,
				action: { dismiss() }
			)
			return
		}

		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						await MainActor.run {
							installer.packageUrl = packageUrl
							viewModel.status = .ready
						}
						
						if case .installing = await viewModel.status {
							let task = await startInstallProgressPolling(
								bundleID: app.identifier!,
								viewModel: viewModel
							)

							await MainActor.run {
								progressTask = task
							}
						}
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()
				
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
