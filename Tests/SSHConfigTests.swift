import Testing
@testable import Conterm

/// The parser's contract is `ssh -G`: whatever OpenSSH would resolve for an
/// alias is what we must resolve. These pin the rules that are easy to get
/// subtly wrong — and that Conterm's Mac parser skipped, because
/// `/usr/bin/ssh` was doing the resolution for it.
struct SSHConfigTests {

    @Test("wildcard blocks supply defaults to concrete hosts")
    func wildcardDefaults() {
        let result = SSHConfig.parse("""
        Host *
          User deploy
          Port 2222

        Host web-01
          Hostname 10.0.0.4
        """)
        #expect(result.hosts.count == 1)
        let host = result.hosts[0]
        #expect(host.alias == "web-01")
        #expect(host.hostname == "10.0.0.4")
        #expect(host.user == "deploy")
        #expect(host.port == 2222)
    }

    @Test("first obtained value wins, not the last")
    func firstValueWins() {
        // This is the rule people most often assume is the other way round.
        let result = SSHConfig.parse("""
        Host web-01
          Port 2222

        Host *
          Port 22
        """)
        #expect(result.hosts.first?.port == 2222)
    }

    @Test("a negated pattern excludes a host from a wildcard block")
    func negation() {
        let result = SSHConfig.parse("""
        Host * !jump
          User deploy

        Host jump
          Hostname jump.example.com
        Host web
          Hostname web.example.com
        """)
        let jump = result.hosts.first { $0.alias == "jump" }
        let web = result.hosts.first { $0.alias == "web" }
        #expect(jump?.user == nil)
        #expect(web?.user == "deploy")
    }

    @Test("wildcard aliases never appear as hosts of their own")
    func wildcardsAreNotHosts() {
        let result = SSHConfig.parse("""
        Host *.internal
          User ops
        Host db-01.internal
          Hostname 10.0.0.9
        """)
        #expect(result.hosts.map(\.alias) == ["db-01.internal"])
        #expect(result.hosts[0].user == "ops")
    }

    @Test("Match blocks are skipped, not attributed to the previous Host")
    func matchBlocksSkipped() {
        let result = SSHConfig.parse("""
        Host web-01
          Hostname 10.0.0.4

        Match host nothing
          User wrong
        """)
        #expect(result.hosts.first?.user == nil)
    }

    @Test("keywords are case-insensitive and accept = as a separator")
    func lexing() {
        let result = SSHConfig.parse("""
        HOST web-01
          HostName=10.0.0.4
          port = 2200
        """)
        #expect(result.hosts.first?.hostname == "10.0.0.4")
        #expect(result.hosts.first?.port == 2200)
    }

    @Test("comments are stripped, but not inside quotes")
    func comments() {
        let result = SSHConfig.parse("""
        # a leading comment
        Host web-01
          Hostname 10.0.0.4   # trailing
          ProxyJump "bastion # 1"
        """)
        #expect(result.hosts.first?.hostname == "10.0.0.4")
        #expect(result.hosts.first?.proxyJump == "bastion # 1")
    }

    @Test("IdentityFile accumulates while everything else takes the first")
    func identityFilesAccumulate() {
        let result = SSHConfig.parse("""
        Host web-01
          IdentityFile ~/.ssh/id_ed25519
          IdentityFile ~/.ssh/id_rsa
        """)
        #expect(result.hosts.first?.identityFiles.count == 2)
    }

    @Test("ProxyJump none means no jump host")
    func proxyJumpNone() {
        let result = SSHConfig.parse("""
        Host web-01
          ProxyJump none
        """)
        #expect(result.hosts.first?.proxyJump == nil)
    }

    @Test("an unfollowable Include is reported rather than silently dropped")
    func unresolvedIncludesReported() {
        // Without a base directory there is nothing to resolve against. The
        // import screen needs to be able to say so — quietly losing half
        // someone's fleet is the worst possible outcome here.
        let result = SSHConfig.parse("""
        Include config.d/*
        Host web-01
          Hostname 10.0.0.4
        """)
        #expect(result.unresolvedIncludes == ["config.d/*"])
        #expect(result.hosts.count == 1)
    }

    @Test("glob matching handles the patterns ssh actually uses",
          arguments: [
            ("*", "anything", true),
            ("web-*", "web-01", true),
            ("web-*", "db-01", false),
            ("*.internal", "db.internal", true),
            ("web-0?", "web-01", true),
            ("web-0?", "web-011", false),
            ("*-*-*", "a-b-c", true),
          ])
    func globMatching(pattern: String, candidate: String, expected: Bool) {
        #expect(SSHConfig.matches(pattern: pattern, candidate) == expected)
    }
}
