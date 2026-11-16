using System.Text.Json;
using Windows.Security.Credentials;

namespace OcPlayer.Windows.Services;

internal sealed record SavedServer(string Id, string Name, string Kind, string UserName, bool NeedsLogin = false);
internal sealed record ServerProfileIndex(SavedServer[] Servers, string? ActiveId, string? DefaultId, bool AutoConnect = true);

// Each server/account has its own vault credential. The index contains no tokens.
internal sealed class ServerProfiles
{
    private readonly string _resource, _path;
    private ServerProfileIndex _index = new([], null, null);
    public IReadOnlyList<SavedServer> Items => _index.Servers;
    public string? DefaultId => _index.DefaultId;
    public string? ActiveId => _index.ActiveId;
    public ServerProfiles(string directory, string resource)
    {
        _resource = resource; _path = Path.Combine(directory, "servers.json");
        try { _index = JsonSerializer.Deserialize<ServerProfileIndex>(File.ReadAllText(_path)) ?? _index; }
        catch (Exception ex) when (ex is IOException or JsonException) { }
        if (_index.Servers.Length == 0)
        {
            var legacy = ReadCredential("active-server");
            if (legacy is not null) Save(legacy, true);
        }
    }
    private ServerProfile? ReadCredential(string key)
    {
        try
        {
            var credential = new PasswordVault().Retrieve(_resource, key); credential.RetrievePassword();
            return JsonSerializer.Deserialize<ServerProfile>(credential.Password, MediaServer.JsonOptions);
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or JsonException) { return null; }
    }
    public ServerProfile? Get(string id) => ReadCredential("server:" + id);
    public ServerProfile? Startup() => _index.AutoConnect && (_index.DefaultId ?? _index.ActiveId) is { } id && Items.Any(x => x.Id == id && !x.NeedsLogin) ? Get(id) : null;
    public void Save(ServerProfile profile, bool activate = false)
    {
        new PasswordVault().Add(new PasswordCredential(_resource, "server:" + profile.Id, JsonSerializer.Serialize(profile, MediaServer.JsonOptions)));
        var entry = new SavedServer(profile.Id, profile.DisplayName, profile.Kind, profile.UserName ?? "", string.IsNullOrEmpty(profile.Token));
        _index = _index with { Servers = _index.Servers.Where(x => x.Id != profile.Id).Append(entry).ToArray(), ActiveId = activate ? profile.Id : _index.ActiveId };
        Persist();
    }
    public void SetDefault(string? id) { _index = _index with { DefaultId = id, AutoConnect = id is not null }; Persist(); }
    public void Deactivate() { _index = _index with { ActiveId = null }; Persist(); }
    public void Invalidate(string id) { if (Get(id) is { } p) Save(p with { Token = null }); }
    public void Delete(string id)
    {
        var vault = new PasswordVault();
        try { vault.Remove(vault.Retrieve(_resource, "server:" + id)); } catch (System.Runtime.InteropServices.COMException) { }
        // Remove the obsolete single-server entry too, so deletion cannot resurrect it on migration.
        if (ReadCredential("active-server")?.Id == id)
            try { vault.Remove(vault.Retrieve(_resource, "active-server")); } catch (System.Runtime.InteropServices.COMException) { }
        _index = _index with { Servers = _index.Servers.Where(x => x.Id != id).ToArray(), ActiveId = _index.ActiveId == id ? null : _index.ActiveId, DefaultId = _index.DefaultId == id ? null : _index.DefaultId };
        Persist();
    }
    private void Persist()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path + ".tmp", JsonSerializer.Serialize(_index)); File.Move(_path + ".tmp", _path, true);
    }
}
