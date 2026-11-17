from pathlib import Path
p=Path('/Volumes/Backup/软件/OcPlayer-Core/crates/ocp-jellyfin/src/lib.rs');s=p.read_text()
idx=s.index('\npub mod endpoint;')
s=s[:idx]+'''
fn null_string_map<'de,D>(deserializer:D)->Result<serde_json::Value,D::Error>
where D:serde::Deserializer<'de> {
    let values=Option::<std::collections::BTreeMap<String,String>>::deserialize(deserializer)?;
    Ok(values.map(|m|serde_json::Value::Object(m.into_iter().map(|(k,v)|(k,serde_json::Value::String(v))).collect())).unwrap_or(serde_json::Value::Null))
}
fn null_string_array<'de,D>(deserializer:D)->Result<serde_json::Value,D::Error>
where D:serde::Deserializer<'de> {
    let values=Option::<Vec<String>>::deserialize(deserializer)?;
    Ok(values.map(|v|serde_json::Value::Array(v.into_iter().map(serde_json::Value::String).collect())).unwrap_or(serde_json::Value::Null))
}
#[derive(Deserialize)]
struct ItemResult<T> {
    #[serde(rename="Items",default,deserialize_with="null_default")]
    items:Vec<T>,
}
'''+s[idx:]
# Generic derives need explicit bounds, not an accidental T:Default bound.
s=s.replace('#[derive(Deserialize)]\nstruct ItemResult<T>', '#[derive(Deserialize)]\n#[serde(bound(deserialize = "T: Deserialize<\'de>"))]\nstruct ItemResult<T>')
# Validate collections on the wire while retaining public Value representations.
for attr in ['#[serde(alias = "ImageTags", default)]','#[serde(default, alias = "ImageTags")]']:
 s=s.replace(attr,attr[:-2]+', deserialize_with = "null_string_map")]')
s=s.replace('#[serde(alias = "BackdropImageTags", default)]','#[serde(alias = "BackdropImageTags", default, deserialize_with = "null_string_array")]')
s=s.replace('#[serde(alias = "ParentBackdropImageTags", default)]','#[serde(alias = "ParentBackdropImageTags", default, deserialize_with = "null_string_array")]')
s=s.replace('''#[serde(alias = "ProviderIds")]
    #[serde(default)]''','''#[serde(alias = "ProviderIds", default, deserialize_with = "null_string_map")]''')
a=s.index('pub struct MediaLibrary');b=s.index('\nimpl Serialize for MediaLibrary',a)
block=s[a:b].replace('pub id: String','pub id: Option<String>').replace('pub name: String','pub name: Option<String>');s=s[:a]+block+s[b:]
a=s.index('impl Serialize for MediaLibrary');b=s.index('\nimpl Serialize for MediaItem',a)
block=s[a:b].replace('value.serialize_field("name", &self.name)?;','value.serialize_field("name", &self.name.as_deref().unwrap_or(""))?;').replace('value.serialize_field("collectionType", &self.collection_type)?;','value.serialize_field("collectionType", &self.collection_type.as_ref().map(|kind|kind.to_lowercase()))?;')
s=s[:a]+block+s[b:]
# Business list responses centralize null/missing handling; malformed values/elements remain errors.
a=s.index('    pub async fn user_views(');b=s.index('\n    pub async fn libraries',a)
s=s[:a]+'''    pub async fn user_views(&self) -> Result<Vec<MediaItem>, JellyfinError> {
        let response:ItemResult<MediaItem> = self.get("UserViews",vec![]).await?;
        Ok(response.items)
    }
'''+s[b:]
a=s.index('    pub async fn libraries(');b=s.index('\n    async fn item_list',a)
block=s[a:b];x=block.index('        #[derive(Deserialize)]');y=block.index('        let path',x);block=block[:x]+block[y:];block=block.replace('self.get::<Response>','self.get::<ItemResult<MediaLibrary>>');s=s[:a]+block+s[b:]
a=s.index('    async fn item_list(');b=s.index('\n    pub async fn resume_items',a)
block=s[a:b];x=block.index('        #[derive(Deserialize)]');block=block[:x]+'''        Ok(self.get::<ItemResult<MediaItem>>(path,params).await?.items)
    }
    pub async fn similar_items(&self,id:&str,limit:i32)->Result<Vec<MediaItem>,JellyfinError> {
        self.item_list(&format!("Items/{id}/Similar"),vec![("limit",limit.clamp(1,100).to_string()),("fields",MEDIA_LIST_FIELDS.into())]).await
    }
''';s=s[:a]+block+s[b:]
p.write_text(s)
p=Path('/Volumes/Backup/软件/OcPlayer-Core/crates/ocp-core/src/lib.rs');s=p.read_text();a=s.index('                "browse.similar" => {',s.index('fn run_server_command'));b=s.index('                "playback.info" =>',a)
s=s[:a]+'''                "browse.similar" => {
                    let id = required_str(&arguments, "itemId")?;
                    let limit = arguments.get("limit").and_then(Value::as_i64).unwrap_or(12).clamp(1,100) as i32;
                    Ok(json!({"items":client.similar_items(id,limit).await?}))
                }
'''+s[b:]
s=s.replace('value.get("Items").cloned().unwrap_or_else(|| json!([]))','value.get("Items").filter(|v| !v.is_null()).cloned().unwrap_or_else(|| json!([]))')
p.write_text(s)
p=Path('/Users/jumusu/Documents/project/OcPlayer/Packages/JellyfinKit/Sources/JellyfinKit/RustCoreMediaServer.swift');s=p.read_text().replace('''    public func userViews() async throws -> [MediaLibrary] {
        try await dataAsync("server.libraries")
    }''','''    public func userViews() async throws -> [MediaLibrary] {
        let libraries: [RustLibrary] = try await dataAsync("server.libraries")
        return libraries.map { MediaLibrary(id: $0.id ?? UUID().uuidString, name: $0.name ?? "",
            collectionType: MediaLibrary.CollectionType($0.collectionType), primaryImageTag: $0.primaryImageTag) }
            .filter { $0.collectionType != .unknown && $0.collectionType != .folders }
    }''')
s=s.replace('private struct RustItemsPage:', '''private struct RustLibrary: Decodable {
    let id: String?
    let name: String?
    let collectionType: String?
    let primaryImageTag: String?
}
private struct RustItemsPage:''',1);p.write_text(s)
