//
//  RaDownAppPresets.swift
//  RaDown
//
//  Remembers the signing options used for each app, keyed by the app's
//  identifier, so the next signing (or "Re-sign All") starts from the same
//  name, tweaks and toggles.
//

import Foundation

enum RaDownAppPresets {
	private static let _key = "RaDown.appPresets"

	/// Saves the options used to sign `identifier`. A duplicate's identifier
	/// and name are not kept, so the next signing starts from the original.
	static func save(_ options: Options, for identifier: String?) {
		guard let identifier else { return }

		var preset = options
		if let custom = preset.appIdentifier, custom.contains(".copy") {
			preset.appIdentifier = nil
			preset.appName = nil
		}

		guard let data = try? JSONEncoder().encode(preset) else { return }
		var stored = _all()
		stored[identifier] = data
		UserDefaults.standard.set(stored, forKey: _key)
	}

	/// The saved options for `identifier`, with any files that no longer
	/// exist (tweaks, entitlements) dropped.
	static func load(for identifier: String?) -> Options? {
		guard
			let identifier,
			let data = _all()[identifier],
			var options = try? JSONDecoder().decode(Options.self, from: data)
		else {
			return nil
		}

		let fileManager = FileManager.default
		options.injectionFiles = options.injectionFiles.filter { fileManager.fileExists(atPath: $0.path) }
		if let entitlements = options.appEntitlementsFile, !fileManager.fileExists(atPath: entitlements.path) {
			options.appEntitlementsFile = nil
		}
		return options
	}

	/// Saved options for `identifier`, or the global signing options.
	static func options(for identifier: String?) -> Options {
		load(for: identifier) ?? OptionsManager.shared.options
	}

	static func remove(for identifier: String?) {
		guard let identifier else { return }
		var stored = _all()
		stored.removeValue(forKey: identifier)
		UserDefaults.standard.set(stored, forKey: _key)
	}

	private static func _all() -> [String: Data] {
		UserDefaults.standard.dictionary(forKey: _key) as? [String: Data] ?? [:]
	}
}
