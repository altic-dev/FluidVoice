# Security Policy

FluidVoice welcomes reports that help protect its users, their data, and their devices. Please report suspected vulnerabilities privately so we can investigate, fix, and coordinate disclosure responsibly.

## Supported Versions

| Version | Supported |
| --- | --- |
| Latest stable release published from this repository | Yes |
| Current `main` branch | Yes |
| Beta, prerelease, and older releases | No |

If an issue affects an unsupported version, please still report it if you can reproduce it on a supported version or believe it materially affects users of the current release.

## Report a Vulnerability Privately

Use GitHub's private vulnerability-reporting form for this repository:

1. Open the repository's **Security & quality** page.
2. Select **Report a vulnerability**.
3. Submit the report through the GitHub Security Advisory (GHSA) form.

**Do not** report suspected vulnerabilities in public GitHub issues, pull requests, Discussions, Discord, social media, or release comments. Do not include real API keys, private audio, transcribed text, personal data, or other third-party data in a report. Redact sensitive material and provide a minimal proof of concept whenever possible.

A private report should include:

- A clear description of the issue and its potential impact.
- The affected FluidVoice version, macOS version, and hardware architecture.
- Reproduction steps and a minimal proof of concept.
- Any relevant configuration, logs, screenshots, or recordings, with sensitive data removed.
- Suggested mitigations or fixes, if available.
- Whether and how you would like to be credited if an advisory is published.

## Scope

This policy covers vulnerabilities in the FluidVoice source code and official releases published from this repository, including:

- Microphone, Accessibility, Apple Events, and other permission or privilege boundaries.
- Dictation, text insertion, command execution, and local API behavior.
- Storage and handling of provider credentials, audio, transcripts, history, analytics, and other user data.
- Optional cloud-AI integration, where FluidVoice's handling of requests, credentials, or data is affected.
- Update, release, code-signing, build, CI, and repository automation paths controlled by this project.

Third-party services, operating systems, package dependencies, model providers, and cloud-AI providers are outside this policy when the issue is solely in that third party. Please report those issues to the relevant vendor. If a third-party issue materially affects FluidVoice, report it privately here as well so we can assess mitigations for FluidVoice users.

## Good-Faith Research

We support good-faith security research conducted only on systems, accounts, data, and copies of the application that you own or are explicitly authorized to test. To the extent permitted by applicable law, we consider research that follows this policy to be authorized.

Please:

- Avoid privacy violations, service disruption, and destruction or modification of data.
- Stop testing and report promptly if you encounter data that is not yours.
- Use an exploit only as far as needed to demonstrate the vulnerability.
- Give maintainers a reasonable opportunity to investigate and remediate before public disclosure.

The following are not authorized under this policy:

- Denial-of-service, load, or stress testing that could impair services or users.
- Social engineering, phishing, physical attacks, or attacks on third-party systems.
- Accessing, exfiltrating, modifying, deleting, or retaining data that is not yours.
- Establishing persistence, escalating access beyond what is needed for a minimal proof of concept, or pivoting to other systems.
- Automated high-volume testing or scanning against project infrastructure without prior written permission.

## What to Expect

For reports submitted through the private GHSA form, maintainers aim to:

- Acknowledge receipt within **3 business days**.
- Provide an initial triage assessment within **7 business days**.
- Share material status updates at least every **14 days** while remediation is active, when contact information is available.
- Coordinate public disclosure after a fix or effective mitigation is available, normally through a GitHub Security Advisory and release notes.

Resolution timelines depend on severity, reproducibility, affected users, and availability of a safe fix. Please do not publish exploit details or disclose the issue publicly while coordinated remediation is in progress.

## Recognition and Rewards

FluidVoice does not operate a bug-bounty program and does not offer monetary rewards for vulnerability reports. With your permission, maintainers may credit you in a published security advisory or release notes.

## Policy Updates

This policy may be updated as FluidVoice's security processes and supported release channels evolve.
