// Executed by osascript, never by a browser. No note content is written to logs.
// Bulk specifier reads for metadata; per-note body() because a single Apple Event
// of every note body can exceed the reply size and fail with -1741.
// argv[0] is a snapshot path so osascript does not have to return hundreds of MB.
function run(argv) {
    var notes = Application("Notes");
    var records = [];
    var omittedImages = 0;
    var omittedAttachments = 0;

    function dateString(value) {
        if (value === null || value === undefined) return null;
        if (!(value instanceof Date) || !isFinite(value.getTime())) {
            throw new Error("Invalid Notes date.");
        }
        return value.toISOString();
    }

    function asArray(value) {
        if (value === null || value === undefined) return [];
        if (Object.prototype.toString.call(value) === "[object Array]") return value;
        if (typeof value !== "string" && typeof value.length === "number") {
            return Array.prototype.slice.call(value);
        }
        return [value];
    }

    function values(collection, property) {
        try {
            var bulk = collection[property]();
            if (bulk !== undefined && bulk !== null) return asArray(bulk);
        } catch (e) {}
        var items = collection();
        var out = [];
        for (var i = 0; i < items.length; i++) out.push(items[i][property]());
        return out;
    }

    function containerIDs(collection) {
        try {
            var bulk = collection.container.id();
            if (bulk !== undefined && bulk !== null) return asArray(bulk);
        } catch (e) {}
        var containers = values(collection, "container");
        var out = [];
        for (var i = 0; i < containers.length; i++) out.push(containers[i].id());
        return out;
    }

    function progress(message) {
        console.log("NOTES_PROGRESS " + message);
    }

    function folderPaths(account, accountID) {
        var paths = Object.create(null);
        var seen = Object.create(null);
        function walk(folder) {
            var id = String(folder.id());
            if (seen[id]) return;
            seen[id] = true;
            var children = folder.folders();
            for (var c = 0; c < children.length; c++) walk(children[c]);
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
            paths[id] = parts.join("/");
        }
        var folders = account.folders();
        for (var f = 0; f < folders.length; f++) walk(folders[f]);
        return paths;
    }

    try {
        var accounts = notes.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var account = accounts[a];
            var accountName = String(account.name());
            var accountID = String(account.id());
            progress("reading account " + (a + 1) + "/" + accounts.length);
            var paths = folderPaths(account, accountID);
            var collection = account.notes;
            var ids = values(collection, "id");
            var titles = values(collection, "name");
            var locked = values(collection, "passwordProtected");
            var created = values(collection, "creationDate");
            var modified = values(collection, "modificationDate");
            var folders = containerIDs(collection);
            if (ids.length !== titles.length || ids.length !== locked.length ||
                ids.length !== created.length || ids.length !== modified.length ||
                ids.length !== folders.length) {
                throw new Error("NOTES_READ_FAILED");
            }
            progress(ids.length + " notes in this account; reading bodies");
            var items = collection();
            if (items.length !== ids.length) throw new Error("NOTES_READ_FAILED");
            var seen = Object.create(null);
            for (var i = 0; i < ids.length; i++) {
                var id = String(ids[i]);
                if (!id || seen[id]) throw new Error("NOTES_READ_FAILED");
                seen[id] = true;
                var folderID = String(folders[i]);
                // Locked notes become body-less stubs so a newly locked note does not look deleted.
                // Their title, dates and folder are readable without unlocking.
                if (locked[i]) {
                    records.push({
                        id: id,
                        title: String(titles[i]),
                        account: accountName,
                        folder: paths[folderID] || "",
                        folderID: folderID,
                        created: dateString(created[i]),
                        modified: dateString(modified[i]),
                        bodyHTML: "",
                        locked: true
                    });
                    continue;
                }
                var media = stripMedia(String(items[i].body()));
                records.push({
                    id: id,
                    title: String(titles[i]),
                    account: accountName,
                    folder: paths[folderID] || "",
                    folderID: folderID,
                    created: dateString(created[i]),
                    modified: dateString(modified[i]),
                    bodyHTML: media.html,
                    locked: false
                });
                omittedImages += media.images;
                omittedAttachments += media.attachments;
                if (records.length % 25 === 0) progress("read " + records.length + " notes");
            }
        }
    } catch (error) {
        // Abort instead of returning a partial snapshot that could prune notes.
        // Do not let Apple-event errors echo note bodies or other private data.
        if (error.number === -1743) throw new Error("NOTES_AUTOMATION_DENIED");
        throw new Error("NOTES_READ_FAILED");
    }

    progress("encoding " + records.length + " notes");
    // NotesExporter.decode adds the password-protected warning when it drops locked stubs.
    var warnings = [];
    if (omittedImages > 0 || omittedAttachments > 0) {
        var parts = [];
        if (omittedImages > 0) parts.push(omittedImages === 1 ? "1 embedded image" : String(omittedImages) + " embedded images");
        if (omittedAttachments > 0) parts.push(omittedAttachments === 1 ? "1 attachment" : String(omittedAttachments) + " attachments");
        warnings.push(parts.join(" and ") + (omittedImages + omittedAttachments === 1 ? " was omitted." : " were omitted."));
    }
    var payload = { records: records, warnings: warnings };
    var dest = argv && argv.length > 0 ? String(argv[0]) : "";
    if (dest) {
        writeSnapshot(dest, payload);
        return "ok";
    }
    return JSON.stringify(payload);
}

function stripMedia(html) {
    var images = 0;
    var attachments = 0;
    var out = html.replace(/<img\b[^>]*>/gi, function(tag) {
        images += 1;
        var alt = /\balt\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(tag);
        var label = alt && (alt[1] || alt[2]) ? (alt[1] || alt[2]) : "Image";
        return '<img alt="' + String(label).replace(/"/g, "") + '">';
    });
    out = out.replace(/<(object|embed)\b[^>]*>[\s\S]*?<\/\1>/gi, function() {
        attachments += 1;
        return "<object></object>";
    });
    out = out.replace(/<(embed\b[^>]*|object\s[^>]*)\/?>/gi, function() {
        attachments += 1;
        return "<object></object>";
    });
    out = out.replace(/\s(?:src|href|data)\s*=\s*["']data:[^"']*["']/gi, "");
    return { html: out, images: images, attachments: attachments };
}

function writeSnapshot(path, payload) {
    ObjC.import("Foundation");
    var error = $();
    var ok = $(JSON.stringify(payload)).writeToFileAtomicallyEncodingError(
        path, true, $.NSUTF8StringEncoding, error
    );
    if (!ok) throw new Error("NOTES_READ_FAILED");
}
