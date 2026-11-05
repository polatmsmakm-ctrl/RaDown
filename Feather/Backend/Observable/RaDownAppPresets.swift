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

	/// Saves the options used to sign `identifier` as the difference against
	/// the global signing options.
	///
	/// Only what was changed for this app is kept, so a later change to the
	/// global options still reaches the app, and a preset keeps working when a
	/// new option is added to `Options`. The identifier and name a duplicate
	/// gets, and the identifier PPQ protection generates, belong to that one
	/// signing rather than to the app, so they are not kept.
	static func save(_ options: Options, for identifier: String?) {
		guard let identifier else { return }

		var preset = options

		if let custom = preset.appIdentifier {
			if custom.hasPrefix("\(identifier).copy") {
				preset.appIdentifier = nil
				preset.appName = nil
			} else if custom == "\(identifier).\(OptionsManager.shared.options.ppqString)" {
				preset.appIdentifier = nil
			}
		}

		guard
			let presetValues = _values(of: preset),
			let globalValues = _values(of: OptionsManager.shared.options)
		else {
			return
		}

		var changes: [String: Any] = [:]

		for (key, value) in presetValues where !_isEqual(value, globalValues[key]) {
			changes[key] = value
		}

		// Values this app cleared (its name, say) while the global options set them.
		for key in globalValues.keys where presetValues[key] == nil {
			changes[key] = NSNull()
		}

		guard !changes.isEmpty else {
			remove(for: identifier)
			return
		}

		guard let data = try? JSONSerialization.data(withJSONObject: changes) else { return }

		var stored = _all()
		stored[identifier] = data
		UserDefaults.standard.set(stored, forKey: _key)
	}

	/// The options last used for `identifier`, applied on top of the current
	/// global options, with any files that no longer exist (tweaks,
	/// entitlements) dropped.
	static func load(for identifier: String?) -> Options? {
		guard
			let identifier,
			let data = _all()[identifier],
			let changes = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			!changes.isEmpty,
			var values = _values(of: OptionsManager.shared.options)
		else {
			return nil
		}

		for (key, value) in changes {
			if value is NSNull {
				values.removeValue(forKey: key)
			} else {
				values[key] = value
			}
		}

		guard
			let merged = try? JSONSerialization.data(withJSONObject: values),
			var options = try? JSONDecoder().decode(Options.self, from: merged)
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

	/// The options as a plain dictionary, so they can be compared and merged
	/// field by field without listing every field here.
	private static func _values(of options: Options) -> [String: Any]? {
		guard let data = try? JSONEncoder().encode(options) else { return nil }
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}

	private static func _isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
		switch (lhs, rhs) {
		case (nil, nil):
			return true
		case let (lhs?, rhs?):
			return NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
		default:
			return false
		}
	}
}
