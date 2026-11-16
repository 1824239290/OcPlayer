using Windows.Storage;

namespace OcPlayer.Windows.Services;

internal static class ShareableMediaFile
{
    internal static async Task<StorageFile> PrepareAsync(string path)
    {
        path = Path.GetFullPath(path);
        try { return await StorageFile.GetFileFromPathAsync(path); }
        catch (UnauthorizedAccessException)
        {
            // A desktop process can read a file that the WinRT storage broker rejects.
            // A streamed file is supported by share contracts and reads only on demand.
            return await StorageFile.CreateStreamedFileAsync(Path.GetFileName(path),
                request => ProvideFile(path, request), null);
        }
    }

    private static async void ProvideFile(string path, StreamedFileDataRequest request)
    {
        Stream? destination = null;
        try
        {
            using var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            destination = request.AsStreamForWrite();
            await source.CopyToAsync(destination, 64 * 1024).ConfigureAwait(false);
            await destination.FlushAsync().ConfigureAwait(false);
        }
        catch
        {
            // Signal failure to the requesting share target; never let an async callback
            // terminate playback when a removed or inaccessible source cannot be read.
            try { request.FailAndClose(StreamedFileFailureMode.Incomplete); }
            catch { /* The target may already have closed or cancelled its request. */ }
        }
        finally
        {
            // Failure must be signalled before closing the adapter so a partial copy
            // cannot be mistaken for a successfully completed file.
            try { destination?.Dispose(); request.Dispose(); }
            catch { /* A cancelled request may already be closed. */ }
        }
    }
}
