import Foundation
import Testing

@testable import DirnexCore

/// The nginx and `.env` scanners, and routing a file by its contents when its name does not settle
/// it (docs/HISTORY.md, 2026-09-16).
@Suite("SyntaxNginx, SyntaxDotenv and routing by contents")
struct SyntaxConfigurationScannerTests {
    private typealias Span = SyntaxSpan

    private func nginx(_ text: String) -> [Span] { syntaxSpans(text, .nginx) }
    private func dotenv(_ text: String) -> [Span] { syntaxSpans(text, .dotenv) }

    // MARK: - nginx

    @Test("a directive is the first word of a statement, and the same word in a value is not")
    func directivesStartStatements() {
        let source = """
        server {
            listen 80;
            location / {
                index index.html;
                try_files $uri $uri/ /index.html;
                proxy_pass http://backend:8000;
            }
        }
        """
        // The case a keyword list gets wrong: `index` is a directive and a file name on one line,
        // and `http` is a block name and every upstream's scheme.
        #expect(nginx(source) == [
            Span("server", .keyword),
            Span("listen", .keyword),
            Span("80", .number),
            Span("location", .keyword),
            Span("index", .keyword),
            Span("try_files", .keyword),
            Span("$uri", .typeOrTag),
            Span("$uri", .typeOrTag),
            Span("proxy_pass", .keyword)
        ])
    }

    @Test("a variable is marked wherever it sits in a value, and a bare $ is a regex anchor")
    func variables() {
        let source = """
        proxy_set_header Host $host$request_uri;
        return 301 https://${host}/new;
        rewrite ^/old/(.*)$ /$1 last;
        """
        #expect(nginx(source) == [
            Span("proxy_set_header", .keyword),
            Span("$host", .typeOrTag),
            Span("$request_uri", .typeOrTag),
            Span("return", .keyword),
            Span("301", .number),
            Span("${host}", .typeOrTag),
            Span("rewrite", .keyword),
            Span("$1", .typeOrTag)
        ])
    }

    @Test("a statement may continue across lines, and only a ; or a brace ends it")
    func multiLineStatement() {
        let source = """
        log_format main '$remote_addr'
                        '$status';
        access_log off; events { worker_connections 1024; }
        """
        #expect(nginx(source) == [
            Span("log_format", .keyword),
            Span("'$remote_addr'", .string),
            Span("'$status'", .string),
            Span("access_log", .keyword),
            Span("events", .keyword),
            Span("worker_connections", .keyword),
            Span("1024", .number)
        ])
    }

    @Test("a # starts a comment only where a word could, and a ; in a string ends nothing")
    func commentsAndStrings() {
        let source = """
        # main site
        add_header X-Note "a;b" always; # tail
        return 302 http://x/#top;
        """
        #expect(nginx(source) == [
            Span("# main site", .comment),
            Span("add_header", .keyword),
            Span("\"a;b\"", .string),
            Span("# tail", .comment),
            Span("return", .keyword),
            Span("302", .number)
        ])
    }

    @Test("a string with no closer stops at the line break")
    func unterminatedString() {
        #expect(nginx("set $a \"open\nx;") == [
            Span("set", .keyword),
            Span("$a", .typeOrTag),
            Span("\"open", .string)
        ])
    }

    // MARK: - Routing by contents

    private let nginxSite = """
    server {
        listen 80;
        server_name localhost;
    }
    """

    @Test("a .conf, or a name that claims nothing, is nginx when it reads as nginx")
    func nginxByContents() {
        #expect(SyntaxLanguage.forFile(named: "default.conf", text: nginxSite) == .nginx)
        // Debian's `sites-available/default`, and the `proxy/conf` of a Compose sample in `~/Dev`.
        #expect(SyntaxLanguage.forFile(named: "default", text: nginxSite) == .nginx)
        #expect(SyntaxLanguage.forFile(named: "conf", text: nginxSite) == .nginx)
    }

    /// The narrowness half: each is a shape the measurement over this Mac's `.conf` files met.
    @Test("a configuration that is not nginx's is not read as nginx")
    func otherConfigurationsStayINI() {
        // `racoon.conf`: statements end in `;` and blocks open with `{`, but none is nginx's.
        let racoon = "path include \"/etc/racoon\";\nremote anonymous {\n    proposal_check obey;\n}\n"
        #expect(SyntaxLanguage.forFile(named: "racoon.conf", text: racoon) == .ini)
        let apache = "ServerRoot \"/usr\"\n<VirtualHost *:80>\n    DocumentRoot /srv\n</VirtualHost>\n"
        #expect(SyntaxLanguage.forFile(named: "httpd.conf", text: apache) == .ini)
        // An HCL `server` block has no `;` statement.
        let hcl = "server {\n  enabled = true\n}\n"
        #expect(SyntaxLanguage.forFile(named: "agent", text: hcl) == nil)
        // A name that claims a language keeps it, whatever the text looks like.
        #expect(SyntaxLanguage.forFile(named: "Server.swift", text: nginxSite) == .swift)
    }

    @Test("nginx's shape is looked for in the first lines only")
    func nginxLineLimit() {
        let preamble = String(repeating: "key value;\n", count: 600)
        #expect(!SyntaxNginxScanner.looksLikeConfiguration(preamble + "server {\n"))
        #expect(SyntaxNginxScanner.looksLikeConfiguration("key value;\r\nhttp {\r\n"))
    }

    @Test("an XML declaration makes a .conf, or a name that claims nothing, markup")
    func xmlByContents() {
        let fontconfig = "<?xml version=\"1.0\"?>\n<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n<fontconfig/>\n"
        #expect(SyntaxLanguage.forFile(named: "60-latin.conf", text: fontconfig) == .markup)
        #expect(SyntaxLanguage.forFile(named: "profile.mobileconfig", text: fontconfig) == .markup)
        // It has to open the file.
        #expect(SyntaxLanguage.forFile(named: "notes", text: "see <?xml version?>\n") == nil)
    }

    // MARK: - .env

    @Test("a key, its value and a comment, with export and the forms a value takes")
    func keysAndValues() {
        let source = """
        # Database
        export DB_HOST=localhost
        PORT = 5432 # default
        CONNECTION=Host=db;Port=5432;Password=p#1
        COLOR=#fff
        EMPTY= # nothing
        """
        #expect(dotenv(source) == [
            Span("# Database", .comment),
            Span("export", .keyword),
            Span("DB_HOST", .keyword),
            Span("localhost", .string),
            Span("PORT", .keyword),
            Span("5432", .string),
            Span("# default", .comment),
            Span("CONNECTION", .keyword),
            Span("Host=db;Port=5432;Password=p#1", .string),
            Span("COLOR", .keyword),
            Span("#fff", .string),
            Span("EMPTY", .keyword),
            Span("# nothing", .comment)
        ])
    }

    @Test("a quoted value takes escapes, may cross lines, and carries a comment after it")
    func quotedValues() {
        let source = """
        GREETING="say \\"hi\\"" # quoted
        KEY="-----BEGIN
        abc
        -----END"
        NEXT='single # not a comment'
        """
        #expect(dotenv(source) == [
            Span("GREETING", .keyword),
            Span("\"say \\\"hi\\\"\"", .string),
            Span("# quoted", .comment),
            Span("KEY", .keyword),
            Span("\"-----BEGIN\nabc\n-----END\"", .string),
            Span("NEXT", .keyword),
            Span("'single # not a comment'", .string)
        ])
    }

    @Test("only a quote that opens a value opens a string")
    func apostropheInsideAValue() {
        #expect(dotenv("NAME=don't\nOTHER=1") == [
            Span("NAME", .keyword),
            Span("don't", .string),
            Span("OTHER", .keyword),
            Span("1", .string)
        ])
    }

    @Test("a line that is not KEY=value stays in the text color")
    func notAnAssignment() {
        #expect(dotenv("just some text\n=value\nexport\n").isEmpty)
    }

    @Test(".env handling survives CRLF, and an unclosed quote runs to the end")
    func dotenvEdges() {
        #expect(dotenv("A=1\r\nB=2\r\n") == [
            Span("A", .keyword),
            Span("1", .string),
            Span("B", .keyword),
            Span("2", .string)
        ])
        #expect(dotenv("A=\"open\nB=2") == [Span("A", .keyword), Span("\"open\nB=2", .string)])
        #expect(SyntaxHighlighter.tokens(in: "", language: .dotenv).isEmpty)
    }
}
