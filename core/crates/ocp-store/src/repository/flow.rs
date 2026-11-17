//! Retained effect sequencing for all five repository refresh kinds. Responses
//! carry a single-use sequence receipt; hosts execute only the yielded effect.
use super::*;
mod cached;
#[derive(Default)]
pub(super) struct Flows {
    next: u64,
    active: HashMap<u64, Flow>,
}
impl Flows {
    pub(super) fn is_empty(&self) -> bool {
        self.active.is_empty()
    }
}
#[derive(Clone)]
struct Flow {
    kind: String,
    phase: String,
    input: Value,
    previous: Value,
    content: Value,
    parts: Value,
    failures: Value,
    started: f64,
    sequence: u64,
    result: Value,
}
fn object(v: &Value) -> Result<(), String> {
    v.as_object()
        .ok_or_else(|| "object required".to_owned())
        .map(|_| ())
}
fn clock(v: &Value, field: &str) -> Result<f64, String> {
    v[field]
        .as_f64()
        .filter(|v| v.is_finite())
        .ok_or_else(|| format!("finite {field} required"))
}
fn string(v: &Value, field: &str) -> Result<String, String> {
    v[field]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("{field} string required"))
}
fn items(v: &Value) -> Result<(), String> {
    for item in v.as_array().ok_or("items array required")? {
        string(item, "id")?;
    }
    Ok(())
}
const KINDS: &[&str] = &[
    "movie",
    "series",
    "season",
    "episode",
    "boxSet",
    "musicAlbum",
    "musicArtist",
    "audio",
    "book",
    "photo",
    "folder",
    "playlist",
    "other",
];
fn optional_string(v: &Value, field: &str) -> Result<Option<String>, String> {
    if v[field].is_null() {
        Ok(None)
    } else {
        string(v, field).map(Some)
    }
}
fn page_key(v: &Value) -> Result<Value, String> {
    let d = &v["descriptor"];
    object(d)?;
    d["recursive"]
        .as_bool()
        .ok_or("recursive must be boolean")?;
    let parent = optional_string(d, "parentID")?.unwrap_or_default();
    let search = optional_string(d, "searchTerm")?.unwrap_or_default();
    let mut kinds = vec![];
    if !d["kinds"].is_null() {
        for k in d["kinds"].as_array().ok_or("kinds must be an array")? {
            let k = k
                .as_str()
                .filter(|s| KINDS.contains(s))
                .ok_or("invalid kind")?;
            kinds.push(k.to_owned());
        }
    }
    kinds.sort();
    let sort = if let Some(field) = optional_string(d, "sortField")? {
        if !["name", "dateAdded", "year", "rating", "runtime", "random"].contains(&field.as_str()) {
            return Err("invalid sortField".into());
        }
        let ascending = d["ascending"]
            .as_bool()
            .ok_or("ascending must be boolean")?;
        format!("{field}:{}", if ascending { "asc" } else { "desc" })
    } else {
        String::new()
    };
    let watch = optional_string(d, "watchState")?.unwrap_or_default();
    if !["", "all", "watched", "unwatched"].contains(&watch.as_str()) {
        return Err("invalid watchState".into());
    }
    let start = v["startIndex"].as_i64().ok_or("startIndex must be Int64")?;
    let limit = v["limit"].as_i64().ok_or("limit must be Int64")?;
    Ok(
        json!({"parentID":parent,"kinds":kinds.join(","),"sortKey":sort,"watchState":watch,"searchTerm":search,"startIndex":start,"limit":limit}),
    )
}
fn item(v: &Value) -> Result<(), String> {
    string(v, "id").map(|_| ())
}
fn part(v: &Value, array: bool) -> Result<(), String> {
    object(v)?;
    if !v["failure"].is_null() {
        string(&v["failure"], "message")?;
        v["failure"]["isConnectivity"]
            .as_bool()
            .ok_or("failure isConnectivity required")?;
    }
    if !v["value"].is_null() {
        if array {
            items(&v["value"])?;
        } else {
            object(&v["value"])?;
        }
    }
    Ok(())
}
fn compose(repo: &Repository, method: &str, v: Value) -> Result<Value, String> {
    composition::call(repo, method, &json!({"payloadJSON":v.to_string()}))
}
fn blank_detail(item: Value) -> Value {
    json!({"item":item,"seasons":[],"episodes":[],"collectionMembers":[]})
}
fn blank_home() -> Value {
    json!({"libraries":[],"resume":[],"nextUp":[],"latest":[]})
}
fn collection(id: &Value) -> Value {
    json!({"parentID":id,"recursive":false,"sortField":"year","ascending":true})
}
impl Flow {
    fn effect(&mut self, phase: &str, arguments: Value) -> Value {
        self.phase = phase.into();
        json!({"done":false,"effect":phase,"arguments":arguments,"sequence":self.sequence})
    }
    fn done(&mut self, result: Value) -> Value {
        self.phase = "done".into();
        json!({"done":true,"sequence":self.sequence,"result":result})
    }
    fn save_items(&mut self, values: Value, rail: Option<&str>, phase: &str) -> Value {
        let mut args = json!({"items":values,"requestStartedAt":self.started});
        if let Some(rail) = rail {
            args["rail"] = json!(rail);
        }
        self.effect(phase, args)
    }
    fn failure(&mut self, name: &str, p: &Value) {
        if !p["failure"].is_null() {
            self.failures[name] = p["failure"].clone();
        }
    }
    fn next_home(
        &mut self,
        repo: &Repository,
        mut index: usize,
        now: f64,
    ) -> Result<Value, String> {
        let names = ["libraries", "resume", "nextUp", "latest"];
        while index < 4 {
            let name = names[index];
            let p = self.parts[name].clone();
            self.failure(name, &p);
            if !p["value"].is_null() {
                if index == 0 {
                    self.content[name] = p["value"].clone();
                    return Ok(self.effect("saveLibraries", json!({"libraries":p["value"]})));
                }
                return Ok(self.save_items(
                    p["value"].clone(),
                    Some(name),
                    &format!("saveHome_{name}"),
                ));
            }
            index += 1;
        }
        let success = names.iter().any(|n| !self.parts[*n]["value"].is_null());
        let fetched = if success {
            now
        } else {
            self.previous["fetchedAt"].as_f64().unwrap_or(now)
        };
        let source = if success {
            json!("network")
        } else {
            self.previous
                .get("source")
                .cloned()
                .unwrap_or(json!("network"))
        };
        let content = compose(
            repo,
            "home",
            json!({"content":self.content,"requestStartedAt":self.started}),
        )?;
        self.result = json!({"snapshot":{"value":content,"fetchedAt":fetched,"source":source},"failures":self.failures});
        Ok(self.effect("commitHome", json!({"home":self.result})))
    }
    fn detail_commit(
        &mut self,
        repo: &Repository,
        merge: bool,
        remember: bool,
    ) -> Result<Value, String> {
        self.content = compose(
            repo,
            "detail",
            json!({"content":self.content,"requestStartedAt":self.started,"mergeProgress":merge}),
        )?;
        let values = if remember {
            self.content["seasons"]
                .as_array()
                .unwrap()
                .iter()
                .chain(self.content["episodes"].as_array().unwrap())
                .cloned()
                .collect::<Vec<_>>()
        } else {
            vec![]
        };
        Ok(self.effect(
            "commitDetail",
            json!({"itemID":self.input["itemID"],"detail":self.content,"items":values}),
        ))
    }
    fn seasons_ready(&mut self, repo: &Repository, seasons: Value) -> Result<Value, String> {
        let id = compose(repo, "defaultSeason", json!({"seasons":seasons}))?;
        self.content["seasons"] = seasons;
        if id.is_null() {
            return self.detail_commit(repo, true, true);
        }
        self.content["episodesSeasonID"] = id.clone();
        Ok(self.effect(
            "loadDetailEpisodes",
            json!({"seriesID":self.input["itemID"],"seasonID":id}),
        ))
    }
    fn page_composed(&mut self, repo: &Repository, previous: Value) -> Result<Value, String> {
        let content = compose(
            repo,
            "page",
            json!({"items":self.content["items"],"totalRecordCount":self.content["totalRecordCount"],"startIndex":self.input["startIndex"],"limit":self.input["limit"],"previous":previous,"requestStartedAt":self.started}),
        )?;
        self.result = content.clone();
        Ok(self.effect("publishPage",json!({"descriptor":self.input["descriptor"],"pageContent":content,"items":self.content["items"]})))
    }
    fn begin(&mut self, repo: &mut Repository) -> Result<Value, String> {
        if self.kind.starts_with("cached") {
            return cached::begin(self, repo);
        }
        Ok(match self.kind.as_str() {
            "prefetch" => self.effect("loadPrefetchCache",json!({"itemID":self.input["itemID"]})),
            "home" => self.effect("loadHome",json!({"limit":24})),
            "detail" => {
                let kind=self.input["kindHint"].as_str().or(self.previous["item"]["kind"].as_str());
                let series=kind==Some("series");
                self.effect(if series { "loadSeries" } else { "loadDetailItem" },json!({"itemID":self.input["itemID"]}))
            }
            "page" => self.effect("fetchPage",json!({"descriptor":self.input["descriptor"],"startIndex":self.input["startIndex"],"limit":self.input["limit"]})),
            "item" => self.effect("fetchItem",json!({"itemID":self.input["itemID"]})),
            "episodes" => self.effect("fetchEpisodes",json!({"seriesID":self.input["seriesID"],"seasonID":self.input["seasonID"]})),
            _=>return Err("invalid refresh kind".into()),
        })
    }
    fn advance(
        &mut self,
        repo: &mut Repository,
        response: Value,
        now: f64,
    ) -> Result<Value, String> {
        if self.kind.starts_with("cached") {
            return cached::advance(self, repo, response, now);
        }
        let phase = self.phase.clone();
        match phase.as_str() {
            "loadPrefetchCache"=>{
                if !response.is_null() && response["source"]=="memory"{return Ok(self.done(json!({})));}
                Ok(self.effect("loadPrefetchDetail",json!({"itemID":self.input["itemID"],"kindHint":self.input["kindHint"]})))
            }
            "loadPrefetchDetail"=>Ok(self.done(json!({}))),
            "loadHome"=>{
                object(&response)?;
                for name in ["libraries","resume","nextUp","latest"] { part(&response[name],true)?; }
                self.parts=response;
                self.next_home(repo,0,now)
            }
            "saveLibraries"=>self.next_home(repo,1,now),
            "saveHome_resume"|"saveHome_nextUp"|"saveHome_latest"=>{
                items(&response)?;
                let name=phase.strip_prefix("saveHome_").unwrap();
                self.content[name]=if name=="nextUp" {
                    compose(repo,"nextUp",json!({"nextUp":response,"resume":self.content["resume"]}))?
                } else { response };
                self.next_home(repo,if name=="resume"{2}else if name=="nextUp"{3}else{4},now)
            }
            "commitHome"=>Ok(self.done(self.result.clone())),
            "loadSeries"=>{
                item(&response["item"])?;part(&response["seasons"],true)?;
                self.content=blank_detail(response["item"].clone());
                let p=&response["seasons"]; self.failure("seasons",p);
                if p["value"].is_null() {
                    let seasons=self.previous.get("seasons").cloned().unwrap_or(json!([]));
                    self.seasons_ready(repo,seasons)
                } else { Ok(self.save_items(p["value"].clone(),None,"saveSeasons")) }
            }
            "saveSeasons"=>{ items(&response)?;self.seasons_ready(repo,response) }
            "loadDetailEpisodes"=>{
                part(&response,true)?; self.failure("episodes",&response);
                self.content["episodes"]=if !response["value"].is_null(){response["value"].clone()}
                    else if identity(&self.previous["episodesSeasonID"])==identity(&self.content["episodesSeasonID"]) {self.previous.get("episodes").cloned().unwrap_or(json!([]))} else{json!([])};
                self.detail_commit(repo,true,true)
            }
            "loadDetailItem"=>{
                item(&response)?;
                let kind=self.input["kindHint"].as_str().or(self.previous["item"]["kind"].as_str());
                let members=response["kind"]=="boxSet"||kind==Some("boxSet");
                let series=response["kind"]=="series";
                self.content=blank_detail(response);
                if members { Ok(self.effect("loadMembers",json!({"descriptor":collection(&self.input["itemID"]),"startIndex":0,"limit":200}))) }
                else if series { Ok(self.effect("reloadDetail",json!({"itemID":self.input["itemID"]}))) }
                else{self.detail_commit(repo,false,false)}
            }
            "reloadDetail"=>{
                if !response.is_null() {
                    compose(repo,"detail",json!({"content":response,"requestStartedAt":now,"mergeProgress":false}))?;
                }
                self.previous=response;self.started=now;self.input["kindHint"]=json!("series");
                self.begin(repo)
            }
            "loadMembers"=>{
                part(&response,false)?;self.failure("members",&response);
                let page=&response["value"]["value"];
                let members=page.get("items").or(self.previous.get("collectionMembers")).cloned().unwrap_or(json!([]));items(&members)?;
                self.content["collectionMembers"]=members;
                let total=page.get("totalCount").filter(|v|!v.is_null()).or(self.previous.get("collectionMembersTotalCount"));
                if let Some(total)=total { if total.as_i64().is_none() {return Err("member count must be Int64".into());}self.content["collectionMembersTotalCount"]=total.clone(); }
                self.detail_commit(repo,true,false)
            }
            "commitDetail"=>Ok(self.done(json!({"snapshot":{"value":self.content,"fetchedAt":now,"source":"network"},"failures":self.failures}))),
            "fetchPage"=>{
                items(&response["items"])?;
                response["startIndex"].as_i64().ok_or("page startIndex required")?;
                if !response["totalRecordCount"].is_null() && response["totalRecordCount"].as_i64().is_none(){return Err("totalRecordCount must be Int64".into());}
                self.content=response;
                Ok(self.save_items(self.content["items"].clone(),None,"savePageItems"))
            }
            "savePageItems"=>{
                items(&response)?; self.content["items"]=response;
                if self.input["startIndex"]==0 {self.page_composed(repo,Value::Null)}
                else {Ok(self.effect("readPreviousPage",json!({"descriptor":self.input["descriptor"],"limit":self.input["limit"]})))}
            }
            "readPreviousPage"=>self.page_composed(repo,response),
            "publishPage"=>Ok(self.effect("savePage",json!({"page":self.content,"key":self.input["key"]}))),
            "savePage"=>{
                self.result["items"]=json!(progress::merged(repo,self.result["items"].as_array().unwrap().clone(),self.started));
                Ok(self.effect("commitPage",json!({"descriptor":self.input["descriptor"],"pageContent":self.result})))
            }
            "commitPage"=>Ok(self.done(json!({"value":self.result,"fetchedAt":now,"source":"network"}))),
            "fetchItem"=>{ item(&response)?;Ok(self.save_items(json!([response]),None,"saveItem")) }
            "saveItem"=>{
                items(&response)?;if response.as_array().unwrap().len()!=1{return Err("item save must return one item".into());}
                self.content=response[0].clone();
                Ok(self.effect("rememberItem",json!({"items":[self.content]})))
            }
            "rememberItem"=>{
                let key=self.input["itemID"].clone();
                let existing=repo.call("get",&json!({"bucket":"details","payloadJSON":json!({"key":key}).to_string()}))?;
                if existing.is_null() {return Ok(self.done(self.content.clone()));}
                let mut detail=existing["value"].clone();object(&detail)?;detail["item"]=self.content.clone();
                Ok(self.effect("commitItemDetail",json!({"itemID":key,"detail":detail})))
            }
            "commitItemDetail"=>Ok(self.done(self.content.clone())),
            "fetchEpisodes"=>{items(&response)?;Ok(self.save_items(response,None,"saveEpisodes"))}
            "saveEpisodes"=>{
                items(&response)?;self.content=response;
                Ok(self.effect("publishEpisodes",json!({"seriesID":self.input["seriesID"],"seasonID":self.input["seasonID"],"items":self.content})))
            }
            "publishEpisodes"=>{
                let key=self.input["seriesID"].clone();
                let entry=repo.call("get",&json!({"bucket":"details","payloadJSON":json!({"key":key}).to_string()}))?;
                if entry.is_null() || identity(&entry["value"]["episodesSeasonID"])!=identity(&self.input["seasonID"]) {return Ok(self.done(self.content.clone()));}
                let mut detail=entry["value"].clone();object(&detail)?;detail["episodes"]=self.content.clone();
                Ok(self.effect("commitEpisodeDetail",json!({"itemID":key,"detail":detail})))
            }
            "commitEpisodeDetail"=>Ok(self.done(self.content.clone())),
            _=>Err("invalid active phase".into()),
        }
    }
}
pub(super) fn call(repo: &mut Repository, method: &str, args: &Value) -> Result<Value, String> {
    if method == "stats" {
        return Ok(json!({"active":repo.flows.active.len(),"nextToken":repo.flows.next}));
    }
    let raw = args["payloadJSON"].as_str().ok_or("payloadJSON required")?;
    let mut v: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
    object(&v)?;
    if method == "collectionDescriptor" {
        string(&v, "itemID")?;
        return Ok(collection(&v["itemID"]));
    }
    if method == "pageKey" {
        return page_key(&v);
    }
    if method == "cancel" {
        let token = v["token"].as_u64().ok_or("token must be UInt64")?;
        return Ok(json!({"cancelled":repo.flows.active.remove(&token).is_some()}));
    }
    if method == "start" {
        let kind = string(&v, "kind")?;
        let now = clock(&v, "now")?;
        match kind.as_str() {
            "home" => {
                if !v["previous"].is_null() {
                    clock(&v["previous"], "fetchedAt")?;
                    if !["memory", "disk", "network"]
                        .contains(&v["previous"]["source"].as_str().unwrap_or(""))
                    {
                        return Err("invalid home source".into());
                    }
                    compose(
                        repo,
                        "home",
                        json!({"content":v["previous"]["value"],"requestStartedAt":now}),
                    )?;
                }
            }
            "detail" | "prefetch" => {
                string(&v, "itemID")?;
                if let Some(hint) = optional_string(&v, "kindHint")? {
                    if !KINDS.contains(&hint.as_str()) {
                        return Err("invalid kindHint".into());
                    }
                }
                if !v["previous"].is_null() {
                    compose(
                        repo,
                        "detail",
                        json!({"content":v["previous"],"requestStartedAt":now,"mergeProgress":false}),
                    )?;
                }
            }
            "item" | "cachedItem" | "cachedDetail" => {
                string(&v, "itemID")?;
            }
            "episodes" | "cachedEpisodes" => {
                string(&v, "seriesID")?;
                string(&v, "seasonID")?;
            }
            "page" | "cachedPage" => {
                v["key"] = page_key(&v)?;
            }
            "cachedHome" => {}
            _ => return Err("invalid refresh kind".into()),
        }
        if kind == "cachedDetail" {
            v["hasStore"].as_bool().ok_or("hasStore must be boolean")?;
        }
        if repo.flows.active.len() >= 1024 {
            return Err("too many active repository flows".into());
        }
        let token = repo
            .flows
            .next
            .checked_add(1)
            .ok_or("flow token exhausted")?;
        let previous = v.get("previous").cloned().unwrap_or(Value::Null);
        let content = if kind == "home" {
            previous.get("value").cloned().unwrap_or_else(blank_home)
        } else {
            Value::Null
        };
        let mut flow = Flow {
            kind,
            phase: String::new(),
            input: v,
            previous,
            content,
            parts: Value::Null,
            failures: json!({}),
            started: now,
            sequence: 0,
            result: Value::Null,
        };
        let mut result = flow.begin(repo)?;
        result["token"] = json!(token);
        repo.flows.next = token;
        if flow.phase != "done" {
            repo.flows.active.insert(token, flow);
        }
        return Ok(result);
    }
    if method == "resume" {
        let token = v["token"].as_u64().ok_or("token must be UInt64")?;
        let sequence = v["sequence"].as_u64().ok_or("sequence must be UInt64")?;
        let now = clock(&v, "now")?;
        let response: Value =
            serde_json::from_str(v["responseJSON"].as_str().ok_or("responseJSON required")?)
                .map_err(|e| e.to_string())?;
        let mut flow = repo
            .flows
            .active
            .get(&token)
            .cloned()
            .ok_or("flow not active")?;
        if flow.sequence != sequence {
            return Err("stale flow receipt".into());
        }
        flow.sequence = flow
            .sequence
            .checked_add(1)
            .ok_or("flow sequence exhausted")?;
        let mut result = flow.advance(repo, response, now)?;
        result["token"] = json!(token);
        if flow.phase == "done" {
            repo.flows.active.remove(&token);
        } else {
            repo.flows.active.insert(token, flow);
        }
        return Ok(result);
    }
    Err(format!("unknown flow method {method}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn invoke(r: &mut Repository, m: &str, v: Value) -> Value {
        call(r, m, &json!({"payloadJSON":v.to_string()})).unwrap()
    }
    fn begin(r: &mut Repository, kind: &str, extra: Value) -> Value {
        let mut v = json!({"kind":kind,"now":1.125});
        for (k, vv) in extra.as_object().unwrap() {
            v[k] = vv.clone();
        }
        invoke(r, "start", v)
    }
    fn resume(r: &mut Repository, s: &Value, response: Value) -> Value {
        invoke(
            r,
            "resume",
            json!({"token":s["token"],"sequence":s["sequence"],"now":4.125,"responseJSON":response.to_string()}),
        )
    }
    fn item(id: &str) -> Value {
        json!({"id":id,"kind":"movie","year":i64::MAX})
    }
    #[test]
    fn home_partial_effects_and_all_failure_source_match_native() {
        let mut r = Repository::default();
        let previous = json!({"value":{"libraries":[],"resume":[item("r")],"nextUp":[item("n")],"latest":[]},"source":"disk","fetchedAt":-10.125});
        let s = begin(&mut r, "home", json!({"previous":previous}));
        let error = json!({"message":"offline","isConnectivity":true});
        let s = resume(
            &mut r,
            &s,
            json!({"libraries":{"failure":error},"resume":{"failure":error},"nextUp":{},"latest":{"failure":error}}),
        );
        assert_eq!(s["effect"], "commitHome");
        assert_eq!(s["arguments"]["home"]["snapshot"], previous);
        assert!(s["arguments"]["home"]["failures"]["nextUp"].is_null());
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["done"], true);
        assert!(r.flows.is_empty());
        let s = begin(&mut r, "home", json!({}));
        let s = resume(
            &mut r,
            &s,
            json!({"libraries":{"value":[]},"resume":{"value":[item("é")]},"nextUp":{"value":[item("e\u{301}"),item("n")]},"latest":{}}),
        );
        assert_eq!(s["effect"], "saveLibraries");
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["effect"], "saveHome_resume");
        let s = resume(&mut r, &s, json!([item("é")]));
        assert_eq!(s["effect"], "saveHome_nextUp");
        let s = resume(&mut r, &s, json!([item("e\u{301}"), item("n")]));
        assert_eq!(
            s["arguments"]["home"]["snapshot"]["value"]["nextUp"],
            json!([item("n")])
        );
        assert_eq!(s["arguments"]["home"]["snapshot"]["source"], "network");
    }
    #[test]
    fn series_retry_fallback_and_collection_nil_total_are_retained() {
        let mut r = Repository::default();
        let s = begin(&mut r, "detail", json!({"itemID":"s"}));
        let s = resume(&mut r, &s, json!({"id":"s","kind":"series"}));
        assert_eq!(s["effect"], "reloadDetail");
        let prev = json!({"item":{"id":"s","kind":"series"},"seasons":[{"id":"é","seasonNumber":1}],"episodesSeasonID":"e\u{301}","episodes":[item("cached")],"collectionMembers":[]});
        let s = resume(&mut r, &s, prev);
        assert_eq!(s["effect"], "loadSeries");
        let s = resume(
            &mut r,
            &s,
            json!({"item":{"id":"s","kind":"series"},"seasons":{}}),
        );
        assert_eq!(s["effect"], "loadDetailEpisodes");
        assert_eq!(s["arguments"]["seasonID"], "é");
        let s = resume(
            &mut r,
            &s,
            json!({"failure":{"message":"cancel","isConnectivity":false}}),
        );
        assert_eq!(
            s["arguments"]["detail"]["episodes"],
            json!([item("cached")])
        );
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["result"]["failures"]["episodes"]["message"], "cancel");
        let prev = json!({"item":{"id":"c","kind":"boxSet"},"seasons":[],"episodes":[],"collectionMembers":[item("previous")],"collectionMembersTotalCount":i64::MAX});
        let s = begin(&mut r, "detail", json!({"itemID":"c","previous":prev}));
        let s = resume(&mut r, &s, item("c"));
        assert_eq!(s["effect"], "loadMembers");
        assert_eq!(s["arguments"]["descriptor"], collection(&json!("c")));
        let s = resume(
            &mut r,
            &s,
            json!({"value":{"value":{"items":[item("new")],"nextStartIndex":1,"lastPageWasFull":false},"source":"network","fetchedAt":1}}),
        );
        assert_eq!(
            s["arguments"]["detail"]["collectionMembersTotalCount"],
            i64::MAX
        );
    }
    #[test]
    fn page_rechecks_progress_after_persist_and_receipts_do_not_replay() {
        let mut r = Repository::default();
        let s = begin(
            &mut r,
            "page",
            json!({"descriptor":{"parentID":"lib","recursive":true},"startIndex":0,"limit":1}),
        );
        let payload =
            json!({"token":s["token"],"sequence":s["sequence"],"now":2,"responseJSON":"{}"});
        assert!(call(
            &mut r,
            "resume",
            &json!({"payloadJSON":payload.to_string()})
        )
        .is_err());
        assert_eq!(r.flows.active.len(), 1);
        let first = s.clone();
        let s = resume(
            &mut r,
            &s,
            json!({"items":[item("é")],"startIndex":0,"totalRecordCount":i64::MAX}),
        );
        let stale = json!({"token":first["token"],"sequence":first["sequence"],"now":2,"responseJSON":"{}"});
        assert!(call(&mut r, "resume", &json!({"payloadJSON":stale.to_string()})).is_err());
        let s = resume(&mut r, &s, json!([item("é")]));
        assert_eq!(s["effect"], "publishPage");
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["effect"], "savePage");
        r.call("progress.beginFinal",&json!({"payloadJSON":json!({"item":item("e\u{301}"),"recordedAt":3,"positionSeconds":42}).to_string()})).unwrap();
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["effect"], "commitPage");
        assert_eq!(
            s["arguments"]["pageContent"]["items"][0]["playState"]["positionSeconds"].as_f64(),
            Some(42.0)
        );
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["done"], true);
        assert!(r.flows.is_empty());
        let s = begin(&mut r, "item", json!({"itemID":"i"}));
        r.call("progress.shutdown", &json!({})).unwrap();
        assert!(!r.flows.is_empty());
        assert_eq!(
            invoke(&mut r, "cancel", json!({"token":s["token"]}))["cancelled"],
            true
        );
        assert_eq!(
            invoke(&mut r, "cancel", json!({"token":s["token"]}))["cancelled"],
            false
        );
    }
    #[test]
    fn cached_flows_preserve_nil_memory_hits_and_full_row_age() {
        let mut r = Repository::default();
        let s = begin(&mut r, "cachedHome", json!({}));
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["done"], true);
        assert_eq!(s["result"], Value::Null);
        assert!(r.flows.is_empty());
        r.call("put",&json!({"bucket":"items","payloadJSON":json!({"key":"é","entry":{"value":item("e\u{301}"),"fetchedAt":-20.125}}).to_string()})).unwrap();
        let s = begin(&mut r, "cachedItem", json!({"itemID":"é"}));
        assert_eq!(s["done"], true);
        assert_eq!(s["result"]["source"], "memory");
        assert!(r.flows.is_empty());
        let s = begin(
            &mut r,
            "cachedPage",
            json!({"descriptor":{"parentID":"lib","recursive":true},"startIndex":0,"limit":1}),
        );
        let s = resume(
            &mut r,
            &s,
            json!([
            {"items":[item("first")],"startIndex":0,"limit":1,"fetchedAt":10},
            {"items":[item("gap")],"startIndex":2,"limit":1,"fetchedAt":-100.125}]),
        );
        assert_eq!(s["effect"], "commitCachedPage");
        assert_eq!(
            s["arguments"]["pageSnapshot"]["fetchedAt"].as_f64(),
            Some(-100.125)
        );
        assert_eq!(
            s["arguments"]["pageSnapshot"]["value"]["items"],
            json!([item("first")])
        );
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["result"]["source"], "disk");
        assert!(r.flows.is_empty());
    }
    #[test]
    fn cached_series_effects_and_empty_episode_list_keep_native_schema() {
        let mut r = Repository::default();
        let s = begin(
            &mut r,
            "cachedDetail",
            json!({"itemID":"s","hasStore":true}),
        );
        let s = resume(
            &mut r,
            &s,
            json!({"item":{"id":"s","kind":"series"},"fetchedAt":-4.125}),
        );
        assert_eq!(s["effect"], "readCachedSeasons");
        let s = resume(
            &mut r,
            &s,
            json!([{"id":"special","seasonNumber":0},{"id":"missing"}]),
        );
        assert_eq!(s["effect"], "readDetailCachedEpisodes");
        assert_eq!(s["arguments"]["seasonID"], "missing");
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["effect"], "commitCachedDetail");
        assert_eq!(
            s["arguments"]["detailSnapshot"]["value"]["episodes"],
            json!([])
        );
        let s = resume(&mut r, &s, Value::Null);
        assert_eq!(s["result"]["fetchedAt"].as_f64(), Some(-4.125));
        let s = begin(
            &mut r,
            "cachedEpisodes",
            json!({"seriesID":"s","seasonID":"season"}),
        );
        let s = resume(&mut r, &s, json!([]));
        assert_eq!(s["result"], Value::Null);
        assert!(r.flows.is_empty());
    }
}
