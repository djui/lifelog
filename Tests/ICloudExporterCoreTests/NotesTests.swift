import Foundation
import XCTest
@testable import ICloudExporterCore

final class NotesTests: XCTestCase {
    func testConvertsNoteStructureAndEntities() {
        let html = """
        <html><head><style>ignored</style></head><body>
        <h1>A &amp; B</h1><div>One&nbsp;two <b>bold</b> and <i>italic</i>.</div>
        <div>Next<br>line &#x1F680; &lt;literal&gt;</div>
        <ul><li>First<ul><li>Nested</li></ul></li><li>Second</li></ul>
        <ol start="3"><li>Third</li><li value="7">Seventh</li></ol>
        </body></html>
        """
        XCTAssertEqual(NotesHTML.markdown(from: html), """
        # A & B

        One two **bold** and *italic*.

        Next
        line 🚀 \\<literal\\>

        - First
            - Nested
        - Second

        3. Third
        7. Seventh
        """)
    }

    func testLinksImagesAndAttachmentsStayLocalAndInert() {
        let html = """
        <p><a href="https://example.com/a%20b?q=(x)&amp;n=1">Link</a>
        <a href="javascript:alert(1)">unsafe link</a></p>
        <img src="https://example.com/tracker" alt="An image">
        <object data="cid:attachment"></object><script>alert('ignored')</script>
        """
        let markdown = NotesHTML.markdown(from: html)
        XCTAssertTrue(markdown.contains("[Link](https://example.com/a%20b?q=%28x%29&n=1)"))
        XCTAssertTrue(markdown.contains("unsafe link"))
        XCTAssertTrue(markdown.contains("[An image]"))
        XCTAssertTrue(markdown.contains("[Attachment]"))
        XCTAssertFalse(markdown.contains("javascript:"))
        XCTAssertFalse(markdown.contains("tracker"))
        XCTAssertFalse(markdown.contains("alert"))
    }

    func testTableCheckboxAndCode() {
        let html = """
        <table><thead><tr><th>Name</th><th>Value</th></tr></thead>
        <tbody><tr><td>A | B</td><td>One<br>two</td></tr></tbody></table>
        <ul><li><input type="checkbox" checked>Done</li><li><input type="checkbox">Open</li></ul>
        <pre>let x = &quot;```&quot;\n  print(x)</pre>
        """
        let markdown = NotesHTML.markdown(from: html)
        XCTAssertTrue(markdown.contains("| Name | Value |\n| --- | --- |\n| A \\| B | One<br>two |"))
        XCTAssertTrue(markdown.contains("- [x] Done\n- [ ] Open"))
        XCTAssertTrue(markdown.contains("````\nlet x = \"```\"\n  print(x)\n````"))
    }

    func testQuotedAngleBracketAndMalformedHTML() {
        XCTAssertEqual(NotesHTML.markdown(from: "<div title='a > b'>Visible &amp; safe</div><p>Unclosed"),
                       "Visible & safe\n\nUnclosed")
        XCTAssertEqual(NotesHTML.markdown(from: "<ul><li>One<li>Two</ul>"), "- One\n- Two")
    }

    func testDecodeNotesSupportsFractionalAndWholeSecondDates() throws {
        let data = Data("""
        {"records":[{"id":"note-1","title":"Example","account":"Local","folder":"Work/Subfolder", "created":"2026-09-07T08:00:00.123Z","modified":"2026-09-07T09:00:00Z", "bodyHTML":"<div>Text</div>"}], "warnings":["1 password-protected note(s) were skipped."]}
        """.utf8)
        let result = try NotesExporter.decode(data)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].folder, "Work/Subfolder")
        XCTAssertNotNil(result.records[0].created)
        XCTAssertNotNil(result.records[0].modified)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testDecodeRejectsPartialOrInvalidSnapshots() {
        for json in [
            "not JSON",
            #"{"records":[],"warnings":[]"#,
            #"{"records":[{"id":"1","title":"secret"}],"warnings":[]}"#,
            #"{"records":[{"id":"1","title":"secret","account":"A","folder":"F","created":"bad","bodyHTML":"private"}],"warnings":[]}"#,
            #"{"records":[{"id":"1","title":"T","account":"A","folder":"F","bodyHTML":"X"},{"id":"1","title":"T","account":"A","folder":"F","bodyHTML":"X"}],"warnings":[]}"#
        ] {
            XCTAssertThrowsError(try NotesExporter.decode(Data(json.utf8))) { error in
                XCTAssertTrue(error is NotesExportError)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
        XCTAssertNoThrow(try NotesExporter.decode(Data(#"{"records":[],"warnings":[]}"#.utf8)))
    }

    func testProcessDrainsLargeOutputWithoutAccessingNotes() throws {
        let script = try fixtureScript("function run() { return Array(262145).join('x'); }")
        defer { try? FileManager.default.removeItem(at: script) }
        let output = try NotesExporter.run(script: script, timeout: 10)
        XCTAssertGreaterThanOrEqual(output.count, 262_144)
    }

    func testBundledScriptTraversesNestedFoldersAndSkipsProtectedNotes() throws {
        let original = try String(contentsOf: XCTUnwrap(NotesExporter.scriptURL))
        // Replace the JXA Application constructor call so the real traversal code
        // runs against synthetic objects and never sends an Apple event.
        let fixture = """
        var account, parent, child, openNote, protectedNote;
        function note(id, locked) {
          return { id: function() { return id; }, passwordProtected: function() { return locked; },
            name: function() { return 'Example'; }, container: function() { return child; },
            creationDate: function() { return new Date('2026-09-07T08:00:00Z'); },
            modificationDate: function() { return null; },
            body: function() { if (locked) throw new Error('must not read locked note'); return '<p>Text</p>'; } };
        }
        openNote = note('open', false); protectedNote = note('locked', true);
        child = { id: function() { return 'child'; }, name: function() { return 'Child'; },
          container: function() { return parent; }, folders: function() { return []; },
          notes: function() { return [openNote, protectedNote]; } };
        parent = { id: function() { return 'parent'; }, name: function() { return 'Parent'; },
          container: function() { return account; }, folders: function() { return [child]; },
          notes: function() { return []; } };
        account = { id: function() { return 'account'; }, name: function() { return 'Local'; },
          folders: function() { return [parent, child]; }, notes: function() { return [openNote, protectedNote]; } };
        var MockApplication = function() { return { accounts: function() { return [account]; } }; };
        """
        XCTAssertTrue(original.contains("Application(\"Notes\")"))
        let mocked = original.replacingOccurrences(of: "Application(\"Notes\")", with: "MockApplication()")
        let script = try fixtureScript(fixture + "\n" + mocked)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try NotesExporter.decode(NotesExporter.run(script: script, timeout: 10))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.folder, "Parent/Child")
        XCTAssertEqual(result.warnings, ["1 password-protected note(s) were skipped."])
    }

    func testProcessTimeoutWithoutAccessingNotes() throws {
        let script = try fixtureScript("function run() { while (true) {} }")
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertThrowsError(try NotesExporter.run(script: script, timeout: 0.1)) { error in
            guard case NotesExportError.timedOut = error else {
                return XCTFail("Expected a sanitized timeout error")
            }
        }
    }

    func testProcessErrorDoesNotExposeScriptError() throws {
        let script = try fixtureScript("function run() { throw new Error('private note text'); }")
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertThrowsError(try NotesExporter.run(script: script, timeout: 10)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private note text"))
            guard case NotesExportError.failed = error else {
                return XCTFail("Expected a sanitized process failure")
            }
        }
    }

    private func fixtureScript(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-test-\(UUID().uuidString).js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
