import Foundation
import RegexBuilder

extension Redactor {
    /// Compiled patterns. `Regex` is an immutable value type but is not declared `Sendable`,
    /// so this container vouches for it: nothing here is ever mutated after initialization.
    struct Patterns: @unchecked Sendable {
        /// Any of the three line terminators, CRLF first so it is never split in half.
        let lineSeparator = #/\r\n|\n|\r/#
        /// Shared scalar grammar also owns bounded cross-record control state.
        let terminalEscape = TerminalControlGrammar.escape
        /// The continuation of a folded header: leading whitespace (folding requires it) and
        /// anything at all after it.
        let foldedContinuation = #/\s+\S.*/#
        /// A line that opens with a header field name and its colon. Used the other way round
        /// from the rules here: a line that matches is the *next header*, and everything else
        /// standing unindented under a bare authorization label is that label's value.
        let headerLabelStart = #/^\s*(?:\\*["'])?[A-Za-z0-9][A-Za-z0-9-]*(?:\\*["'])?\s*:/#
        /// A PEM header. RFC 7468 labels are not only upper-case letters and spaces: they carry
        /// hyphens, digits, and dots (`ACME-PRIVATE KEY`, `X9.42 DH PARAMETERS`), and a label
        /// this rule cannot spell leaves the block, header and key material alike, in the clear.
        /// The label is matched lazily and has to end on an alphanumeric, so it can never eat
        /// the closing dashes and a second block on the same line stays its own match.
        let pemBegin = #/-----BEGIN ([A-Za-z0-9](?:[A-Za-z0-9 ._+-]*?[A-Za-z0-9])?)-----/#
        /// The whole header value, quoted or to the end of the line, so multi-parameter schemes
        /// (Digest, AWS SigV4) leave nothing behind. The key may be quoted the way JSON, a
        /// Python dictionary, or a JSON string embedded in a log line quotes it.
        /// The same match determines continuation state before replacement. An empty value
        /// arms the next line even when a logger prefixes or quotes the field name.
        let authorizationHeader = #/(^|[^A-Za-z0-9])(?:\\*["'])?(?:(?:(?:proxy|request)[ _-]?)?authorization|(?:(?:set|request)[ _-]?)?cookies?)(?:\\*["'])?\s*[:=]\s*("(?:[^"\\]|\\.)*"(?=$|[\s,;\]})>])|'(?:[^'\\]|\\.)*'(?=$|[\s,;\]})>])|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length. Every token and label rule
        /// here starts at a character that cannot be part of the word rather than at `\b`:
        /// Swift's word boundary is the Unicode one, where the dot in `<token>.partial`, in
        /// `cache.<token>`, or in `payload.Authorization` is not a break, and a secret beside
        /// one would survive. The character is captured so it can be put back. A label may also
        /// start after an underscore, which names most of them: `refresh_token`, `access_token`.
        let bearer = #/(^|[^A-Za-z0-9])(bearer\s+[A-Za-z0-9._~+\/=-]+)/#.ignoresCase()
        /// A standalone authentication value can reach decoded diagnostics without its header
        /// name. Basic is recognized only when the Base64 decodes to a user/password separator;
        /// Digest must start with an authentication parameter assignment, not ordinary prose.
        private static var basicValue: Regex<(Substring, Substring, Substring)> {
            #/(basic[ \t]+)([A-Za-z0-9+\/]{2,}={0,2})(?![A-Za-z0-9+\/=])/#
        }
        let basicCredentialSpan = basicValue.ignoresCase()
        let basicAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            basicValue
        }.ignoresCase()
        private static var digestValue: Regex<Substring> {
            #/digest[ \t]+(?=(?:username\*?|realm|nonce|uri|response|algorithm|cnonce|opaque|qop|nc|userhash)\s*=)[^\r\n]+/#
        }
        let digestCredentialSpan = digestValue.ignoresCase()
        let digestAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            digestValue
        }.ignoresCase()
        /// Distinctive integrated-auth blobs and signed AWS requests remain recognizable after
        /// their header name is lost. Ordinary scheme-name prose alone is not a credential.
        private static var specializedValue: Regex<Substring> {
            #/(?:ntlm|negotiate)[ \t]+[A-Za-z0-9+\/_-]{8,}={0,2}|aws4-hmac-sha256[ \t]+(?=(?:credential|signedheaders|signature)\s*=)[^\r\n]+/#
        }
        let specializedCredentialSpan = specializedValue.ignoresCase()
        let specializedAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            specializedValue
        }.ignoresCase()
        /// Classic and fine-grained GitHub tokens. Nothing at all is required in front of the
        /// prefix, not even a delimiter: an untrusted file, branch, or cache name is glued
        /// straight onto a token by concatenation, and `artifactghp_...` carried a complete
        /// usable credential through a rule that only tolerated `artifact_ghp_...`. These
        /// prefixes are the reason it is safe to drop the boundary here — text that ends in
        /// `ghp`, `ghs`, or `github_pat` immediately before twenty alphanumerics is far rarer
        /// than the concatenation. The API-key rule below keeps its boundary, because `sk-` is
        /// three ordinary letters and dropping it there would redact `risk-averse-...`.
        /// Even a short fragment is sensitive once its distinctive prefix is present.
        let githubToken = #/(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]*|github_pat_[A-Za-z0-9_]*/#
        /// At line end a boundary-delimited bare `sk-` conservatively arms wrapped-key redaction.
        let wrappedTokenAtLineEnd = #/(?:^|[^A-Za-z0-9]|(?=(?:ghp|gho|ghu|ghs|ghr)_|github_pat_|sk-(?:proj|svcacct|ant)-))((?:ghp|gho|ghu|ghs|ghr)_|github_pat_|sk-(?:(?:proj|svcacct|ant)-)?)[A-Za-z0-9_-]*$/#
        let tokenContinuation = #/^[ \t]*[A-Za-z0-9_-]+/#
        /// Distinctive project/provider prefixes survive filename concatenation. A generic
        /// `sk-` still needs its boundary so ordinary hyphenated words such as `risk-averse`
        /// remain intact.
        let apiKey = #/(^|[^A-Za-z0-9]|(?=sk-(?:proj|svcacct|ant)-))(sk-(?:[A-Za-z0-9_-]{16,}|[A-Za-z0-9_-]*$))/#
        let distinctiveAPIKey = #/sk-(?:proj|svcacct|ant)-[A-Za-z0-9_-]*/#
        /// JSON Web Tokens, matched structurally: Base64URL segments (the last may be empty) of
        /// which one decodes to a JSON object, whitespace allowed. More than three segments are
        /// taken because a JWT can follow a label, as in `session.<jwt>`.
        let jwt = #/(^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*){2,})/#
        /// Credentials embedded in URLs: `https://user:secret@host`. The authority ends at the
        /// last `@` before a slash or whitespace, so a password containing `@` is fully covered.
        /// It also ends at `?` and `#`, which end an authority exactly as `/` does (RFC 3986):
        /// without them `https://example.com?email=user@example.org` reads its query's `@` as
        /// userinfo and rewrites a legitimate link into `https://[redacted:userinfo]@example.org`.
        /// Nothing that is really userinfo is lost, because a `?` inside one has to be
        /// percent-encoded for the text to be a URL at all.
        /// A URL that reached a log through JSON keeps that encoding's escaped slashes.
        /// A network-path reference can omit the scheme (`//user:secret@host`). Its leading
        /// delimiter must start a value, so doubled slashes inside a path or URL query do not
        /// turn an ordinary `@` later in that value into userinfo.
        /// Assignment names may include a command option's leading one or two dashes.
        private static var urlAuthorityPrefix: Regex<(Substring, Substring)> {
            // Scan the existing record; no escape-depth buffer is retained. A depth cap
            // here would leave deeper encodings unmatched and expose their credentials.
            #/((?::|^|[\s"'(<\[{]|(?:^|[\s"'(<\[{])(?:--?)?[A-Za-z][A-Za-z0-9_.-]*[ \t]*=[ \t]*)(?:\\*\/){2})/#
        }
        let urlUserInfo = Regex {
            urlAuthorityPrefix
            #/[^\s\/?#]+@/#
        }
        let partialURLAuthority = #/(?:^|[\s"'(<\[{])(?:(?:--?)?[A-Za-z][A-Za-z0-9_.-]*[ \t]*=[ \t]*)?(?:[A-Za-z][A-Za-z0-9+.-]*:(?:\\*\/)?|\\*\/)$/#
        let incompleteURLUserInfo = Regex {
            urlAuthorityPrefix
            #/(?!\[)[^\s\/?#@]*$/#
        }
        /// `password: hunter2`, `passphrase=...`, `token=...`, `secret: "..."`, `"api_key":"..."`,
        /// and the camel-case keys structured diagnostics use: `accessToken`, `refreshToken`,
        /// `clientSecret`. Those need a name in front of the label word, and the names come from
        /// a closed list so that an ordinary word ending in `token` or `secret` is still not a
        /// label. The key is quoted the way JSON, a Python dictionary, or a JSON string embedded
        /// in a log line quotes it. An unquoted value runs to the end of the line rather than to
        /// the first space, because a passphrase is words: `password: correct horse battery`. It
        /// still has to start with one non-space character, so a bare label falls to the rule
        /// below and arms the next line instead of matching an empty value here.
        /// One vocabulary shared by inline fields, bare labels, and command options.
        /// Explicit private-key labels are sensitive even when the value is not PEM.
        private static var secretName: Regex<Substring> {
            #/(?:(?:access|refresh|auth|client|app|session|user|bearer|private|shared|signing|master|id|current|new|old|previous|confirm|confirmation)[ _-]?)?(?:password|passphrase|passwd|secret|token|credentials?|api[ _-]?key|private[ _-]?key|secret[ _-]?key|secret[ _-]?access[ _-]?key|access[ _-]?key[ _-]?secret)/#
        }
        private static var secretLabel: Regex<(Substring, Substring, Substring)> {
            Regex {
                #/(^|[^A-Za-z0-9])(?:\\*["'])?/#
                Capture { secretName }
                #/(?:\\*["'])?\s*[:=]\s*/#
            }
        }
        // A quote only bounds the value at a real sibling/whitespace boundary. Adjacent
        // fragments remain in the conservative unquoted-value alternative below.
        let labeledSecret = Regex {
            secretLabel
            Capture {
                #/"(?:[^"\\]|\\.)*"(?=$|[\s,;\]})>])|'(?:[^'\\]|\\.)*'(?=$|[\s,;\]})>])|\S[^\r\n]*/#
            }
        }.ignoresCase()
        /// The same labels with nothing after the delimiter: CLI and pretty-printed output puts
        /// the value on the next line.
        let secretLabelOnly = Regex {
            secretLabel
            Anchor.endOfSubject
        }.ignoresCase()
        /// The same secret named as a command-line option, which CLI diagnostics echo back
        /// verbatim: `--password hunter2`, `--github-token opaqueCredential`. There is no `:`
        /// or `=` to key on, so the leading dash is what makes this a secret rather than the
        /// word `token` in a sentence. The value is one argv word, or a quoted one, rather than
        /// the rest of the line: an echoed command line carries the options after it, and
        /// `--token abc --verbose` must keep its second option.
        private static var credentialOptionName: Regex<Substring> {
            Regex { ChoiceOf { secretName; #/(?:device|user)[_-]?codes?/# } }
        }
        let secretOption = Regex {
            #/(^|[\s\u{001F}"'\[({<:=\u{0060},;])/#
            Capture {
                #/--?[A-Za-z0-9_-]*/#
                credentialOptionName
            }
            #/([ \t]+|=)(?=\S)/#
        }.ignoresCase()
        let secretOptionOnly = Regex {
            #/(^|[\s\u{001F}"'\[({<:=\u{0060},;])--?[A-Za-z0-9_-]*/#
            credentialOptionName
            #/[ \t]*(?:=[ \t]*)?$/#
        }.ignoresCase()
        /// JSON/Python-style argv diagnostics retain the option as a quoted array element.
        /// Its value is the next element, possibly on a later line.
        let serializedSecretOption = Regex {
            #/(?:\\*["'])--?[A-Za-z0-9_-]*/#
            credentialOptionName
            #/(?:\\*["'])[ \t]*,[ \t]*/#
        }.ignoresCase()
        /// The explicit code fields of an OAuth device flow. Their values are opaque and their
        /// shape is the provider's choice, so the whole value goes, not just a `XXXX-XXXX` one,
        /// and an unquoted one runs to the end of the line the way a labeled secret's does.
        let codeField = #/(^|[^A-Za-z0-9])(?:\\*["'])?((?:user|device)[ _-]?codes?)(?:\\*["'])?\s*[:=]\s*("(?:[^"\\]|\\.)*"(?=$|[\s,;\]})>])|'(?:[^'\\]|\\.)*'(?=$|[\s,;\]})>])|\S[^\r\n]*)/#.ignoresCase()
        /// The prose a CLI prints when it wants a code typed in — `Your one-time code is: …` —
        /// with the value on the same line. The value is as opaque as a field's, so all of it
        /// goes whatever its shape. The code has to be named: a line that merely contains the
        /// word, such as `process exited with code 1`, is a diagnostic, not a prompt. The
        /// `user_code` and `device_code` fields keep their own rule above, which keeps the field
        /// name in the output, so they are deliberately absent here.
        /// Imperative prompts can also delimit their opaque value with a colon or equals.
        /// Up to two instruction words may follow `code`, as in `code shown below:`.
        let codePrompt = #/((?:^|[^A-Za-z0-9])(?:\\*["'])?(?:(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access)[ _-]?codes?(?:\\*["'])?(?:\s+(?!\[redacted:)\S+){0,2}?|(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?(?:\s+(?!\[redacted:)\S+){0,2}?)\s*[:=]|^\s*codes?\s*[:=])\s*(?:"(?:[^"\\]|\\.)*"(?=$|[\s,;\]})>])|'(?:[^'\\]|\\.)*'(?=$|[\s,;\]})>])|\S[^\r\n]*)/#.ignoresCase()
        /// The same prompt with nothing after the delimiter: the value is on the next line. The
        /// device-flow field names are included, because arming the next line has no output whose
        /// shape has to be kept. A line that is nothing but `code:` is a prompt too — there is
        /// nothing else on it for the word to belong to.
        let codePromptOnly = #/(?:(?:^|[^A-Za-z0-9])(?:\\*["'])?(?:(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\\*["'])?(?:\s+(?!\[redacted:)\S+){0,2}?|(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?(?:\s+(?!\[redacted:)\S+){0,2}?)|^\s*codes?)\s*[:=]\s*$|(?:^|[^A-Za-z0-9])(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?\s*$/#.ignoresCase()
        /// Device codes such as `1A2B-3C4D` and the `WDJB.MJHT` an RFC 8628 provider may print:
        /// runs of four to eight upper-case characters joined by single separators. Applied only
        /// on lines that mention a code (including the `user_code` and `device_code` field names
        /// of OAuth device flows), and never when the match is part of a longer hyphenated or
        /// dotted identifier such as a UUID or a reverse-DNS name.
        let mentionsCode = #/\b(?:codes?|(?:user|device)[_-]code)\b/#.ignoresCase()
        /// The trailing exclusion covers a dot that continues the identifier as well as a letter,
        /// a digit, or a hyphen: without it `ABCD-EFGH.example.com` becomes
        /// `[redacted:device-code].example.com`, which is the longer dotted identifier this rule
        /// says it leaves alone. A dot that ends a sentence is not one, so `your code: AB12-CD34.`
        /// still loses its code.
        let deviceCode = #/(^|[^A-Za-z0-9.-])([A-Z0-9]{4,8}(?:[-.][A-Z0-9]{4,8}){1,3})(?![A-Za-z0-9-]|\.[A-Za-z0-9])/#
        /// A prompt that names the code with no delimiter at all: `Enter the code ABC123 at the
        /// URL shown` is the prose an RFC 8628 provider prints, and only a value that happens to
        /// have the dotted or hyphenated shape above was removed from it. Two forms qualify: the
        /// imperative one, which asks for the code, and a historical declaration with a copula.
        /// Present-tense declarations also have the opaque-value rule below. Here a value has
        /// to look like a code rather than
        /// like the next English word: four or more alphanumerics across groups that are
        /// upper-case or carry a digit. `process exited with code 1`, `Enter the code shown
        /// below`, and `the login code was rejected` are all left alone. The words are matched
        /// without regard to case; the value's own alternatives are not, or every lower-case
        /// word after the label would be a code.
        let codePromptWithoutDelimiter = Regex {
            #/((?:^|[^A-Za-z0-9])(?:(?i:(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?)|(?i:(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\s+(?:is|are|was|were|reads|equals))+)))/#
            #/\s+/#
            TryCapture {
                #/(?:[A-Z0-9._-]+|[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]*)(?![A-Za-z0-9._-])(?:[ \t]+(?:[A-Z0-9._-]+|[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]*)(?![A-Za-z0-9._-]))*/#
            } transform: { value -> Substring? in
                // Providers may group a six-digit code as 123 456. Validate the total
                // candidate, not each group; short diagnostic fragments remain visible.
                value.lazy.filter { $0.isLetter || $0.isNumber }.prefix(4).count == 4 ? value : nil
            }
        }
        /// Present-tense declarations explicitly supply the code. Lowercase, short, and
        /// quoted values are opaque. Historical status prose keeps the conservative rule above.
        /// Encoded quotes span the remaining line; the value scanner preserves their suffix.
        /// A copula may end in a delimiter; without one, whitespace still bounds the word.
        /// Empty delimited declarations belong to `codePromptOnly` and keep their prompt text.
        /// Spaces can group an opaque code; a comma or semicolon bounds following prose.
        let declarativeCodePrompt = #/((?:^|[^A-Za-z0-9])(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?\s+(?:is|are|reads|equals)(?:\s*[:=](?=\s*\S)|(?=\s|$)(?!\s*[:=])))(?:\s*("(?:[^"\\]|\\.)*"(?=$|[\s,;\]})>])|'(?:[^'\\]|\\.)*'(?=$|[\s,;\]})>])|\\+["'][^\r\n]*|[^,;\r\n]+)|\s*$)/#.ignoresCase()
    }

    static let patterns = Patterns()
}
