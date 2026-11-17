from pathlib import Path
p=Path('/Users/jumusu/Documents/project/OcPlayer/App/Shared/Features/Settings/ConfigBackupCoordinator.swift')
# field, native key, Foundation getter kind
rows=[
('playback.skipIntro','skipIntro','bool'),('playback.skipOutro','skipOutro','bool'),('playback.outroRetentionSeconds','outroRetentionSeconds','integer'),('playback.subtitleLanguage','subtitleLanguagePreference','string'),('playback.lumaUpscaler','lumaUpscaler','string'),('playback.subtitleStyleOverrides','subtitleStyleOverrides','castBool'),('playback.subtitleAlignment','subtitleAlignment','castInt'),('playback.subtitleMarginVertical','subtitleMarginVertical','castInt'),('playback.subtitlePrimaryColor','subtitlePrimaryColor','integer'),('playback.subtitleOutlineColor','subtitleOutlineColor','integer'),('playback.subtitleOutlineWidth','subtitleOutlineWidth','castDouble'),('playback.subtitleBold','subtitleBold','castBool'),('playback.httpReadAheadMiB','httpReadAheadMiB','integer'),('playback.httpBackBufferMiB','httpBackBufferMiB','integer'),
('danmaku.danmakuEnabled','danmakuEnabled','bool'),('danmaku.opacity','danmakuOpacity','double'),('danmaku.displayArea','danmakuDisplayArea','double'),('danmaku.blockTop','danmakuBlockTop','bool'),('danmaku.blockBottom','danmakuBlockBottom','bool'),('danmaku.blockScroll','danmakuBlockScroll','bool'),('danmaku.fontSize','danmakuFontSize','double'),('danmaku.autoLoad','danmakuAutoLoad','bool'),
('general.bangumiEnabled','bangumiEnabled','bool'),('general.moviepilotEnabled','moviepilotEnabled','bool'),('general.homeSections','homeSections','string'),('general.episodeSortAscending','episodeSortAscending','bool'),
('mirror.bangumiEnabled','bangumiMirrorEnabled','castBool'),('mirror.bangumiRootDomain','bangumiMirrorRootDomain','string'),('mirror.tmdbEnabled','tmdbMirrorEnabled','castBool'),('mirror.tmdbAPIBaseURL','tmdbMirrorAPIBaseURL','string'),('mirror.tmdbImageBaseURL','tmdbMirrorImageBaseURL','string')]
helper='''    private enum PreferenceRead { case bool, integer, double, string, castBool, castInt, castDouble }
    private static let preferenceSpecs: [(field: String, key: String, read: PreferenceRead)] = [
'''+''.join(f'        ("{field}", SettingsKeys.{key}, .{read}),\n' for field,key,read in rows)+'''    ]
    private static var preferenceKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: preferenceSpecs.map { ($0.field, $0.key) })
    }
    private static func preferenceFacts(in defaults: UserDefaults) -> [String: OcpSettingsBackup.Preference] {
        Dictionary(uniqueKeysWithValues: preferenceSpecs.map { spec in
            let raw = defaults.object(forKey: spec.key)
            let value: Any?
            switch spec.read {
            case .bool: value = defaults.bool(forKey: spec.key)
            case .integer: value = defaults.integer(forKey: spec.key)
            case .double: value = defaults.double(forKey: spec.key)
            case .string: value = defaults.string(forKey: spec.key)
            case .castBool: value = raw as? Bool
            case .castInt: value = raw as? Int
            case .castDouble: value = raw as? Double
            }
            return (spec.field, .init(present: raw != nil, value: value))
        })
    }
'''
s=p.read_text();i=s.index('    // MARK: - 导出');s=s[:i]+helper+'\n'+s[i:]
needle='''            return (effect, try effect.value())'''
assert needle in s
s=s.replace(needle,'''            let value = try effect.value()
            let valid: Bool
            if effect.target == "tmdb" {
                switch effect.field {
                case "tmdb.apiKey", "tmdb.language": valid = value is String && effect.operation == "set"
                case "tmdb.preferText", "tmdb.replaceImages", "tmdb.showPlaceholders": valid = value is Bool && effect.operation == "set"
                case "tmdb.cacheDays": valid = value is NSNumber && effect.operation == "set"
                default: valid = false
                }
            } else if effect.target == "dandanplay" {
                valid = effect.field == "danmaku.dandanplayGatewayURL" && value is String && effect.operation == "set"
            } else if effect.operation == "remove" {
                valid = ["mirror.bangumiRootDomain", "mirror.tmdbAPIBaseURL", "mirror.tmdbImageBaseURL"].contains(effect.field)
            } else {
                let spec = preferenceSpecs.first { $0.field == effect.field }!
                switch spec.read {
                case .bool, .castBool: valid = value is Bool
                case .string: valid = value is String
                default: valid = value is NSNumber
                }
            }
            guard valid else { throw ConfigBackupError.invalidFormat("Invalid Core backup effect value") }
            return (effect, value)''')
p.write_text(s)
print('installed',len(rows),'platform getter/key mappings')
