# Security Policy

MCV handles web content, local browser state and extension code. Treat security reports as engineering reports, not launch announcements.

## Report privately

Do not open a public issue for vulnerabilities involving code execution, permission bypass, path traversal, profile data, credentials or active exploits. Contact the repository owner privately and include:

- the affected MCV revision and macOS version;
- exact reproduction steps;
- the expected and observed security boundary;
- a minimal proof of concept where safe;
- whether user interaction is required.

Do not include real credentials, cookies or third-party private data.

## Supported version

Only the current main branch is supported during pre-release development. Security fixes may not be backported.

## Boundaries

- Web pages are untrusted.
- Extension JavaScript is untrusted even after installation.
- Native permission checks are authoritative; JavaScript shims are not.
- Private tabs must not enter persistent semantic memory.
- MCV does not bypass CAPTCHAs, anti-bot systems or access controls.

Public WebKit limitations are documented as limitations. They are never silently relabelled as security features.
