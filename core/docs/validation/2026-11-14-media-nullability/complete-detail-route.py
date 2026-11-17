from pathlib import Path
import shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');out=Path('/tmp/ocp-nullable-macos');pre=out/'preliminary/before-detail-route';pre.mkdir(parents=True,exist_ok=True)
for p in out.iterdir():
 if p.is_file():shutil.copy2(p,pre/p.name)
(pre/'gate-termination.txt').write_text('Preliminary gate intentionally stopped (143) after endpoint audit identified missing Emby legacy detail path and explicit detail fields. Complete final gate rerun required.\n')
p=core/'crates/ocp-jellyfin/src/lib.rs';s=p.read_text();marker='    pub async fn item(&self, id: &str)';s=s.replace(marker,'''    pub fn item_detail_path(&self, id: &str) -> String {
        match self.profile.kind {
            ServerKind::Jellyfin => format!("Items/{id}"),
            ServerKind::Emby => format!("Users/{}/Items/{id}", self.profile.user_id.as_deref().unwrap_or_default()),
        }
    }
'''+marker);s=s.replace('''    pub async fn item(&self, id: &str) -> Result<MediaItem, JellyfinError> {
        self.get(
            &format!("Items/{id}"),
            vec![("fields", MEDIA_LIST_FIELDS.into())],''','''    pub async fn item(&self, id: &str) -> Result<MediaItem, JellyfinError> {
        self.get(
            &self.item_detail_path(id),
            vec![("fields", "People,Genres,Overview,Chapters,PrimaryImageAspectRatio".into())],''');p.write_text(s)
p=core/'crates/ocp-core/src/lib.rs';s=p.read_text();s=s.replace('''&format!("Items/{id}"),
                            vec![("fields", "Chapters".into())],''','''&client.item_detail_path(id),
                            vec![("fields", "Chapters".into())],''');s=s.replace('''&format!("Items/{id}"),
                                vec![("fields", "Chapters".into())],''','''&client.item_detail_path(id),
                                vec![("fields", "Chapters".into())],''');s=s.replace('value.get("Chapters").cloned().unwrap_or_else(|| json!([]))','nullable_response_array(&value, "Chapters")?');needle='''fn nullable_response_items(value: &Value) -> Result<Vec<Value>, CommandError> {
    let object''';s=s.replace(needle,'''fn nullable_response_items(value: &Value) -> Result<Vec<Value>, CommandError> {
    nullable_response_array(value, "Items")
}
fn nullable_response_array(value: &Value, key: &str) -> Result<Vec<Value>, CommandError> {
    let object''');s=s.replace('object.get("Items").cloned().unwrap_or(Value::Null)','object.get(key).cloned().unwrap_or(Value::Null)');p.write_text(s)
p=core/'tests/media_nullable_server.py';s=p.read_text();s=s.replace(' def send(self,data):',' def send(self,data,status=200):').replace('self.send_response(200)','self.send_response(status)');s=s.replace("  if case=='missing_identity':",'''  if case=='containers_null':item['Chapters']=None
  if case=='containers_empty':item['Chapters']=[]
  if case=='wrong_chapters':item['Chapters']=1
  if case=='missing_identity':''');s=s.replace("  if path.endswith('/Items/item'):self.send(self.item());return",'''  if path.endswith('/Items/item'):
   if self.headers.get('Authorization','').startswith('Emby ') and not path.endswith('/Users/user/Items/item'):
    self.send({'error':'Emby requires legacy user detail path'},404);return
   fields=query.get('fields',[''])[0].split(',')
   if fields!=['Chapters'] and 'People' not in fields:
    self.send({'error':'detail must explicitly request People'},400);return
   self.send(self.item());return''');p.write_text(s);(native/'Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_nullable_server.py').write_text(s)
p=native/'Packages/JellyfinKit/Tests/JellyfinKitTests/MediaNullableHTTPTests.swift';s=p.read_text();s=s.replace('let segments = try await server.mediaSegments(itemID: "item")','let segments = try await server.mediaSegments(itemID: "item"), chapters = try await server.chapters(itemID: "item")');s=s.replace('XCTAssertTrue(similar.isEmpty); XCTAssertTrue(segments.isEmpty)','XCTAssertTrue(similar.isEmpty); XCTAssertTrue(segments.isEmpty); XCTAssertTrue(chapters.isEmpty)');s=s.replace('["wrong_list", "wrong_genres",','["wrong_list", "wrong_chapters", "wrong_genres",');s=s.replace('if name == "wrong_list" { _ = try await server.similar','if name == "wrong_chapters" { _ = try await server.chapters(itemID: "item") }\n                            else if name == "wrong_list" { _ = try await server.similar');p.write_text(s)
p=core/'tests/media_nullable_contract.py';s=p.read_text().replace("('media.segments', {'itemId':'item'})", "('browse.chapters', {'itemId':'item'}), ('media.segments', {'itemId':'item'})");s=s.replace("result.get('items', result.get('Items'))","result.get('items', result.get('Items', result.get('chapters')))");s=s.replace("cases = [('wrong_list','browse.similar')", "cases = [('wrong_chapters','browse.chapters'), ('wrong_list','browse.similar')");p.write_text(s)
p=core/'docs/media-nullability-contract.md';s=p.read_text().replace('`MediaStreams`, genres and people','`MediaStreams`, `Chapters`, genres and people');s=s.replace('Emby media segments read `Items/{id}?fields=Chapters`,','Detail uses Jellyfin `Items/{id}` and Emby `Users/{userId}/Items/{id}`. Both\nexplicitly request People, Genres, Overview, Chapters and PrimaryImageAspectRatio\nas the native clients do. The fixture rejects a missing People field or a modern\nEmby detail route, so permissive test routing cannot conceal these differences.\n\nEmby media segments read `Users/{userId}/Items/{id}?fields=Chapters`,');p.write_text(s);(native/'Docs/SHARED-MEDIA-NULLABILITY.md').write_text(s)
