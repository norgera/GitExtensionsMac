# Security Policy

## Supported Version

Only the latest publicly released version of GitExtensionsMac receives security updates.

## Reporting a Vulnerability

Functional defects with no security impact are regular application bugs and should be reported through [GitHub Issues](https://github.com/norgera/GitExtensionsMac/issues).

Use the [GitHub private vulnerability reporting form](https://github.com/norgera/GitExtensionsMac/security/advisories/new) for security vulnerabilities that could allow an attacker to execute unauthorized code or commands, access information they should not have access to, or otherwise compromise the security of the system through GitExtensionsMac.

GitExtensionsMac runs the Git executable installed on your Mac. Behavior that Git itself provides, such as running a repository's hooks or applying its configuration, is not a GitExtensionsMac vulnerability unless GitExtensionsMac causes it in a way Git would not. Vulnerabilities in Git should be reported to the [Git project](https://git-scm.com/community).

A report should include the affected GitExtensionsMac version, a description of the vulnerability and how it can be exploited, its potential impact, and the steps required to reproduce it.

Reports will be reviewed as soon as possible. GitExtensionsMac is developed in spare time, so no specific response or resolution timeframe can be guaranteed.
