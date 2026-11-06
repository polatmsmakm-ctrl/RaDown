//
//  CertificateExpiryNotifier.swift
//  RaDown
//
//  A free Apple certificate lasts seven days. When it lapses, every app signed
//  with it stops opening, and the only sign of it is the apps refusing to
//  launch. This gives notice while there is still time to sign them again.
//

import Foundation
import UserNotifications
import OSLog

enum CertificateExpiryNotifier {
	private static let _identifierPrefix = "RaDown.certificateExpiry."
	private static let _askedKey = "RaDown.didAskForNotifications"

	/// How long before the date to give notice, longest first.
	private static let _noticeIntervals: [TimeInterval] = [
		2 * 24 * 60 * 60,
		6 * 60 * 60,
	]

	/// Asks once, the first time there is a certificate worth warning about.
	static func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void = { _ in }) {
		let center = UNUserNotificationCenter.current()

		center.getNotificationSettings { settings in
			switch settings.authorizationStatus {
			case .notDetermined:
				UserDefaults.standard.set(true, forKey: _askedKey)
				center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
					completion(granted)
				}
			case .authorized, .provisional, .ephemeral:
				completion(true)
			default:
				completion(false)
			}
		}
	}

	/// Replaces the pending notices with ones for this date.
	static func schedule(for expiration: Date?, certificateName: String?) {
		let center = UNUserNotificationCenter.current()
		cancelAll()

		guard let expiration, expiration > Date() else { return }

		requestAuthorizationIfNeeded { granted in
			guard granted else { return }

			let name = certificateName ?? String.localized("Certificate")

			for (index, interval) in _noticeIntervals.enumerated() {
				let fireDate = expiration.addingTimeInterval(-interval)
				guard fireDate > Date() else { continue }

				let content = UNMutableNotificationContent()
				content.title = .localized("Certificate expiring")
				content.body = interval > 24 * 60 * 60
					? .localized("‘%@‘ expires in two days. Sign your apps again before then, or they will stop opening.", arguments: name)
					: .localized("‘%@‘ expires today. Sign your apps again now, or they will stop opening.", arguments: name)
				content.sound = .default

				let components = Calendar.current.dateComponents(
					[.year, .month, .day, .hour, .minute],
					from: fireDate
				)

				let request = UNNotificationRequest(
					identifier: "\(_identifierPrefix)\(index)",
					content: content,
					trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
				)

				center.add(request) { error in
					if let error {
						Logger.misc.error("Could not schedule the certificate notice: \(error)")
					}
				}
			}
		}
	}

	static func cancelAll() {
		let identifiers = _noticeIntervals.indices.map { "\(_identifierPrefix)\($0)" }
		UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
	}
}
