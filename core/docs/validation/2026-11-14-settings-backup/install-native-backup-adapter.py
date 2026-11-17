from pathlib import Path
root=Path('/Users/jumusu/Documents/project/OcPlayer')
p=root/'App/Shared/Features/Settings/ConfigBackupCoordinator.swift';s=p.read_text().replace('import PlaybackKit','import PlaybackKit\nimport OcPlayerCore')
for old,new in [('makeBackup','nativeMakeBackup'),('applyBackup','nativeApplyBackup'),('encode','nativeEncode'),('decode','nativeDecode'),('summary','nativeSummary')]:
 s=s.replace('static func '+old+'(', 'static func '+new+'(')
# Preserve the native reference implementation while file readers dispatch through Core.
insert=s.index('    // MARK: - 导出')
s=s[:insert]+'''    nonisolated private static let sharedBackup = OcpSettingsBackup()
    nonisolated static var isCoreBackupActive: Bool { sharedBackup != nil }

    nonisolated private static func mapped<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as OcpSettingsBackup.Failure {
            switch error.kind {
            case "emptyData": throw ConfigBackupError.emptyData
            case "unsupportedVersion": throw ConfigBackupError.unsupportedVersion(error.version ?? 0)
            default: throw ConfigBackupError.invalidFormat(error.message)
            }
        }
    }
    static func makeBackup(tmdb: TMDbCoordinator, dandanplayGatewayURL: String? = nil,
                           defaults: UserDefaults = .standard, deviceName: String? = nil,
                           appVersion: String? = nil) throws -> AppConfigBackup {
        guard let sharedBackup else {
            return nativeMakeBackup(tmdb: tmdb, dandanplayGatewayURL: dandanplayGatewayURL,
                                    defaults: defaults, deviceName: deviceName, appVersion: appVersion)
        }
        let formatter = ISO8601DateFormatter()
        let projection = try mapped {
            try sharedBackup.snapshot(preferences: preferenceFacts(in: defaults), tmdb: [
                "apiKey": tmdb.rawAPIKey as Any, "language": tmdb.language,
                "preferText": tmdb.preferText, "replaceImages": tmdb.replaceImages,
                "showPlaceholders": tmdb.showPlaceholders, "cacheDays": tmdb.cacheDays,
            ], exportedAt: formatter.string(from: Date()), appVersion: appVersion ?? AppVersion.currentShortVersion,
               deviceName: deviceName ?? currentDeviceName(), dandanplayGatewayURL: dandanplayGatewayURL)
        }
        return try nativeDecode(projection.backupData)
    }
    nonisolated static func encode(_ backup: AppConfigBackup) throws -> Data {
        let native = try nativeEncode(backup)
        guard let sharedBackup else { return native }
        let projection = try mapped { try sharedBackup.prepare(native) }
        return try nativeEncode(nativeDecode(projection.backupData))
    }
    nonisolated static func decode(_ data: Data) throws -> AppConfigBackup {
        guard let sharedBackup else { return try nativeDecode(data) }
        let projection = try mapped { try sharedBackup.decode(data) }
        return try nativeDecode(projection.backupData)
    }
    nonisolated static func summary(of backup: AppConfigBackup) throws -> BackupSummary {
        guard let sharedBackup else { return nativeSummary(of: backup) }
        let projection = try mapped { try sharedBackup.prepare(nativeEncode(backup)) }
        let core = projection.summary
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return BackupSummary(hasTMDb: core.hasTMDb, tmdbKeyTail: core.tmdbKeyTail,
            tmdbLanguage: core.tmdbLanguage, hasPlayback: core.hasPlayback,
            hasDanmaku: core.hasDanmaku, hasGeneral: core.hasGeneral, hasMirror: core.hasMirror,
            exportedAtFormatted: formatter.string(from: backup.exportedAt), deviceName: core.deviceName)
    }
    static func applyBackup(_ backup: AppConfigBackup, tmdb: TMDbCoordinator,
                            dandanplayStore: DandanplaySettingsStore? = nil,
                            defaults: UserDefaults = .standard) throws {
        guard let sharedBackup else {
            nativeApplyBackup(backup, tmdb: tmdb, dandanplayStore: dandanplayStore, defaults: defaults)
            return
        }
        let projection = try mapped { try sharedBackup.prepare(nativeEncode(backup)) }
        // Decode every effect before any preference or coordinator is changed.
        let effects = try projection.effects.map { effect in
            guard ["preferences", "tmdb", "dandanplay"].contains(effect.target),
                  ["set", "remove"].contains(effect.operation),
                  effect.target != "preferences" || preferenceKeys[effect.field] != nil else {
                throw ConfigBackupError.invalidFormat("Unknown Core backup effect")
            }
            return (effect, try effect.value())
        }
        for (effect, value) in effects {
            switch effect.target {
            case "tmdb":
                switch effect.field {
                case "tmdb.apiKey": tmdb.setAPIKey(value as! String)
                case "tmdb.language": tmdb.setLanguage(value as! String)
                case "tmdb.preferText": tmdb.setPreferText(value as! Bool)
                case "tmdb.replaceImages": tmdb.setReplaceImages(value as! Bool)
                case "tmdb.showPlaceholders": tmdb.setShowPlaceholders(value as! Bool)
                case "tmdb.cacheDays": tmdb.setCacheDays((value as! NSNumber).intValue)
                default: preconditionFailure("Invalid Core TMDB effect")
                }
            case "dandanplay":
                if var store = dandanplayStore { store.gatewayURLString = value as? String }
            default:
                let key = preferenceKeys[effect.field]!
                if effect.operation == "remove" { defaults.removeObject(forKey: key) }
                else { defaults.set(value, forKey: key) }
            }
        }
    }

''' + s[insert:]
# All direct call sites in the app and its existing tests now propagate errors.
p.write_text(s)
for p in [root/'App/Shared/Features/Settings/SettingsPagesMaintenance.swift',root/'AppTests/ConfigBackupTests.swift']:
 s=p.read_text()
 for name in ['makeBackup','applyBackup','summary']:
  s=s.replace('ConfigBackupCoordinator.'+name+'(', 'try ConfigBackupCoordinator.'+name+'(')
 p.write_text(s)
# Put export assembly inside its existing error handler.
p=root/'App/Shared/Features/Settings/SettingsPagesMaintenance.swift';s=p.read_text();s=s.replace('''    private func exportConfig() {
        let backup = try''','''    private func exportConfig() {
        do {
        let backup = try''').replace('''        do {
            exportDocument = try ConfigBackupDocument(backup: backup)''','''            exportDocument = try ConfigBackupDocument(backup: backup)''')
s=s.replace('''        try ConfigBackupCoordinator.applyBackup(
            backup,''','''        do {
        try ConfigBackupCoordinator.applyBackup(
            backup,''').replace('''        statusNotice = "配置已成功恢复并生效"
        isError = false
    }''','''        statusNotice = "配置已成功恢复并生效"
        isError = false
        } catch {
            statusNotice = "恢复配置失败：\\(error.localizedDescription)"
            isError = true
        }
    }''');p.write_text(s)
print('native dispatch and UI error propagation installed')
