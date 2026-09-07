// Executed by osascript, never by a browser. No note content is written to logs.
function run() {
    var notes = Application("Notes");
    var records = [];
    var seenNotes = Object.create(null);
    var seenFolders = Object.create(null);
    var folderPaths = Object.create(null);
    var protectedCount = 0;

    function dateString(value) {
        if (value === null || value === undefined) return null;
        if (!(value instanceof Date) || !isFinite(value.getTime())) {
            throw new Error("Invalid Notes date.");
        }
        return value.toISOString();
    }

    function folderPath(folder, accountID) {
        var id = String(folder.id());
        if (folderPaths[id] !== undefined) return folderPaths[id];
        var parts = [];
        var visited = Object.create(null);
        var current = folder;
        while (String(current.id()) !== accountID) {
            var currentID = String(current.id());
            if (visited[currentID]) throw new Error("Invalid Notes folder hierarchy.");
            visited[currentID] = true;
            parts.unshift(String(current.name()));
            current = current.container();
        }
        var path = parts.join("/");
        folderPaths[id] = path;
        return path;
    }

    function collectNote(note, accountName, accountID) {
        var id = String(note.id());
        if (seenNotes[id]) return;
        seenNotes[id] = true;
        // Deliberately skip all password-protected notes, including unlocked ones.
        if (note.passwordProtected()) {
            protectedCount += 1;
            return;
        }
        records.push({
            id: id,
            title: String(note.name()),
            account: accountName,
            folder: folderPath(note.container(), accountID),
            created: dateString(note.creationDate()),
            modified: dateString(note.modificationDate()),
            bodyHTML: String(note.body())
        });
    }

    function collectFolder(folder, accountName, accountID) {
        var id = String(folder.id());
        if (seenFolders[id]) return;
        seenFolders[id] = true;
        var children = folder.folders();
        for (var c = 0; c < children.length; c++) {
            collectFolder(children[c], accountName, accountID);
        }
        var items = folder.notes();
        for (var n = 0; n < items.length; n++) {
            collectNote(items[n], accountName, accountID);
        }
    }

    try {
        var accounts = notes.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var account = accounts[a];
            var accountName = String(account.name());
            var accountID = String(account.id());
            var folders = account.folders();
            for (var f = 0; f < folders.length; f++) {
                collectFolder(folders[f], accountName, accountID);
            }
            // Also inspect the account collection; deduplication makes this safe
            // whether Notes exposes direct notes or every descendant here.
            var items = account.notes();
            for (var n = 0; n < items.length; n++) {
                collectNote(items[n], accountName, accountID);
            }
        }
    } catch (error) {
        // Abort instead of returning a partial snapshot that could prune notes.
        // Do not let Apple-event errors echo note bodies or other private data.
        if (error.number === -1743) throw new Error("NOTES_AUTOMATION_DENIED");
        throw new Error("NOTES_READ_FAILED");
    }

    var warnings = [];
    if (protectedCount > 0) {
        warnings.push(String(protectedCount) + " password-protected note(s) were skipped.");
    }
    return JSON.stringify({ records: records, warnings: warnings });
}
