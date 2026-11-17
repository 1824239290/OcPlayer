from pathlib import Path
import re
p=Path('/Volumes/Backup/软件/OcPlayer-Core/crates/ocp-jellyfin/src/lib.rs');s=p.read_text()
# Option-based deserialization accepts only missing/null defaults; bad non-null types remain errors.
idx=s.index('\npub mod endpoint;')
s=s[:idx]+'''
fn null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where D: serde::Deserializer<'de>, T: Deserialize<'de> + Default {
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}
'''+s[idx:]
a=s.index('#[derive(Debug, Clone, Deserialize, PartialEq)]\n#[serde(rename_all = "camelCase")]\npub struct MediaItem');b=s.index('\n#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n#[serde(rename_all = "camelCase")]\npub struct Person',a)
original=s[a:b]
extra='''    #[serde(alias = "AlbumPrimaryImageTag")]
    pub album_primary_image_tag: Option<String>,
    #[serde(alias = "SeriesPrimaryImageTag")]
    pub series_primary_image_tag: Option<String>,
    #[serde(alias = "ParentLogoImageTag")]
    pub parent_logo_image_tag: Option<String>,
    #[serde(alias = "ParentLogoItemId")]
    pub parent_logo_item_id: Option<String>,
    #[serde(alias = "SeriesThumbImageTag")]
    pub series_thumb_image_tag: Option<String>,
    #[serde(alias = "ParentPrimaryImageItemId")]
    pub parent_primary_image_item_id: Option<String>,
    #[serde(alias = "ParentPrimaryImageTag")]
    pub parent_primary_image_tag: Option<String>,
    #[serde(alias = "ParentBackdropImageTags", default)]
    pub parent_backdrop_image_tags: serde_json::Value,
    has_play_state: bool,
    name_was_missing: bool,
'''
domain=original.replace('#[serde(rename_all = "camelCase")]','#[serde(rename_all = "camelCase", from = "WireMediaItem")]',1)
domain=domain[:domain.rfind('}')]+extra+domain[domain.rfind('}'):]
wire=original.replace('pub struct MediaItem','struct WireMediaItem',1)
for field in ['id','name','kind']:wire=wire.replace('pub '+field+': String','pub '+field+': Option<String>',1)
wire=wire.replace('pub cast: Vec<Person>','pub cast: Vec<WirePerson>')
wire=wire.replace('pub play_state: PlayState','pub play_state: Option<PlayState>')
wire=wire.replace('#[serde(alias = "Genres", default)]','#[serde(alias = "Genres", default, deserialize_with = "null_default")]')
wire=wire.replace('#[serde(alias = "People", default)]','#[serde(alias = "People", default, deserialize_with = "null_default")]')
wire=wire[:wire.rfind('}')]+extra[:extra.index('    has_play_state:')]+wire[wire.rfind('}'):]
fields=re.findall(r'(?:pub )?(\w+): [^\n]+,',domain[domain.index('{')+1:])
conversion='''
impl From<WireMediaItem> for MediaItem {
    fn from(wire: WireMediaItem) -> Self {
        let id = wire.id.unwrap_or_else(|| missing_item_id(wire.name.as_deref(), wire.kind.as_deref()));
        let name_was_missing = wire.name.is_none();
        let has_play_state = wire.user_data.is_some() || wire.play_state.is_some();
        Self {
            id, name: wire.name.unwrap_or_else(|| "未命名".into()), kind: wire.kind.unwrap_or_default(),
            name_was_missing, has_play_state,
            cast: wire.cast.into_iter().filter_map(|person| Some(Person {
                id: person.id?, name: person.name?, role: person.role,
                kind: person.kind.unwrap_or_else(|| "Actor".into()),
            })).collect(),
            play_state: wire.play_state.unwrap_or_default(),
'''
for field in fields:
 if field not in ['id','name','kind','cast','play_state','name_was_missing','has_play_state']:conversion+='            '+field+': wire.'+field+',\n'
conversion+='''        }
    }
}
fn missing_item_id(name: Option<&str>, kind: Option<&str>) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in format!("part:{}kind:{}",name.unwrap_or("unnamed"),kind.unwrap_or("")).bytes() {
        hash ^= u64::from(byte); hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("missing-{hash:016x}")
}
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct WirePerson {
    #[serde(alias = "Id")] id: Option<String>,
    #[serde(alias = "Name")] name: Option<String>,
    #[serde(alias = "Role")] role: Option<String>,
    #[serde(alias = "Type")] kind: Option<String>,
}
'''
s=s[:a]+domain+'\n'+wire+conversion+s[b:]
s=s.replace('    playback_position_ticks: i64,','    playback_position_ticks: Option<i64>,').replace('    played: bool,\n    #[serde(default)]\n    played_percentage:', '    played: Option<bool>,\n    #[serde(default)]\n    played_percentage:')
s=s.replace('data.playback_position_ticks as f64','data.playback_position_ticks.unwrap_or_default() as f64').replace('played: data.played,','played: data.played.unwrap_or_default(),')
s=s.replace('#[serde(default, alias = "MediaStreams")]','#[serde(default, alias = "MediaStreams", deserialize_with = "null_default")]')
# Query result containers all allow both omitted and explicit null, preserving array element validation.
s=s.replace('#[serde(rename = "Items")]\n            items: Vec<', '#[serde(rename = "Items", default, deserialize_with = "null_default")]\n            items: Vec<')
s=s.replace('#[serde(rename = "Items", default)]\n            items: Vec<', '#[serde(rename = "Items", default, deserialize_with = "null_default")]\n            items: Vec<')
s=s.replace('#[serde(rename = "MediaSources")]\n            media_sources:', '#[serde(rename = "MediaSources", default, deserialize_with = "null_default")]\n            media_sources:')
s=s.replace('#[serde(rename = "StartIndex")]\n            start_index: i32,', '#[serde(rename = "StartIndex", default, deserialize_with = "null_default")]\n            start_index: i32,')
# Full DTO item normalization follows ServerItemFields, including season and parent-image rules.
s=s.replace('value.serialize_field("seasonID", &self.season_id)?;\n        value.serialize_field("seasonName", &self.season_name)?;\n        value.serialize_field("seasonNumber", &self.season_number)?;\n        value.serialize_field("episodeNumber", &self.index_number)?;', '''let is_season = self.kind == "Season" || self.kind == "season";
        let season_id = if is_season { Some(&self.id) } else { self.season_id.as_ref() };
        let season_name = if is_season { (!self.name_was_missing).then_some(&self.name) } else { self.season_name.as_ref() };
        value.serialize_field("seasonID", &season_id)?;
        value.serialize_field("seasonName", &season_name)?;
        value.serialize_field("seasonNumber", &if is_season { self.index_number } else { self.season_number })?;
        value.serialize_field("episodeNumber", &if is_season { None } else { self.index_number })?;''')
s=s.replace('value.serialize_field("playState", &play_state)?;','value.serialize_field("playState", &self.has_play_state.then_some(play_state))?;',1)
s=s.replace('value.serialize_field("primaryImageTag", &image_tag(&self.image_tags, "Primary"))?;', '''let own_primary = image_tag(&self.image_tags, "Primary");
        let primary = if swift_kind(&self.kind) == "episode" { own_primary } else {
            own_primary.or_else(||self.album_primary_image_tag.clone()).or_else(||self.series_primary_image_tag.clone())
        };
        value.serialize_field("primaryImageTag", &primary)?;''',1 if False else 0) if False else s
# Replace only within MediaItem serializer (library has the same primary field).
a=s.index('impl Serialize for MediaItem');prefix=s[:a];tail=s[a:]
tail=tail.replace('value.serialize_field("primaryImageTag", &image_tag(&self.image_tags, "Primary"))?;', '''let own_primary = image_tag(&self.image_tags, "Primary");
        let primary = if swift_kind(&self.kind) == "episode" { own_primary } else {
            own_primary.or_else(||self.album_primary_image_tag.clone()).or_else(||self.series_primary_image_tag.clone())
        };
        value.serialize_field("primaryImageTag", &primary)?;''',1)
tail=tail.replace('&image_tag(&self.image_tags, "Backdrop")','&first_tag(&self.backdrop_image_tags)',1)
tail=tail.replace('value.serialize_field("parentBackdropImageTag", &self.parent_backdrop_image_tag)?;', '''value.serialize_field("parentBackdropImageTag", &first_tag(&self.parent_backdrop_image_tags).or_else(||self.parent_backdrop_image_tag.clone()))?;
        value.serialize_field("logoImageTag", &image_tag(&self.image_tags,"Logo").or_else(||self.parent_logo_image_tag.clone()))?;
        value.serialize_field("parentLogoItemID", &self.parent_logo_item_id)?;
        value.serialize_field("seriesThumbImageTag", &self.series_thumb_image_tag)?;
        value.serialize_field("parentPrimaryImageItemID", &self.parent_primary_image_item_id)?;
        value.serialize_field("parentPrimaryImageTag", &self.parent_primary_image_tag)?;
        value.serialize_field("seriesPrimaryImageTag", &self.series_primary_image_tag)?;''',1)
s=prefix+tail
idx=s.index('\nfn image_tag(')
s=s[:idx]+'''
fn first_tag(value: &serde_json::Value) -> Option<String> {
    value.as_array()?.first()?.as_str().map(str::to_owned)
}
'''+s[idx:]
p.write_text(s)
